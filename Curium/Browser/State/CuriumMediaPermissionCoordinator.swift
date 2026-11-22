import AVFoundation
import CuriumEngineContract
import Foundation

/// Normalized site media permissions bridged to and from `CrIOSMediaPermissionTypes`.
struct CuriumMediaPermissions: OptionSet, Hashable, Sendable {
    let rawValue: UInt

    static let camera = CuriumMediaPermissions(rawValue: 1 << 0)
    static let microphone = CuriumMediaPermissions(rawValue: 1 << 1)

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    init(engineTypes: CrIOSMediaPermissionTypes) {
        var mapped: CuriumMediaPermissions = []
        if engineTypes.contains(.camera) { mapped.insert(.camera) }
        if engineTypes.contains(.microphone) { mapped.insert(.microphone) }
        self = mapped
    }

    var engineTypes: CrIOSMediaPermissionTypes {
        var mapped: CrIOSMediaPermissionTypes = []
        if contains(.camera) { mapped.insert(.camera) }
        if contains(.microphone) { mapped.insert(.microphone) }
        return mapped
    }

    var devicePhrase: String {
        switch (contains(.camera), contains(.microphone)) {
        case (true, true): "camera and microphone"
        case (true, false): "camera"
        case (false, true): "microphone"
        case (false, false): "media devices"
        }
    }
}

/// Validated HTTP(S) origin with canonical comparison key and user-facing site label.
struct CuriumMediaPermissionOrigin: Equatable, Sendable {
    let key: String
    let displaySite: String

    static func parse(_ url: URL) -> CuriumMediaPermissionOrigin? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme?.lowercased(),
              rawScheme == "https" || rawScheme == "http",
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty,
              !rawHost.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return nil
        }

        let defaultPort = rawScheme == "https" ? 443 : 80
        if let port = components.port, !(1...65535).contains(port) {
            return nil
        }
        let effectivePort = components.port ?? defaultPort
        let formattedHost = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let key = "\(rawScheme)://\(formattedHost):\(effectivePort)"

        let hostAndPort = effectivePort == defaultPort
            ? formattedHost
            : "\(formattedHost):\(effectivePort)"
        let displaySite = rawScheme == "https"
            ? hostAndPort
            : "\(rawScheme)://\(hostAndPort)"
        return CuriumMediaPermissionOrigin(key: key, displaySite: displaySite)
    }

    static func key(for url: URL?) -> String? {
        guard let url else { return nil }
        return parse(url)?.key
    }
}

/// Snapshot of the currently displayed site media permission prompt.
struct CuriumMediaPermissionPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let tabID: String
    let originKey: String
    let displaySite: String
    let permissions: CuriumMediaPermissions

    var title: String {
        "Allow \(displaySite) to use your \(permissions.devicePhrase)?"
    }
}

enum CuriumCaptureMediaKind: Equatable, Sendable {
    case video
    case audio

    var avMediaType: AVMediaType {
        switch self {
        case .video: .video
        case .audio: .audio
        }
    }
}

/// Serializes, coalesces, and lifecycle-guards camera and microphone permission prompts
/// on top of Build 40's `CrIOSBrowserHostDelegateV1.requestMediaPermissions` callback.
///
/// Design invariants:
/// - Site approval always precedes iOS `AVCaptureDevice` authorization.
/// - Concurrent identical/subset requests coalesce onto the active prompt so the user
///   never sees duplicate alerts, while distinct requests queue cleanly instead of
///   failing transiently and poisoning the engine's page-scoped decision cache.
/// - Navigation commits, origin changes, tab switches, and tab closures invalidate
///   active and queued prompts fail-closed and dismiss the presented alert automatically.
@MainActor
final class CuriumMediaPermissionCoordinator {
    typealias ValidityCheck = @MainActor (_ tabID: String, _ originKey: String) -> Bool
    typealias CaptureAuthorizer = @MainActor (_ kind: CuriumCaptureMediaKind) async -> Bool
    typealias PromptChangeHandler = @MainActor (_ prompt: CuriumMediaPermissionPrompt?) -> Void

    static let maxQueuedRequests = 8

    @MainActor
    private final class Waiter {
        let permissions: CuriumMediaPermissions
        private var completion: (@MainActor (CuriumMediaPermissions) -> Void)?

