import SwiftUI

/// Compact modal intake sheet for starting direct HTTP multi-lane or HLS `.m3u8` downloads by URL.
struct CuriumNewDownloadSheet: View {
    @Environment(\.curiumPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    let store: CuriumBrowserStore
    var onStarted: ((CuriumDownload) -> Void)? = nil

    @State private var urlText = ""
    @State private var customFilename = ""
    /// `0` represents `Auto (8×)`; explicit presets map to `1`, `4`, `8`, `16`.
    @State private var laneSelection: Int = 0
    @State private var includeActiveTabCookies = false
    @State private var userTouchedCookieToggle = false
    @State private var isStarting = false
    @FocusState private var isURLFieldFocused: Bool

    private var parsedURL: URL? {
        let cleaned = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let url = URL(string: cleaned),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false),
              !host.isEmpty else {
            return nil
        }
        return url
    }

    private var canInheritCookies: Bool {
        guard let url = parsedURL else { return false }
        return store.canInheritActiveTabCookies(for: url)
    }

    private var effectiveLanes: Int {
        laneSelection == 0 ? CuriumTransferRecord.defaultLanes : laneSelection
    }

    private var optionalSuggestedFilename: String? {
        let trimmed = customFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        TextField("https://example.com/file.mp4 or .m3u8", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .focused($isURLFieldFocused)
                            .onSubmit(submitDownload)
                            .accessibilityIdentifier("curium.newDownload.url")

                        if !urlText.isEmpty {
                            Button {
                                urlText = ""
                            } label: {
                                Label("Clear URL", systemImage: "xmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        PasteButton(payloadType: String.self) { strings in
                            if let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !pasted.isEmpty {
                                urlText = pasted
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(palette.tint)
                        .accessibilityIdentifier("curium.newDownload.paste")
                    }
                } header: {
                    Text("Source URL")
                } footer: {
                    Text("Direct files accelerate across parallel HTTP 206 byte-range lanes. HLS (.m3u8) playlists remux losslessly to MP4.")
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("Filename (optional)", text: $customFilename)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("curium.newDownload.filename")

                        if !customFilename.isEmpty {
                            Button {
                                customFilename = ""
                            } label: {
                                Label("Clear Filename", systemImage: "xmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Picker("Parallel Lanes", selection: $laneSelection) {
                        Text("Auto (8×)").tag(0)
                        Text("1×").tag(1)
                        Text("4×").tag(4)
                        Text("8×").tag(8)
                        Text("16×").tag(16)
                    }
                    .accessibilityIdentifier("curium.newDownload.lanes")

                    Toggle(
                        "Include Active Tab Cookies & UA",
                        isOn: Binding(
                            get: { canInheritCookies && includeActiveTabCookies },
                            set: { newValue in
                                userTouchedCookieToggle = true
                                includeActiveTabCookies = newValue
                            }
                        )
                    )
                    .tint(palette.tint)
                    .disabled(!canInheritCookies)
                    .accessibilityIdentifier("curium.newDownload.cookies")
                } header: {
                    Text("Transfer Options")
                } footer: {
                    if canInheritCookies {
                        Text("Matches the active tab’s site. Enabling this reuses the tab’s cookies, User-Agent, and Referer for authenticated links.")
                    } else {
                        Text("Cookie inheritance unlocks automatically when the URL matches the active tab’s site.")
                    }
                }

                Section {
                    Button {
                        submitDownload()
                    } label: {
                        HStack {
                            Spacer()
                            if isStarting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Start Download")
                                }
                                .font(.headline)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(palette.tint)
                    .disabled(parsedURL == nil || isStarting)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .accessibilityIdentifier("curium.newDownload.start")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
            }
            .onAppear {
                isURLFieldFocused = true
            }
            .onChange(of: parsedURL) { _, newURL in
                let eligible = newURL.map { store.canInheritActiveTabCookies(for: $0) } ?? false
                if !eligible {
                    includeActiveTabCookies = false
                    userTouchedCookieToggle = false
                } else if !userTouchedCookieToggle {
                    includeActiveTabCookies = true
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submitDownload() {
        guard let url = parsedURL, !isStarting else { return }
        let useCookies = canInheritCookies && includeActiveTabCookies
        let filename = optionalSuggestedFilename
        let lanes = effectiveLanes
        isStarting = true

        Task { @MainActor in
            let started = await store.startManualDownload(
                url: url,
                suggestedFilename: filename,
                lanes: lanes,
                includeActiveTabCookies: useCookies
            )
            isStarting = false
            if let started {
                onStarted?(started)
            }
            dismiss()
        }
    }
}
