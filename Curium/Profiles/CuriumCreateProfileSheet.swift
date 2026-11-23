import SwiftUI

/// Guided local profile creation sheet with live persona preview, curated 16-symbol
/// icon grid, 6 actinide accent swatches, 7 fingerprint archetypes, and per-profile defaults.
struct CuriumCreateProfileSheet: View {
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
    @State private var selectedTemplateID: String = CuriumProfileTemplate.allTemplates.first?.id ?? "default"
    @State private var selectedSymbol: String = CuriumProfileTemplate.allTemplates.first?.defaultSymbolName ?? "person.crop.circle"
    @State private var selectedPalette: CuriumPalette = CuriumProfileTemplate.allTemplates.first?.defaultPalette ?? .violet
    @State private var userPickedSymbol = false
    @State private var userPickedPalette = false
    @State private var selectedSiteMode: CuriumSiteMode = .adaptive
    @State private var selectedSearchEngine: CuriumSearchEngine = .google
    @State private var alertMessage: String?

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private let paletteColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    .disabled(trimmedDisplayName.isEmpty || fingerprintStore.loadError != nil)
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
                    Text("\(selectedPalette.title) · \(selectedPalette.notation)")
                        .font(.caption.monospaced())
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
                    if !userPickedSymbol {
                        selectedSymbol = template.defaultSymbolName
                    }
                    if !userPickedPalette {
                        selectedPalette = template.defaultPalette
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
            Text("Fingerprint Archetype")
        } footer: {
            Text(
                "Templates seed an independent local profile with its own random farbling seed. Every setting can be customized after creation."
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
                "Stored locally on this device with isolated cookies, site storage, extensions, SQLite bookmarks/history, and open tabs."
            )
        }
    }

    // MARK: - Actions

    private func createProfile() {
        guard !trimmedDisplayName.isEmpty else { return }
        guard let created = fingerprintStore.createProfile(
            fromTemplate: selectedTemplateID,
            displayName: trimmedDisplayName,
            symbolName: selectedSymbol,
            palette: selectedPalette,
            siteMode: selectedSiteMode,
            searchEngine: selectedSearchEngine
        ) else {
            alertMessage = fingerprintStore.lastPersistError ?? "Unable to create profile."
            return
        }
        onCreated(created)
        dismiss()
    }
}
