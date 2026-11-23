import CuriumEngineContract
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct CuriumExtensionsSheet: View {
    let browser: CuriumBrowserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFile = false
    @State private var pendingCRXURL: URL?
    @State private var storeLink = ""
    @State private var activeAlert: AlertState?
    @State private var sheetReady = false
    @State private var isAwaitingModalDismissal = false
    @State private var deferredAlertTask: Task<Void, Never>?
    @State private var removing: CuriumExtension?
    @State private var popup: CuriumPopup?

    private var store: CuriumExtensionStore { browser.extensions }

    private enum ErrorSource: Equatable {
        case extensionStore
        case browser
    }

    private enum AlertState: Equatable {
        case storeLink
        case error(source: ErrorSource, message: String)

        var title: String {
            switch self {
            case .storeLink: "Chrome Web Store Link"
            case .error(let source, _):
                switch source {
                case .extensionStore: "Extension"
                case .browser: "Curium"
                }
            }
        }
    }

    private struct BlockedPollKey: Equatable {
        let active: Bool
        let tabID: Int32
        let isLoading: Bool
        let url: URL?
    }

    var body: some View {
        VStack(spacing: 0) {
            CuriumSheetHeader(title: "Extensions")
            ScrollViewReader { scroll in
                extensionList
                    .onChange(of: store.review?.id) { _, token in
                        if let token { withAnimation { scroll.scrollTo(token, anchor: .top) } }
                    }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            store.refresh(tabID: browser.activeTab?.extensionTabID ?? -1, includeBlockedCounts: true)
        }
        .task {
            if store.operationError != nil || browser.sheetErrorMessage != nil {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled else { return }
            sheetReady = true
            presentPendingErrorIfNeeded()
        }
        .task(id: BlockedPollKey(
            active: scenePhase == .active && popup == nil && store.hasEnabledExtensions
                && (browser.activeTab?.extensionTabID ?? -1) >= 0,
            tabID: browser.activeTab?.extensionTabID ?? -1,
            isLoading: browser.activeTab?.isLoading == true,
            url: browser.activeTab?.url
        )) {
            let initialTabID = browser.activeTab?.extensionTabID ?? -1
            guard scenePhase == .active,
                  popup == nil,
                  store.hasEnabledExtensions,
                  initialTabID >= 0 else { return }
            var intervalSeconds = 2
            var unchangedPolls = 0
            var lastTotal = store.blockedCount
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(intervalSeconds)) } catch { break }
                guard scenePhase == .active, popup == nil else { break }
                let currentTabID = browser.activeTab?.extensionTabID ?? -1
                guard currentTabID >= 0 else { break }
                store.refreshBlockedCounts(tabID: currentTabID)
                let nextTotal = store.blockedCount
                if nextTotal == lastTotal {
                    unchangedPolls += 1
                    if browser.activeTab?.isLoading != true {
                        if unchangedPolls >= 3 { break }
                        intervalSeconds = min(8, intervalSeconds * 2)
                    }
                } else {
                    lastTotal = nextTotal
                    unchangedPolls = 0
                    intervalSeconds = 2
                }
            }
        }
        .onChange(of: browser.backgroundEpoch) { _, _ in
            setPopup(nil)
        }
        .onChange(of: store.installed) { _, installed in
            guard let activePopup = popup else { return }
            let stillValid = installed.contains { $0.id == activePopup.host.extensionID && $0.canShowPopup }
            if !stillValid { setPopup(nil) }
        }
        .onChange(of: store.operationError) { _, _ in
            presentPendingErrorIfNeeded()
        }
        .onChange(of: browser.sheetErrorMessage) { _, _ in
            presentPendingErrorIfNeeded()
        }
        .onDisappear {
            deferredAlertTask?.cancel()
            deferredAlertTask = nil
            pendingCRXURL = nil
            setPopup(nil)
            store.endInstallSession()
        }
        .sheet(isPresented: $choosingFile, onDismiss: {
            if let url = pendingCRXURL {
                pendingCRXURL = nil
                store.prepareSignedFile(url)
            }
            presentPendingErrorIfNeeded()
        }) {
            CuriumCRXPicker { url in
                pendingCRXURL = url
                choosingFile = false
            }
            .ignoresSafeArea()
        }
        .sheet(item: Binding(
            get: { popup },
            set: { if $0 == nil { setPopup(nil) } }
        ), onDismiss: {
            presentPendingErrorIfNeeded()
        }) { activePopup in
            CuriumPopupView(presentation: activePopup)
                .presentationSizing(.fitted)
        }
        .alert(
            activeAlert?.title ?? "",
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { dismissActiveAlert() } }
            ),
            presenting: activeAlert
        ) { state in
            switch state {
            case .storeLink:
                TextField("https://chromewebstore.google.com/…", text: $storeLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Continue") {
                    let submitted = storeLink
                    activeAlert = nil
                    scheduleDeferredErrorSync(delay: .milliseconds(350))
                    store.prepareStoreLink(submitted)
                }
                Button("Cancel", role: .cancel) {
                    activeAlert = nil
                }
            case .error:
                Button("OK", role: .cancel) {
                    dismissActiveAlert()
                }
            }
        } message: { state in
            switch state {
            case .storeLink:
                EmptyView()
            case .error(_, let message):
                Text(message)
            }
        }
        .confirmationDialog("Remove Extension?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { item in
            Button("Remove \(item.name)", role: .destructive) { store.remove(item) }
        }
    }

    private var extensionList: some View {
        List {
            if store.isWorking {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Downloading and verifying extension…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let review = store.review {
                Section("Review Extension Permissions") {
                    LabeledContent("Extension", value: review.name)
                    if !review.version.isEmpty { LabeledContent("Version", value: review.version) }
                    LabeledContent("Permissions", value: review.permissions.isEmpty ? "None" : review.permissions.joined(separator: ", "))
                    LabeledContent("Site Access", value: review.hosts.isEmpty ? "None" : review.hosts.joined(separator: ", "))
                    Button { store.confirmReview() } label: { Label("Add Extension", systemImage: "checkmark") }
                    Button(role: .cancel) { store.cancelReview() } label: { Label("Cancel Review", systemImage: "xmark") }
                }
                .id(review.id)
            }

            Section("Installed · Manifest V3") {
                if !store.isAvailable {
                    Text(browser.isEngineReady ? "This Blink build does not expose extension management." :
                         "Extension management will be available when Blink is ready.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let error = store.listError {
                    Text(error).foregroundStyle(.secondary)
                } else if store.installed.isEmpty {
                    Text("No extensions installed.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.installed) { item in extensionRows(item) }
                }
            }

            Section("Add an Extension") {
                Button {
                    if let url = URL(string: "https://chromewebstore.google.com/"),
                       browser.newTab(url: url) {
                        dismiss()
                    }
                } label: {
                    Label("Browse Chrome Web Store", systemImage: "safari")
                }
                Button { choosingFile = true } label: {
                    Label("Import Signed CRX from Files…", systemImage: "doc.badge.plus")
                }
                Button {
                    storeLink = ""
                    activeAlert = .storeLink
                } label: {
                    Label("Install from Chrome Web Store Link…", systemImage: "link")
                }
            }
            .disabled(!store.isAvailable || store.isWorking || store.review != nil)
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func extensionRows(_ item: CuriumExtension) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(get: { item.isEnabled }, set: { store.setEnabled($0, for: item) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                    if !item.version.isEmpty { Text("Version \(item.version)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let count = item.blockedCount, count > 0 {
                Text("Blocked on this page: \(count, format: .number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if item.canShowPopup {
            Button {
                if let host = store.popup(for: item) {
                    let presentation = CuriumPopup(host: host, name: item.name)
                    let closeIfCurrent: @MainActor () -> Void = { [weak presentation] in
                        guard let presentation, popup === presentation else { return }
                        setPopup(nil)
                    }
                    host.onRequestClose = {
                        // Defer out of WebContentsImpl::Close / CloseWebState so host.close()
                        // does not synchronously destroy WebState and its delegate mid-callback.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                closeIfCurrent()
                            }
                        }
                    }
                    setPopup(presentation)
                }
            } label: {
                Label("Open \(item.name)", systemImage: "puzzlepiece.extension")
                    .badge(item.badge.map { Text(verbatim: $0) })
            }
        }
        if item.isEnabled, let url = item.optionsURL {
            Button {
                if browser.newTab(url: url) { dismiss() }
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("\(item.name) Options")
        }
        if item.isRemovable {
            Button(role: .destructive) { removing = item } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityLabel("Remove \(item.name)")
        }
    }

    private func setPopup(_ newValue: CuriumPopup?) {
        popup?.close()
        popup = newValue
    }

    private func presentPendingErrorIfNeeded() {
        guard sheetReady,
              !isAwaitingModalDismissal,
              activeAlert == nil,
              !choosingFile,
              popup == nil else { return }
        if let message = store.operationError {
            activeAlert = .error(source: .extensionStore, message: message)
        } else if let message = browser.sheetErrorMessage {
            activeAlert = .error(source: .browser, message: message)
        }
    }

    private func scheduleDeferredErrorSync(delay: Duration) {
        deferredAlertTask?.cancel()
        isAwaitingModalDismissal = true
        deferredAlertTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isAwaitingModalDismissal = false
            deferredAlertTask = nil
            presentPendingErrorIfNeeded()
        }
    }

    private func dismissActiveAlert() {
        let previous = activeAlert
        activeAlert = nil
        switch previous {
        case .error(let source, _):
            switch source {
            case .extensionStore:
                store.operationError = nil
            case .browser:
                browser.sheetErrorMessage = nil
            }
            if store.operationError != nil || browser.sheetErrorMessage != nil {
                scheduleDeferredErrorSync(delay: .milliseconds(350))
            }
        case .storeLink, nil:
            break
        }
    }
}

private struct CuriumCRXPicker: UIViewControllerRepresentable {
    let finish: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let type = UTType(filenameExtension: "crx", conformingTo: .data) ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: (URL?) -> Void

        init(finish: @escaping (URL?) -> Void) { self.finish = finish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    }
}

/// Safe KVO observer for `CrIOSExtensionPopupHostingV1.preferredContentSize` updates.
private final class PreferredContentSizeObserver: NSObject {
    private nonisolated(unsafe) static var kvoContext: UInt8 = 0
    private var target: NSObject?
    private let onChange: @MainActor @Sendable () -> Void

    @MainActor
    init(target: NSObject, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.target = target
        self.onChange = onChange
        super.init()
        target.addObserver(
            self,
            forKeyPath: "preferredContentSize",
            options: [.new],
            context: &Self.kvoContext
        )
    }

    func invalidate() {
        guard let target else { return }
        self.target = nil
        target.removeObserver(self, forKeyPath: "preferredContentSize", context: &Self.kvoContext)
    }

    deinit {
        invalidate()
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard context == &Self.kvoContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        let callback = onChange
        if Thread.isMainThread {
            MainActor.assumeIsolated { callback() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { callback() }
            }
        }
    }
}

@MainActor
@Observable
private final class CuriumPopup: Identifiable {
    let host: any CrIOSExtensionPopupHostingV1
    let view: UIView
    let name: String
    private(set) var preferredContentSize: CGSize
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var sizeObserver: PreferredContentSizeObserver?

    init(host: any CrIOSExtensionPopupHostingV1, name: String) {
        self.host = host
        view = host.view
        self.name = name
        preferredContentSize = host.preferredContentSize
        if let object = host as? NSObject {
            sizeObserver = PreferredContentSizeObserver(target: object) { [weak self] in
                self?.refreshPreferredContentSize()
            }
        }
    }

    isolated deinit {
        close()
    }

    func refreshPreferredContentSize() {
        guard !isClosed else { return }
        let latest = host.preferredContentSize
        if preferredContentSize != latest {
            preferredContentSize = latest
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        sizeObserver?.invalidate()
        sizeObserver = nil
        host.onRequestClose = nil
        view.removeFromSuperview()
        host.close()
    }
}

private struct CuriumPopupView: View {
    let presentation: CuriumPopup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let size = presentation.preferredContentSize
        let rawWidth = size.width.isFinite && size.width > 0 ? size.width : 360
        let rawHeight = size.height.isFinite && size.height > 0 ? size.height : 440
        let idealWidth = min(480, max(280, rawWidth))
        let idealHeight = min(560, max(240, rawHeight))

        NavigationStack {
            Surface(content: presentation.view) {
                let latest = presentation.host.preferredContentSize
                guard latest != presentation.preferredContentSize else { return }
                Task { @MainActor in
                    presentation.refreshPreferredContentSize()
                }
            }
            .frame(
                idealWidth: idealWidth,
                maxWidth: .infinity,
                idealHeight: idealHeight,
                maxHeight: .infinity
            )
            .navigationTitle(presentation.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
        .frame(
            idealWidth: idealWidth,
            maxWidth: .infinity,
            idealHeight: idealHeight + 44,
            maxHeight: .infinity
        )
    }

    private final class ContainerView: UIView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    private struct Surface: UIViewRepresentable {
        let content: UIView
        let onLayout: () -> Void

        func makeUIView(context: Context) -> ContainerView {
            let wrapper = ContainerView()
            wrapper.onLayout = onLayout
            content.frame = wrapper.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            content.translatesAutoresizingMaskIntoConstraints = true
            wrapper.addSubview(content)
            return wrapper
        }

        func updateUIView(_ uiView: ContainerView, context: Context) {
            uiView.onLayout = onLayout
            if content.superview !== uiView {
                content.frame = uiView.bounds
                content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                content.translatesAutoresizingMaskIntoConstraints = true
                uiView.addSubview(content)
            }
        }

        static func dismantleUIView(_ uiView: ContainerView, coordinator: Void) {
            uiView.onLayout = nil
            uiView.subviews.forEach { $0.removeFromSuperview() }
        }
    }
}
