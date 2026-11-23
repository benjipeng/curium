import SwiftUI
import UIKit

/// Imports either a full `CuriumFingerprintProfile` JSON export or a Build 40/41/42
/// engine wire payload (`schemaVersion` + `profileId`) as a brand-new local profile
/// under a freshly minted collision-free `p-<8hex>` slug.
struct CuriumProfileImportSheet: View {
    var store: CuriumFingerprintStore
    var onImported: (CuriumFingerprintProfile) -> Void

    init(
        store: CuriumFingerprintStore = .shared,
        onImported: @escaping (CuriumFingerprintProfile) -> Void
    ) {
        self.store = store
        self.onImported = onImported
    }

    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var errorMessages: [String] = []
    @State private var warningMessages: [String] = []
    @State private var importedWithWarnings: CuriumFingerprintProfile?

    private var canImport: Bool {
        !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.loadError == nil
            && importedWithWarnings == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let imported = importedWithWarnings {
                    Section {
                        Label(
                            "Imported \"\(imported.displayName)\" (\(imported.id)) with warnings. Review the items below before continuing.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.green)

                        Button {
                            onImported(imported)
                            dismiss()
                        } label: {
                            Label("Open Imported Profile", systemImage: "arrow.right.circle")
                        }
                        .accessibilityIdentifier("curium.import.open")
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
                            importedWithWarnings = nil
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("curium.import.paste")

                    TextEditor(text: $jsonText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("curium.import.editor")

                    if importedWithWarnings == nil {
                        Button {
                            performImport()
                        } label: {
                            Label("Import as New Profile", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!canImport)
                        .accessibilityIdentifier("curium.import.importButton")
                    }
                } header: {
                    Text("Profile or Engine Wire JSON")
                } footer: {
                    Text(
                        "Accepts exported Curium profile JSON or Build 40/41/42 engine wire payloads (schemaVersion 1–2). Always mints a fresh isolated profile ID so existing, template, and retired slugs never collide."
                    )
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
                        if let imported = importedWithWarnings {
                            onImported(imported)
                        }
                        dismiss()
                    } label: {
                        Label(
                            importedWithWarnings == nil ? "Cancel" : "Done",
                            systemImage: importedWithWarnings == nil ? "xmark" : "checkmark"
                        )
                    }
                    .accessibilityIdentifier("curium.import.cancel")
                }

                if importedWithWarnings == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            performImport()
                        } label: {
                            Label("Import as New Profile", systemImage: "square.and.arrow.down")
                        }
                        .disabled(!canImport)
                        .accessibilityIdentifier("curium.import.submit")
                    }
                }
            }
        }
    }

    private func performImport() {
        let data = Data(jsonText.utf8)
        do {
            let result = try store.importProfileWithFreshSlug(data)
            errorMessages = result.report.errors
            warningMessages = result.report.warnings

            guard result.report.isValid, let saved = result.profile else {
                return
            }

            if result.report.warnings.isEmpty {
                onImported(saved)
                dismiss()
            } else {
                importedWithWarnings = saved
            }
        } catch {
            errorMessages = ["Invalid JSON: \(CuriumFingerprintStore.describeDecodingError(error))"]
            warningMessages = []
        }
    }
}
