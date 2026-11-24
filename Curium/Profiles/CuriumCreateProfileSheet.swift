import SwiftUI

/// Guided local profile creation sheet with live persona preview, curated 16-symbol
/// icon grid, 6 actinide accent swatches, verified Chrome 158 fingerprint archetypes,
/// selectable chip/RAM/screen hardware variants, optional proxy/locale, and defaults.
struct CuriumCreateProfileSheet: View {
    private static let autoDistinctVariantTag = "__auto_distinct__"
    private static let nativeHardwareTag = "__native_hw__"

    private enum ProxyModeChoice: String, CaseIterable, Identifiable {
        case system
        case direct
        case fixed

        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "System"
            case .direct: return "Direct"
            case .fixed: return "Fixed"
            }
        }
    }

    private enum LanguagePreset: String, CaseIterable, Identifiable {
        case system
        case enUS
        case enGB
        case zhCN
        case jaJP
        case deDE

        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "System Default"
            case .enUS: return "English (US)"
            case .enGB: return "English (UK)"
            case .zhCN: return "Chinese (Simplified)"
            case .jaJP: return "Japanese"
            case .deDE: return "German"
            }
        }

        var shortSummary: String? {
            switch self {
            case .system: return nil
            case .enUS: return "en-US"
            case .enGB: return "en-GB"
            case .zhCN: return "zh-CN"
            case .jaJP: return "ja-JP"
            case .deDE: return "de-DE"
            }
        }

        var tags: [String]? {
            switch self {
            case .system: return nil
            case .enUS: return ["en-US", "en"]
            case .enGB: return ["en-GB", "en"]
            case .zhCN: return ["zh-CN", "zh", "en"]
            case .jaJP: return ["ja-JP", "ja", "en"]
            case .deDE: return ["de-DE", "de", "en"]
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

    var fingerprintStore: CuriumFingerprintStore
    var onCreated: (CuriumFingerprintProfile) -> Void

    init(
        fingerprintStore: CuriumFingerprintStore = .shared,
        onCreated: @escaping (CuriumFingerprintProfile) -> Void
    ) {
        self.fingerprintStore = fingerprintStore
        self.onCreated = onCreated
    }

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var selectedTemplateID: String = CuriumProfileTemplate.allTemplates.first?.id ?? "macos-desktop"
    @State private var selectedSymbol: String = CuriumProfileTemplate.allTemplates.first?.defaultSymbolName ?? "laptopcomputer"
    @State private var selectedPalette: CuriumPalette = CuriumProfileTemplate.allTemplates.first?.defaultPalette ?? .neptunium
    @State private var userPickedSymbol = false
    @State private var userPickedPalette = false
    @State private var userToggledFarbling = false
    @State private var enableFarbling = CuriumProfileTemplate.allTemplates.first?.enablesFarblingByDefault ?? false
    @State private var selectedHardwareChoice: String = CuriumCreateProfileSheet.autoDistinctVariantTag
    @State private var isNetworkLocaleExpanded = false
    @State private var proxyModeSelection: ProxyModeChoice = .system
    @State private var fixedProxyRules = ""
    @State private var fixedProxyBypass = ""
    @State private var selectedTimezone = ""
    @State private var selectedLanguagePreset: LanguagePreset = .system
    @State private var selectedSiteMode: CuriumSiteMode = .adaptive
    @State private var selectedSearchEngine: CuriumSearchEngine = .google
    @State private var alertMessage: String?

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private let paletteColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedProxyRules: String {
        fixedProxyRules.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedProxyBypass: String {
        fixedProxyBypass.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFixedProxyRulesValid: Bool {
        guard proxyModeSelection == .fixed else { return true }
        let rules = trimmedProxyRules
        guard !rules.isEmpty,
              rules.utf8.count <= 1024,
              !rules.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return false }
        return CuriumFingerprintValidator.isValidFixedProxyRules(rules)
    }

    private var isFixedProxyBypassValid: Bool {
        guard proxyModeSelection == .fixed else { return true }
        let bypass = trimmedProxyBypass
        guard bypass.utf8.count <= 2048,
              !bypass.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return false }
        return true
    }

    private var canCreateProfile: Bool {
        !trimmedDisplayName.isEmpty
            && fingerprintStore.loadError == nil
            && isFixedProxyRulesValid
            && isFixedProxyBypassValid
    }

    private var networkLocaleSummary: String {
        var parts: [String] = []
        switch proxyModeSelection {
        case .system:
            parts.append("System")
        case .direct:
            parts.append("Direct")
        case .fixed:
            parts.append("Fixed Proxy")
        }
        if selectedTimezone.isEmpty {
            if proxyModeSelection == .system && selectedLanguagePreset == .system {
                parts.append("Native TZ")
            }
        } else {
            let shortTZ = selectedTimezone
                .split(separator: "/")
                .last
                .map { $0.replacingOccurrences(of: "_", with: " ") }
                ?? selectedTimezone
            parts.append(shortTZ)
        }
        if let langSummary = selectedLanguagePreset.shortSummary {
            parts.append(langSummary)
        }
        return parts.joined(separator: " · ")
    }

    private var selectedTemplate: CuriumProfileTemplate {
        CuriumProfileTemplate.template(for: selectedTemplateID)
            ?? CuriumProfileTemplate.allTemplates[0]
    }

    var body: some View {
        NavigationStack {
            Form {
                previewHeaderSection
                identitySection
                templatesSection
                fingerprintProtectionSection
                networkAndLocaleSection
                defaultsSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("curium.createProfile.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        createProfile()
                    } label: {
                        Label("Create", systemImage: "checkmark")
                    }
                    .disabled(!canCreateProfile)
                    .accessibilityIdentifier("curium.createProfile.create")
                }
            }
            .alert("New Profile", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var previewHeaderSection: some View {
        Section {
            VStack(spacing: 10) {
                CuriumProfileAvatar(
                    symbolName: selectedSymbol,
                    palette: selectedPalette,
                    size: 64,
                    isCircle: true
                )

                Text(trimmedDisplayName.isEmpty ? "New Profile" : trimmedDisplayName)
                    .font(.headline)
                    .foregroundStyle(trimmedDisplayName.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(selectedTemplate.badge.uppercased())
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(selectedPalette.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(selectedPalette.tile, in: Capsule())

                    Text(selectedTemplate.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .animation(.snappy(duration: 0.2), value: selectedSymbol)
            .animation(.snappy(duration: 0.2), value: selectedPalette)
            .animation(.snappy(duration: 0.2), value: selectedTemplateID)
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Profile Name", text: $displayName)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .accessibilityIdentifier("curium.createProfile.name")

            VStack(alignment: .leading, spacing: 10) {
                Text("Icon")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: iconColumns, spacing: 8) {
                    ForEach(CuriumProfileSymbols.curated, id: \.self) { symbol in
                        let isSelected = selectedSymbol == symbol
                        Button {
                            selectedSymbol = symbol
                            userPickedSymbol = true
                        } label: {
                            Image(systemName: symbol)
                                .font(.title3.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? selectedPalette.tint : .primary)
                                .frame(maxWidth: .infinity, minHeight: CuriumSpace.tapTarget)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? selectedPalette.tile : Color(uiColor: .tertiarySystemFill))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? selectedPalette.tint : .clear,
                                            lineWidth: 1.5
                                        )
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(CuriumProfileSymbolLabels.label(for: symbol))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("curium.createProfile.symbol.\(symbol)")
                    }
                }
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Accent")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(selectedPalette.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: paletteColumns, spacing: 8) {
                    ForEach(CuriumPalette.allCases) { option in
                        let isSelected = selectedPalette == option
                        Button {
                            selectedPalette = option
                            userPickedPalette = true
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
                        .accessibilityLabel("\(option.title) (\(option.notation))")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("curium.createProfile.palette.\(option.rawValue)")
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var templatesSection: some View {
        Section {
            ForEach(CuriumProfileTemplate.allTemplates) { template in
                let isSelected = selectedTemplateID == template.id
                Button {
                    selectedTemplateID = template.id
                    selectedHardwareChoice = Self.autoDistinctVariantTag
                    if !userPickedSymbol {
                        selectedSymbol = template.defaultSymbolName
                    }
                    if !userPickedPalette {
                        selectedPalette = template.defaultPalette
                    }
                    if !userToggledFarbling {
                        enableFarbling = template.enablesFarblingByDefault
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(template.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(template.badge)
                                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(isSelected ? selectedPalette.tint : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        isSelected ? selectedPalette.tile : Color(uiColor: .tertiarySystemFill),
                                        in: Capsule()
                                    )
                                    .fixedSize(horizontal: true, vertical: false)
                                    .layoutPriority(1)
                            }

                            Text(template.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if template.hasHardwareVariantPool {
                                Text("\(template.hardwareVariantCount) hardware variants")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selectedPalette.tint)
                                .padding(.top, 2)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("curium.createProfile.template.\(template.id)")
            }
        } header: {
            Text("Profile Template")
        } footer: {
            Text(
                "Both templates run Apple Silicon macOS Chrome 158 with isolated cookies, storage, and extensions."
            )
        }
    }

    private var fingerprintProtectionSection: some View {
        let poolVariants = CuriumFingerprintDevicePools.variants(forTemplateID: selectedTemplate.id)

        return Section {
            Toggle(
                "Anti-Fingerprinting Protection",
                isOn: Binding(
                    get: { enableFarbling },
                    set: { next in
                        userToggledFarbling = true
                        enableFarbling = next
                    }
                )
            )
            .accessibilityIdentifier("curium.createProfile.farbling")

            if !poolVariants.isEmpty {
                Picker("Mac Hardware", selection: $selectedHardwareChoice) {
                    Text("Auto (Distinct Mac)").tag(Self.autoDistinctVariantTag)
                    ForEach(poolVariants) { variant in
                        Text(variant.label).tag(variant.id)
                    }
                    if selectedTemplate.supportsNativeHardwareBaseline {
                        Text("Native Apple Silicon").tag(Self.nativeHardwareTag)
                    }
                }
                .accessibilityIdentifier("curium.createProfile.hardwareVariant")
            }
        } header: {
            Text("Device & Protection")
        } footer: {
            Text(
                "Auto assigns a distinct Apple Silicon chip, display, macOS release, and font profile. Optional farbling adds a unique per-site seed (enabled by default on Privacy Hardened)."
            )
        }
    }

    private var networkAndLocaleSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isNetworkLocaleExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Proxy")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("Proxy", selection: $proxyModeSelection) {
                        ForEach(ProxyModeChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("curium.createProfile.proxyMode")
                }
                .padding(.vertical, 2)

                if proxyModeSelection == .fixed {
                    CuriumStackedTextFieldRow(
                        title: "Proxy Rules",
                        placeholder: "socks5://127.0.0.1:1080",
                        text: $fixedProxyRules,
                        isReadOnly: false,
                        monospaced: true,
                        font: .callout,
                        keyboardType: .URL,
                        autocapitalization: .never,
                        textFieldAccessibilityID: "curium.createProfile.proxyRules"
                    )

                    if !isFixedProxyRulesValid {
                        Label(
                            "Enter valid proxy rules (e.g. socks5://127.0.0.1:1080 or http=127.0.0.1:8080;https=127.0.0.1:8080).",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("curium.createProfile.proxyError")
                    }

                    CuriumStackedTextFieldRow(
                        title: "Bypass Rules (Optional)",
                        placeholder: "localhost,127.0.0.1",
                        text: $fixedProxyBypass,
                        isReadOnly: false,
                        monospaced: true,
                        font: .callout,
                        keyboardType: .URL,
                        autocapitalization: .never,
                        textFieldAccessibilityID: "curium.createProfile.proxyBypass"
                    )

                    if !isFixedProxyBypassValid {
                        Label(
                            "Bypass rules contain invalid control characters or exceed 2048 bytes.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }

                Picker("Timezone", selection: $selectedTimezone) {
                    Text("System Default").tag("")
                    ForEach(Self.commonTimezones, id: \.self) { tz in
                        Text(tz).tag(tz)
                    }
                }
                .accessibilityIdentifier("curium.createProfile.timezone")

                Picker("Language", selection: $selectedLanguagePreset) {
                    ForEach(LanguagePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .accessibilityIdentifier("curium.createProfile.language")
            } label: {
                LabeledContent("Proxy & Locale") {
                    Text(networkLocaleSummary)
                        .font(.caption)
                        .foregroundStyle(
                            (!isFixedProxyRulesValid || !isFixedProxyBypassValid) ? .red : .secondary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .accessibilityIdentifier("curium.createProfile.networkLocale")
        } header: {
            Text("Network & Locale")
        } footer: {
            Text(
                "Pairing a per-profile Fixed Proxy IP with a distinct hardware variant prevents server-side services like Fingerprint Pro from linking profiles on the same network."
            )
        }
    }

    private var defaultsSection: some View {
        Section {
            Picker("Default Site Layout", selection: $selectedSiteMode) {
                ForEach(CuriumSiteMode.allCases) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }

            Picker("Search Engine", selection: $selectedSearchEngine) {
                ForEach(CuriumSearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
        } header: {
            Text("Defaults")
        } footer: {
            Text(
                "Duo Adaptive adjusts viewport width on the outer cover display while keeping your macOS browser identity unchanged."
            )
        }
    }

    // MARK: - Actions

    private func createProfile() {
        guard canCreateProfile else { return }
        let proxyConfig: CuriumProxyConfig? = switch proxyModeSelection {
        case .system:
            .system
        case .direct:
            .direct
        case .fixed:
            .fixed(
                rules: trimmedProxyRules,
                bypassRules: trimmedProxyBypass.isEmpty ? nil : trimmedProxyBypass
            )
        }
        let timezone = selectedTimezone.isEmpty ? nil : selectedTimezone
        let languages = selectedLanguagePreset.tags

        let randomizeVariant: Bool
        let explicitVariantID: String?
        if !selectedTemplate.hasHardwareVariantPool || selectedHardwareChoice == Self.nativeHardwareTag {
            randomizeVariant = false
            explicitVariantID = nil
        } else if selectedHardwareChoice == Self.autoDistinctVariantTag {
            randomizeVariant = true
            explicitVariantID = nil
        } else {
            randomizeVariant = false
            explicitVariantID = selectedHardwareChoice
        }

        guard let created = fingerprintStore.createProfile(
            fromTemplate: selectedTemplateID,
            displayName: trimmedDisplayName,
            symbolName: selectedSymbol,
            palette: selectedPalette,
            siteMode: selectedSiteMode,
            searchEngine: selectedSearchEngine,
            enableFarbling: enableFarbling,
            randomizeHardwareVariant: randomizeVariant,
            hardwareVariantID: explicitVariantID,
            proxy: proxyConfig,
            timezone: timezone,
            languages: languages
        ) else {
            alertMessage = fingerprintStore.lastPersistError ?? "Unable to create profile."
            return
        }
        onCreated(created)
        dismiss()
    }
}
