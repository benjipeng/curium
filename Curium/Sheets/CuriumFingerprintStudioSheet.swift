import SwiftUI
import UIKit

/// Native iOS 27.2 Fingerprint & Isolated Profile Studio presented from Settings.
/// Uses a single root `NavigationStack` and `.insetGrouped` lists so iPhone Duo's
/// 84 pt vertical bar and centered sheet placement work natively with zero custom glass chrome.
struct CuriumFingerprintStudioSheet: View {
    @Bindable var store: CuriumFingerprintStore
    let onDismissCallback: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var engineStatus: CuriumEngineFingerprintStatus?
    @State private var engineCapabilities: CuriumEngineFingerprintCapabilities?
    @State private var usageByProfileID: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
    @State private var activeProfileIDInProcess: String?
    @State private var navigationPath: [Route] = []
    @State private var showingImportSheet = false
    @State private var pendingDeleteProfile: CuriumFingerprintProfile?
    @State private var pendingWipeProfile: CuriumFingerprintProfile?
    @State private var isWiping = false
    @State private var alertMessage: String?
    @State private var copiedToastID: String?

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

    private var hasPendingLaunchSwitch: Bool {
        let activeID = (activeProfileIDInProcess ?? "default").lowercased()
        let nextID = (store.selectedProfileID ?? "default").lowercased()
        if store.selectedProfileID == nil && engineStatus?.state == "default_0105" {
            return false
        }
        if store.selectedProfileID == "default" && engineStatus?.state == "default_0105" {
            return true
        }
        return activeID != nextID
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                engineSessionSection
                defaultBuild39Section
                builtInPresetsSection
                customProfilesSection
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
                                navigationPath.removeLast()
                                navigationPath.append(.editCustom(copy.id))
                                Task { await refreshUsage() }
                            },
                            onSaved: {
                                Task { await refreshUsage() }
                            },
                            onWiped: {
                                Task { await refreshUsage() }
                            }
                        )
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
                                Task { await refreshUsage() }
                            },
                            onSaved: {
                                Task { await refreshUsage() }
                            },
                            onWiped: {
                                Task { await refreshUsage() }
                            }
                        )
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
                            navigationPath.removeLast()
                            Task { await refreshUsage() }
                        },
                        onWiped: {}
                    )
                }
            }
        }
        .task {
            refreshEngineInfo()
            await refreshUsage()
        }
        .sheet(isPresented: $showingImportSheet) {
            CuriumFingerprintImportSheet(store: store) { importedID in
                Task { await refreshUsage() }
                if let importedID {
                    navigationPath.append(.editCustom(importedID))
                }
            }
        }
        .confirmationDialog(
            "Delete Custom Profile?",
            isPresented: Binding(
                get: { pendingDeleteProfile != nil },
                set: { if !$0 { pendingDeleteProfile = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteProfile
        ) { profile in
            Button("Delete Profile & Wipe Storage", role: .destructive) {
                deleteProfile(profile, wipeStorage: true)
            }
            Button("Delete Profile Entry Only", role: .destructive) {
                deleteProfile(profile, wipeStorage: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Removes \"\(profile.displayName)\" (\(profile.id)) from Curium. Isolated cookies and site data can be wiped now if this profile is not currently running.")
        }
        .confirmationDialog(
            "Wipe Isolated Profile Storage?",
            isPresented: Binding(
                get: { pendingWipeProfile != nil },
                set: { if !$0 { pendingWipeProfile = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingWipeProfile
        ) { profile in
            Button("Wipe Cookies, Cache & Storage", role: .destructive) {
                wipeProfileStorage(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Permanently clears isolated cookies, localStorage, IndexedDB, CacheStorage, and HTTP cache for \"\(profile.displayName)\" (\(profile.id)). The profile configuration itself is kept.")
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
                            if activeProfileIDInProcess == "default" && engineStatus?.state == "default_0105" {
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
                    Button {
                        selectProfile(profile)
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    .tint(.accentColor)
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
                        Button {
                            selectProfile(profile)
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteProfile = profile
                        } label: {
                            Label("Delete", systemImage: "trash")
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

    // MARK: - Row & Menu Builders

    private func profileRowContent(_ profile: CuriumFingerprintProfile) -> some View {
        let isSelected = store.selectedProfileID == profile.id
        let isLive = isActiveInProcess(profile.id)
            && !(profile.id == "default" && engineStatus?.state == "default_0105")
        let usage = usageByProfileID[profile.id]

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .foregroundStyle(.primary)
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
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func profileContextMenu(_ profile: CuriumFingerprintProfile) -> some View {
        Button {
            selectProfile(profile)
        } label: {
            Label("Select for Next Launch", systemImage: "checkmark.circle")
        }

        Button {
            duplicateAndOpen(profile)
        } label: {
            Label("Duplicate & Customize", systemImage: "plus.square.on.square")
        }

        Button {
            copyProfileJSON(profile)
        } label: {
            Label("Copy Profile JSON", systemImage: "doc.on.doc")
        }

        if profile.id != "default", !isActiveInProcess(profile.id), !isWiping,
           usageByProfileID[profile.id]?.exists == true
        {
            Button(role: .destructive) {
                pendingWipeProfile = profile
            } label: {
                Label("Wipe Isolated Storage", systemImage: "externaldrive.badge.xmark")
            }
        }

        if !profile.isBuiltIn {
            Divider()
            Button(role: .destructive) {
                pendingDeleteProfile = profile
            } label: {
                Label("Delete Profile", systemImage: "trash")
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

    private func refreshUsage() async {
        let ids = Array(Set(["default"] + store.profiles.map(\.id)))
        let snapshot = await Task.detached(priority: .utility) {
            var map: [String: CuriumFingerprintProfileStorage.UsageSnapshot] = [:]
            for id in ids {
                map[id] = CuriumFingerprintProfileStorage.measureUsage(for: id)
            }
            return map
        }.value
        usageByProfileID = snapshot
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
        Task { await refreshUsage() }
    }

    private func copyProfileJSON(_ profile: CuriumFingerprintProfile) {
        do {
            let data = try store.exportProfileJSON(id: profile.id)
            if let text = String(data: data, encoding: .utf8) {
                UIPasteboard.general.string = text
                copiedToastID = profile.id
            }
        } catch {
            alertMessage = "Failed to export profile JSON: \(error.localizedDescription)"
        }
    }

    private func wipeProfileStorage(_ profile: CuriumFingerprintProfile) {
        guard !isWiping else { return }
        isWiping = true
        let isActive = CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(profile.id)
        Task.detached(priority: .userInitiated) {
            do {
                try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                    profile.id,
                    isActiveInCurrentProcess: isActive
                )
                await MainActor.run {
                    isWiping = false
                    Task { await refreshUsage() }
                }
            } catch {
                await MainActor.run {
                    isWiping = false
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteProfile(_ profile: CuriumFingerprintProfile, wipeStorage: Bool) {
        let isActive = CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(profile.id)
        guard store.deleteProfile(id: profile.id) else {
            alertMessage = store.lastPersistError ?? "Could not delete profile \"\(profile.id)\"."
            return
        }
        if wipeStorage && !isActive && profile.id != "default" {
            Task.detached(priority: .userInitiated) {
                do {
                    try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                        profile.id,
                        isActiveInCurrentProcess: false
                    )
                } catch {
                    await MainActor.run {
                        alertMessage = "Profile entry deleted, but storage wipe skipped: \(error.localizedDescription)"
                    }
                }
                await refreshUsage()
            }
        } else {
            if wipeStorage && isActive {
                alertMessage = "Profile entry deleted. Its storage directory is active in this session and can be cleared after relaunch."
            }
            Task { await refreshUsage() }
        }
    }
}

// MARK: - Profile Editor / Built-In Inspector

private struct CuriumFingerprintEditorView: View {
    enum Mode {
        case inspectBuiltIn
        case editCustom
        case createNew
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
    @State private var hardwareOverrideEnabled: Bool
    @State private var useSystemLanguages: Bool
    @State private var languagesText: String
    @State private var proxyModeSelection: ProxyModeChoice
    @State private var fixedProxyRules: String
    @State private var fixedProxyBypass: String
    @State private var copiedLabel: String?
    @State private var confirmingWipe = false
    @State private var isWiping = false
    @State private var alertMessage: String?

    private enum ProxyModeChoice: String, CaseIterable, Identifiable {
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
    }

    private static func trimmedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedSlot(_ slot: CuriumIdentitySlot) -> CuriumIdentitySlot {
        var copy = slot
        copy.uaString = trimmedOptional(slot.uaString)
        copy.osCpu = trimmedOptional(slot.osCpu)
        copy.productVersion = trimmedOptional(slot.productVersion)
        if let brand = slot.primaryBrand {
            // Preserve explicit empty string ("") for Chromium-only 2-brand mode; trim non-empty brands.
            copy.primaryBrand = brand.isEmpty ? "" : brand.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        copy.majorVersion = trimmedOptional(slot.majorVersion)
        copy.fullVersion = trimmedOptional(slot.fullVersion)
        copy.platform = trimmedOptional(slot.platform)
        if let pv = slot.platformVersion {
            copy.platformVersion = pv.isEmpty ? "" : trimmedOptional(pv)
        }
        if let arch = slot.architecture {
            copy.architecture = arch.isEmpty ? "" : trimmedOptional(arch)
        }
        if let model = slot.model {
            copy.model = model.isEmpty ? "" : trimmedOptional(model)
        }
        copy.navigatorPlatform = trimmedOptional(slot.navigatorPlatform)
        copy.webglVendor = trimmedOptional(slot.webglVendor)
        copy.webglRenderer = trimmedOptional(slot.webglRenderer)
        return copy
    }

    private var effectiveDraft: CuriumFingerprintProfile {
        var profile = draft
        profile.id = draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.hardware.timezone = Self.trimmedOptional(draft.hardware.timezone)
        profile.mobile = Self.normalizedSlot(draft.mobile)
        profile.desktop = Self.normalizedSlot(draft.desktop)
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
        return profile
    }

    private var validationReport: CuriumFingerprintValidationReport {
        let candidate = effectiveDraft
        var report = CuriumFingerprintValidator.validate(candidate)
        if mode == .createNew {
            let lowered = candidate.id.lowercased()
            let builtInLowered = Set(CuriumFingerprintPresets.builtInIDs.map { $0.lowercased() })
            if store.profiles.contains(where: { $0.id.lowercased() == lowered }) {
                report.errors.append("A profile with ID \"\(candidate.id)\" already exists (APFS IDs are case-insensitive).")
            }
            if builtInLowered.contains(lowered) {
                report.errors.append("\"\(candidate.id)\" is reserved for a built-in preset.")
            }
        }
        return report
    }

    var body: some View {
        let report = validationReport
        Form {
            quickActionSection
            if !report.errors.isEmpty || !report.warnings.isEmpty {
                validationSection(report)
            }
            profileMetadataSection
            identitySlotsSection
            antiFingerprintingSection
            hardwareAndGPUSection
            networkAndPrivacySection
            storageAndJSONSection
        }
        .navigationTitle(mode == .createNew ? "New Profile" : draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft.usesNativeHardwareAndGPU) { _, isNative in
            if !isNative && !hardwareOverrideEnabled {
                hardwareOverrideEnabled = true
            }
        }
        .toolbar {
            if !isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveProfile()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .disabled(!report.isValid)
                    .accessibilityIdentifier("curium.studio.editor.save")
                }
            }
        }
        .confirmationDialog(
            "Wipe Isolated Storage?",
            isPresented: $confirmingWipe,
            titleVisibility: .visible
        ) {
            Button("Wipe Cookies, Cache & Storage", role: .destructive) {
                wipeStorage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears isolated cookies, localStorage, IndexedDB, CacheStorage, and HTTP cache for \"\(draft.id)\".")
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
                    if !store.selectProfile(id: draft.id) {
                        alertMessage = store.lastPersistError ?? "Unable to select profile."
                    }
                } label: {
                    Label(
                        isSelectedForNextLaunch ? "Selected for Next Launch" : "Use for Next Launch",
                        systemImage: isSelectedForNextLaunch ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
                .disabled(isSelectedForNextLaunch)
                .accessibilityIdentifier("curium.studio.editor.select")
            }

            if isReadOnly {
                Button {
                    duplicateBuiltIn()
                } label: {
                    Label("Duplicate & Customize", systemImage: "plus.square.on.square")
                }
                .accessibilityIdentifier("curium.studio.editor.duplicate")
            }
        } footer: {
            if isReadOnly {
                Text("Built-in presets are immutable templates. Duplicate this preset to edit its identity, proxy, language, or hardware overrides.")
            } else if isActiveInProcess {
                Text("This profile is active in the current session. Saved edits bump revision and apply on the next cold launch.")
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
                LabeledContent("Profile ID") {
                    TextField("work-us-01", text: $draft.id)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
            } else {
                LabeledContent("Profile ID") {
                    Text(draft.id)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Display Name") {
                TextField("Display Name", text: $draft.displayName)
                    .multilineTextAlignment(.trailing)
                    .disabled(isReadOnly)
            }

            LabeledContent("Notes") {
                TextField("Optional notes", text: $draft.notes)
                    .multilineTextAlignment(.trailing)
                    .disabled(isReadOnly)
            }

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
                    Text("\(seed.prefix(12))…\(seed.suffix(8))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                if !isReadOnly {
                    Button {
                        draft.fingerprintSeed = CuriumFingerprintSchema.generateRandomSeedHex()
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

                LabeledContent("Custom IANA TZ") {
                    TextField("e.g. Europe/Berlin", text: optionalStringBinding(\.hardware.timezone))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }

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

                LabeledContent("Desktop WebGL Vendor") {
                    TextField("Native", text: optionalStringBinding(\.desktop.webglVendor))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .disabled(isReadOnly)
                }

                LabeledContent("Desktop WebGL Renderer") {
                    TextField("Native", text: optionalStringBinding(\.desktop.webglRenderer))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .disabled(isReadOnly)
                }

                if draft.mobile.hasWebGLOverride
                    || draft.mobile.webglVendor != draft.desktop.webglVendor
                    || draft.mobile.webglRenderer != draft.desktop.webglRenderer
                {
                    LabeledContent("Mobile WebGL Vendor") {
                        TextField("Native", text: optionalStringBinding(\.mobile.webglVendor))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                            .disabled(isReadOnly)
                    }

                    LabeledContent("Mobile WebGL Renderer") {
                        TextField("Native", text: optionalStringBinding(\.mobile.webglRenderer))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                            .disabled(isReadOnly)
                    }
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
                LabeledContent("BCP-47 Tags") {
                    TextField("en-US, en", text: $languagesText)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }

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
                LabeledContent("Proxy Rules") {
                    TextField("socks5://127.0.0.1:1080", text: $fixedProxyRules)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }

                LabeledContent("Bypass Rules") {
                    TextField("Optional (e.g. <-loopback>)", text: $fixedProxyBypass)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }

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
            if let loc = CuriumFingerprintProfileStorage.locations(for: draft.id) {
                LabeledContent("Storage Folder") {
                    Text(loc.isDefault ? "Chromium/" : "ChromiumProfiles/\(draft.id)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let usage {
                LabeledContent("Disk Footprint") {
                    Text(usage.exists
                        ? ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
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
            .disabled(!validationReport.isValid)

            if let shareText = exportJSONString() {
                ShareLink(item: shareText) {
                    Label("Share Profile JSON", systemImage: "square.and.arrow.up")
                }
            }

            if mode != .createNew && draft.id != "default" {
                Button(role: .destructive) {
                    confirmingWipe = true
                } label: {
                    Label(
                        isWiping ? "Wiping Isolated Storage…" : "Wipe Isolated Storage",
                        systemImage: "externaldrive.badge.xmark"
                    )
                }
                .disabled(isActiveInProcess || isWiping || usage?.exists != true)
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

    private func saveProfile() {
        let candidate = effectiveDraft
        let report = store.upsert(candidate)
        guard report.isValid else {
            alertMessage = report.errors.joined(separator: "\n")
            return
        }
        if let updated = store.profiles.first(where: { $0.id == candidate.id }) {
            draft = updated
        }
        onSaved()
        if mode == .editCustom {
            dismiss()
        }
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
    @Binding var slot: CuriumIdentitySlot
    let isReadOnly: Bool

    @State private var brandMode: PrimaryBrandMode
    @State private var customBrandText: String

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

    init(title: String, slot: Binding<CuriumIdentitySlot>, isReadOnly: Bool) {
        self.title = title
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
    }

    var body: some View {
        Form {
            Section("User-Agent") {
                LabeledContent("OS / CPU Token") {
                    TextField("Auto", text: optText(\.osCpu))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .disabled(isReadOnly)
                }

                LabeledContent("Full UA Override") {
                    TextField("Leave blank to synthesize", text: optText(\.uaString))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .disabled(isReadOnly)
                }

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
                    LabeledContent("Custom Brand") {
                        TextField("Google Chrome", text: $customBrandText)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(isReadOnly)
                            .onChange(of: customBrandText) { _, value in
                                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                slot.primaryBrand = trimmed.isEmpty ? nil : value
                            }
                    }
                }

                LabeledContent("Major Version") {
                    TextField("Engine default (160)", text: optText(\.majorVersion))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }

                LabeledContent("Full Version") {
                    TextField("Auto from major", text: optText(\.fullVersion))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }
            }

            Section {
                LabeledContent("CH Platform") {
                    TextField("macOS / Windows / Android / Linux", text: optText(\.platform))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isReadOnly)
                }

                LabeledContent("Platform Version") {
                    TextField("Auto (empty for Linux)", text: optText(\.platformVersion))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }

                LabeledContent("Architecture") {
                    TextField("Auto (arm / x86)", text: optText(\.architecture))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }

                Picker("Bitness", selection: $slot.bitness) {
                    Text("Auto").tag(String?.none)
                    Text("Empty (Mobile Android)").tag(String?.some(""))
                    Text("64-bit").tag(String?.some("64"))
                    Text("32-bit").tag(String?.some("32"))
                }
                .disabled(isReadOnly)

                LabeledContent("Device Model") {
                    TextField("Auto (empty or e.g. Pixel 9)", text: optText(\.model))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .disabled(isReadOnly)
                }

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

                LabeledContent("navigator.platform") {
                    TextField("MacIntel / Win32 / Linux armv81", text: optText(\.navigatorPlatform))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        .disabled(isReadOnly)
                }
            } header: {
                Text("Client Hints & Navigator")
            } footer: {
                Text("Leave Platform Version, Architecture, or Device Model blank to let the engine auto-resolve platform defaults (e.g. empty platformVersion on Linux and empty architecture on Android).")
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

                LabeledContent("WebGL Vendor") {
                    TextField("Native Apple", text: optText(\.webglVendor))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .disabled(isReadOnly)
                }

                LabeledContent("WebGL Renderer") {
                    TextField("Native Apple Metal", text: optText(\.webglRenderer))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                        .disabled(isReadOnly)
                }

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
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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

    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var errorMessages: [String] = []
    @State private var warningMessages: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        if let paste = UIPasteboard.general.string {
                            jsonText = paste
                            errorMessages = []
                            warningMessages = []
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
            .navigationTitle("Import Profile JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { performImport() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func performImport() {
        let data = Data(jsonText.utf8)
        do {
            let previousIDs = Set(store.profiles.map(\.id))
            let report = try store.importProfileJSON(data)
            errorMessages = report.errors
            warningMessages = report.warnings
            guard report.isValid else { return }
            let importedID = store.profiles.first { !previousIDs.contains($0.id) }?.id
                ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap {
                    ($0["id"] as? String) ?? ($0["profileId"] as? String)
                }
            onImported(importedID)
            dismiss()
        } catch {
            errorMessages = ["Invalid JSON: \(error.localizedDescription)"]
        }
    }
}
