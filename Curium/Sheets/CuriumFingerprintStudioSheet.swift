import SwiftUI
import UIKit

/// Native iOS 27.2 Fingerprint & Isolated Profile Studio presented from Settings.
/// Uses a single root `NavigationStack` and `.insetGrouped` lists so iPhone Duo's
/// 84 pt vertical bar and centered sheet placement work natively with zero custom glass chrome.
struct CuriumFingerprintStudioSheet: View {
    @Bindable var store: CuriumFingerprintStore
    let onDismissCallback: () -> Void

    init(store: CuriumFingerprintStore, onDismissCallback: @escaping () -> Void = {}) {
        self.store = store
        self.onDismissCallback = onDismissCallback
    }

    @Environment(\.dismiss) private var dismiss
    @State private var engineStatus: CuriumEngineFingerprintStatus?
    @State private var engineCapabilities: CuriumEngineFingerprintCapabilities?
    @State private var usageByProfileID: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
    @State private var orphanedProfiles: [String] = []
    @State private var orphanUsageBySlug: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
    @State private var activeProfileIDInProcess: String?
    @State private var navigationPath: [Route] = []
    @State private var showingImportSheet = false
    @State private var activeDialog: StudioDialog?
    @State private var wipingTargetID: String?
    @State private var alertMessage: String?
    @State private var copiedToastID: String?
    @State private var usageTask: Task<Void, Never>?
    @State private var copiedToastTask: Task<Void, Never>?

    private var isWiping: Bool { wipingTargetID != nil }

    private enum StudioDialog: Identifiable {
        case deleteProfile(CuriumFingerprintProfile)
        case wipeProfile(CuriumFingerprintProfile)

        var id: String {
            switch self {
            case .deleteProfile(let profile): return "delete:\(profile.id)"
            case .wipeProfile(let profile): return "wipe:\(profile.id)"
            }
        }

        var title: String {
            switch self {
            case .deleteProfile: return "Delete Custom Profile?"
            case .wipeProfile: return "Wipe Isolated Profile Storage?"
            }
        }
    }

    private func isActiveInProcess(_ profileID: String) -> Bool {
        activeProfileIDInProcess?.lowercased() == profileID.lowercased()
    }

    enum Route: Hashable {
        case inspectBuiltIn(String)
        case editCustom(String)
        case createNew(CuriumFingerprintProfile)

        func hash(into hasher: inout Hasher) {
            switch self {
            case .inspectBuiltIn(let id):
                hasher.combine(0)
                hasher.combine(id)
            case .editCustom(let id):
                hasher.combine(1)
                hasher.combine(id)
            case .createNew(let profile):
                hasher.combine(2)
                hasher.combine(profile.id)
                hasher.combine(profile.revision)
            }
        }
    }

    private var selectedLaunchLabel: String {
        if let selected = store.selectedProfile {
            return "\(selected.displayName) (\(selected.id))"
        }
        return "Default (Build 39 Authentic Chrome)"
    }

    private var isEngineRunningBuild39: Bool {
        if let status = engineStatus {
            return status.state == "default_0105"
        }
        if case .defaultBuild39 = CuriumFingerprintBootstrap.lastOutcome {
            return true
        }
        return false
    }

    private var runningLaunchIdentity: (isBuild39Baseline: Bool, profileID: String)? {
        if isEngineRunningBuild39 {
            return (true, "default")
        }
        if let active = activeProfileIDInProcess {
            return (false, active.lowercased())
        }
        return nil
    }

    private var nextLaunchIdentity: (isBuild39Baseline: Bool, profileID: String) {
        if let selectedID = store.selectedProfileID {
            return (false, selectedID.lowercased())
        }
        return (true, "default")
    }

