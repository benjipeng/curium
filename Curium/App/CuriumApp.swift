import CuriumEngineContract
import os
import SwiftUI
import UIKit

@main
@MainActor
enum CuriumApp {
    static func main() {
        #if CURIUM_LINKED_ENGINE
        let launchOutcome = CuriumFingerprintBootstrap.prepareEngineLaunch()
        switch launchOutcome {
        case .rejected:
            // Fail closed: launch a dedicated UIKit recovery delegate that
            // overrides Info.plist's Chromium SceneDelegate manifest so the
            // recovery UI renders cleanly without ever starting ChromeMain.
            UIApplicationMain(
                CommandLine.argc,
                CommandLine.unsafeArgv,
                nil,
                NSStringFromClass(CuriumRecoveryApplicationDelegate.self)
            )
            return
        case .defaultBuild39, .configured:
            let activeProfileID = CuriumFingerprintBootstrap.activeProfileID
            if CuriumRegisterShell(CuriumShellBootstrap(activeProfileID: activeProfileID)) {
                exit(ChromeMain(CommandLine.argc, CommandLine.unsafeArgv))
            }
        }
        #endif
        CuriumStandbyApp.main()
    }
}

private struct CuriumStandbyApp: App {
    var body: some Scene {
        WindowGroup {
            if case .rejected(let profileID, let reason) = CuriumFingerprintBootstrap.lastOutcome {
                CuriumProfileLaunchRecoveryView(profileID: profileID, reason: reason)
            } else {
                CuriumStandbyWindow(activeProfileID: CuriumFingerprintBootstrap.activeProfileID)
            }
        }
    }
}

@MainActor
private final class CuriumRecoveryApplicationDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = CuriumRecoverySceneDelegate.self
        return config
    }
}

@MainActor
private final class CuriumRecoverySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard case .rejected(let profileID, let reason) = CuriumFingerprintBootstrap.lastOutcome else {
            // A previous blocked launch left a persisted recovery UISceneSession.
            // Replace it with a fresh default session so ChromeMain's SceneDelegate attaches.
            let app = UIApplication.shared
            app.requestSceneSessionDestruction(session, options: nil)
            app.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(
            rootView: CuriumProfileLaunchRecoveryView(profileID: profileID, reason: reason)
        )
        window.makeKeyAndVisible()
        self.window = window
    }
}

private struct CuriumProfileLaunchRecoveryView: View {
    let profileID: String
    let reason: String

    @Environment(\.layoutDirection) private var layoutDirection
    @State private var store = CuriumFingerprintStore.shared
    @State private var statusMessage: String?
    @State private var persistFailed = false
    @State private var readyToRelaunch = false
    @State private var copiedDetails = false
    @State private var blockedProfileUsage: CuriumFingerprintProfileStorage.UsageSnapshot?
    @State private var confirmingWipe = false
    @State private var isWiping = false

    private enum RecoveryFoldLayout {
        case centered
        case sidePane(leftInset: CGFloat, rightInset: CGFloat, maxWidth: CGFloat)
        case tabletopSplit(topHeight: CGFloat, creaseHeight: CGFloat, bottomHeight: CGFloat)
    }

    private var isStoreCorrupt: Bool {
        store.loadError != nil
    }

    private var engineSupportsProfiles: Bool {
        CuriumFingerprintBootstrap.engineCapabilities().supportsLaunchFingerprintConfig
    }

    private var canOfferIsolatedWipe: Bool {
        !isStoreCorrupt
            && profileID != "default"
            && profileID != "store"
            && CuriumFingerprintValidator.isValidProfileID(profileID)
    }

    private var alternativeProfiles: [CuriumFingerprintProfile] {
        guard !isStoreCorrupt, engineSupportsProfiles else { return [] }
        let blockedLowered = profileID.lowercased()
        return store.profiles.filter {
            !$0.isPrimaryDefault
                && $0.id.lowercased() != blockedLowered
                && CuriumFingerprintValidator.validate($0).isValid
        }
    }

