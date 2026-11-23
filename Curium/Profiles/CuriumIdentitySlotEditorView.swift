import SwiftUI
import UIKit

// MARK: - Narrow-Width-Safe Form Controls

/// Stacked label + multi-line `TextField` that stays readable at iPhone Duo's
/// `382 pt` outer portrait safe width and Dynamic Type XL without horizontal clipping.
/// In read-only mode, renders selectable text so users can copy technical fields.
struct CuriumStackedTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let isReadOnly: Bool
    var monospaced: Bool = true
    var font: Font = .callout
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never
    var textFieldAccessibilityID: String? = nil

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
                textField
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var textField: some View {
        let field = TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...4)
            .font(monospaced ? font.monospaced() : font)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled()
        if let textFieldAccessibilityID {
            field.accessibilityIdentifier(textFieldAccessibilityID)
        } else {
            field
        }
    }
}

/// Preserves the 3-way Client Hint distinction between `nil` (Engine Auto),
/// `""` (Explicit Empty string, e.g. Linux `platformVersion` / Android `architecture`),
/// and a non-empty custom value.
struct CuriumTriStateTextField: View {
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

// MARK: - Identity Slot Sub-Editor

/// Per-slot (Mobile / Desktop) UA, Client Hints, Navigator, Input, WebGL, and Web Screen editor
/// with debounced inline `CuriumFingerprintValidator.validateSlot(...)` feedback.
struct CuriumIdentitySlotEditorView: View {
    let title: String
    let slotKey: String
    @Binding var slot: CuriumIdentitySlot
    let isReadOnly: Bool

    @State private var brandMode: PrimaryBrandMode
    @State private var customBrandText: String
    @State private var cachedSlotReport: CuriumFingerprintValidationReport
    @State private var isWebGLLimitsExpanded: Bool
    @FocusState private var isNumberPadFocused: Bool

    private static let webGLLimitPresets: [Int] = [4096, 8192, 16384, 32768]

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
        let current = slot.wrappedValue
        let currentBrand = current.primaryBrand
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
                current.normalizedForPersistence(),
                name: slotKey
            )
        )
        _isWebGLLimitsExpanded = State(
            initialValue: current.webglMaxTextureSize != nil
                || current.webglMaxRenderbufferSize != nil
                || current.webglMaxCubeMapTextureSize != nil
        )
    }

    var body: some View {
        Form {
            userAgentSection
            brandAndVersionSection
            clientHintsSection
            inputAndWebGLSection
            webScreenSection

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
                Button {
                    isNumberPadFocused = false
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                } label: {
                    Label("Done", systemImage: "checkmark")
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

    // MARK: - Sections

    private var userAgentSection: some View {
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
    }

    private var brandAndVersionSection: some View {
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
    }

    private var clientHintsSection: some View {
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
            Text(
                "Choose Auto to let the engine resolve defaults, Empty (\"\") to emit an explicit empty Client Hint header (e.g. Linux platformVersion or Android architecture), or Custom."
            )
        }
    }

    private var inputAndWebGLSection: some View {
        Section("Optional Input & WebGL Slot Overrides") {
            Picker("Max Touch Points", selection: $slot.maxTouchPoints) {
                Text("Native Device").tag(Int?.none)
                Text("0 (Mouse Desktop)").tag(Int?.some(0))
                Text("5 (Mobile Touch)").tag(Int?.some(5))
                Text("10 (Tablet Touch)").tag(Int?.some(10))
                if let current = slot.maxTouchPoints, ![0, 5, 10].contains(current) {
                    Text("\(current) (Custom)").tag(Int?.some(current))
                }
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

            DisclosureGroup("WebGL Capability Limits", isExpanded: $isWebGLLimitsExpanded) {
                webGLLimitPicker("Max Texture Size", selection: $slot.webglMaxTextureSize)
                webGLLimitPicker("Max Renderbuffer Size", selection: $slot.webglMaxRenderbufferSize)
                webGLLimitPicker("Max Cube Map Size", selection: $slot.webglMaxCubeMapTextureSize)
            }

            Picker("PDF Viewer Metadata", selection: $slot.pdfViewerEnabled) {
                Text("Auto (Desktop Only)").tag(Bool?.none)
                Text("Expose PDF Viewer").tag(Bool?.some(true))
                Text("Disabled").tag(Bool?.some(false))
            }
            .disabled(isReadOnly)
        }
    }

    private var webScreenSection: some View {
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
            Text(
                "Applies strictly to Web Screen/MediaValues/outerHeight APIs without changing native iPhone Duo display layout."
            )
        }
    }

    private func webGLLimitPicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("Auto").tag(Int?.none)
            ForEach(Self.webGLLimitPresets, id: \.self) { size in
                Text("\(size)").tag(Int?.some(size))
            }
            if let current = selection.wrappedValue, !Self.webGLLimitPresets.contains(current) {
                Text("\(current) (Custom)").tag(Int?.some(current))
            }
        }
        .disabled(isReadOnly)
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
