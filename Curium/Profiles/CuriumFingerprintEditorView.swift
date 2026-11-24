import SwiftUI
import UIKit

struct CuriumShareDocument: Identifiable {
    let id = UUID()
    let text: String
}

struct CuriumActivityShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Clean local profile and privacy editor for every retained profile (including `"default"`
/// Personal). Daily preferences and high-level hardware/network/privacy controls stay calm
/// at the top level, while wire-level identity slots, manual GPU overrides, seeds, and JSON
/// export live inside a single secondary `Advanced` screen.
struct CuriumFingerprintEditorView: View {
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

    private struct ValidationTrigger: Equatable {
        let draft: CuriumFingerprintProfile
        let useSystemLanguages: Bool
        let languagesText: String
        let proxyModeSelection: ProxyModeChoice
        let fixedProxyRules: String
        let fixedProxyBypass: String
    }

    var store: CuriumFingerprintStore
    let isActiveInProcess: Bool
    let usage: CuriumFingerprintProfileStorage.UsageSnapshot?
    var onDuplicateToEdit: ((CuriumFingerprintProfile) -> Void)?
    var onSaved: ((CuriumFingerprintProfile) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onWiped: (() -> Void)?

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
    @State private var isIconPickerExpanded = false
    @State private var copiedLabel: String?
    @State private var activeDialog: EditorDialog?
    @State private var isWiping = false
    @State private var alertMessage: String?
    @State private var pendingShareDocument: CuriumShareDocument?
    private let supportsHotRuntimePrivacyPolicy: Bool

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private let paletteColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    static let commonTimezones: [String] = [
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

    private var isSelectedForNextLaunch: Bool {
        store.nextLaunchProfileID.lowercased() == draft.id.lowercased()
    }

    private var hasUnsavedChanges: Bool {
        effectiveDraft != savedBaseline
    }

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
        isActiveInProcess: Bool,
        usage: CuriumFingerprintProfileStorage.UsageSnapshot?,
        onDuplicateToEdit: ((CuriumFingerprintProfile) -> Void)? = nil,
        onSaved: ((CuriumFingerprintProfile) -> Void)? = nil,
        onSelectionChanged: (() -> Void)? = nil,
        onWiped: (() -> Void)? = nil
    ) {
        self.store = store
        self.isActiveInProcess = isActiveInProcess
        self.usage = usage
        self.onDuplicateToEdit = onDuplicateToEdit
        self.onSaved = onSaved
        self.onSelectionChanged = onSelectionChanged
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
        _cachedReport = State(initialValue: Self.evaluateValidation(candidate: initialNormalized))
        self.supportsHotRuntimePrivacyPolicy = CuriumFingerprintBootstrap
            .engineCapabilities()
            .supportsHotRuntimePrivacyPolicy
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
        candidate: CuriumFingerprintProfile
    ) -> CuriumFingerprintValidationReport {
        var report = CuriumFingerprintValidator.validate(candidate)
        if candidate.displayName.isEmpty {
            report.errors.insert("Display Name cannot be empty.", at: 0)
        }
        return report
    }

    private var storageFolderDisplayName: String? {
        let trimmed = draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CuriumFingerprintValidator.isValidProfileID(trimmed) else { return nil }
        return trimmed == "default" ? "Chromium/" : "ChromiumProfiles/\(trimmed)"
    }

    private var hardwareProfileSummary: String {
        if draft.usesNativeHardwareAndGPU {
            return "Native Apple Silicon"
        }
        let poolVariants = CuriumFingerprintDevicePools.variants(forProfile: draft)
        if let matched = poolVariants.first(where: { $0.matches(draft) }) {
            return matched.label
        }
        var parts: [String] = []
        let primarySlot = draft.defaultSlot == .desktop ? draft.desktop : draft.mobile
        if let chipName = CuriumMacOSManifold.chipDisplayName(fromWebGLRenderer: primarySlot.webglRenderer) {
            parts.append(chipName)
        }
        if let cores = draft.hardware.hardwareConcurrency {
            parts.append("\(cores)c")
        }
        if let mem = draft.hardware.deviceMemoryGB {
            parts.append(mem < 1 ? "\(mem) GB" : "\(Int(mem)) GB")
        }
        if let screen = primarySlot.screen {
            parts.append("\(screen.width)×\(screen.height)")
        }
        return parts.isEmpty ? "Custom Hardware" : parts.joined(separator: " · ")
    }

    var body: some View {
        Form {
            profileSection
            deviceAndPrivacySection
            storageAndActionsSection
            advancedLinkSection
            if !cachedReport.errors.isEmpty || !cachedReport.warnings.isEmpty {
                validationSection(cachedReport)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(draft.displayName.isEmpty ? "Profile" : draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedChanges || isWiping)
        .interactiveDismissDisabled(hasUnsavedChanges || isWiping)
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
            cachedReport = Self.evaluateValidation(candidate: effectiveDraft)
        }
        .toolbar {
            if hasUnsavedChanges || isWiping {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if hasUnsavedChanges {
                            activeDialog = .discardChanges
                        } else {
                            dismiss()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(isWiping)
                    .accessibilityIdentifier("curium.editor.back")
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveProfile(dismissAfterSave: true)
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .disabled(isWiping || !cachedReport.isValid || store.loadError != nil)
                .accessibilityIdentifier("curium.editor.save")
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
                Button("Wipe Cookies, Bookmarks & Storage", role: .destructive) {
                    wipeStorage()
                }
                .disabled(isWiping)
                Button("Cancel", role: .cancel) {}

            case .discardChanges:
                Button("Discard Changes", role: .destructive) {
                    dismiss()
                }
                .disabled(isWiping)
                Button("Keep Editing", role: .cancel) {}

            case .saveBeforeSelect:
                if cachedReport.isValid {
                    Button("Save & Use for Next Launch") {
                        if saveProfile(dismissAfterSave: false) {
                            selectCurrentProfile()
                        }
                    }
                    .disabled(isWiping)
                }
                Button("Use Previously Saved Version") {
                    selectCurrentProfile()
                }
                .disabled(isWiping)
                Button("Cancel", role: .cancel) {}
            }
        } message: { dialog in
            switch dialog {
            case .wipeStorage:
                Text(
                    "Clears isolated cookies, localStorage, IndexedDB, CacheStorage, HTTP cache, bookmarks, history, and saved tabs for \"\(draft.displayName)\"."
                )
            case .discardChanges:
                Text(
                    "Your unsaved edits to \"\(draft.displayName.isEmpty ? draft.id : draft.displayName)\" will be lost."
                )
            case .saveBeforeSelect:
                if cachedReport.isValid {
                    Text(
                        "You have unsaved edits. Save them before selecting this profile for next launch, or select the previously saved version."
                    )
                } else {
                    Text(
                        "Your current edits have validation errors and cannot be saved yet. Fix them first or select the previously saved version."
                    )
                }
            }
        }
        .sheet(item: $pendingShareDocument) { doc in
            CuriumActivityShareSheet(text: doc.text)
                .presentationDetents([.medium, .large])
        }
        .alert("Profile", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Form Sections

    private var profileSection: some View {
        let resolvedPalette = draft.resolvedPalette
        let resolvedSymbol = draft.resolvedSymbolName

        return Section {
            HStack(spacing: 12) {
                CuriumProfileAvatar(
                    symbolName: resolvedSymbol,
                    palette: resolvedPalette,
                    size: 44,
                    isCircle: true
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.displayName.isEmpty ? "Untitled Profile" : draft.displayName)
                        .font(.headline)
                        .foregroundStyle(draft.displayName.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Text(draft.conciseStartPostureSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)

            CuriumStackedTextFieldRow(
                title: "Display Name",
                placeholder: "Profile Name",
                text: $draft.displayName,
                isReadOnly: false,
                monospaced: false,
                font: .body,
                autocapitalization: .words,
                textFieldAccessibilityID: "curium.editor.displayName"
            )

            DisclosureGroup(isExpanded: $isIconPickerExpanded) {
                LazyVGrid(columns: iconColumns, spacing: 8) {
                    ForEach(CuriumProfileSymbols.curated, id: \.self) { symbol in
                        let isSelected = resolvedSymbol == symbol
                        Button {
                            if symbol != resolvedSymbol {
                                draft.symbolName = symbol
                            }
                        } label: {
                            Image(systemName: symbol)
                                .font(.title3.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? resolvedPalette.tint : .primary)
                                .frame(maxWidth: .infinity, minHeight: CuriumSpace.tapTarget)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? resolvedPalette.tile : Color(uiColor: .tertiarySystemFill))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? resolvedPalette.tint : .clear,
                                            lineWidth: 1.5
                                        )
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(CuriumProfileSymbolLabels.label(for: symbol))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } label: {
                LabeledContent("Icon") {
                    HStack(spacing: 6) {
                        Image(systemName: resolvedSymbol)
                            .foregroundStyle(resolvedPalette.tint)
                        Text(CuriumProfileSymbolLabels.label(for: resolvedSymbol))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Accent")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(resolvedPalette.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: paletteColumns, spacing: 8) {
                    ForEach(CuriumPalette.allCases) { option in
                        let isSelected = resolvedPalette == option
                        Button {
                            if option != resolvedPalette {
                                draft.palette = option
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(option.tint)
                                    .frame(width: 28, height: 28)

                                if isSelected {
                                    Circle()
                                        .strokeBorder(option.tint, lineWidth: 2)
                                        .frame(width: 36, height: 36)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: CuriumSpace.tapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 4)

            Picker("Search Engine", selection: searchEngineBinding) {
                ForEach(CuriumSearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }

            Picker("Default Site Layout", selection: siteModeBinding) {
                ForEach(CuriumSiteMode.allCases) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
        } header: {
            Text("Profile")
        } footer: {
            Text(
                "Name, icon, accent, search engine, and layout apply immediately. Duo Adaptive adjusts viewport width on the outer cover display without changing your macOS identity."
            )
        }
    }

    private var deviceAndPrivacySection: some View {
        let poolVariants = CuriumFingerprintDevicePools.variants(forProfile: draft)

        return Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Hardware")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(hardwareProfileSummary)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 2)

            if !poolVariants.isEmpty {
                Menu {
                    Button {
                        restoreNativeAppleHardware()
                    } label: {
                        if draft.usesNativeHardwareAndGPU {
                            Label("Native Apple Silicon", systemImage: "checkmark")
                        } else {
                            Text("Native Apple Silicon")
                        }
                    }

                    Divider()

                    ForEach(poolVariants) { variant in
                        Button {
                            draft = variant.apply(to: draft)
                            hardwareOverrideEnabled = !draft.usesNativeHardwareAndGPU
                        } label: {
                            if variant.matches(draft) {
                                Label(variant.label, systemImage: "checkmark")
                            } else {
                                Text(variant.label)
                            }
                        }
                    }
                } label: {
                    Label("Choose Mac Profile…", systemImage: "laptopcomputer")
                }
                .accessibilityIdentifier("curium.editor.chooseHardware")

                Button {
                    if let rolled = CuriumFingerprintPresets.rollCoherentHardwareVariant(
                        for: draft,
                        avoiding: store.profiles.filter { $0.id != draft.id }
                    ) {
                        draft = rolled
                        hardwareOverrideEnabled = !rolled.usesNativeHardwareAndGPU
                    }
                } label: {
                    Label("Roll Distinct Mac", systemImage: "dice")
                }
                .accessibilityIdentifier("curium.editor.rollHardware")
            }

            Toggle(isOn: privacyHardeningBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy Hardening")
                    Text("Full farbling, Sec-GPC & non-proxied WebRTC UDP off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("curium.editor.privacyHardening")

            Toggle("Anti-Fingerprinting", isOn: Binding(
                get: { draft.fingerprintSeed != nil },
                set: { enabled in
                    if enabled {
                        if draft.fingerprintSeed == nil {
                            draft.fingerprintSeed = CuriumFingerprintSchema.generateRandomSeedHex()
                        }
                        if draft.farbling == nil {
                            draft.farbling = draft.templateID == CuriumFingerprintPresets.privacyHardened.id
                                ? .allEnabled
                                : .stealthSafe
                        }
                    } else {
                        draft.fingerprintSeed = nil
                        draft.farbling = nil
                    }
                }
            ))
            .accessibilityIdentifier("curium.editor.farbling")

            Picker("Proxy", selection: $proxyModeSelection) {
                ForEach(ProxyModeChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }

            if proxyModeSelection == .fixed {
                CuriumStackedTextFieldRow(
                    title: "Proxy Rules",
                    placeholder: "socks5://127.0.0.1:1080",
                    text: $fixedProxyRules,
                    isReadOnly: false,
                    keyboardType: .URL
                )

                CuriumStackedTextFieldRow(
                    title: "Bypass Rules",
                    placeholder: "Optional (e.g. <-loopback>)",
                    text: $fixedProxyBypass,
                    isReadOnly: false
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
            }

            Picker("Timezone", selection: Binding<String>(
                get: { draft.hardware.timezone ?? "" },
                set: { draft.hardware.timezone = $0.isEmpty ? nil : $0 }
            )) {
                Text("System Default").tag("")
                ForEach(Self.commonTimezones, id: \.self) { tz in
                    Text(tz).tag(tz)
                }
                if let current = draft.hardware.timezone,
                   !current.isEmpty,
                   !Self.commonTimezones.contains(current)
                {
                    Text(current).tag(current)
                }
            }

            Toggle("Follow System Languages", isOn: Binding(
                get: { useSystemLanguages },
                set: { followSystem in
                    useSystemLanguages = followSystem
                    if !followSystem && languagesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        languagesText = "en-US, en"
                    }
                }
            ))

            if !useSystemLanguages {
                CuriumStackedTextFieldRow(
                    title: "Language Tags",
                    placeholder: "en-US, en",
                    text: $languagesText,
                    isReadOnly: false
                )

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

            Picker("WebRTC IP Policy", selection: $draft.webrtcIpHandlingPolicy) {
                ForEach(CuriumWebRTCPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }

            Toggle("Global Privacy Control (Sec-GPC)", isOn: $draft.enableGlobalPrivacyControl)
        } header: {
            Text("Device & Privacy")
        } footer: {
            Text(deviceAndPrivacyFooterCopy)
        }
    }

    private var storageAndActionsSection: some View {
        Section("Storage & Actions") {
            if !isActiveInProcess {
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
                .disabled(isWiping || (isSelectedForNextLaunch && !hasUnsavedChanges) || store.loadError != nil)
                .accessibilityIdentifier("curium.editor.select")
            }

            if let currentUsage {
                LabeledContent("Disk Footprint") {
                    Text(
                        currentUsage.exists
                            ? ByteCountFormatter.string(fromByteCount: currentUsage.totalBytes, countStyle: .file)
                            : "Not created yet"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                duplicateProfile()
            } label: {
                Label("Duplicate Profile", systemImage: "plus.square.on.square")
            }
            .disabled(isWiping || store.loadError != nil)

            if !draft.isPrimaryDefault {
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

    private var advancedLinkSection: some View {
        Section {
            NavigationLink {
                CuriumProfileAdvancedView(
                    draft: $draft,
                    hardwareOverrideEnabled: $hardwareOverrideEnabled,
                    copiedLabel: $copiedLabel,
                    storageFolderDisplayName: storageFolderDisplayName,
                    canCopyWireJSON: cachedReport.isValid,
                    onRestoreNativeHardware: restoreNativeAppleHardware,
                    onCopyProfileJSON: copyProfileJSON,
                    onCopyEngineWireJSON: copyEngineWireJSON,
                    onShareProfileJSON: shareProfileJSON
                )
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced")
                    Text("Identity slots, farbling seed, manual GPU overrides & JSON")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityIdentifier("curium.editor.advanced")
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

    // MARK: - Bindings & Helpers

    private var isPrivacyHardeningEnabled: Bool {
        draft.isPrivacyHardeningEnabled
    }

    private var privacyHardeningBinding: Binding<Bool> {
        Binding(
            get: { isPrivacyHardeningEnabled },
            set: { enabled in
                let proxyOverride: CuriumProxyConfig = switch proxyModeSelection {
                case .fixed: .fixed(rules: fixedProxyRules, bypassRules: nil)
                case .direct: .direct
                case .system: .system
                }
                draft.setPrivacyHardeningEnabled(enabled, proxyOverride: proxyOverride)
            }
        )
    }

    private var deviceAndPrivacyFooterCopy: String {
        if supportsHotRuntimePrivacyPolicy {
            if isActiveInProcess {
                return "Privacy Hardening, Anti-Fingerprinting, WebRTC IP policy, and Sec-GPC apply live on save without relaunching. Hardware, proxy, timezone, and language changes apply on the next cold launch."
            }
            return "Privacy Hardening toggles full farbling, Sec-GPC, and non-proxied WebRTC UDP off together. Hardware, proxy, and locale changes apply when this profile is launched; privacy controls apply live once active."
        }
        return "Device, proxy, locale, and privacy changes apply on the next cold launch on this engine build."
    }

    private var siteModeBinding: Binding<CuriumSiteMode> {
        Binding(
            get: { draft.resolvedSiteMode },
            set: { newValue in
                if newValue != draft.resolvedSiteMode {
                    draft.siteMode = newValue
                }
            }
        )
    }

    private var searchEngineBinding: Binding<CuriumSearchEngine> {
        Binding(
            get: { draft.resolvedSearchEngine },
            set: { newValue in
                if newValue != draft.resolvedSearchEngine {
                    draft.searchEngine = newValue
                }
            }
        )
    }

    private func restoreNativeAppleHardware() {
        let preservedTimezone = draft.hardware.timezone
        draft.hardware = CuriumHardwareOverrides(
            hardwareConcurrency: nil,
            deviceMemoryGB: nil,
            timezone: preservedTimezone
        )
        draft.mobile.webglVendor = nil
        draft.mobile.webglRenderer = nil
        draft.mobile.screen = nil
        draft.desktop.webglVendor = nil
        draft.desktop.webglRenderer = nil
        draft.desktop.screen = nil
        hardwareOverrideEnabled = !draft.usesNativeHardwareAndGPU
    }

    private func selectCurrentProfile() {
        guard !isWiping else { return }
        let targetID: String? = savedBaseline.isPrimaryDefault ? nil : savedBaseline.id
        if store.selectProfile(id: targetID) {
            onSelectionChanged?()
        } else {
            alertMessage = store.lastPersistError ?? "Unable to select profile."
        }
    }

    private func duplicateProfile() {
        guard !isWiping else { return }
        guard let copy = store.duplicateProfile(
            from: draft.id,
            displayName: "\(draft.displayName) Copy"
        ) else {
            alertMessage = store.lastPersistError ?? "Unable to duplicate profile."
            return
        }
        onDuplicateToEdit?(copy)
    }

    @discardableResult
    private func saveProfile(dismissAfterSave: Bool) -> Bool {
        guard !isWiping else { return false }
        let candidate = effectiveDraft
        let preflight = Self.evaluateValidation(candidate: candidate)
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
        let saved = store.profile(id: candidate.id) ?? candidate
        draft = saved
        savedBaseline = saved.normalizedForPersistence()
        if saved.isPrimaryDefault {
            let defaults = UserDefaults.standard
            defaults.set(saved.resolvedPalette.rawValue, forKey: "curium.palette")
            defaults.set(saved.resolvedSiteMode.rawValue, forKey: "curium.siteMode")
            defaults.set(saved.resolvedSearchEngine.rawValue, forKey: "curium.searchEngine")
        }
        onSaved?(saved)
        if dismissAfterSave {
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

    private func shareProfileJSON() {
        if let text = exportJSONString() {
            pendingShareDocument = CuriumShareDocument(text: text)
        } else {
            alertMessage = "Failed to encode profile JSON for sharing."
        }
    }

    private func wipeStorage() {
        guard !isWiping, !draft.isPrimaryDefault else { return }
        let targetID = draft.id
        let active = isActiveInProcess || CuriumFingerprintProfileStorage.isProfileActiveInCurrentProcess(targetID)
        guard !active else {
            alertMessage = CuriumFingerprintProfileStorage.WipeError.activeProfileProtected.localizedDescription
            return
        }
        isWiping = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                        targetID,
                        isActiveInCurrentProcess: false
                    )
                }.value
                isWiping = false
                currentUsage = CuriumFingerprintProfileStorage.UsageSnapshot(
                    supportBytes: 0,
                    cacheBytes: 0,
                    exists: false
                )
                onWiped?()
            } catch {
                isWiping = false
                alertMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Secondary Advanced Profile Controls

/// Power-user and protocol-level controls tucked cleanly behind `Advanced`:
/// raw identity slots (UA / Client Hints / `navigator.platform`), granular farbling
/// seed & surface toggles, manual hardware/GPU overrides, metadata, and JSON export.
private struct CuriumProfileAdvancedView: View {
    @Binding var draft: CuriumFingerprintProfile
    @Binding var hardwareOverrideEnabled: Bool
    @Binding var copiedLabel: String?
    let storageFolderDisplayName: String?
    let canCopyWireJSON: Bool
    let onRestoreNativeHardware: () -> Void
    let onCopyProfileJSON: () -> Void
    let onCopyEngineWireJSON: () -> Void
    let onShareProfileJSON: () -> Void

    var body: some View {
        Form {
            identitySlotsSection
            farblingDetailsSection
            manualHardwareSection
            metadataAndExportSection
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var identitySlotsSection: some View {
        Section {
            Picker("Default Slot", selection: $draft.defaultSlot) {
                ForEach(CuriumDefaultSlot.allCases) { slot in
                    Text(slot.title).tag(slot)
                }
            }

            NavigationLink {
                CuriumIdentitySlotEditorView(
                    title: "Mobile Slot",
                    slotKey: "mobile",
                    slot: $draft.mobile,
                    isReadOnly: false
                )
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mobile Identity Slot")
                    Text(slotSummary(draft.mobile, fallbackPlatform: "macOS"))
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
                    isReadOnly: false
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
            Text("Identity Slots")
        } footer: {
            Text(
                "Real Apple Silicon Chrome reports \"Intel Mac OS X 10_15_7\" in User-Agent and \"MacIntel\" in navigator.platform for web compatibility while advertising ARM64 in Client Hints. Keep both slots aligned to macOS so outer and inner displays never flip your OS identity."
            )
        }
    }

    private var farblingDetailsSection: some View {
        Section {
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

                Button {
                    draft.fingerprintSeed = CuriumFingerprintStore.mintFreshSeed(differentFrom: seed)
                } label: {
                    Label("Rotate Farbling Seed", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("curium.editor.rotateSeed")

                Toggle("Canvas 2D & OffscreenCanvas", isOn: farblingBinding(\.canvas))
                Toggle("WebAudio (Offline & Analyser)", isOn: farblingBinding(\.audio))
                Toggle("WebGL readPixels", isOn: farblingBinding(\.webgl))
                Toggle("Canvas TextMetrics", isOn: farblingBinding(\.textMetrics))
            } else {
                Text("Enable Anti-Fingerprinting on the main profile page to configure per-site farbling surfaces and seed rotation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker("Font Profile", selection: $draft.fontProfile) {
                Text("Auto (Match Platform)").tag(CuriumFontProfile?.none)
                ForEach(CuriumFontProfile.allCases) { option in
                    Text(option.title).tag(CuriumFontProfile?.some(option))
                }
            }

            Picker("Speech Synthesis Voices", selection: $draft.hideSpeechVoices) {
                Text("Auto").tag(Bool?.none)
                Text("Hide Apple Voices").tag(Bool?.some(true))
                Text("Native Voices").tag(Bool?.some(false))
            }
        } header: {
            Text("Anti-Fingerprinting Surfaces")
        }
    }

    private var manualHardwareSection: some View {
        Section {
            Toggle("Override Hardware & GPU", isOn: Binding(
                get: { hardwareOverrideEnabled },
                set: { enabled in
                    hardwareOverrideEnabled = enabled
                    if !enabled {
                        onRestoreNativeHardware()
                    }
                }
            ))
            .accessibilityIdentifier("curium.editor.hwOverride")

            if let activeScreen = (draft.defaultSlot == .desktop ? draft.desktop.screen : draft.mobile.screen) {
                LabeledContent("Active Screen") {
                    Text(activeScreen.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            if hardwareOverrideEnabled {
                Picker("CPU Cores", selection: $draft.hardware.hardwareConcurrency) {
                    Text("Native Device").tag(Int?.none)
                    ForEach([2, 4, 6, 8, 10, 12, 14, 16, 18, 24, 32], id: \.self) { count in
                        Text("\(count) cores").tag(Int?.some(count))
                    }
                }

                Picker("Device Memory (W3C)", selection: $draft.hardware.deviceMemoryGB) {
                    Text("Native Device").tag(Double?.none)
                    ForEach(CuriumFingerprintSchema.validDeviceMemoryBuckets, id: \.self) { gb in
                        Text(gb < 1 ? "\(gb) GB" : "\(Int(gb)) GB").tag(Double?.some(gb))
                    }
                }

                CuriumStackedTextFieldRow(
                    title: "Custom IANA Timezone",
                    placeholder: "e.g. Europe/Berlin",
                    text: optionalStringBinding(\.hardware.timezone),
                    isReadOnly: false
                )

                Menu {
                    Button("Clear WebGL (Native Apple Metal)") {
                        applyWebGLPreset(vendor: nil, renderer: nil)
                    }
                    Button("Apple M1 (macOS Metal)") { applyAppleSiliconWebGLPreset(chip: "Apple M1") }
                    Button("Apple M2 (macOS Metal)") { applyAppleSiliconWebGLPreset(chip: "Apple M2") }
                    Button("Apple M3 (macOS Metal)") { applyAppleSiliconWebGLPreset(chip: "Apple M3") }
                    Button("Apple M3 Pro (macOS Metal)") { applyAppleSiliconWebGLPreset(chip: "Apple M3 Pro") }
                    Button("Apple M4 (macOS Metal)") { applyAppleSiliconWebGLPreset(chip: "Apple M4") }
                    Button("Apple M4 Pro (macOS Metal)") { applyAppleSiliconWebGLPreset(chip: "Apple M4 Pro") }
                    Button("Apple M4 Max (macOS Metal)") { applyAppleSiliconWebGLPreset(chip: "Apple M4 Max") }
                    Button("Apple M5 Max (macOS Metal)") { applyAppleSiliconWebGLPreset(chip: "Apple M5 Max") }
                } label: {
                    Label("Apply Apple Silicon GPU Preset…", systemImage: "cpu")
                }

                CuriumStackedTextFieldRow(
                    title: "Desktop WebGL Vendor",
                    placeholder: "Native Apple",
                    text: optionalStringBinding(\.desktop.webglVendor),
                    isReadOnly: false,
                    font: .caption
                )

                CuriumStackedTextFieldRow(
                    title: "Desktop WebGL Renderer",
                    placeholder: "Native Apple Metal",
                    text: optionalStringBinding(\.desktop.webglRenderer),
                    isReadOnly: false,
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
                        isReadOnly: false,
                        font: .caption
                    )

                    CuriumStackedTextFieldRow(
                        title: "Mobile WebGL Renderer",
                        placeholder: "Native Apple Metal",
                        text: optionalStringBinding(\.mobile.webglRenderer),
                        isReadOnly: false,
                        font: .caption
                    )
                }
            }

            Toggle("Send Do Not Track (DNT: 1)", isOn: $draft.enableDoNotTrack)
        } header: {
            Text("Manual Hardware & GPU Overrides")
        }
    }

    private var metadataAndExportSection: some View {
        Section("Metadata & JSON Export") {
            LabeledContent("Profile ID") {
                Text(draft.id)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let folder = storageFolderDisplayName {
                LabeledContent("Storage Folder") {
                    Text(folder)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("Revision", value: "\(draft.revision)")

            CuriumStackedTextFieldRow(
                title: "Notes",
                placeholder: "Optional notes",
                text: $draft.notes,
                isReadOnly: false,
                monospaced: false,
                font: .callout,
                autocapitalization: .sentences
            )

            Button {
                onCopyProfileJSON()
            } label: {
                Label(
                    copiedLabel == "profile" ? "Copied Profile JSON" : "Copy Profile JSON",
                    systemImage: copiedLabel == "profile" ? "checkmark.circle" : "doc.on.doc"
                )
            }

            Button {
                onCopyEngineWireJSON()
            } label: {
                Label(
                    copiedLabel == "wire"
                        ? "Copied Engine Wire JSON"
                        : "Copy Engine Wire JSON (v\(CuriumFingerprintSchema.version))",
                    systemImage: copiedLabel == "wire" ? "checkmark.circle" : "curlybraces"
                )
            }
            .disabled(!canCopyWireJSON)

            Button {
                onShareProfileJSON()
            } label: {
                Label("Share Profile JSON", systemImage: "square.and.arrow.up")
            }
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

    private func optionalStringBinding(_ keyPath: WritableKeyPath<CuriumFingerprintProfile, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { newValue in
                draft[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func slotSummary(_ slot: CuriumIdentitySlot, fallbackPlatform: String) -> String {
        let platform = slot.platform ?? fallbackPlatform
        let nav = slot.navigatorPlatform ?? "auto"
        let version = slot.majorVersion.map { "Chrome/\($0)" } ?? "Engine Chrome"
        return "\(platform) · \(nav) · \(version)"
    }

    private func applyWebGLPreset(vendor: String?, renderer: String?) {
        draft.mobile.webglVendor = vendor
        draft.mobile.webglRenderer = renderer
        draft.desktop.webglVendor = vendor
        draft.desktop.webglRenderer = renderer
    }

    private func applyAppleSiliconWebGLPreset(chip: String) {
        let vendor = "Google Inc. (Apple)"
        let renderer = "ANGLE (Apple, ANGLE Metal Renderer: \(chip), Unspecified Version)"
        draft.desktop.webglVendor = vendor
        draft.desktop.webglRenderer = renderer
        draft.desktop.webglProfile = .native
        if draft.mobile.mobile != true {
            draft.mobile.webglVendor = vendor
            draft.mobile.webglRenderer = renderer
            draft.mobile.webglProfile = .native
        }
    }
}