    private var hasPendingLaunchSwitch: Bool {
        guard let running = runningLaunchIdentity else { return true }
        let next = nextLaunchIdentity
        return running.isBuild39Baseline != next.isBuild39Baseline
            || running.profileID != next.profileID
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if let loadError = store.loadError {
                    corruptStoreSection(loadError)
                }
                engineSessionSection
                defaultBuild39Section
                builtInPresetsSection
                customProfilesSection
                if !orphanedProfiles.isEmpty {
                    orphanedStorageSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Identity & Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            var blank = CuriumFingerprintPresets.defaultAuthenticChrome
                            blank.id = store.nextAvailableID(base: "custom")
                            blank.displayName = "Custom Profile"
                            blank.notes = ""
                            blank.isBuiltIn = false
                            blank.revision = 1
                            navigationPath.append(.createNew(blank))
                        } label: {
                            Label("New Blank Profile", systemImage: "doc.badge.plus")
                        }

                        Button {
                            let sourceID = store.selectedProfileID ?? "default"
                            if var copy = store.profiles.first(where: { $0.id == sourceID }) {
                                copy.id = store.nextAvailableID(base: sourceID)
                                copy.displayName = "\(copy.displayName) Copy"
                                copy.isBuiltIn = false
                                copy.revision = 1
                                if copy.fingerprintSeed != nil || copy.hasFarblingEnabled {
                                    copy.fingerprintSeed = CuriumFingerprintStore.mintFreshSeed(
                                        differentFrom: copy.fingerprintSeed
                                    )
                                }
                                navigationPath.append(.createNew(copy))
                            }
                        } label: {
                            Label("Duplicate Selected Profile", systemImage: "plus.square.on.square")
                        }

                        Button {
                            showingImportSheet = true
                        } label: {
                            Label("Import JSON…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Add Profile", systemImage: "plus")
                    }
                    .disabled(store.loadError != nil)
                    .accessibilityIdentifier("curium.studio.add")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onDismissCallback()
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .accessibilityIdentifier("curium.studio.done")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .inspectBuiltIn(let id):
                    if let profile = store.profiles.first(where: { $0.id == id }) {
                        CuriumFingerprintEditorView(
                            store: store,
                            initialProfile: profile,
                            mode: .inspectBuiltIn,
                            isActiveInProcess: isActiveInProcess(profile.id),
                            usage: usageByProfileID[profile.id],
                            onDuplicateToEdit: { copy in
                                if !navigationPath.isEmpty {
                                    navigationPath.removeLast()
                                }
                                navigationPath.append(.editCustom(copy.id))
                                scheduleRefreshUsage(onlyProfileIDs: [copy.id])
                            },
                            onSaved: {
                                scheduleRefreshUsage(onlyProfileIDs: [profile.id])
                            },
                            onWiped: {
                                usageByProfileID[profile.id] = CuriumFingerprintProfileStorage.UsageSnapshot(
                                    supportBytes: 0, cacheBytes: 0, exists: false
                                )
                                scheduleRefreshUsage(onlyProfileIDs: [profile.id])
                            }
                        )
                    } else {
                        missingProfileView(id: id)
                    }
                case .editCustom(let id):
                    if let profile = store.profiles.first(where: { $0.id == id }) {
                        CuriumFingerprintEditorView(
                            store: store,
                            initialProfile: profile,
                            mode: .editCustom,
                            isActiveInProcess: isActiveInProcess(profile.id),
                            usage: usageByProfileID[profile.id],
                            onDuplicateToEdit: { copy in
                                navigationPath.append(.editCustom(copy.id))
                                scheduleRefreshUsage(onlyProfileIDs: [copy.id])
                            },
                            onSaved: {
                                scheduleRefreshUsage(onlyProfileIDs: [profile.id])
                            },
                            onWiped: {
                                usageByProfileID[profile.id] = CuriumFingerprintProfileStorage.UsageSnapshot(
                                    supportBytes: 0, cacheBytes: 0, exists: false
                                )
                                scheduleRefreshUsage(onlyProfileIDs: [profile.id])
                            }
                        )
                    } else {
                        missingProfileView(id: id)
                    }
                case .createNew(let draft):
                    CuriumFingerprintEditorView(
                        store: store,
                        initialProfile: draft,
                        mode: .createNew,
                        isActiveInProcess: false,
                        usage: nil,
                        onDuplicateToEdit: { _ in },
                        onSaved: {
                            if !navigationPath.isEmpty {
                                navigationPath.removeLast()
                            }
                            scheduleRefreshUsage()
                        },
                        onWiped: {}
                    )
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
        .sheet(isPresented: $showingImportSheet) {
            CuriumFingerprintImportSheet(store: store) { importedID in
                scheduleRefreshUsage(onlyProfileIDs: importedID.map { [$0] })
                if let importedID, store.profiles.contains(where: { $0.id == importedID }) {
                    navigationPath.append(.editCustom(importedID))
                }
            }
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
            case .deleteProfile(let profile):
                if !isActiveInProcess(profile.id) {
                    Button("Delete Profile & Wipe Storage", role: .destructive) {
                        deleteProfile(profile, wipeStorage: true)
                    }
                    Button("Delete Profile Entry Only", role: .destructive) {
                        deleteProfile(profile, wipeStorage: false)
                    }
                }
                Button("Cancel", role: .cancel) {}
            case .wipeProfile(let profile):
                Button("Wipe Cookies, Cache & Storage", role: .destructive) {
                    wipeProfileStorage(profile)
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { dialog in
            switch dialog {
            case .deleteProfile(let profile):
                if isActiveInProcess(profile.id) {
                    Text("\"\(profile.displayName)\" (\(profile.id)) is currently active in this running session. Switch to another profile and relaunch Curium before deleting it.")
                } else if store.selectedProfileID == profile.id {
                    Text("Removes \"\(profile.displayName)\" (\(profile.id)) from Curium and resets next launch selection to Default (Build 39). Wiping storage permanently deletes its isolated cookies and site data.")
                } else {
                    Text("Removes \"\(profile.displayName)\" (\(profile.id)) from Curium. Wiping storage permanently deletes its isolated cookies, site data, and HTTP cache.")
                }
            case .wipeProfile(let profile):
                Text("Permanently clears isolated cookies, localStorage, IndexedDB, CacheStorage, and HTTP cache for \"\(profile.displayName)\" (\(profile.id)). The profile configuration itself is kept.")
            }
        }
        .alert("Identity & Profiles", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Sections

    private func corruptStoreSection(_ loadError: String) -> some View {
        Section {
            Label(loadError, systemImage: "exclamationmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            Button(role: .destructive) {
                if store.backupCorruptStoreAndReset() {
                    scheduleRefreshUsage()
                } else {
                    alertMessage = store.lastPersistError ?? "Unable to back up and reset corrupt profile store."
                }
            } label: {
                Label("Back Up Corrupt Store & Reset", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Store Recovery Required")
        } footer: {
            Text("Saving is blocked to protect your existing fingerprint-profiles.json from being overwritten. Backing up moves it aside to a .bak file before resetting.")
        }
    }

    private func missingProfileView(id: String) -> some View {
        ContentUnavailableView(
            "Profile Unavailable",
            systemImage: "person.crop.circle.badge.exclamationmark",
            description: Text("Profile \"\(id)\" is no longer present in the profile store.")
        )
        .navigationTitle("Unavailable")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var engineSessionSection: some View {
        Section {
            if let status = engineStatus {
                LabeledContent("Running Profile") {
                    Text(status.appliedProfileId)
                        .font(.subheadline.monospaced())
                }
                LabeledContent("Engine State") {
                    Text("\(status.state) · rev \(status.appliedConfigRevision)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Hardware Mode") {
                    Text(status.hardwareOverridesActive ? "Custom Override" : "Native Apple HW/GPU")
                        .foregroundStyle(status.hardwareOverridesActive ? .orange : .green)
                }
                LabeledContent("Active Proxy") {
                    Text(status.proxyMode.capitalized)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Engine Session", value: "Standby / Pre-Build 40")
            }

            LabeledContent("Next Launch") {
                Text(selectedLaunchLabel)
                    .font(.subheadline)
                    .foregroundStyle(hasPendingLaunchSwitch ? .orange : .secondary)
                    .multilineTextAlignment(.trailing)
            }

            if hasPendingLaunchSwitch {
                Label(
                    "Relaunch Curium to switch to the selected isolated profile and storage container.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Active Engine Session")
        } footer: {
            if let caps = engineCapabilities, caps.supportsLaunchFingerprintConfig {
                Text("Engine contract v\(caps.contractVersion) active (max \(caps.maxConfigBytes / 1024) KiB). One isolated profile runs per cold launch.")
            } else {
                Text("Profile changes are persisted locally and validated before Blink launches.")
            }
        }
    }

    private var defaultBuild39Section: some View {
        Section {
            Button {
                if !store.resetToBuild39Default() {
                    alertMessage = store.lastPersistError ?? "Unable to save profile selection."
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Default (Build 39 Authentic Chrome)")
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if isEngineRunningBuild39 {
                                statusBadge("LIVE", color: .green)
                            }
                        }
                        Text(defaultUsageSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.selectedProfileID == nil {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.loadError != nil)
            .accessibilityAddTraits(store.selectedProfileID == nil ? .isSelected : [])
            .accessibilityIdentifier("curium.studio.profile.defaultBuild39")
        } header: {
            Text("Unconfigured Baseline")
        } footer: {
            Text("Uses legacy Chromium/ storage and preserves Settings Brand & Mobile Profile switches with 100% native Apple hardware.")
        }
    }

    private var builtInPresetsSection: some View {
        Section {
            ForEach(store.builtInProfiles) { profile in
                NavigationLink(value: Route.inspectBuiltIn(profile.id)) {
                    profileRowContent(profile)
                }
                .accessibilityIdentifier("curium.studio.profile.\(profile.id)")
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if store.selectedProfileID != profile.id {
                        Button {
                            selectProfile(profile)
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .tint(.accentColor)
                    }
                }
                .contextMenu {
                    profileContextMenu(profile)
                }
            }
        } header: {
            Text("Built-In Presets (\(store.builtInProfiles.count))")
        } footer: {
            Text("Built-in templates stay read-only across updates. Tap any preset to inspect, select, or duplicate into a custom profile.")
        }
    }

    private var customProfilesSection: some View {
        Section {
            if store.customProfiles.isEmpty {
                Text("No custom profiles yet. Tap + or duplicate a built-in preset to customize UA, Client Hints, proxy, language, timezone, or GPU.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.customProfiles) { profile in
                    NavigationLink(value: Route.editCustom(profile.id)) {
                        profileRowContent(profile)
                    }
                    .accessibilityIdentifier("curium.studio.profile.\(profile.id)")
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if store.selectedProfileID != profile.id {
                            Button {
                                selectProfile(profile)
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            .tint(.accentColor)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if isActiveInProcess(profile.id) {
                            Button {
                                alertMessage = "\"\(profile.displayName)\" (\(profile.id)) is currently active in this running session. Switch to another profile and relaunch Curium before deleting it."
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
                        }
                    }
                    .contextMenu {
                        profileContextMenu(profile)
                    }
                }
            }
        } header: {
            Text("Custom Profiles (\(store.customProfiles.count))")
        }
    }

    private var orphanedStorageSection: some View {
        Section {
            ForEach(orphanedProfiles, id: \.self) { slug in
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
                                statusBadge("LIVE", color: .green)
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
                        .accessibilityIdentifier("curium.studio.orphan.wipe.\(slug)")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Orphaned Storage (\(orphanedProfiles.count))")
        } footer: {
            Text("Isolated ChromiumProfiles/ directories remain on disk without a profile entry. Wipe them to reclaim disk space and prevent accidental cookie reuse if an ID is recreated.")
        }
    }

    // MARK: - Row & Menu Builders

    private func profileRowContent(_ profile: CuriumFingerprintProfile) -> some View {
        let isSelected = store.selectedProfileID == profile.id
        let isLive = !isEngineRunningBuild39 && isActiveInProcess(profile.id)
        let usage = usageByProfileID[profile.id]
        let wipingThis = wipingTargetID == profile.id

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if isLive {
                        statusBadge("LIVE", color: .green)
                    }
                    if isSelected {
                        statusBadge("NEXT", color: .accentColor)
                    }
                    if copiedToastID == profile.id {
                        statusBadge("COPIED", color: .secondary)
                    }
                }
                Text(profileSubtitle(profile, usage: usage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if wipingThis {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func profileContextMenu(_ profile: CuriumFingerprintProfile) -> some View {
        if store.selectedProfileID != profile.id {
            Button {
                selectProfile(profile)
            } label: {
                Label("Select for Next Launch", systemImage: "checkmark.circle")
            }
            .disabled(store.loadError != nil)
        }

        Button {
            duplicateAndOpen(profile)
        } label: {
            Label("Duplicate & Customize", systemImage: "plus.square.on.square")
        }
        .disabled(store.loadError != nil)

        Button {
            copyProfileJSON(profile)
        } label: {
            Label("Copy Profile JSON", systemImage: "doc.on.doc")
        }

        if profile.id != "default", !isActiveInProcess(profile.id), !isWiping,
           usageByProfileID[profile.id]?.exists == true
        {
            Button(role: .destructive) {
                activeDialog = .wipeProfile(profile)
            } label: {
                Label("Wipe Isolated Storage", systemImage: "externaldrive.badge.xmark")
            }
        }

        if !profile.isBuiltIn {
            Divider()
            if isActiveInProcess(profile.id) {
                Button(role: .destructive) {} label: {
                    Label("Delete Profile (Switch & Relaunch First)", systemImage: "lock.fill")
                }
                .disabled(true)
            } else {
                Button(role: .destructive) {
                    activeDialog = .deleteProfile(profile)
                } label: {
                    Label("Delete Profile", systemImage: "trash")
                }
            }
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    private var defaultUsageSubtitle: String {
        var parts = ["Legacy Chromium/", "Native Apple HW/GPU"]
        if let usage = usageByProfileID["default"], usage.exists {
            parts.append(formatBytes(usage.totalBytes))
        }
        return parts.joined(separator: " · ")
    }

    private func profileSubtitle(
        _ profile: CuriumFingerprintProfile,
        usage: CuriumFingerprintProfileStorage.UsageSnapshot?
    ) -> String {
        let hwLabel = profile.usesNativeHardwareAndGPU ? "Native Apple HW/GPU" : "Custom HW/GPU"
        var parts = [profile.id, hwLabel, profile.proxy.summary]
        if let usage, usage.exists {
            parts.append(formatBytes(usage.totalBytes))
        }
        return parts.joined(separator: " · ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Actions

    private func refreshEngineInfo() {
        engineStatus = CuriumFingerprintBootstrap.activeEngineStatus()
        engineCapabilities = CuriumFingerprintBootstrap.engineCapabilities()
        if let status = engineStatus,
           status.profileDirectoryOpened || status.state == "configured" || status.state == "default_0105"
        {
            activeProfileIDInProcess = status.appliedProfileId
        } else {
            switch CuriumFingerprintBootstrap.lastOutcome {
            case .defaultBuild39: activeProfileIDInProcess = "default"
            case .configured(let id, _, _): activeProfileIDInProcess = id
            case .rejected: activeProfileIDInProcess = nil
            }
        }
    }

    private func scheduleRefreshUsage(onlyProfileIDs: Set<String>? = nil) {
        usageTask?.cancel()
        let knownIDs = Set(store.profiles.map(\.id))
        let targetIDs: [String]
        if let onlyProfileIDs {
            targetIDs = Array(onlyProfileIDs)
        } else {
            targetIDs = Array(Set(["default"] + store.profiles.map(\.id)))
        }
        usageTask = Task {
            let result = await Task.detached(priority: .utility) {
                var usageMap: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
                for id in targetIDs {
                    if Task.isCancelled { return (usageMap, [String](), [String: CuriumFingerprintProfileStorage.UsageSnapshot]()) }
                    usageMap[id] = CuriumFingerprintProfileStorage.measureUsage(for: id)
                }
                let orphans = CuriumFingerprintProfileStorage.discoverOrphanedProfiles(knownIDs: knownIDs)
                var orphanMap: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
                for slug in orphans {
                    if Task.isCancelled { return (usageMap, orphans, orphanMap) }
                    orphanMap[slug] = CuriumFingerprintProfileStorage.measureUsage(for: slug)
                }
                return (usageMap, orphans, orphanMap)
            }.value
            guard !Task.isCancelled else { return }
            if onlyProfileIDs != nil {
                for (id, snap) in result.0 {
                    usageByProfileID[id] = snap
                }
            } else {
                usageByProfileID = result.0
            }
            orphanedProfiles = result.1
            orphanUsageBySlug = result.2
        }
    }

    private func selectProfile(_ profile: CuriumFingerprintProfile) {
        if !store.selectProfile(id: profile.id) {
            alertMessage = store.lastPersistError ?? "Unable to select profile \"\(profile.id)\"."
        }
    }

    private func duplicateAndOpen(_ profile: CuriumFingerprintProfile) {
        let newID = store.nextAvailableID(base: profile.id)
        guard let copy = store.duplicateProfile(
            from: profile.id,
            newID: newID,
            displayName: "\(profile.displayName) Copy"
        ) else {
            alertMessage = store.lastPersistError ?? "Unable to duplicate profile."
            return
        }
        navigationPath.append(.editCustom(copy.id))
        scheduleRefreshUsage(onlyProfileIDs: [copy.id])
    }

    private func copyProfileJSON(_ profile: CuriumFingerprintProfile) {
        do {
            let data = try store.exportProfileJSON(id: profile.id)
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
        guard !isWiping else { return }
        wipingTargetID = profile.id
        let isActive = CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(profile.id)
        let targetID = profile.id
        Task.detached(priority: .userInitiated) {
            do {
                try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                    targetID,
                    isActiveInCurrentProcess: isActive
                )
                await MainActor.run {
                    wipingTargetID = nil
                    usageByProfileID[targetID] = CuriumFingerprintProfileStorage.UsageSnapshot(
                        supportBytes: 0, cacheBytes: 0, exists: false
                    )
                    scheduleRefreshUsage(onlyProfileIDs: [targetID])
                }
            } catch {
                await MainActor.run {
                    wipingTargetID = nil
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func wipeOrphanedProfile(_ slug: String) {
        guard !isWiping else { return }
        let isActive = CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(slug)
        guard !isActive else {
            alertMessage = "Orphaned directory \"\(slug)\" is currently active in this session. Relaunch Curium on another profile first."
            return
        }
        wipingTargetID = slug
        Task.detached(priority: .userInitiated) {
            do {
                try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                    slug,
                    isActiveInCurrentProcess: false
                )
                await MainActor.run {
                    wipingTargetID = nil
                    orphanedProfiles.removeAll { $0 == slug }
                    orphanUsageBySlug.removeValue(forKey: slug)
                    scheduleRefreshUsage(onlyProfileIDs: [])
                }
            } catch {
                await MainActor.run {
                    wipingTargetID = nil
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteProfile(_ profile: CuriumFingerprintProfile, wipeStorage: Bool) {
        let isActive = CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(profile.id)
        if isActive {
            alertMessage = "\"\(profile.displayName)\" (\(profile.id)) is currently active in this session. Switch to another profile and relaunch Curium before deleting it."
            return
        }
        let wasSelected = store.selectedProfileID == profile.id
        guard store.deleteProfile(id: profile.id) else {
            alertMessage = store.lastPersistError ?? "Could not delete profile \"\(profile.id)\"."
            return
        }
        let targetID = profile.id
        if wipeStorage && targetID != "default" {
            wipingTargetID = targetID
            Task.detached(priority: .userInitiated) {
                do {
                    try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                        targetID,
                        isActiveInCurrentProcess: false
                    )
                    await MainActor.run {
                        wipingTargetID = nil
                        usageByProfileID.removeValue(forKey: targetID)
                        if wasSelected {
                            alertMessage = "Deleted \"\(profile.displayName)\" and wiped its isolated storage. Next launch was reset to Default (Build 39)."
                        }
                        scheduleRefreshUsage(onlyProfileIDs: [])
                    }
                } catch {
                    await MainActor.run {
                        wipingTargetID = nil
                        alertMessage = "Profile entry deleted, but storage wipe skipped: \(error.localizedDescription). You can wipe it later under Orphaned Storage."
                        scheduleRefreshUsage(onlyProfileIDs: [])
                    }
                }
            }
        } else {
            usageByProfileID.removeValue(forKey: targetID)
            if wasSelected {
                alertMessage = "Deleted \"\(profile.displayName)\" entry. Next launch was reset to Default (Build 39)."
            }
            scheduleRefreshUsage(onlyProfileIDs: [])
        }
    }
}

// MARK: - Narrow-Width-Safe Form Controls

/// Stacked label + multi-line `TextField` that stays readable at iPhone Duo's
/// `382 pt` outer portrait safe width and Dynamic Type XL without horizontal clipping.
/// In read-only mode, renders selectable text so users can copy technical fields.
private struct CuriumStackedTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let isReadOnly: Bool
    var monospaced: Bool = true
    var font: Font = .callout
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isReadOnly {
                Text(text.isEmpty ? placeholder : text)
                    .font(monospaced ? font.monospaced() : font)
                    .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .font(monospaced ? font.monospaced() : font)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(autocapitalization)
                    .autocorrectionDisabled()
            }
        }
        .padding(.vertical, 2)
    }
}

/// Preserves the 3-way Client Hint distinction between `nil` (Engine Auto),
/// `""` (Explicit Empty string, e.g. Linux `platformVersion` / Android `architecture`),
/// and a non-empty custom value.
private struct CuriumTriStateTextField: View {
    let title: String
    let emptyLabel: String
    let customPlaceholder: String
    @Binding var value: String?
    let isReadOnly: Bool
    var monospaced: Bool = true

    private enum Mode: String, CaseIterable, Identifiable {
        case auto
        case explicitEmpty
        case custom

        var id: String { rawValue }
    }

    @State private var mode: Mode
    @State private var customText: String

    init(
        title: String,
        emptyLabel: String = "Empty (\"\")",
        customPlaceholder: String,
        value: Binding<String?>,
        isReadOnly: Bool,
        monospaced: Bool = true
    ) {
        self.title = title
        self.emptyLabel = emptyLabel
        self.customPlaceholder = customPlaceholder
        self._value = value
        self.isReadOnly = isReadOnly
        self.monospaced = monospaced
        if let current = value.wrappedValue {
            if current.isEmpty {
                _mode = State(initialValue: .explicitEmpty)
                _customText = State(initialValue: "")
            } else {
                _mode = State(initialValue: .custom)
                _customText = State(initialValue: current)
            }
        } else {
            _mode = State(initialValue: .auto)
            _customText = State(initialValue: "")
        }
    }

    var body: some View {
        Picker(title, selection: $mode) {
            Text("Auto").tag(Mode.auto)
            Text(emptyLabel).tag(Mode.explicitEmpty)
            Text("Custom").tag(Mode.custom)
        }
        .disabled(isReadOnly)
        .onChange(of: mode) { _, next in
            switch next {
            case .auto:
                value = nil
            case .explicitEmpty:
                value = ""
            case .custom:
                value = customText
            }
        }

        if mode == .custom {
            CuriumStackedTextFieldRow(
                title: "\(title) Value",
                placeholder: customPlaceholder,
                text: $customText,
                isReadOnly: isReadOnly,
                monospaced: monospaced
            )
            .onChange(of: customText) { _, next in
                guard mode == .custom else { return }
                value = next
            }
        }
    }
}

private struct CuriumShareDocument: Identifiable {
    let id = UUID()
    let text: String
}

private struct CuriumActivityShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Profile Editor / Built-In Inspector

private struct CuriumFingerprintEditorView: View {
    enum Mode {
        case inspectBuiltIn
        case editCustom
        case createNew
    }

    private enum EditorDialog: Identifiable {
        case wipeStorage
        case discardChanges
        case saveBeforeSelect

        var id: String {
            switch self {
            case .wipeStorage: return "wipeStorage"
            case .discardChanges: return "discardChanges"
            case .saveBeforeSelect: return "saveBeforeSelect"
            }
        }

        var title: String {
            switch self {
            case .wipeStorage: return "Wipe Isolated Storage?"
            case .discardChanges: return "Discard Unsaved Changes?"
            case .saveBeforeSelect: return "Save Changes Before Selecting?"
            }
        }
    }

    private struct ValidationTrigger: Equatable {
        let draft: CuriumFingerprintProfile
        let useSystemLanguages: Bool
        let languagesText: String
        let proxyModeSelection: ProxyModeChoice
        let fixedProxyRules: String
        let fixedProxyBypass: String
    }

    @Bindable var store: CuriumFingerprintStore
    let mode: Mode
    let isActiveInProcess: Bool
    let usage: CuriumFingerprintProfileStorage.UsageSnapshot?
    let onDuplicateToEdit: (CuriumFingerprintProfile) -> Void
    let onSaved: () -> Void
    let onWiped: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CuriumFingerprintProfile
    @State private var savedBaseline: CuriumFingerprintProfile
    @State private var currentUsage: CuriumFingerprintProfileStorage.UsageSnapshot?
    @State private var hardwareOverrideEnabled: Bool
    @State private var useSystemLanguages: Bool
    @State private var languagesText: String
    @State private var proxyModeSelection: ProxyModeChoice
    @State private var fixedProxyRules: String
    @State private var fixedProxyBypass: String
    @State private var cachedReport: CuriumFingerprintValidationReport
    @State private var copiedLabel: String?
    @State private var activeDialog: EditorDialog?
    @State private var isWiping = false
    @State private var alertMessage: String?
    @State private var pendingShareDocument: CuriumShareDocument?

    private enum ProxyModeChoice: String, CaseIterable, Identifiable, Equatable {
        case system, direct, fixed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "System"
            case .direct: return "Direct"
            case .fixed: return "Fixed"
            }
        }
    }

    private static let commonTimezones: [String] = [
        "UTC",
        "America/New_York",
        "America/Chicago",
        "America/Los_Angeles",
        "Europe/London",
        "Europe/Berlin",
        "Europe/Paris",
        "Asia/Tokyo",
        "Asia/Shanghai",
        "Asia/Singapore",
        "Australia/Sydney",
    ]

    private var isReadOnly: Bool { mode == .inspectBuiltIn }
    private var isSelectedForNextLaunch: Bool { store.selectedProfileID == draft.id }
    private var hasUnsavedChanges: Bool { !isReadOnly && effectiveDraft != savedBaseline }

    private var validationTrigger: ValidationTrigger {
        ValidationTrigger(
            draft: draft,
            useSystemLanguages: useSystemLanguages,
            languagesText: languagesText,
            proxyModeSelection: proxyModeSelection,
            fixedProxyRules: fixedProxyRules,
            fixedProxyBypass: fixedProxyBypass
        )
    }

    init(
        store: CuriumFingerprintStore,
        initialProfile: CuriumFingerprintProfile,
        mode: Mode,
        isActiveInProcess: Bool,
        usage: CuriumFingerprintProfileStorage.UsageSnapshot?,
        onDuplicateToEdit: @escaping (CuriumFingerprintProfile) -> Void,
        onSaved: @escaping () -> Void,
        onWiped: @escaping () -> Void
    ) {
        self.store = store
        self.mode = mode
        self.isActiveInProcess = isActiveInProcess
        self.usage = usage
        self.onDuplicateToEdit = onDuplicateToEdit
        self.onSaved = onSaved
        self.onWiped = onWiped
        _draft = State(initialValue: initialProfile)
        _savedBaseline = State(initialValue: initialProfile.normalizedForPersistence())
        _currentUsage = State(initialValue: usage)
        _hardwareOverrideEnabled = State(initialValue: !initialProfile.usesNativeHardwareAndGPU)
        _useSystemLanguages = State(initialValue: initialProfile.languages == nil)
        _languagesText = State(initialValue: (initialProfile.languages ?? []).joined(separator: ", "))
        switch initialProfile.proxy {
        case .system:
            _proxyModeSelection = State(initialValue: .system)
            _fixedProxyRules = State(initialValue: "")
            _fixedProxyBypass = State(initialValue: "")
        case .direct:
            _proxyModeSelection = State(initialValue: .direct)
            _fixedProxyRules = State(initialValue: "")
            _fixedProxyBypass = State(initialValue: "")
        case .fixed(let rules, let bypass):
            _proxyModeSelection = State(initialValue: .fixed)
            _fixedProxyRules = State(initialValue: rules)
            _fixedProxyBypass = State(initialValue: bypass ?? "")
        }
        let initialNormalized = initialProfile.normalizedForPersistence()
        let initialReport = Self.evaluateValidation(
            candidate: initialNormalized,
            mode: mode,
            store: store
        )
        _cachedReport = State(initialValue: initialReport)
    }

    private var effectiveDraft: CuriumFingerprintProfile {
        var profile = draft
        if useSystemLanguages {
            profile.languages = nil
        } else {
            let parsed = languagesText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            profile.languages = parsed
        }
        switch proxyModeSelection {
        case .system:
            profile.proxy = .system
        case .direct:
            profile.proxy = .direct
        case .fixed:
            let trimmedBypass = fixedProxyBypass.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.proxy = .fixed(
                rules: fixedProxyRules.trimmingCharacters(in: .whitespacesAndNewlines),
                bypassRules: trimmedBypass.isEmpty ? nil : trimmedBypass
            )
        }
        return profile.normalizedForPersistence()
    }

    private static func evaluateValidation(
        candidate: CuriumFingerprintProfile,
        mode: Mode,
        store: CuriumFingerprintStore
    ) -> CuriumFingerprintValidationReport {
        if mode == .createNew {
            var report = store.validateForUpsert(candidate)
            let lowered = candidate.id.lowercased()
            if store.profiles.contains(where: { $0.id.lowercased() == lowered })
                && !report.errors.contains(where: { $0.contains("already exists") || $0.contains("Built-in profile") })
            {
                report.errors.append("A profile with ID \"\(candidate.id)\" already exists (APFS IDs are case-insensitive).")
            }
            return report
        }
        return CuriumFingerprintValidator.validate(candidate)
    }

    private var storageFolderDisplayName: String? {
        let trimmed = draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CuriumFingerprintValidator.isValidProfileID(trimmed) else { return nil }
        return trimmed == "default" ? "Chromium/" : "ChromiumProfiles/\(trimmed)"
    }

    var body: some View {
        Form {
            quickActionSection
            profileMetadataSection
            identitySlotsSection
            antiFingerprintingSection
            hardwareAndGPUSection
            networkAndPrivacySection
            storageAndJSONSection
            if !cachedReport.errors.isEmpty || !cachedReport.warnings.isEmpty {
                validationSection(cachedReport)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(mode == .createNew ? "New Profile" : draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .interactiveDismissDisabled(hasUnsavedChanges)
        .onChange(of: usage) { _, latest in
            currentUsage = latest
        }
        .onChange(of: draft.usesNativeHardwareAndGPU) { _, isNative in
            if !isNative && !hardwareOverrideEnabled {
                hardwareOverrideEnabled = true
            }
        }
        .task(id: validationTrigger) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            cachedReport = Self.evaluateValidation(
                candidate: effectiveDraft,
                mode: mode,
                store: store
            )
        }
        .toolbar {
            if hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        activeDialog = .discardChanges
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .accessibilityIdentifier("curium.studio.editor.back")
                }
            }
            if !isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveProfile(dismissAfterSave: true)
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .disabled(!cachedReport.isValid || store.loadError != nil)
                    .accessibilityIdentifier("curium.studio.editor.save")
                }
            }
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
            case .wipeStorage:
                Button("Wipe Cookies, Cache & Storage", role: .destructive) {
                    wipeStorage()
                }
                Button("Cancel", role: .cancel) {}
            case .discardChanges:
                Button("Discard Changes", role: .destructive) {
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            case .saveBeforeSelect:
                if cachedReport.isValid {
                    Button("Save & Use for Next Launch") {
                        if saveProfile(dismissAfterSave: false) {
                            selectCurrentProfile()
                        }
                    }
                }
                Button("Use Previously Saved Version") {
                    selectCurrentProfile()
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { dialog in
            switch dialog {
            case .wipeStorage:
                Text("Clears isolated cookies, localStorage, IndexedDB, CacheStorage, and HTTP cache for \"\(draft.id)\".")
            case .discardChanges:
                Text("Your unsaved edits to \"\(draft.displayName.isEmpty ? draft.id : draft.displayName)\" will be lost.")
            case .saveBeforeSelect:
                if cachedReport.isValid {
                    Text("You have unsaved edits. Save them before selecting this profile for next launch, or select the previously saved version.")
                } else {
                    Text("Your current edits have validation errors and cannot be saved yet. You can fix them first or select the previously saved version.")
                }
            }
        }
        .sheet(item: $pendingShareDocument) { doc in
            CuriumActivityShareSheet(text: doc.text)
                .presentationDetents([.medium, .large])
        }
        .alert("Profile Editor", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Form Sections

    private var quickActionSection: some View {
        Section {
            if mode != .createNew {
                Button {
                    if hasUnsavedChanges {
                        activeDialog = .saveBeforeSelect
                    } else {
                        selectCurrentProfile()
                    }
                } label: {
                    Label(
                        isSelectedForNextLaunch ? "Selected for Next Launch" : "Use for Next Launch",
                        systemImage: isSelectedForNextLaunch ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
                .disabled((isSelectedForNextLaunch && !hasUnsavedChanges) || store.loadError != nil)
                .accessibilityIdentifier("curium.studio.editor.select")
            }

            if isReadOnly {
                Button {
                    duplicateBuiltIn()
                } label: {
                    Label("Duplicate & Customize", systemImage: "plus.square.on.square")
                }
                .disabled(store.loadError != nil)
                .accessibilityIdentifier("curium.studio.editor.duplicate")
            } else {
                // Constant-height validation status anchor so typing never shifts TextFields below.
                validationSummaryRow
            }
        } footer: {
            if isReadOnly {
                Text("Built-in presets are immutable templates. Duplicate this preset to edit its identity, proxy, language, or hardware overrides.")
            } else if isActiveInProcess {
                Text("This profile is active in the current session. Saved edits bump revision and apply on the next cold launch.")
            }
        }
    }

    private var validationSummaryRow: some View {
        Group {
            if !cachedReport.errors.isEmpty {
                Label(
                    "\(cachedReport.errors.count) validation \(cachedReport.errors.count == 1 ? "error" : "errors") — see Validation below",
                    systemImage: "xmark.octagon.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
            } else if !cachedReport.warnings.isEmpty {
                Label(
                    "\(cachedReport.warnings.count) coherence \(cachedReport.warnings.count == 1 ? "warning" : "warnings") — see Validation below",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } else {
                Label("Configuration valid", systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

    private func validationSection(_ report: CuriumFingerprintValidationReport) -> some View {
        Section("Validation & Coherence") {
            ForEach(report.errors, id: \.self) { error in
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var profileMetadataSection: some View {
        Section("Profile") {
            if mode == .createNew {
                CuriumStackedTextFieldRow(
                    title: "Profile ID",
                    placeholder: "work-us-01",
                    text: $draft.id,
                    isReadOnly: false,
                    monospaced: true,
                    font: .body
                )
            } else {
                LabeledContent("Profile ID") {
                    Text(draft.id)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            CuriumStackedTextFieldRow(
                title: "Display Name",
                placeholder: "Display Name",
                text: $draft.displayName,
                isReadOnly: isReadOnly,
                monospaced: false,
                font: .body,
                autocapitalization: .words
            )

            CuriumStackedTextFieldRow(
                title: "Notes",
                placeholder: "Optional notes",
                text: $draft.notes,
                isReadOnly: isReadOnly,
                monospaced: false,
                font: .callout,
                autocapitalization: .sentences
            )

            Picker("Default Slot", selection: $draft.defaultSlot) {
                ForEach(CuriumDefaultSlot.allCases) { slot in
                    Text(slot.title).tag(slot)
                }
            }
            .disabled(isReadOnly)

            if mode != .createNew {
                LabeledContent("Revision", value: "\(draft.revision)")
            }
        }
    }

    private var identitySlotsSection: some View {
        Section {
            NavigationLink {
                CuriumIdentitySlotEditorView(
                    title: "Mobile Slot",
                    slotKey: "mobile",
                    slot: $draft.mobile,
                    isReadOnly: isReadOnly
                )
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mobile Identity Slot")
                    Text(slotSummary(draft.mobile, fallbackPlatform: "Android"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            NavigationLink {
                CuriumIdentitySlotEditorView(
                    title: "Desktop Slot",
                    slotKey: "desktop",
                    slot: $draft.desktop,
                    isReadOnly: isReadOnly
                )
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Desktop Identity Slot")
                    Text(slotSummary(draft.desktop, fallbackPlatform: "macOS"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("IdentitySpec (Dual-Slot)")
        } footer: {
            Text("Mobile and Desktop slots are frozen at launch; Request Desktop Site toggles between the two slots without mutating history.")
        }
    }

    private var antiFingerprintingSection: some View {
        Section {
            Toggle("Deterministic Per-Site Farbling", isOn: Binding(
                get: { draft.fingerprintSeed != nil },
                set: { enabled in
                    if enabled {
                        if draft.fingerprintSeed == nil {
                            draft.fingerprintSeed = CuriumFingerprintSchema.generateRandomSeedHex()
                        }
                        if draft.farbling == nil {
                            draft.farbling = .allEnabled
                        }
                    } else {
                        draft.fingerprintSeed = nil
                        draft.farbling = nil
                    }
                }
            ))
            .disabled(isReadOnly)
            .accessibilityIdentifier("curium.studio.editor.farbling")

            if let seed = draft.fingerprintSeed {
                LabeledContent("Seed (HMAC-SHA256)") {
                    HStack(spacing: 6) {
                        Text("\(seed.prefix(12))…\(seed.suffix(8))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.string = seed
                            copiedLabel = "seed"
                        } label: {
                            Image(systemName: copiedLabel == "seed" ? "checkmark.circle" : "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy Farbling Seed")
                    }
                }

                if !isReadOnly {
                    Button {
                        draft.fingerprintSeed = CuriumFingerprintStore.mintFreshSeed(differentFrom: seed)
                    } label: {
                        Label("Rotate Farbling Seed", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Toggle("Canvas 2D & OffscreenCanvas", isOn: farblingBinding(\.canvas))
                    .disabled(isReadOnly)
                Toggle("WebAudio (Offline & Analyser)", isOn: farblingBinding(\.audio))
                    .disabled(isReadOnly)
                Toggle("WebGL readPixels", isOn: farblingBinding(\.webgl))
                    .disabled(isReadOnly)
                Toggle("Canvas TextMetrics", isOn: farblingBinding(\.textMetrics))
                    .disabled(isReadOnly)
            }

            Picker("Font Profile", selection: $draft.fontProfile) {
                Text("Auto (Match Platform)").tag(CuriumFontProfile?.none)
                ForEach(CuriumFontProfile.allCases) { option in
                    Text(option.title).tag(CuriumFontProfile?.some(option))
                }
            }
            .disabled(isReadOnly)

            Picker("Speech Synthesis Voices", selection: $draft.hideSpeechVoices) {
                Text("Auto (Hide on Non-Apple)").tag(Bool?.none)
                Text("Hide Apple Voices").tag(Bool?.some(true))
                Text("Native Voices").tag(Bool?.some(false))
            }
            .disabled(isReadOnly)
        } header: {
            Text("Native Anti-Fingerprinting (Build 41)")
        } footer: {
            Text("Perturbations are deterministic per top-level site in Blink C++ with zero JS prototype footprint. Non-Apple font profiles hide Apple-exclusive fonts while preserving CJK & Emoji glyph fallback.")
        }
    }

    private func farblingBinding(_ keyPath: WritableKeyPath<CuriumFarblingSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { (draft.farbling ?? .allEnabled)[keyPath: keyPath] },
            set: { newValue in
                var current = draft.farbling ?? .allEnabled
                current[keyPath: keyPath] = newValue
                draft.farbling = current
            }
        )
    }

    private var hardwareAndGPUSection: some View {
        Section {
            Toggle("Override Hardware & GPU", isOn: Binding(
                get: { hardwareOverrideEnabled },
                set: { enabled in
                    hardwareOverrideEnabled = enabled
                    if !enabled {
                        // Explicitly restore authentic native Apple hardware & Metal GPU.
                        draft.hardware = .native
                        draft.mobile.webglVendor = nil
                        draft.mobile.webglRenderer = nil
                        draft.desktop.webglVendor = nil
                        draft.desktop.webglRenderer = nil
                    }
                }
            ))
            .disabled(isReadOnly)
            .accessibilityIdentifier("curium.studio.editor.hwOverride")

            if !hardwareOverrideEnabled {
                Label("Native Apple Silicon CPU, RAM, Timezone & Metal GPU preserved (zero override overhead).", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                Picker("CPU Cores", selection: $draft.hardware.hardwareConcurrency) {
                    Text("Native Device").tag(Int?.none)
                    ForEach([2, 4, 6, 8, 10, 12, 16, 24, 32], id: \.self) { count in
                        Text("\(count) cores").tag(Int?.some(count))
                    }
                }
                .disabled(isReadOnly)

                Picker("Device Memory (W3C)", selection: $draft.hardware.deviceMemoryGB) {
                    Text("Native Device").tag(Double?.none)
                    ForEach(CuriumFingerprintSchema.validDeviceMemoryBuckets, id: \.self) { gb in
                        Text(gb < 1 ? "\(gb) GB" : "\(Int(gb)) GB").tag(Double?.some(gb))
                    }
                }
                .disabled(isReadOnly)

                Picker("Timezone Preset", selection: Binding<String>(
                    get: { draft.hardware.timezone ?? "" },
                    set: { draft.hardware.timezone = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Native Device Timezone").tag("")
                    ForEach(Self.commonTimezones, id: \.self) { tz in
                        Text(tz).tag(tz)
                    }
                    if let current = draft.hardware.timezone, !current.isEmpty, !Self.commonTimezones.contains(current) {
                        Text(current).tag(current)
                    }
                }
                .disabled(isReadOnly)

                CuriumStackedTextFieldRow(
                    title: "Custom IANA Timezone",
                    placeholder: "e.g. Europe/Berlin",
                    text: optionalStringBinding(\.hardware.timezone),
                    isReadOnly: isReadOnly
                )

                if !isReadOnly {
                    Menu {
                        Button("Clear WebGL (Native Apple Metal)") {
                            applyWebGLPreset(vendor: nil, renderer: nil)
                        }
                        Button("Intel Iris Xe (Windows D3D11)") {
                            applyWebGLPreset(
                                vendor: "Google Inc. (Intel)",
                                renderer: "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)"
                            )
                        }
                        Button("Mesa Intel ADL GT2 (Linux OpenGL)") {
                            applyWebGLPreset(
                                vendor: "Google Inc. (Intel)",
                                renderer: "ANGLE (Intel, Mesa Intel(R) Graphics (ADL GT2), OpenGL 4.6)"
                            )
                        }
                        Button("NVIDIA RTX 4070 (Windows D3D11)") {
                            applyWebGLPreset(
                                vendor: "Google Inc. (NVIDIA)",
                                renderer: "ANGLE (NVIDIA, NVIDIA GeForce RTX 4070 Direct3D11 vs_5_0 ps_5_0, D3D11)"
                            )
                        }
                    } label: {
                        Label("Apply WebGL GPU Preset to Both Slots…", systemImage: "cpu")
                    }
                }

                CuriumStackedTextFieldRow(
                    title: "Desktop WebGL Vendor",
                    placeholder: "Native Apple",
                    text: optionalStringBinding(\.desktop.webglVendor),
                    isReadOnly: isReadOnly,
                    font: .caption
                )

                CuriumStackedTextFieldRow(
                    title: "Desktop WebGL Renderer",
                    placeholder: "Native Apple Metal",
                    text: optionalStringBinding(\.desktop.webglRenderer),
                    isReadOnly: isReadOnly,
                    font: .caption
                )

                if draft.mobile.hasWebGLOverride
                    || draft.mobile.webglVendor != draft.desktop.webglVendor
                    || draft.mobile.webglRenderer != draft.desktop.webglRenderer
                {
                    CuriumStackedTextFieldRow(
                        title: "Mobile WebGL Vendor",
                        placeholder: "Native Apple",
                        text: optionalStringBinding(\.mobile.webglVendor),
                        isReadOnly: isReadOnly,
                        font: .caption
                    )

                    CuriumStackedTextFieldRow(
                        title: "Mobile WebGL Renderer",
                        placeholder: "Native Apple Metal",
                        text: optionalStringBinding(\.mobile.webglRenderer),
                        isReadOnly: isReadOnly,
                        font: .caption
                    )
                }
            }
        } header: {
            Text("Hardware, Timezone & GPU")
        } footer: {
            Text("Leave off for authentic Apple hardware. Turn on only when spoofing a non-Apple platform (such as Windows or Linux) where WebGL and CPU/RAM parity matter.")
        }
    }

    private var networkAndPrivacySection: some View {
        Section("Network, Languages & Privacy") {
            Toggle("Follow iOS System Languages", isOn: Binding(
                get: { useSystemLanguages },
                set: { followSystem in
                    useSystemLanguages = followSystem
                    if !followSystem && languagesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        languagesText = "en-US, en"
                    }
                }
            ))
            .disabled(isReadOnly)

            if !useSystemLanguages {
                CuriumStackedTextFieldRow(
                    title: "BCP-47 Language Tags",
                    placeholder: "en-US, en",
                    text: $languagesText,
                    isReadOnly: isReadOnly
                )

                if !isReadOnly {
                    Menu {
                        Button("English (US): en-US, en") { languagesText = "en-US, en" }
                        Button("Chinese + English: zh-Hans-CN, en-US") { languagesText = "zh-Hans-CN, en-US" }
                        Button("Japanese + English: ja-JP, en-US") { languagesText = "ja-JP, en-US" }
                        Button("German + English: de-DE, en-US") { languagesText = "de-DE, en-US" }
                        Button("French + English: fr-FR, en-US") { languagesText = "fr-FR, en-US" }
                    } label: {
                        Label("Quick Language Preset…", systemImage: "globe")
                    }
                }
            }

            Picker("Proxy Mode", selection: $proxyModeSelection) {
                ForEach(ProxyModeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .disabled(isReadOnly)

            if proxyModeSelection == .fixed {
                CuriumStackedTextFieldRow(
                    title: "Proxy Rules",
                    placeholder: "socks5://127.0.0.1:1080",
                    text: $fixedProxyRules,
                    isReadOnly: isReadOnly,
                    keyboardType: .URL
                )

                CuriumStackedTextFieldRow(
                    title: "Bypass Rules",
                    placeholder: "Optional (e.g. <-loopback>)",
                    text: $fixedProxyBypass,
                    isReadOnly: isReadOnly
                )

                Toggle("Proxy Loopback Traffic (<-loopback>)", isOn: Binding(
                    get: { fixedProxyBypass.contains("<-loopback>") },
                    set: { include in
                        var parts = fixedProxyBypass
                            .split(separator: ";")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty && $0 != "<-loopback>" }
                        if include { parts.append("<-loopback>") }
                        fixedProxyBypass = parts.joined(separator: ";")
                    }
                ))
                .disabled(isReadOnly)
            }

            Picker("WebRTC IP Policy", selection: $draft.webrtcIpHandlingPolicy) {
                ForEach(CuriumWebRTCPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .disabled(isReadOnly)

            Toggle("Send Do Not Track (DNT: 1)", isOn: $draft.enableDoNotTrack)
                .disabled(isReadOnly)

            Toggle("Global Privacy Control (Sec-GPC: 1)", isOn: $draft.enableGlobalPrivacyControl)
                .disabled(isReadOnly)
        }
    }

    private var storageAndJSONSection: some View {
        Section("Storage & JSON Export") {
            if let folder = storageFolderDisplayName {
                LabeledContent("Storage Folder") {
                    Text(folder)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let currentUsage {
                LabeledContent("Disk Footprint") {
                    Text(currentUsage.exists
                        ? ByteCountFormatter.string(fromByteCount: currentUsage.totalBytes, countStyle: .file)
                        : "Not created yet")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                copyProfileJSON()
            } label: {
                Label(
                    copiedLabel == "profile" ? "Copied Profile JSON" : "Copy Profile JSON",
                    systemImage: copiedLabel == "profile" ? "checkmark.circle" : "doc.on.doc"
                )
            }

            Button {
                copyEngineWireJSON()
            } label: {
                Label(
                    copiedLabel == "wire" ? "Copied Engine Wire JSON" : "Copy Engine Wire JSON (v\(CuriumFingerprintSchema.version))",
                    systemImage: copiedLabel == "wire" ? "checkmark.circle" : "curlybraces"
                )
            }
            .disabled(!cachedReport.isValid)

            Button {
                if let text = exportJSONString() {
                    pendingShareDocument = CuriumShareDocument(text: text)
                } else {
                    alertMessage = "Failed to encode profile JSON for sharing."
                }
            } label: {
                Label("Share Profile JSON", systemImage: "square.and.arrow.up")
            }

            if mode != .createNew && draft.id != "default" {
                Button(role: .destructive) {
                    activeDialog = .wipeStorage
                } label: {
                    HStack {
                        Label(
                            isWiping ? "Wiping Isolated Storage…" : "Wipe Isolated Storage",
                            systemImage: "externaldrive.badge.xmark"
                        )
                        if isWiping {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isActiveInProcess || isWiping || currentUsage?.exists != true)
            }
        }
    }

    // MARK: - Helpers

    private func slotSummary(_ slot: CuriumIdentitySlot, fallbackPlatform: String) -> String {
        let platform = slot.platform ?? fallbackPlatform
        let nav = slot.navigatorPlatform ?? "auto"
        let version = slot.majorVersion.map { "Chrome/\($0)" } ?? "Engine Chrome"
        return "\(platform) · \(nav) · \(version)"
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<CuriumFingerprintProfile, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { newValue in
                draft[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func applyWebGLPreset(vendor: String?, renderer: String?) {
        draft.mobile.webglVendor = vendor
        draft.mobile.webglRenderer = renderer
        draft.desktop.webglVendor = vendor
        draft.desktop.webglRenderer = renderer
    }

    private func selectCurrentProfile() {
        if !store.selectProfile(id: draft.id) {
            alertMessage = store.lastPersistError ?? "Unable to select profile."
        }
    }

    private func duplicateBuiltIn() {
        let newID = store.nextAvailableID(base: draft.id)
        guard let copy = store.duplicateProfile(
            from: draft.id,
            newID: newID,
            displayName: "\(draft.displayName) Copy"
        ) else {
            alertMessage = store.lastPersistError ?? "Unable to duplicate preset."
            return
        }
        onDuplicateToEdit(copy)
    }

    @discardableResult
    private func saveProfile(dismissAfterSave: Bool) -> Bool {
        let candidate = effectiveDraft
        let preflight = Self.evaluateValidation(candidate: candidate, mode: mode, store: store)
        cachedReport = preflight
        guard preflight.isValid else {
            alertMessage = preflight.errors.joined(separator: "\n")
            return false
        }
        let report = store.upsert(candidate)
        cachedReport = report
        guard report.isValid else {
            alertMessage = report.errors.joined(separator: "\n")
            return false
        }
        if let updated = store.profiles.first(where: { $0.id == candidate.id }) {
            draft = updated
            savedBaseline = updated.normalizedForPersistence()
        } else {
            savedBaseline = candidate
        }
        onSaved()
        if dismissAfterSave && mode == .editCustom {
            dismiss()
        }
        return true
    }

    private func exportJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(effectiveDraft) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func copyProfileJSON() {
        guard let text = exportJSONString() else { return }
        UIPasteboard.general.string = text
        copiedLabel = "profile"
    }

    private func copyEngineWireJSON() {
        do {
            let data = try effectiveDraft.makeEngineLaunchJSON()
            if let text = String(data: data, encoding: .utf8) {
                UIPasteboard.general.string = text
                copiedLabel = "wire"
            }
        } catch {
            alertMessage = "Failed to encode engine wire JSON: \(error.localizedDescription)"
        }
    }

    private func wipeStorage() {
        guard !isWiping else { return }
        isWiping = true
        let id = draft.id
        let active = CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(id)
        Task.detached(priority: .userInitiated) {
            do {
                try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                    id,
                    isActiveInCurrentProcess: active
                )
                await MainActor.run {
                    isWiping = false
                    currentUsage = CuriumFingerprintProfileStorage.UsageSnapshot(
                        supportBytes: 0, cacheBytes: 0, exists: false
                    )
                    onWiped()
                }
            } catch {
                await MainActor.run {
                    isWiping = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Identity Slot Sub-Editor

private struct CuriumIdentitySlotEditorView: View {
    let title: String
    let slotKey: String
    @Binding var slot: CuriumIdentitySlot
    let isReadOnly: Bool

    @State private var brandMode: PrimaryBrandMode
    @State private var customBrandText: String
    @State private var cachedSlotReport: CuriumFingerprintValidationReport
    @FocusState private var isNumberPadFocused: Bool

    private enum PrimaryBrandMode: String, CaseIterable, Identifiable {
        case defaultChrome
        case chromiumOnly
        case custom

        var id: String { rawValue }
        var title: String {
            switch self {
            case .defaultChrome: return "Default (Google Chrome)"
            case .chromiumOnly: return "Chromium Only (2 Brands)"
            case .custom: return "Custom Brand"
            }
        }
    }

    init(title: String, slotKey: String, slot: Binding<CuriumIdentitySlot>, isReadOnly: Bool) {
        self.title = title
        self.slotKey = slotKey
        self._slot = slot
        self.isReadOnly = isReadOnly
        let currentBrand = slot.wrappedValue.primaryBrand
        if let currentBrand {
            if currentBrand.isEmpty {
                _brandMode = State(initialValue: .chromiumOnly)
                _customBrandText = State(initialValue: "Google Chrome")
            } else {
                _brandMode = State(initialValue: .custom)
                _customBrandText = State(initialValue: currentBrand)
            }
        } else {
            _brandMode = State(initialValue: .defaultChrome)
            _customBrandText = State(initialValue: "Google Chrome")
        }
        _cachedSlotReport = State(
            initialValue: CuriumFingerprintValidator.validateSlot(
                slot.wrappedValue.normalizedForPersistence(),
                name: slotKey
            )
        )
    }

    var body: some View {
        Form {
            Section("User-Agent") {
                CuriumStackedTextFieldRow(
                    title: "OS / CPU Token",
                    placeholder: "Auto",
                    text: optText(\.osCpu),
                    isReadOnly: isReadOnly,
                    font: .caption
                )

                CuriumStackedTextFieldRow(
                    title: "Full UA Override",
                    placeholder: "Leave blank to synthesize",
                    text: optText(\.uaString),
                    isReadOnly: isReadOnly,
                    font: .caption
                )

                Picker("Append Mobile Token", selection: $slot.appendMobileToken) {
                    Text("Auto").tag(Bool?.none)
                    Text("Yes (Mobile)").tag(Bool?.some(true))
                    Text("No").tag(Bool?.some(false))
                }
                .disabled(isReadOnly)
            }

            Section("Brand & Chrome Version") {
                Picker("Primary Brand", selection: $brandMode) {
                    ForEach(PrimaryBrandMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .disabled(isReadOnly)
                .onChange(of: brandMode) { _, next in
                    switch next {
                    case .defaultChrome:
                        slot.primaryBrand = nil
                    case .chromiumOnly:
                        slot.primaryBrand = ""
                    case .custom:
                        let trimmed = customBrandText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            customBrandText = "Google Chrome"
                            slot.primaryBrand = "Google Chrome"
                        } else {
                            slot.primaryBrand = customBrandText
                        }
                    }
                }

                if brandMode == .custom {
                    CuriumStackedTextFieldRow(
                        title: "Custom Brand",
                        placeholder: "Google Chrome",
                        text: $customBrandText,
                        isReadOnly: isReadOnly,
                        monospaced: false
                    )
                    .onChange(of: customBrandText) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        slot.primaryBrand = trimmed.isEmpty ? nil : value
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Major Version")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if isReadOnly {
                        Text(slot.majorVersion ?? "Engine default (160)")
                            .font(.callout.monospaced())
                            .foregroundStyle(slot.majorVersion == nil ? .tertiary : .primary)
                            .textSelection(.enabled)
                    } else {
                        TextField("Engine default (160)", text: optText(\.majorVersion))
                            .keyboardType(.numberPad)
                            .focused($isNumberPadFocused)
                            .font(.callout.monospaced())
                    }
                }
                .padding(.vertical, 2)

                CuriumStackedTextFieldRow(
                    title: "Full Version",
                    placeholder: "Auto from major",
                    text: optText(\.fullVersion),
                    isReadOnly: isReadOnly
                )
            }

            Section {
                CuriumStackedTextFieldRow(
                    title: "CH Platform",
                    placeholder: "macOS / Windows / Android / Linux",
                    text: optText(\.platform),
                    isReadOnly: isReadOnly,
                    monospaced: false
                )

                CuriumTriStateTextField(
                    title: "Platform Version",
                    emptyLabel: "Empty (\"\" — Linux)",
                    customPlaceholder: "e.g. 15.0.0 or 19.0.0",
                    value: $slot.platformVersion,
                    isReadOnly: isReadOnly
                )

                CuriumTriStateTextField(
                    title: "Architecture",
                    emptyLabel: "Empty (\"\" — Android)",
                    customPlaceholder: "e.g. arm or x86",
                    value: $slot.architecture,
                    isReadOnly: isReadOnly
                )

                Picker("Bitness", selection: $slot.bitness) {
                    Text("Auto").tag(String?.none)
                    Text("Empty (Mobile Android)").tag(String?.some(""))
                    Text("64-bit").tag(String?.some("64"))
                    Text("32-bit").tag(String?.some("32"))
                }
                .disabled(isReadOnly)

                CuriumTriStateTextField(
                    title: "Device Model",
                    emptyLabel: "Empty (\"\")",
                    customPlaceholder: "e.g. Pixel 9",
                    value: $slot.model,
                    isReadOnly: isReadOnly,
                    monospaced: false
                )

                Picker("CH Mobile (?1 / ?0)", selection: $slot.mobile) {
                    Text("Auto").tag(Bool?.none)
                    Text("Mobile (?1)").tag(Bool?.some(true))
                    Text("Desktop (?0)").tag(Bool?.some(false))
                }
                .disabled(isReadOnly)

                Picker("WoW64", selection: $slot.wow64) {
                    Text("Auto").tag(Bool?.none)
                    Text("False (?0)").tag(Bool?.some(false))
                    Text("True (?1)").tag(Bool?.some(true))
                }
                .disabled(isReadOnly)

                CuriumStackedTextFieldRow(
                    title: "navigator.platform",
                    placeholder: "MacIntel / Win32 / Linux armv81",
                    text: optText(\.navigatorPlatform),
                    isReadOnly: isReadOnly
                )
            } header: {
                Text("Client Hints & Navigator")
            } footer: {
                Text("Choose Auto to let the engine resolve defaults, Empty (\"\") to emit an explicit empty Client Hint header (e.g. Linux platformVersion or Android architecture), or Custom.")
            }

            Section("Optional Input & WebGL Slot Overrides") {
                Picker("Max Touch Points", selection: $slot.maxTouchPoints) {
                    Text("Native Device").tag(Int?.none)
                    Text("0 (Mouse Desktop)").tag(Int?.some(0))
                    Text("5 (Mobile Touch)").tag(Int?.some(5))
                    Text("10 (Tablet Touch)").tag(Int?.some(10))
                }
                .disabled(isReadOnly)

                Picker("Pointer Type", selection: $slot.pointerType) {
                    Text("Native Device").tag(CuriumPointerType?.none)
                    ForEach(CuriumPointerType.allCases) { option in
                        Text(option.title).tag(CuriumPointerType?.some(option))
                    }
                }
                .disabled(isReadOnly)

                Picker("Hover Capability", selection: $slot.hoverType) {
                    Text("Native Device").tag(CuriumHoverType?.none)
                    ForEach(CuriumHoverType.allCases) { option in
                        Text(option.title).tag(CuriumHoverType?.some(option))
                    }
                }
                .disabled(isReadOnly)

                CuriumStackedTextFieldRow(
                    title: "WebGL Vendor",
                    placeholder: "Native Apple",
                    text: optText(\.webglVendor),
                    isReadOnly: isReadOnly,
                    font: .caption
                )

                CuriumStackedTextFieldRow(
                    title: "WebGL Renderer",
                    placeholder: "Native Apple Metal",
                    text: optText(\.webglRenderer),
                    isReadOnly: isReadOnly,
                    font: .caption
                )

                Picker("WebGL Capability Profile", selection: $slot.webglProfile) {
                    Text("Auto (Match Platform)").tag(CuriumWebGLProfile?.none)
                    ForEach(CuriumWebGLProfile.allCases) { option in
                        Text(option.title).tag(CuriumWebGLProfile?.some(option))
                    }
                }
                .disabled(isReadOnly)

                Picker("PDF Viewer Metadata", selection: $slot.pdfViewerEnabled) {
                    Text("Auto (Desktop Only)").tag(Bool?.none)
                    Text("Expose PDF Viewer").tag(Bool?.some(true))
                    Text("Disabled").tag(Bool?.some(false))
                }
                .disabled(isReadOnly)
            }

            Section {
                if let screen = slot.screen {
                    LabeledContent("Web Screen", value: screen.summary)
                } else {
                    LabeledContent("Web Screen", value: "Native Device")
                }

                if !isReadOnly {
                    Menu {
                        Button("Native Device Screen") { slot.screen = nil }
                        Button("1920×1080 Windows Desktop (avail 1040)") { slot.screen = .desktop1080pWindows }
                        Button("1920×1080 Linux Desktop (avail 1050)") { slot.screen = .desktop1080pLinux }
                        Button("1440×900 Laptop Desktop (avail 875)") { slot.screen = .desktop1440x900 }
                        Button("412×915 Mobile Android (Pixel 9)") { slot.screen = .mobilePixel9 }
                    } label: {
                        Label("Choose Web Screen Preset…", systemImage: "display")
                    }
                }
            } header: {
                Text("Web-Exposed Screen Metrics")
            } footer: {
                Text("Applies strictly to Web Screen/MediaValues/outerHeight APIs without changing native iPhone Duo display layout.")
            }

            if !cachedSlotReport.errors.isEmpty || !cachedSlotReport.warnings.isEmpty {
                Section("Slot Validation") {
                    ForEach(cachedSlotReport.errors, id: \.self) { error in
                        Label(error, systemImage: "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    ForEach(cachedSlotReport.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isNumberPadFocused = false
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
        }
        .task(id: slot) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            cachedSlotReport = CuriumFingerprintValidator.validateSlot(
                slot.normalizedForPersistence(),
                name: slotKey
            )
        }
    }

    private func optText(_ keyPath: WritableKeyPath<CuriumIdentitySlot, String?>) -> Binding<String> {
        Binding(
            get: { slot[keyPath: keyPath] ?? "" },
            set: { newValue in
                slot[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }
}

// MARK: - JSON Import Sheet

private struct CuriumFingerprintImportSheet: View {
    @Bindable var store: CuriumFingerprintStore
    let onImported: (String?) -> Void

    private struct PendingOverwrite: Identifiable {
        let id = UUID()
        let parsed: CuriumFingerprintStore.ParsedImport
        let existingDisplayName: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var errorMessages: [String] = []
    @State private var warningMessages: [String] = []
    @State private var pendingOverwrite: PendingOverwrite?
    @State private var importedWithWarningsID: String?

    var body: some View {
        NavigationStack {
            Form {
                if let importedID = importedWithWarningsID {
                    Section {
                        Label(
                            "Imported \"\(importedID)\" with warnings. Review the items below before continuing.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.green)

                        Button {
                            onImported(importedID)
                            dismiss()
                        } label: {
                            Label("Open Imported Profile", systemImage: "arrow.right.circle")
                        }
                    } header: {
                        Text("Import Completed")
                    }
                }

                Section {
                    Button {
                        if let paste = UIPasteboard.general.string {
                            jsonText = paste
                            errorMessages = []
                            warningMessages = []
                            importedWithWarningsID = nil
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }

                    TextEditor(text: $jsonText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Profile or Engine Wire JSON")
                } footer: {
                    Text("Accepts exported Curium profile JSON or engine wire payloads (schemaVersion 1 or 2). Built-in IDs are protected from overwrite.")
                }

                if !errorMessages.isEmpty || !warningMessages.isEmpty {
                    Section("Validation") {
                        ForEach(errorMessages, id: \.self) { err in
                            Label(err, systemImage: "xmark.octagon.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        ForEach(warningMessages, id: \.self) { warn in
                            Label(warn, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Import Profile JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if let importedID = importedWithWarningsID {
                            onImported(importedID)
                        }
                        dismiss()
                    } label: {
                        Label(importedWithWarningsID == nil ? "Cancel" : "Done", systemImage: importedWithWarningsID == nil ? "xmark" : "checkmark")
                    }
                }
                if importedWithWarningsID == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { performImport() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                            .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.loadError != nil)
                    }
                }
            }
            .confirmationDialog(
                "Overwrite Existing Profile?",
                isPresented: Binding(
                    get: { pendingOverwrite != nil },
                    set: { if !$0 { pendingOverwrite = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingOverwrite
            ) { pending in
                Button("Overwrite \"\(pending.parsed.profile.id)\"", role: .destructive) {
                    commitImport(pending.parsed)
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text("A custom profile named \"\(pending.existingDisplayName)\" (\(pending.parsed.profile.id)) already exists. Overwriting replaces its configuration and bumps its revision.")
            }
        }
    }

    private func performImport() {
        let data = Data(jsonText.utf8)
        do {
            let parsed = try store.parseImportJSON(data)
            if let schemaError = parsed.schemaError {
                errorMessages = [schemaError]
                warningMessages = parsed.warnings
                return
            }
            let preflight = store.validateForUpsert(parsed.profile)
            guard preflight.isValid else {
                errorMessages = preflight.errors
                warningMessages = preflight.warnings + parsed.warnings
                return
            }
            if let existing = store.profiles.first(where: { !$0.isBuiltIn && $0.id == parsed.profile.id }) {
                pendingOverwrite = PendingOverwrite(
                    parsed: parsed,
                    existingDisplayName: existing.displayName
                )
                return
            }
            commitImport(parsed)
        } catch {
            errorMessages = ["Invalid JSON: \(CuriumFingerprintStore.describeDecodingError(error))"]
            warningMessages = []
        }
    }

    private func commitImport(_ parsed: CuriumFingerprintStore.ParsedImport) {
        let report = store.upsert(parsed.profile)
        let combinedWarnings = report.warnings + parsed.warnings
        errorMessages = report.errors
        warningMessages = combinedWarnings
        guard report.isValid else { return }

        if combinedWarnings.isEmpty {
            onImported(parsed.profile.id)
            dismiss()
        } else {
            importedWithWarningsID = parsed.profile.id
        }
    }
}