    var body: some View {
        GeometryReader { proxy in
            switch foldLayout(in: proxy) {
            case .centered:
                ScrollView {
                    VStack(spacing: 16) {
                        headerAndDetailsSection(maxReasonWidth: 440)
                        statusAndActionsSection
                    }
                    .frame(maxWidth: 480)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .scrollBounceBehavior(.basedOnSize)

            case .sidePane(let leftInset, let rightInset, let maxWidth):
                let isLTR = layoutDirection == .leftToRight
                ScrollView {
                    VStack(spacing: 16) {
                        headerAndDetailsSection(maxReasonWidth: maxWidth)
                        statusAndActionsSection
                    }
                    .frame(maxWidth: maxWidth)
                    .padding(.vertical, 24)
                    .padding(.leading, isLTR ? leftInset : rightInset)
                    .padding(.trailing, isLTR ? rightInset : leftInset)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .scrollBounceBehavior(.basedOnSize)

            case .tabletopSplit(let topHeight, let creaseHeight, let bottomHeight):
                VStack(spacing: 0) {
                    ScrollView {
                        headerAndDetailsSection(maxReasonWidth: 440)
                            .frame(maxWidth: 480)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.center, for: .alignment)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: topHeight)

                    Color.clear
                        .frame(height: creaseHeight)
                        .accessibilityHidden(true)

                    ScrollView {
                        statusAndActionsSection
                            .frame(maxWidth: 480)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.center, for: .alignment)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: bottomHeight)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task(id: profileID) {
            guard canOfferIsolatedWipe else {
                blockedProfileUsage = nil
                return
            }
            let targetID = profileID
            let snapshot = await Task.detached(priority: .utility) {
                CuriumFingerprintProfileStorage.measureUsage(for: targetID)
            }.value
            blockedProfileUsage = snapshot
        }
        .confirmationDialog(
            "Wipe Isolated Profile Storage?",
            isPresented: $confirmingWipe,
            titleVisibility: .visible
        ) {
            Button("Wipe Cookies, Cache & Storage", role: .destructive) {
                wipeBlockedProfileStorage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently clears isolated cookies, site data, cache, bookmarks, history, and saved tabs for profile \"\(profileID)\". Your profile settings remain in the store.")
        }
    }

    private func headerAndDetailsSection(maxReasonWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled.trianglebadge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(isStoreCorrupt ? "Profile Store Unreadable" : "Profile Launch Blocked")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(
                isStoreCorrupt
                    ? "Curium could not read fingerprint-profiles.json safely, so it stopped before loading the default profile or overwriting your saved profiles."
                    : "Profile \"\(profileID)\" could not be opened safely, so Curium stopped before loading the default profile."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Text(store.loadError ?? reason)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: maxReasonWidth, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var statusAndActionsSection: some View {
        VStack(spacing: 12) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(persistFailed ? .red : .green)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                if isStoreCorrupt {
                    Button {
                        if store.backupCorruptStoreAndReset() {
                            persistFailed = false
                            readyToRelaunch = true
                            statusMessage = "Corrupt store backed up to a .bak file and reset to Personal (Default). Relaunch Curium to continue."
                        } else {
                            persistFailed = true
                            statusMessage = store.lastPersistError ?? "Could not back up corrupt store."
                        }
                    } label: {
                        Label("Back Up Corrupt Store & Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Switch to Personal (Default) for Next Launch") {
                        if store.resetToBuild39Default() {
                            persistFailed = false
                            readyToRelaunch = true
                            statusMessage = "Switched next launch to Personal (Default). Relaunch Curium to continue."
                        } else {
                            persistFailed = true
                            statusMessage = store.lastPersistError ?? "Could not write profile store to disk."
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if !alternativeProfiles.isEmpty {
                        Menu {
                            ForEach(alternativeProfiles) { profile in
                                Button {
                                    if store.selectProfile(id: profile.id) {
                                        persistFailed = false
                                        readyToRelaunch = true
                                        statusMessage = "Switched next launch to \"\(profile.displayName)\". Relaunch Curium to continue."
                                    } else {
                                        persistFailed = true
                                        statusMessage = store.lastPersistError ?? "Could not write profile store to disk."
                                    }
                                } label: {
                                    Label(profile.displayName, systemImage: profile.resolvedSymbolName)
                                }
                            }
                        } label: {
                            Label("Switch to Another Profile for Next Launch", systemImage: "person.2.crop.square.stack")
                        }
                        .buttonStyle(.bordered)
                    }

                    if canOfferIsolatedWipe, let usage = blockedProfileUsage, usage.exists {
                        Button(role: .destructive) {
                            confirmingWipe = true
                        } label: {
                            let sizeText = ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
                            Label(
                                isWiping ? "Wiping Storage…" : "Wipe Isolated Storage (\(sizeText))",
                                systemImage: "externaldrive.badge.xmark"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWiping)
                    }
                }

                if readyToRelaunch {
                    Button {
                        CuriumProfileRelauncher.relaunchAfterFlush()
                    } label: {
                        Label(
                            CuriumProfileRelauncher.recoveryCloseButtonTitle,
                            systemImage: "xmark.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    let detailText = store.loadError ?? reason
                    UIPasteboard.general.string = "Curium Profile Launch Blocked\nProfile: \(profileID)\nReason: \(detailText)"
                    copiedDetails = true
                } label: {
                    Label(
                        copiedDetails ? "Error Details Copied" : "Copy Error Details",
                        systemImage: copiedDetails ? "checkmark.circle" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func foldLayout(in proxy: GeometryProxy) -> RecoveryFoldLayout {
        guard #available(iOS 27.1, *) else { return .centered }
        let width = proxy.size.width
        let height = proxy.size.height
        for region in proxy.reservedRegions(kind: .division, options: [.includeInactive]) where region.isActive {
            let frame = region.frame
            if frame.height > frame.width, frame.minX < width - 2, frame.maxX > 2 {
                let leftRoom = max(0, frame.minX - 24)
                let rightRoom = max(0, width - frame.maxX - 24)
                if leftRoom >= rightRoom, leftRoom >= 260 {
                    return .sidePane(
                        leftInset: 16,
                        rightInset: width - frame.minX + 16,
                        maxWidth: min(440, leftRoom - 8)
                    )
                } else if rightRoom >= 260 {
                    return .sidePane(
                        leftInset: frame.maxX + 16,
                        rightInset: 16,
                        maxWidth: min(440, rightRoom - 8)
                    )
                }
            } else if frame.width > frame.height, frame.minY < height - 2, frame.maxY > 2 {
                let topHeight = max(0, frame.minY)
                let bottomHeight = max(0, height - frame.maxY)
                if topHeight >= 180, bottomHeight >= 160 {
                    return .tabletopSplit(
                        topHeight: topHeight,
                        creaseHeight: frame.height,
                        bottomHeight: bottomHeight
                    )
                }
            }
        }
        return .centered
    }

    private func wipeBlockedProfileStorage() {
        guard !isWiping, canOfferIsolatedWipe else { return }
        isWiping = true
        let targetID = profileID
        Task.detached(priority: .userInitiated) {
            do {
                try CuriumFingerprintProfileStorage.wipeIsolatedProfile(
                    targetID,
                    isActiveInCurrentProcess: false
                )
                await MainActor.run {
                    isWiping = false
                    persistFailed = false
                    blockedProfileUsage = CuriumFingerprintProfileStorage.UsageSnapshot(
                        supportBytes: 0, cacheBytes: 0, exists: false
                    )
                    statusMessage = "Isolated storage for \"\(targetID)\" was wiped. Close and relaunch Curium to retry."
                }
            } catch {
                await MainActor.run {
                    isWiping = false
                    persistFailed = true
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct CuriumStandbyWindow: View {
    @State private var store: CuriumBrowserStore
    @Environment(\.scenePhase) private var scenePhase

    init(activeProfileID: String = "default") {
        _store = State(initialValue: CuriumBrowserStore(activeProfileID: activeProfileID))
    }

    var body: some View {
        CuriumScene(store: store)
            .task {
                CuriumDownloadsFolderManager.shared.resolveInBackgroundIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .inactive:
                    store.handleSceneWillDeactivate()
                    CuriumCheckpointRunner.run(library: store.library, reason: "StandbyInactive")
                case .background:
                    store.handleSceneDidEnterBackground()
                    CuriumCheckpointRunner.run(library: store.library, reason: "StandbyBackground")
                case .active:
                    CuriumDownloadsFolderManager.shared.resolveInBackgroundIfNeeded()
                    store.handleSceneWillEnterForeground()
                @unknown default:
                    break
                }
            }
    }
}

private final class CuriumBackgroundTask: Sendable {
    private struct State: Sendable {
        var rawIdentifier: Int = UIBackgroundTaskIdentifier.invalid.rawValue
        var ended = false
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    @MainActor
    init(name: String) {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.endFromAnyThread()
        }
        let shouldEndImmediately = lock.withLock { state -> Bool in
            if state.ended {
                return true
            }
            state.rawIdentifier = id.rawValue
            return false
        }
        if shouldEndImmediately && id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    deinit {
        endFromAnyThread()
    }

    @MainActor
    func end() {
        let rawID = takeRawIdentifier()
        guard rawID != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: rawID))
    }

    private func takeRawIdentifier() -> Int {
        lock.withLock { state in
            state.ended = true
            let current = state.rawIdentifier
            state.rawIdentifier = UIBackgroundTaskIdentifier.invalid.rawValue
            return current
        }
    }

    private func endFromAnyThread() {
        let rawID = takeRawIdentifier()
        guard rawID != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: rawID))
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: rawID))
                }
            }
        }
    }
}

@MainActor
private enum CuriumCheckpointRunner {
    static func run(library: CuriumLibrary, reason: String) {
        let taskGuard = CuriumBackgroundTask(name: "CuriumSQLiteCheckpoint-\(reason)")
        Task { @MainActor in
            await library.checkpointAsync()
            taskGuard.end()
        }
    }
}

struct CuriumScene: View {
    let store: CuriumBrowserStore

    private var fingerprintStore: CuriumFingerprintStore { CuriumFingerprintStore.shared }

    private var activeProfile: CuriumFingerprintProfile? {
        fingerprintStore.profile(id: store.activeProfileID)
    }

    private var activePalette: CuriumPalette {
        activeProfile?.resolvedPalette ?? .violet
    }

    private var activeSiteMode: CuriumSiteMode {
        activeProfile?.resolvedSiteMode ?? .adaptive
    }

    var body: some View {
        NavigationStack {
            CuriumBrowserView(store: store, palette: activePalette)
        }
        .tint(activePalette.tint)
        .environment(\.curiumPalette, activePalette)
        .onChange(of: activeSiteMode, initial: true) { _, _ in
            store.syncDefaultSiteModeForBlankTabs()
        }
    }
}

private final class CuriumShellBootstrap: NSObject, CrIOSShellBootstrapDelegate {
    private let activeProfileID: String

    init(activeProfileID: String = "default") {
        self.activeProfileID = activeProfileID
        super.init()
    }

    func makeRootViewController(
        for windowScene: UIWindowScene,
        browserHost: any CrIOSBrowserHostV1,
        extensionManager: (any CrIOSExtensionManagingV1)?
    ) -> UIViewController {
        let store = CuriumBrowserStore(
            host: browserHost,
            extensionManager: extensionManager,
            activeProfileID: activeProfileID
        )
        return CuriumSceneHostingController(windowScene: windowScene, store: store)
    }
}

@MainActor
private final class CuriumSceneHostingController: UIHostingController<CuriumScene> {
    private let store: CuriumBrowserStore
    private weak var observedScene: UIWindowScene?

    init(windowScene: UIWindowScene, store: CuriumBrowserStore) {
        self.store = store
        self.observedScene = windowScene
        super.init(rootView: CuriumScene(store: store))
        CuriumDownloadsFolderManager.shared.resolveInBackgroundIfNeeded()
        installLifecycleObservers(for: windowScene)
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("Use init(windowScene:store:).")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func installLifecycleObservers(for windowScene: UIWindowScene) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onSceneWillDeactivate),
            name: UIScene.willDeactivateNotification,
            object: windowScene
        )
        center.addObserver(
            self,
            selector: #selector(onSceneDidEnterBackground),
            name: UIScene.didEnterBackgroundNotification,
            object: windowScene
        )
        center.addObserver(
            self,
            selector: #selector(onSceneWillEnterForeground),
            name: UIScene.willEnterForegroundNotification,
            object: windowScene
        )
    }

    @objc private func onMemoryWarning(_ notification: Notification) {
        store.handleMemoryWarning()
    }

    @objc private func onSceneWillDeactivate(_ notification: Notification) {
        store.handleSceneWillDeactivate()
        CuriumCheckpointRunner.run(library: store.library, reason: "WillDeactivate")
    }

    @objc private func onSceneDidEnterBackground(_ notification: Notification) {
        store.handleSceneDidEnterBackground()
        CuriumCheckpointRunner.run(library: store.library, reason: "DidEnterBackground")
    }

    @objc private func onSceneWillEnterForeground(_ notification: Notification) {
        CuriumDownloadsFolderManager.shared.resolveInBackgroundIfNeeded()
        store.handleSceneWillEnterForeground()
    }
}
