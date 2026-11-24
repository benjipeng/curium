import SwiftUI

/// Compact modal sheet for verifying and applying a replacement download URL to a paused or
/// failed transfer without risking corruption of staged `.part` or HLS segment data.
struct CuriumRefreshURLSheet: View {
    @Environment(\.curiumPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    let store: CuriumBrowserStore
    let download: CuriumDownload

    @State private var urlText = ""
    @State private var includeActiveTabCookies = false
    @State private var userTouchedCookieToggle = false
    @State private var isVerifying = false
    @State private var verificationErrorMessage: String?
    @State private var verificationTask: Task<Void, Never>?
    @FocusState private var isURLFieldFocused: Bool

    private var parsedURL: URL? {
        let cleaned = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let url = URL(string: cleaned),
              CuriumHLSParser.isAllowedHTTPURL(url) else {
            return nil
        }
        return url
    }

    private var matchesActiveProfile: Bool {
        store.transferMatchesActiveProfile(download)
    }

    private var canAutoInheritCookies: Bool {
        guard matchesActiveProfile, let url = parsedURL else { return false }
        return store.canInheritActiveTabCookies(for: url)
    }

    private var canToggleActiveTabCookies: Bool {
        matchesActiveProfile && store.activeTab != nil && !isVerifying
    }

    private var preservedProgressSummary: String {
        if let totalSegs = download.totalSegments, totalSegs > 0 {
            if download.receivedBytes > 0 {
                return "\(download.completedSegments)/\(totalSegs) segs · \(CuriumTransferFormatters.bytes(download.receivedBytes))"
            }
            return "\(download.completedSegments)/\(totalSegs) segs"
        }
        if let total = download.knownTotalBytes, total > 0 {
            let ratio = "\(CuriumTransferFormatters.bytes(download.receivedBytes)) / \(CuriumTransferFormatters.bytes(total))"
            if download.receivedBytes > 0, let pct = CuriumTransferFormatters.percentage(download.fraction) {
                return "\(ratio) (\(pct))"
            }
            return ratio
        }
        if download.receivedBytes > 0 {
            return CuriumTransferFormatters.bytes(download.receivedBytes)
        }
        return "0 B staged"
    }

    private var urlPlaceholder: String {
        download.transportKind == .hlsRemuxMP4
            ? "https://example.com/fresh-playlist.m3u8"
            : "https://example.com/fresh-signed-link"
    }

    var body: some View {
        NavigationStack {
            List {
                // 1. Preserved Partial Transfer Context
                Section("Preserved Progress") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: download.symbolName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(palette.tint)
                                .accessibilityHidden(true)

                            Text(download.filename)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Text(download.transportKind.displayTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    LabeledContent("Staged Data") {
                        Text(preservedProgressSummary)
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(.primary)
                    }

                    if let eTag = download.eTag, !eTag.isEmpty {
                        LabeledContent("Expected ETag") {
                            Text(eTag)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                // 2. Replacement URL Input & Inline Verification Error
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        TextField(urlPlaceholder, text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .focused($isURLFieldFocused)
                            .disabled(isVerifying)
                            .onSubmit(submitRefresh)
                            .accessibilityIdentifier("curium.refreshURL.url")

                        if !urlText.isEmpty && !isVerifying {
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
                        .disabled(isVerifying)
                        .accessibilityIdentifier("curium.refreshURL.paste")
                    }

                    if let errorMessage = verificationErrorMessage, !errorMessage.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.semibold))
                                Text("Verification Rejected")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.red)

                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("curium.refreshURL.error")
                    }
                } header: {
                    Text("New Download Link")
                } footer: {
                    Text("Curium probes the replacement link and verifies exact file size, ETag, or HLS segment structure before resuming. Partial data is never modified if verification fails.")
                }

                // 3. Active Tab Cookie & User-Agent Inheritance
                Section {
                    Toggle(
                        "Use Active Tab Cookies & UA",
                        isOn: Binding(
                            get: { matchesActiveProfile && includeActiveTabCookies },
                            set: { newValue in
                                userTouchedCookieToggle = true
                                includeActiveTabCookies = newValue
                            }
                        )
                    )
                    .tint(palette.tint)
                    .disabled(!canToggleActiveTabCookies)
                    .accessibilityIdentifier("curium.refreshURL.cookies")
                } footer: {
                    if !matchesActiveProfile {
                        Text("This transfer belongs to a different browser profile, so active tab cookies cannot be attached.")
                    } else if store.activeTab == nil {
                        Text("No active tab is available to supply session cookies.")
                    } else if canAutoInheritCookies {
                        Text("Matches the active tab’s site. Enabled automatically to reuse its cookies, User-Agent, and Referer.")
                    } else {
                        Text("Off by default because the link does not match the active tab’s site. Enable only if this host requires the active tab’s session.")
                    }
                }

                // 4. Verify & Resume Action
                Section {
                    Button {
                        submitRefresh()
                    } label: {
                        HStack {
                            Spacer()
                            if isVerifying {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                    Text("Verifying…")
                                }
                                .font(.headline)
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.shield.fill")
                                    Text("Verify & Resume")
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
                    .disabled(parsedURL == nil || isVerifying || !download.canRefreshURL)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .accessibilityIdentifier("curium.refreshURL.submit")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Update Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        verificationTask?.cancel()
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
            }
            .onAppear {
                isURLFieldFocused = true
            }
            .onDisappear {
                verificationTask?.cancel()
                verificationTask = nil
            }
            .onChange(of: urlText) { _, _ in
                if verificationErrorMessage != nil {
                    verificationErrorMessage = nil
                }
            }
            .onChange(of: parsedURL) { _, newURL in
                let eligible = matchesActiveProfile && (newURL.map { store.canInheritActiveTabCookies(for: $0) } ?? false)
                if !eligible {
                    if !userTouchedCookieToggle {
                        includeActiveTabCookies = false
                    }
                } else if !userTouchedCookieToggle {
                    includeActiveTabCookies = true
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submitRefresh() {
        guard let url = parsedURL, !isVerifying, download.canRefreshURL else { return }
        let useCookies = matchesActiveProfile && store.activeTab != nil && includeActiveTabCookies
        verificationErrorMessage = nil
        isVerifying = true
        isURLFieldFocused = false

        verificationTask?.cancel()
        verificationTask = Task { @MainActor in
            defer {
                isVerifying = false
                verificationTask = nil
            }
            do {
                try await store.refreshTransferURL(
                    download,
                    newURL: url,
                    includeActiveTabCookies: useCookies
                )
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                verificationErrorMessage = error.localizedDescription
            }
        }
    }
}