        init(
            permissions: CuriumMediaPermissions,
            completion: @escaping @MainActor (CuriumMediaPermissions) -> Void
        ) {
            self.permissions = permissions
            self.completion = completion
        }

        func finish(with granted: CuriumMediaPermissions) {
            guard let callback = completion else { return }
            completion = nil
            callback(granted.intersection(permissions))
        }

        isolated deinit {
            // Fail closed if a waiter is ever dropped unexpectedly.
            finish(with: [])
        }
    }

    @MainActor
    private final class Entry {
        let prompt: CuriumMediaPermissionPrompt
        var waiters: [Waiter]
        var invalidated = false

        init(prompt: CuriumMediaPermissionPrompt, waiter: Waiter) {
            self.prompt = prompt
            self.waiters = [waiter]
        }

        func finishAll(with granted: CuriumMediaPermissions) {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.finish(with: granted)
            }
        }
    }

    private enum Phase {
        case idle
        case presentingAlert(Entry)
        case awaitingSystemAuthorization(Entry, Task<Void, Never>)
    }

    private let isRequestCurrent: ValidityCheck
    private let authorizeCapture: CaptureAuthorizer
    private let onPromptChange: PromptChangeHandler

    private var phase: Phase = .idle
    private var queue: [Entry] = []
    private var presentationBlocked = false

    private(set) var activePrompt: CuriumMediaPermissionPrompt? {
        didSet {
            if oldValue != activePrompt {
                onPromptChange(activePrompt)
            }
        }
    }

    init(
        isRequestCurrent: @escaping ValidityCheck,
        authorizeCapture: @escaping CaptureAuthorizer = CuriumMediaPermissionCoordinator.liveCaptureAuthorizer,
        onPromptChange: @escaping PromptChangeHandler = { _ in }
    ) {
        self.isRequestCurrent = isRequestCurrent
        self.authorizeCapture = authorizeCapture
        self.onPromptChange = onPromptChange
    }

    static func liveCaptureAuthorizer(_ kind: CuriumCaptureMediaKind) async -> Bool {
        let mediaType = kind.avMediaType
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        @unknown default:
            return false
        }
    }

    func enqueue(
        permissions: CuriumMediaPermissions,
        originURL: URL,
        tabID: String,
        completion: @escaping @MainActor (CuriumMediaPermissions) -> Void
    ) {
        let requested = permissions.intersection([.camera, .microphone])
        guard !requested.isEmpty,
              let origin = CuriumMediaPermissionOrigin.parse(originURL),
              isRequestCurrent(tabID, origin.key) else {
            completion([])
            return
        }

        let waiter = Waiter(permissions: requested, completion: completion)

        // Coalesce identical or subset requests onto an active prompt for the same tab and origin.
        if let activeEntry = currentEntry,
           !activeEntry.invalidated,
           activeEntry.prompt.tabID == tabID,
           activeEntry.prompt.originKey == origin.key,
           activeEntry.prompt.permissions.isSuperset(of: requested) {
            activeEntry.waiters.append(waiter)
            return
        }

        // Coalesce onto an already-queued superset request for the same tab and origin.
        if let queuedEntry = queue.first(where: {
            !$0.invalidated
                && $0.prompt.tabID == tabID
                && $0.prompt.originKey == origin.key
                && $0.prompt.permissions.isSuperset(of: requested)
        }) {
            queuedEntry.waiters.append(waiter)
            return
        }

        guard queue.count < Self.maxQueuedRequests else {
            waiter.finish(with: [])
            return
        }

        let prompt = CuriumMediaPermissionPrompt(
            id: UUID(),
            tabID: tabID,
            originKey: origin.key,
            displaySite: origin.displaySite,
            permissions: requested
        )
        queue.append(Entry(prompt: prompt, waiter: waiter))
        drainQueue()
    }

    func setPresentationBlocked(_ blocked: Bool) {
        guard presentationBlocked != blocked else { return }
        presentationBlocked = blocked
        if !blocked {
            drainQueue()
        }
    }

    func respondToActivePrompt(allowed: Bool) {
        guard case .presentingAlert(let entry) = phase else { return }

        if !allowed || entry.invalidated || !isRequestCurrent(entry.prompt.tabID, entry.prompt.originKey) {
            phase = .idle
            activePrompt = nil
            entry.finishAll(with: [])
            drainQueue()
            return
        }

        // Hide the site alert immediately before requesting iOS authorization.
        activePrompt = nil
        let promptID = entry.prompt.id
        let task = Task { @MainActor [weak self] in
            guard let self else {
                entry.finishAll(with: [])
                return
            }
            let granted = await self.performSystemAuthorization(for: entry)
            self.finishSystemAuthorization(promptID: promptID, entry: entry, granted: granted)
        }
        phase = .awaitingSystemAuthorization(entry, task)
    }

    func dismissActivePromptWithoutAction() {
        guard case .presentingAlert = phase else { return }
        respondToActivePrompt(allowed: false)
    }

    func invalidate(tabID: String) {
        var remaining: [Entry] = []
        remaining.reserveCapacity(queue.count)
        for entry in queue {
            if entry.prompt.tabID == tabID {
                entry.invalidated = true
                entry.finishAll(with: [])
            } else {
                remaining.append(entry)
            }
        }
        queue = remaining

        switch phase {
        case .idle:
            break
        case .presentingAlert(let entry) where entry.prompt.tabID == tabID:
            entry.invalidated = true
            phase = .idle
            activePrompt = nil
            entry.finishAll(with: [])
            drainQueue()
        case .awaitingSystemAuthorization(let entry, let task) where entry.prompt.tabID == tabID:
            entry.invalidated = true
            task.cancel()
            phase = .idle
            activePrompt = nil
            entry.finishAll(with: [])
            drainQueue()
        default:
            break
        }
    }

    func invalidateIfOriginChanged(tabID: String, currentURL: URL?) {
        let currentKey = CuriumMediaPermissionOrigin.key(for: currentURL)
        let matchesActive = currentEntry.map {
            $0.prompt.tabID == tabID && $0.prompt.originKey != currentKey
        } ?? false
        let matchesQueued = queue.contains {
            $0.prompt.tabID == tabID && $0.prompt.originKey != currentKey
        }
        if matchesActive || matchesQueued {
            invalidate(tabID: tabID)
        }
    }

    func cancelAll() {
        let queued = queue
        queue.removeAll()
        for entry in queued {
            entry.invalidated = true
            entry.finishAll(with: [])
        }
        switch phase {
        case .idle:
            break
        case .presentingAlert(let entry):
            entry.invalidated = true
            phase = .idle
            activePrompt = nil
            entry.finishAll(with: [])
        case .awaitingSystemAuthorization(let entry, let task):
            entry.invalidated = true
            task.cancel()
            phase = .idle
            activePrompt = nil
            entry.finishAll(with: [])
        }
    }

    private var currentEntry: Entry? {
        switch phase {
        case .idle: nil
        case .presentingAlert(let entry), .awaitingSystemAuthorization(let entry, _): entry
        }
    }

    private func drainQueue() {
        guard case .idle = phase, !presentationBlocked else { return }

        while !queue.isEmpty {
            let next = queue.removeFirst()
            if next.invalidated || !isRequestCurrent(next.prompt.tabID, next.prompt.originKey) {
                next.finishAll(with: [])
                continue
            }
            phase = .presentingAlert(next)
            activePrompt = next.prompt
            return
        }
    }

    private func performSystemAuthorization(for entry: Entry) async -> CuriumMediaPermissions {
        let requested = entry.prompt.permissions
        if requested.contains(.camera) {
            let videoGranted = await authorizeCapture(.video)
            guard videoGranted,
                  !Task.isCancelled,
                  !entry.invalidated,
                  isRequestCurrent(entry.prompt.tabID, entry.prompt.originKey) else {
                return []
            }
        }
        if requested.contains(.microphone) {
            let audioGranted = await authorizeCapture(.audio)
            guard audioGranted,
                  !Task.isCancelled,
                  !entry.invalidated,
                  isRequestCurrent(entry.prompt.tabID, entry.prompt.originKey) else {
                return []
            }
        }
        return requested
    }

    private func finishSystemAuthorization(
        promptID: UUID,
        entry: Entry,
        granted: CuriumMediaPermissions
    ) {
        guard case .awaitingSystemAuthorization(let activeEntry, _) = phase,
              activeEntry.prompt.id == promptID else {
            entry.finishAll(with: [])
            return
        }
        phase = .idle
        activePrompt = nil
        let effective: CuriumMediaPermissions =
            (!entry.invalidated && isRequestCurrent(entry.prompt.tabID, entry.prompt.originKey))
            ? granted
            : []
        entry.finishAll(with: effective)
        drainQueue()
    }
}
