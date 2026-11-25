import SwiftUI
import UIKit

/// Native iOS 27.2 local-first Multi-Profile Switcher and Studio entry point.
/// Uses a single root `NavigationStack` with `.insetGrouped` lists and semantic
/// colors so Light Mode, Dark Mode, and iPhone Duo's 84 pt vertical bar work
/// natively with zero glass-on-content clutter.
struct CuriumProfileSwitcherSheet: View {
    let browserStore: CuriumBrowserStore?
    var fingerprintStore: CuriumFingerprintStore
    var onSelectionChanged: (() -> Void)?

    init(
        browserStore: CuriumBrowserStore? = nil,
        fingerprintStore: CuriumFingerprintStore = .shared,
        onSelectionChanged: (() -> Void)? = nil
    ) {
        self.browserStore = browserStore
        self.fingerprintStore = fingerprintStore
        self.onSelectionChanged = onSelectionChanged
    }

    private enum Route: Hashable {
        case editProfile(String)
    }

    private enum SwitcherDialog: Identifiable {
        case switchHandoff(CuriumFingerprintProfile)
        case wipeProfile(CuriumFingerprintProfile)
        case deleteProfile(CuriumFingerprintProfile)

        var id: String {
            switch self {
            case .switchHandoff(let profile): return "switch:\(profile.id)"
            case .wipeProfile(let profile): return "wipe:\(profile.id)"
            case .deleteProfile(let profile): return "delete:\(profile.id)"
            }
        }

