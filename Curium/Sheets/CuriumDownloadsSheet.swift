import CuriumEngineContract
import PDFKit
import QuickLook
import SwiftUI

struct CuriumDownloadsSheet: View {
    let store: CuriumBrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var quickLookURL: URL?

    private struct QuickLookItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private var hasActiveDownloads: Bool {
        store.downloads.contains { $0.isActive }
    }

    private var hasSessionTasks: Bool {
        !store.downloads.isEmpty
    }

    private var hasFinishedTasks: Bool {
        store.downloads.contains { !$0.isActive && $0.state != .pending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.downloads.isEmpty && store.savedDownloads.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.to.line")
                    } description: {
                        Text(
                            store.isEngineReady
                                ? "Saved files and active downloads appear here. PDFs open directly in your tab and only save here when you choose Save."
                                : "Downloads will be available when Blink is ready."
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                } else {
                    List {
                        if hasSessionTasks {
                            Section {
                                ForEach(store.downloads) { item in
                                    activeDownloadRow(item)
                                }
                            } header: {
                                Text("This Session")
                            }
                        }

                        if !store.savedDownloads.isEmpty {
                            Section {
                                ForEach(store.savedDownloads) { file in
                                    savedDownloadRow(file)
                                }
                            } header: {
                                Text("Saved Files")
                            } footer: {
                                Text("Saved files are stored in Curium’s Downloads folder and remain accessible in Files.")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hasFinishedTasks {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            store.clearFinishedDownloadTasks()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
        .onAppear {
            store.refreshSavedDownloads()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshSavedDownloads()
            }
        }
        .task(id: scenePhase == .active && hasActiveDownloads) {
            guard scenePhase == .active, hasActiveDownloads else { return }
            while !Task.isCancelled {
                for item in store.downloads where item.isActive {
                    item.refresh()
                }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { break }
            }
        }
        .curiumSheetErrorAlert(store: store)
        .sheet(item: Binding(
            get: { quickLookURL.map(QuickLookItem.init(url:)) },
            set: { quickLookURL = $0?.url }
        )) { item in
            NavigationStack {
                CuriumQuickLookPreview(url: item.url)
                    .navigationTitle(item.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { quickLookURL = nil } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                        }
                    }
            }
        }
    }

    private func activeDownloadRow(_ item: CuriumDownload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: item.isPDF ? "doc.richtext" : "doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = item.formattedByteSize {
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let failure = item.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if item.isActive {
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Download progress")
                } else {
                    ProgressView("Downloading…")
                }
                Button(role: .cancel) {
                    item.cancel()
                } label: {
                    Label("Cancel Download", systemImage: "xmark")
                }
                .font(.footnote)
            } else {
                switch item.state {
                case .pending:
                    Button {
                        Task { await store.startDownload(item) }
                    } label: {
                        Label("Save Download", systemImage: "arrow.down.circle")
                    }
                case .completed:
                    if let url = store.savedURL(for: item) {
                        HStack(spacing: 16) {
                            Button {
                                openFile(url: url, filename: item.filename, isPDF: item.isPDF)
                            } label: {
                                Label(item.isPDF ? "Open in Tab" : "Preview", systemImage: item.isPDF ? "doc.richtext" : "eye")
                            }
                            .buttonStyle(.borderless)

                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.subheadline)
                    } else if item.savedURL != nil {
                        Text("Deleted").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Saved").font(.footnote).foregroundStyle(.secondary)
                    }
                case .cancelled:
                    Text("Canceled").font(.footnote).foregroundStyle(.secondary)
                case .failed:
                    if item.failure == nil {
                        Text("Download failed").font(.footnote).foregroundStyle(.secondary)
                    }
                case .inProgress:
                    EmptyView()
                @unknown default:
                    Text("Status unavailable").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func savedDownloadRow(_ file: CuriumSavedDownload) -> some View {
        HStack(spacing: 12) {
            Button {
                openFile(url: file.url, filename: file.filename, isPDF: file.isPDF)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: file.isPDF ? "doc.richtext" : "doc")
                        .font(.title3)
                        .foregroundStyle(file.isPDF ? Color.accentColor : Color.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.filename)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(savedMetadataText(for: file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ShareLink(item: file.url) {
                Label("Share \(file.filename)", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .frame(width: CuriumSpace.tapTarget, height: CuriumSpace.tapTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.deleteSavedDownload(file)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func openFile(url: URL, filename: String, isPDF: Bool) {
        if isPDF {
            let saved = CuriumSavedDownload(
                url: url,
                filename: filename,
                byteCount: 0,
                modifiedAt: .now,
                isPDF: true
            )
            store.openSavedPDFInActiveTab(saved)
            dismiss()
        } else {
            quickLookURL = url
        }
    }

    private func savedMetadataText(for file: CuriumSavedDownload) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)
        let date = file.modifiedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(size) · \(date)"
    }
}

private struct CuriumQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