        var title: String {
            switch self {
            case .switchHandoff(let profile):
                return "Switch to \(profile.displayName)?"
            case .wipeProfile(let profile):
                return "Wipe Data for \(profile.displayName)?"
            case .deleteProfile(let profile):
                return "Delete \(profile.displayName)?"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var navigationPath: [Route] = []
    @State private var engineStatus: CuriumEngineFingerprintStatus?
    @State private var engineCapabilities: CuriumEngineFingerprintCapabilities?
    @State private var usageByProfileID: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
    @State private var orphanedSlugs: [String] = []
    @State private var orphanUsageBySlug: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
    @State private var showingCreateSheet = false
    @State private var showingImportSheet = false
    @State private var pendingCreatedProfile: CuriumFingerprintProfile?
    @State private var activeDialog: SwitcherDialog?
    @State private var pendingShareDocument: CuriumShareDocument?
    @State private var wipingTargetID: String?
    @State private var isRelaunching = false
    @State private var copiedToastID: String?
    @State private var alertMessage: String?
    @State private var usageTask: Task<Void, Never>?
    @State private var copiedToastTask: Task<Void, Never>?

    private var isWiping: Bool { wipingTargetID != nil }

    private var activeProfileID: String {
        browserStore?.activeProfileID ?? fingerprintStore.activeLaunchProfileID
    }

    private var activeProfile: CuriumFingerprintProfile {
        fingerprintStore.profile(id: activeProfileID) ?? fingerprintStore.activeProfile
    }

    private var nextLaunchProfile: CuriumFingerprintProfile {
        fingerprintStore.nextLaunchProfile
    }

    private var hasPendingProfileIDSwitch: Bool {
        fingerprintStore.nextLaunchProfileID.lowercased() != activeProfileID.lowercased()
    }

    private var hasPendingActiveEngineRestart: Bool {
        !hasPendingProfileIDSwitch && fingerprintStore.hasPendingActiveProfileEngineChanges
    }

    private var supportsHotSwap: Bool {
        browserStore?.canHotSwapProfile == true
    }

    private var hasPendingSwitch: Bool {
        hasPendingProfileIDSwitch || hasPendingActiveEngineRestart
    }

    private func isActiveProfile(_ profile: CuriumFingerprintProfile) -> Bool {
        profile.id.lowercased() == activeProfileID.lowercased()
    }

    private func isNextLaunchProfile(_ profile: CuriumFingerprintProfile) -> Bool {
        profile.id.lowercased() == fingerprintStore.nextLaunchProfileID.lowercased()
            && !isActiveProfile(profile)
    }

    private func isActiveInProcess(_ profileID: String) -> Bool {
        profileID.lowercased() == activeProfileID.lowercased()
            || CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(profileID)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if let loadError = fingerprintStore.loadError {
                    corruptStoreSection(loadError)
                } else {
                    livePrivacySection
                }

                profilesSection

                if hasPendingSwitch {
                    pendingSwitchSection
                }

                if !orphanedSlugs.isEmpty {
                    orphanedStorageSection
                }

                engineSummarySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWiping || isRelaunching)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }
                    .disabled(isWiping || isRelaunching || fingerprintStore.loadError != nil)
                    .accessibilityIdentifier("curium.profiles.new")

                    Menu {
                        Button {
                            showingImportSheet = true
                        } label: {
                            Label("Import Profile JSON…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isWiping || isRelaunching || fingerprintStore.loadError != nil)

                        Button {
                            refreshEngineInfo()
                            scheduleRefreshUsage()
                        } label: {
                            Label("Refresh Storage", systemImage: "arrow.clockwise")
                        }
                        .disabled(isWiping || isRelaunching)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .disabled(isWiping || isRelaunching)
                    .accessibilityIdentifier("curium.profiles.more")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .disabled(isWiping || isRelaunching)
                    .accessibilityIdentifier("curium.profiles.done")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .editProfile(let profileID):
                    if let profile = fingerprintStore.profile(id: profileID) {
                        CuriumFingerprintEditorView(
                            store: fingerprintStore,
                            initialProfile: profile,
                            isActiveInProcess: isActiveInProcess(profile.id),
                            usage: usageByProfileID[profile.id],
                            onDuplicateToEdit: { copy in
                                navigationPath = [.editProfile(copy.id)]
                                scheduleRefreshUsage(onlyProfileIDs: [copy.id])
                            },
                            onSaved: { saved in
                                onSelectionChanged?()
                                scheduleRefreshUsage(onlyProfileIDs: [saved.id])
                            },
                            onSelectionChanged: {
                                onSelectionChanged?()
                            },
                            onWiped: {
                                usageByProfileID[profile.id] = CuriumFingerprintProfileStorage.UsageSnapshot(
                                    supportBytes: 0,
                                    cacheBytes: 0,
                                    exists: false
                                )
                                scheduleRefreshUsage(onlyProfileIDs: [profile.id])
                            }
                        )
                    } else {
                        missingProfileView(id: profileID)
                    }
                }
            }
        }
        .task {
            refreshEngineInfo()
            scheduleRefreshUsage()
        }
        .onDisappear {
            usageTask?.cancel()
            usageTask = nil
            copiedToastTask?.cancel()
            copiedToastTask = nil
        }
        .sheet(
            isPresented: $showingCreateSheet,
            onDismiss: {
                if let created = pendingCreatedProfile {
                    pendingCreatedProfile = nil
                    activeDialog = .switchHandoff(created)
                }
            }
        ) {
            CuriumCreateProfileSheet(fingerprintStore: fingerprintStore) { created in
                pendingCreatedProfile = created
                scheduleRefreshUsage(onlyProfileIDs: [created.id])
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            CuriumProfileImportSheet(store: fingerprintStore) { imported in
                scheduleRefreshUsage(onlyProfileIDs: [imported.id])
                navigationPath.append(.editProfile(imported.id))
            }
        }
        .sheet(item: $pendingShareDocument) { doc in
            CuriumActivityShareSheet(text: doc.text)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            activeDialog?.title ?? "",
            isPresented: Binding(
                get: { activeDialog != nil },
                set: { if !$0 { activeDialog = nil } }
            ),
            titleVisibility: .visible,
            presenting: activeDialog
        ) { dialog in
            switch dialog {
            case .switchHandoff(let profile):
                Button(supportsHotSwap ? "Switch Now" : CuriumProfileRelauncher.primaryRelaunchButtonTitle) {
                    Task {
                        await performSwitchAndRelaunch(to: profile.id)
                    }
                }
                .disabled(isWiping || isRelaunching)

                if !supportsHotSwap {
                    Button("Switch on Next Launch") {
                        selectForNextLaunch(profile)
                    }
                    .disabled(isWiping || isRelaunching)
                }

                Button("Cancel", role: .cancel) {}

            case .wipeProfile(let profile):
                Button("Wipe Cookies, Bookmarks & Storage", role: .destructive) {
                    wipeProfileStorage(profile)
                }
                .disabled(isWiping || isRelaunching)
                Button("Cancel", role: .cancel) {}

            case .deleteProfile(let profile):
                if !profile.isPrimaryDefault && !isActiveInProcess(profile.id) {
                    Button("Delete Profile & Wipe Data", role: .destructive) {
                        deleteProfileAndWipe(profile)
                    }
                    .disabled(isWiping || isRelaunching)
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { dialog in
            switch dialog {
            case .switchHandoff(let profile):
                if supportsHotSwap {
                    Text(
                        "Saves open tabs and library for \(activeProfile.displayName), pauses active downloads, and switches straight to \(profile.displayName) without restarting Curium."
                    )
                } else {
                    Text(
                        CuriumProfileRelauncher.switchHandoffDescription(
                            activeProfileName: activeProfile.displayName,
                            targetProfileName: profile.displayName
                        )
                    )
                }

            case .wipeProfile(let profile):
                Text(
                    "Permanently clears isolated cookies, site data, cache, bookmarks, history, and saved tabs for \"\(profile.displayName)\". The profile persona and fingerprint settings are kept."
                )

            case .deleteProfile(let profile):
                if isActiveInProcess(profile.id) {
                    Text(
                        "\"\(profile.displayName)\" is currently active in this running session. Switch to another profile and relaunch Curium before deleting it."
                    )
                } else {
                    Text(
                        "Permanently deletes \"\(profile.displayName)\", wipes all of its isolated browser data, and retires its storage identifier so it can never be reused."
                    )
                }
            }
        }
        .alert("Profiles", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Sections

    private var livePrivacySection: some View {
        let hardened = activeProfile.isPrivacyHardeningEnabled
        let hotSupported = engineCapabilities?.supportsHotRuntimePrivacyPolicy
            ?? CuriumFingerprintBootstrap.engineCapabilities().supportsHotRuntimePrivacyPolicy
        return Section {
            Toggle(isOn: Binding(
                get: { activeProfile.isPrivacyHardeningEnabled },
                set: { enabled in
                    if fingerprintStore.setActiveProfilePrivacyHardening(enabled) {
                        onSelectionChanged?()
                        refreshEngineInfo()
                    }
                }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privacy Hardening")
                        Text(
                            hardened
                                ? "Active on \(activeProfile.displayName) · Farbling, Sec-GPC & WebRTC shield"
                                : "Farbling, Sec-GPC & non-proxied WebRTC UDP off"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: hardened ? "checkmark.shield.fill" : "shield")
                        .foregroundStyle(hardened ? Color.accentColor : Color.secondary)
                }
            }
            .disabled(isWiping || isRelaunching || fingerprintStore.loadError != nil)
            .accessibilityIdentifier("curium.profiles.privacyHardening")
        } footer: {
            Text(
                hotSupported
                    ? "Applies immediately to \(activeProfile.displayName) without restarting. Cookies remain scoped to the active profile."
                    : "Applies to \(activeProfile.displayName) on the next relaunch."
            )
        }
    }

    private func corruptStoreSection(_ loadError: String) -> some View {
        Section {
            Label(loadError, systemImage: "exclamationmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(.red)

            Button(role: .destructive) {
                if fingerprintStore.backupCorruptStoreAndReset() {
                    onSelectionChanged?()
                    scheduleRefreshUsage()
                } else {
                    alertMessage = fingerprintStore.lastPersistError
                        ?? "Unable to back up and reset the corrupt profile store."
                }
            } label: {
                Label("Back Up & Reset", systemImage: "arrow.counterclockwise")
            }
            .disabled(isWiping || isRelaunching)
            .accessibilityIdentifier("curium.profiles.corruptReset")
        } header: {
            Text("Store Recovery Required")
        } footer: {
            Text(
                "Saving is blocked to protect your existing fingerprint-profiles.json from being overwritten. Backing up moves it aside to a .bak file before resetting."
            )
        }
    }

    private var profilesSection: some View {
        Section {
            ForEach(fingerprintStore.profiles) { profile in
                profileRow(profile)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            navigationPath.append(.editProfile(profile.id))
                        } label: {
                            Label("Customize", systemImage: "slider.horizontal.3")
                        }
                        .tint(profile.resolvedPalette.tint)
                        .disabled(isWiping || isRelaunching)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !profile.isPrimaryDefault {
                            if isActiveInProcess(profile.id) {
                                Button {
                                    alertMessage =
                                        "\"\(profile.displayName)\" is currently active in this running session. Switch profiles and relaunch Curium before deleting it."
                                } label: {
                                    Label("Active", systemImage: "lock.fill")
                                }
                                .tint(.secondary)
                            } else {
                                Button(role: .destructive) {
                                    activeDialog = .deleteProfile(profile)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(isWiping || isRelaunching || fingerprintStore.loadError != nil)
                            }
                        }
                    }
                    .contextMenu {
                        profileContextMenu(profile)
                    }
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text(
                "Tap a profile to switch into its isolated Blink process, or tap the active profile to customize its persona and fingerprint."
            )
        }
    }

    private var pendingSwitchSection: some View {
        let isActiveEngineRestart = hasPendingActiveEngineRestart
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    CuriumProfileAvatar(
                        symbolName: nextLaunchProfile.resolvedSymbolName,
                        palette: nextLaunchProfile.resolvedPalette,
                        size: 32,
                        isCircle: true
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            isActiveEngineRestart
                                ? (supportsHotSwap ? "Apply Updated Settings" : "Restart to Apply Changes")
                                : "Pending Switch: \(nextLaunchProfile.displayName)"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        Text(
                            isActiveEngineRestart
                                ? (supportsHotSwap
                                    ? "Apply updated settings for \(activeProfile.displayName) now without closing Curium."
                                    : "Reopen Curium to apply updated settings for \(activeProfile.displayName). Tabs and library are saved before closing.")
                                : (supportsHotSwap
                                    ? "Switch directly to \(nextLaunchProfile.displayName) without closing Curium."
                                    : "Tabs and library are saved before closing. Reopen Curium to switch into \(nextLaunchProfile.displayName).")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await performSwitchAndRelaunch(to: nextLaunchProfile.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isRelaunching {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(
                                isActiveEngineRestart
                                    ? (supportsHotSwap ? "Apply Now" : CuriumProfileRelauncher.primaryApplyButtonTitle)
                                    : (supportsHotSwap ? "Switch Now" : CuriumProfileRelauncher.primaryRelaunchButtonTitle)
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isWiping || isRelaunching || fingerprintStore.loadError != nil)
                    .accessibilityIdentifier("curium.profiles.pending.relaunch")

                    if !isActiveEngineRestart {
                        Button("Cancel Switch") {
                            cancelPendingSwitch()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isWiping || isRelaunching || fingerprintStore.loadError != nil)
                        .accessibilityIdentifier("curium.profiles.pending.cancel")
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Next Launch")
        }
    }

    private var orphanedStorageSection: some View {
        Section {
            ForEach(orphanedSlugs, id: \.self) { slug in
                let active = isActiveInProcess(slug)
                let wipingThis = wipingTargetID == slug
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(slug)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if active {
                                statusPill("ACTIVE", foreground: .green, fill: .green.opacity(0.14))
                            }
                        }
                        if let usage = orphanUsageBySlug[slug], usage.exists {
                            Text("ChromiumProfiles/\(slug) · \(formatBytes(usage.totalBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("ChromiumProfiles/\(slug)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if wipingThis {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(role: .destructive) {
                            wipeOrphanedProfile(slug)
                        } label: {
                            Text("Wipe")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(active || isWiping)
                        .accessibilityIdentifier("curium.profiles.orphan.wipe.\(slug)")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Orphaned Storage (\(orphanedSlugs.count))")
        } footer: {
            Text(
                "Isolated profile directories remain on disk without a matching profile entry. Wipe them to reclaim local storage."
            )
        }
    }

    private var engineSummarySection: some View {
        Section {
            LabeledContent("Active Profile") {
                Text(activeProfile.displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let kernel = CuriumDiagnostics.KernelMetadata.bundled {
                LabeledContent("Curium Kernel") {
                    Text(kernel.shortLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let status = engineStatus {
                LabeledContent("Engine Contract") {
                    Text("v\(status.contractVersion) · \(status.state)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else if let caps = engineCapabilities, caps.supportsLaunchFingerprintConfig {
                LabeledContent("Engine Contract") {
                    Text("v\(caps.contractVersion) Active")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(
                "Each profile runs locally with isolated cookies, site storage, extensions, bookmarks, history, and tabs."
            )
        }
    }

    private func missingProfileView(id: String) -> some View {
        ContentUnavailableView(
            "Profile Unavailable",
            systemImage: "person.crop.circle.badge.exclamationmark",
            description: Text("Profile \"\(id)\" is no longer present in the local profile store.")
        )
        .navigationTitle("Unavailable")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Row & Menu Builders

    private func profileRow(_ profile: CuriumFingerprintProfile) -> some View {
        let active = isActiveProfile(profile)
        let next = isNextLaunchProfile(profile)
        let palette = profile.resolvedPalette
        let usage = usageByProfileID[profile.id]
        let wipingThis = wipingTargetID == profile.id

        return HStack(spacing: 12) {
            Button {
                if active {
                    navigationPath.append(.editProfile(profile.id))
                } else {
                    activeDialog = .switchHandoff(profile)
                }
            } label: {
                HStack(spacing: 12) {
                    CuriumProfileAvatar(
                        symbolName: profile.resolvedSymbolName,
                        palette: palette,
                        size: 38
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            if copiedToastID == profile.id {
                                statusPill("COPIED", foreground: .secondary, fill: Color(uiColor: .tertiarySystemFill))
                            }
                        }

                        Text(subtitleText(for: profile, usage: usage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if wipingThis {
                        ProgressView()
                            .controlSize(.small)
                    } else if active {
                        if hasPendingActiveEngineRestart {
                            statusPill("RESTART", foreground: .orange, fill: .orange.opacity(0.14))
                        } else {
                            statusPill("ACTIVE", foreground: palette.tint, fill: palette.tile)
                        }
                    } else if next {
                        nextOutlinePill(palette: palette)
                    }

                    if active {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWiping || isRelaunching || (fingerprintStore.loadError != nil && !active))
            .accessibilityIdentifier("curium.profiles.row.\(profile.id)")

            if !active {
                Button {
                    navigationPath.append(.editProfile(profile.id))
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isWiping || isRelaunching)
                .accessibilityLabel("Customize \(profile.displayName)")
                .accessibilityIdentifier("curium.profiles.customize.\(profile.id)")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func profileContextMenu(_ profile: CuriumFingerprintProfile) -> some View {
        let active = isActiveProfile(profile)
        let activeInProcess = isActiveInProcess(profile.id)
        let canWipe = !profile.isPrimaryDefault
            && !activeInProcess
            && !isWiping
            && !isRelaunching
            && usageByProfileID[profile.id]?.exists == true
        let canDelete = !profile.isPrimaryDefault && !activeInProcess && !isWiping && !isRelaunching

        if !active {
            Button {
                activeDialog = .switchHandoff(profile)
            } label: {
                Label("Switch Profile…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isWiping || isRelaunching || fingerprintStore.loadError != nil)
        }

        Button {
            navigationPath.append(.editProfile(profile.id))
        } label: {
            Label("Customize…", systemImage: "slider.horizontal.3")
        }
        .disabled(isWiping || isRelaunching)

        Button {
            duplicateAndOpen(profile)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .disabled(isWiping || isRelaunching || fingerprintStore.loadError != nil)

        Button {
            exportProfileJSON(profile)
        } label: {
            Label("Export JSON", systemImage: "square.and.arrow.up")
        }

        Button {
            copyProfileJSON(profile)
        } label: {
            Label("Copy JSON", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            activeDialog = .wipeProfile(profile)
        } label: {
            Label("Wipe Data", systemImage: "externaldrive.badge.xmark")
        }
        .disabled(!canWipe)

        Button(role: .destructive) {
            activeDialog = .deleteProfile(profile)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(!canDelete || fingerprintStore.loadError != nil)
    }

    private func statusPill(_ title: String, foreground: Color, fill: Color) -> some View {
        Text(title)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(fill, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    private func nextOutlinePill(palette: CuriumPalette) -> some View {
        Text("NEXT")
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(palette.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(palette.tile.opacity(0.5), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(palette.tint.opacity(0.6), lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    private func subtitleText(
        for profile: CuriumFingerprintProfile,
        usage: CuriumFingerprintProfileStorage.UsageSnapshot?
    ) -> String {
        let archetype = profile.conciseStartPostureSummary
        guard let usage else { return archetype }
        let usageText = usage.exists ? formatBytes(usage.totalBytes) : "Fresh"
        return "\(archetype) · \(usageText)"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Actions

    private func refreshEngineInfo() {
        engineStatus = CuriumFingerprintBootstrap.activeEngineStatus()
        engineCapabilities = CuriumFingerprintBootstrap.engineCapabilities()
    }

    private func scheduleRefreshUsage(onlyProfileIDs: Set<String>? = nil) {
        usageTask?.cancel()
        let knownIDs = Set(fingerprintStore.profiles.map(\.id))
        let targetIDs: [String]
        if let onlyProfileIDs {
            targetIDs = Array(onlyProfileIDs)
        } else {
            targetIDs = Array(Set(["default"] + fingerprintStore.profiles.map(\.id)))
        }

        usageTask = Task {
            let result = await Task.detached(priority: .utility) {
                var usageMap: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
                for id in targetIDs {
                    if Task.isCancelled {
                        return (usageMap, [String](), [String: CuriumFingerprintProfileStorage.UsageSnapshot]())
                    }
                    usageMap[id] = CuriumFingerprintProfileStorage.measureUsage(for: id)
                }
                let orphans = CuriumFingerprintProfileStorage.discoverOrphanedProfiles(knownIDs: knownIDs)
                var orphanMap: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
                for slug in orphans {
                    if Task.isCancelled {
                        return (usageMap, orphans, orphanMap)
                    }
                    orphanMap[slug] = CuriumFingerprintProfileStorage.measureUsage(for: slug)
                }
                return (usageMap, orphans, orphanMap)
            }.value

            guard !Task.isCancelled else { return }
            if onlyProfileIDs != nil {
                for (id, snapshot) in result.0 {
                    usageByProfileID[id] = snapshot
                }
            } else {
                usageByProfileID = result.0
            }
            orphanedSlugs = result.1
            orphanUsageBySlug = result.2
        }
    }

    private func selectForNextLaunch(_ profile: CuriumFingerprintProfile) {
        guard !isWiping, !isRelaunching else { return }
        let targetID: String? = profile.isPrimaryDefault ? nil : profile.id
        if fingerprintStore.selectProfile(id: targetID) {
            onSelectionChanged?()
        } else {
            alertMessage = fingerprintStore.lastPersistError
                ?? "Unable to select \"\(profile.displayName)\" for next launch."
        }
    }

    private func cancelPendingSwitch() {
        guard !isWiping, !isRelaunching else { return }
        let revertID: String? = activeProfile.isPrimaryDefault ? nil : activeProfile.id
        if fingerprintStore.selectProfile(id: revertID) {
            onSelectionChanged?()
        } else {
            alertMessage = fingerprintStore.lastPersistError ?? "Unable to cancel pending profile switch."
        }
    }

    private func performSwitchAndRelaunch(to profileID: String) async {
        guard !isRelaunching, !isWiping else { return }
        isRelaunching = true
        if let browserStore {
            let usedHotSwap = browserStore.canHotSwapProfile
            let ok = await browserStore.switchProfile(to: profileID)
            if ok {
                onSelectionChanged?()
                if usedHotSwap {
                    isRelaunching = false
                    dismiss()
                }
            } else {
                isRelaunching = false
                alertMessage = browserStore.errorMessage ?? fingerprintStore.lastPersistError ?? "Unable to switch profile."
            }
        } else {
            let targetProfile = fingerprintStore.profile(id: profileID)
            let resolvedSelectionID: String? = targetProfile?.isPrimaryDefault == true ? nil : profileID
            if fingerprintStore.selectProfile(id: resolvedSelectionID) {
                onSelectionChanged?()
                await CuriumLibrary(profileID: activeProfileID, fingerprintStore: fingerprintStore).checkpointAsync()
                CuriumDiagnostics.shared.flushSync()
                CuriumProfileRelauncher.relaunchAfterFlush()
            } else {
                isRelaunching = false
                alertMessage = fingerprintStore.lastPersistError ?? "Unable to switch profile."
            }
        }
    }

    private func duplicateAndOpen(_ profile: CuriumFingerprintProfile) {
        guard let copy = fingerprintStore.duplicateProfile(
            from: profile.id,
            displayName: "\(profile.displayName) Copy"
        ) else {
            alertMessage = fingerprintStore.lastPersistError ?? "Unable to duplicate profile."
            return
        }
        scheduleRefreshUsage(onlyProfileIDs: [copy.id])
        navigationPath.append(.editProfile(copy.id))
    }

    private func exportProfileJSON(_ profile: CuriumFingerprintProfile) {
        do {
            let data = try fingerprintStore.exportProfileJSON(id: profile.id)
            if let text = String(data: data, encoding: .utf8) {
                pendingShareDocument = CuriumShareDocument(text: text)
            } else {
                alertMessage = "Failed to encode profile JSON for export."
            }
        } catch {
            alertMessage = "Failed to export profile JSON: \(error.localizedDescription)"
        }
    }

    private func copyProfileJSON(_ profile: CuriumFingerprintProfile) {
        do {
            let data = try fingerprintStore.exportProfileJSON(id: profile.id)
            if let text = String(data: data, encoding: .utf8) {
                UIPasteboard.general.string = text
                copiedToastID = profile.id
                copiedToastTask?.cancel()
                copiedToastTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    if copiedToastID == profile.id {
                        copiedToastID = nil
                    }
                }
            }
        } catch {
            alertMessage = "Failed to export profile JSON: \(error.localizedDescription)"
        }
    }

    private func wipeProfileStorage(_ profile: CuriumFingerprintProfile) {
        guard !isWiping, !profile.isPrimaryDefault else { return }
        let targetID = profile.id
        let active = isActiveInProcess(targetID)
        guard !active else {
            alertMessage = CuriumFingerprintProfileStorage.WipeError.activeProfileProtected.localizedDescription
            return
        }
        wipingTargetID = targetID
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                        targetID,
                        isActiveInCurrentProcess: false
                    )
                }.value
                wipingTargetID = nil
                usageByProfileID[targetID] = CuriumFingerprintProfileStorage.UsageSnapshot(
                    supportBytes: 0,
                    cacheBytes: 0,
                    exists: false
                )
                scheduleRefreshUsage(onlyProfileIDs: [targetID])
            } catch {
                wipingTargetID = nil
                alertMessage = error.localizedDescription
            }
        }
    }

    private func deleteProfileAndWipe(_ profile: CuriumFingerprintProfile) {
        guard !isWiping, !profile.isPrimaryDefault else { return }
        let targetID = profile.id
        guard !isActiveInProcess(targetID) else {
            alertMessage = CuriumFingerprintProfileStorage.WipeError.activeProfileProtected.localizedDescription
            return
        }
        let wasSelected = fingerprintStore.nextLaunchProfileID.lowercased() == targetID.lowercased()
        wipingTargetID = targetID
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                        targetID,
                        isActiveInCurrentProcess: false
                    )
                }.value
                let deleted = fingerprintStore.deleteProfile(id: targetID)
                wipingTargetID = nil
                if deleted {
                    usageByProfileID.removeValue(forKey: targetID)
                    if wasSelected {
                        onSelectionChanged?()
                    }
                    scheduleRefreshUsage(onlyProfileIDs: [])
                } else {
                    alertMessage = fingerprintStore.lastPersistError
                        ?? "Storage was wiped, but the profile entry could not be removed."
                    scheduleRefreshUsage(onlyProfileIDs: [])
                }
            } catch {
                wipingTargetID = nil
                alertMessage = error.localizedDescription
            }
        }
    }

    private func wipeOrphanedProfile(_ slug: String) {
        guard !isWiping else { return }
        guard !isActiveInProcess(slug) else {
            alertMessage =
                "Orphaned directory \"\(slug)\" is currently active in this session. Relaunch Curium on another profile first."
            return
        }
        wipingTargetID = slug
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                        slug,
                        isActiveInCurrentProcess: false
                    )
                }.value
                wipingTargetID = nil
                orphanedSlugs.removeAll { $0 == slug }
                orphanUsageBySlug.removeValue(forKey: slug)
                scheduleRefreshUsage(onlyProfileIDs: [])
            } catch {
                wipingTargetID = nil
                alertMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Shared Persona Avatar & Symbol Accessibility Helpers

struct CuriumProfileAvatar: View {
    let symbolName: String
    let palette: CuriumPalette
    var size: CGFloat = 38
    var isCircle: Bool = false

    var body: some View {
        let iconSize = max(14, (size * 0.44).rounded())
        let cornerRadius = max(8, (size * 0.28).rounded())

        Group {
            if isCircle {
                Circle()
                    .fill(palette.tile)
                    .overlay(
                        Circle()
                            .strokeBorder(palette.tint.opacity(0.22), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(palette.tile)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(palette.tint.opacity(0.22), lineWidth: 1)
                    )
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Image(systemName: symbolName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(palette.tint)
        }
        .accessibilityHidden(true)
    }
}

enum CuriumProfileSymbolLabels {
    static func label(for symbolName: String) -> String {
        switch symbolName {
        case "person.crop.circle": return "Person"
        case "briefcase": return "Briefcase"
        case "bag": return "Shopping Bag"
        case "globe": return "Globe"
        case "shield.lefthalf.filled": return "Privacy Shield"
        case "desktopcomputer": return "Desktop Computer"
        case "laptopcomputer": return "Laptop"
        case "iphone": return "iPhone"
        case "terminal": return "Terminal"
        case "gamecontroller": return "Game Controller"
        case "graduationcap": return "Graduation Cap"
        case "airplane": return "Airplane"
        case "building.2": return "Office Building"
        case "lock.shield": return "Security Lock"
        case "sparkles": return "Sparkles"
        case "flask": return "Lab Flask"
        default: return symbolName
        }
    }
}
