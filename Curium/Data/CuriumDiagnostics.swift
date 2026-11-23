import Darwin
import Foundation
import OSLog
import UIKit
import os

/// Lightweight, lock-protected rolling diagnostics log that writes plain text to the
/// resolved library directory so LiveContainer sessions remain debuggable even when
/// `os_log` renders as `<compose failure>`.
final class CuriumDiagnostics: @unchecked Sendable {
    struct HookStatus: Identifiable, Hashable, Sendable {
        let name: String
        let status: String
        let detail: String

        var id: String { name }
        var isActive: Bool { status == "active" }
        var isFailed: Bool { status == "failed" }
    }

    static let shared = CuriumDiagnostics()
    static let logFileName = "curium-diagnostics.log"
    static let rotatedFileName = "curium-diagnostics.prev.log"

    private struct State {
        var ring: [String] = []
        var pendingLines: [String] = []
        var startupRecorded = false
        var flushScheduled = false
        var directoryCreated = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.appautomaton.curium.diagnostics", qos: .utility)
    private let directory: URL?
    private let maxFileBytes: Int
    private let maxRingLines: Int
    private var notificationTokens: [any NSObjectProtocol] = []

    var logFileURL: URL? {
        directory?.appending(path: Self.logFileName, directoryHint: .notDirectory)
    }

    init(
        directory: URL? = CuriumDiagnostics.defaultDirectory(),
        maxFileBytes: Int = 128 * 1024,
        maxRingLines: Int = 200,
        observeSystemNotifications: Bool = true
    ) {
        self.directory = directory
        self.maxFileBytes = max(1024, maxFileBytes)
        self.maxRingLines = max(1, maxRingLines)

        if observeSystemNotifications {
            let center = NotificationCenter.default
            notificationTokens.append(
                center.addObserver(
                    forName: UIApplication.didReceiveMemoryWarningNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    let avail = ByteCountFormatter.string(
                        fromByteCount: Int64(CuriumAvailableMemoryBytes()),
                        countStyle: .memory
                    )
                    self?.record("memory", "didReceiveMemoryWarning avail=\(avail)", scheduleFlush: false)
                    self?.flushAsync()
                }
            )
            notificationTokens.append(
                center.addObserver(
                    forName: UIScene.didEnterBackgroundNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    let avail = ByteCountFormatter.string(
                        fromByteCount: Int64(CuriumAvailableMemoryBytes()),
                        countStyle: .memory
                    )
                    self?.record("lifecycle", "didEnterBackground avail=\(avail)", scheduleFlush: false)
                    self?.flushAsync()
                }
            )
        }
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    static func defaultDirectory() -> URL? {
        try? CuriumLibraryLocation.resolve().database.deletingLastPathComponent()
    }

    func recordStartupIfNeeded(scheduleFlush: Bool = true) {
        let shouldRecord = state.withLock { state -> Bool in
            guard !state.startupRecorded else { return false }
            state.startupRecorded = true
            return true
        }
        guard shouldRecord else { return }

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let isLiveContainer = ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil
        let envName = isLiveContainer ? "LiveContainer" : "Standalone/Sim"
        let jit = Self.jitModeLabel(CuriumActiveV8JitMode())
        let avail = ByteCountFormatter.string(
            fromByteCount: Int64(CuriumAvailableMemoryBytes()),
            countStyle: .memory
        )

        appendLine(category: "boot", message: "Curium \(version) (\(build)) env=\(envName) v8=\(jit) avail=\(avail)")
        for hook in hookStatuses() {
            let suffix = hook.detail.isEmpty ? "" : " (\(hook.detail))"
            appendLine(category: "hooks", message: "\(hook.name): \(hook.status)\(suffix)")
        }
        if scheduleFlush {
            scheduleFlushIfNeeded()
        }
    }

    func record(_ category: String, _ message: String, scheduleFlush: Bool = true) {
        recordStartupIfNeeded(scheduleFlush: scheduleFlush)
        appendLine(category: category, message: message)
        if scheduleFlush {
            scheduleFlushIfNeeded()
        }
    }

    func currentLines() -> [String] {
        recordStartupIfNeeded()
        return state.withLock { $0.ring }
    }

    func hookStatuses() -> [HookStatus] {
        CuriumRuntimeHookStatuses().map { raw in
            HookStatus(
                name: raw["name"] ?? "unknown",
                status: raw["status"] ?? "unknown",
                detail: raw["detail"] ?? ""
            )
        }
    }

    static func summarizeHooks(_ statuses: [HookStatus]) -> (summary: String, hasFailure: Bool) {
        let active = statuses.filter(\.isActive).count
        let failed = statuses.filter(\.isFailed).count
        let skipped = statuses.count - active - failed
        if failed > 0 {
            return ("\(failed) failed · \(active)/\(statuses.count) active", true)
        }
        if skipped > 0 {
            return ("\(active) active · \(skipped) skipped", false)
        }
        return ("\(active)/\(statuses.count) active", false)
    }

    func hooksSummary() -> String {
        Self.summarizeHooks(hookStatuses()).summary
    }

    func formattedReport(
        hooks: [HookStatus]? = nil,
        lines: [String]? = nil,
        fingerprintStatus: CuriumEngineFingerprintStatus? = nil,
        fingerprintCapabilities: CuriumEngineFingerprintCapabilities? = nil,
        nextLaunchProfile: String? = nil
    ) -> String {
        recordStartupIfNeeded()
        let resolvedHooks = hooks ?? hookStatuses()
        let resolvedLines = lines ?? currentLines()
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let envName = ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil ? "LiveContainer" : "Standalone/Sim"
        let jit = Self.jitModeLabel(CuriumActiveV8JitMode())
        let avail = ByteCountFormatter.string(
            fromByteCount: Int64(CuriumAvailableMemoryBytes()),
            countStyle: .memory
        )

        var out: [String] = [
            "Curium \(version) (\(build)) Diagnostics",
            "Environment: \(envName)",
            "V8 Runtime: \(jit)",
            "Available Memory: \(avail)",
            "Engine Hooks: \(Self.summarizeHooks(resolvedHooks).summary)",
        ]
        if let status = fingerprintStatus {
            out.append(
                "Fingerprint Contract: v\(status.contractVersion) state=\(status.state) "
                    + "profile=\(status.appliedProfileId) rev=\(status.appliedConfigRevision) "
                    + "dirOpened=\(status.profileDirectoryOpened) slot=\(status.defaultSlot) "
                    + "proxy=\(status.proxyMode) hw=\(status.hardwareOverridesActive ? "override" : "native-apple")"
            )
            if let reason = status.rejectionReason, !reason.isEmpty {
                out.append("Fingerprint Rejection: \(reason)")
            }
        }
        if let nextLaunchProfile {
            out.append("Next Launch Profile: \(nextLaunchProfile)")
        }
        if let caps = fingerprintCapabilities, caps.supportsLaunchFingerprintConfig {
            let enabled = caps.features.filter(\.value).map(\.key).sorted().joined(separator: ",")
            out.append("Fingerprint Capabilities: v\(caps.contractVersion) maxBytes=\(caps.maxConfigBytes) features=[\(enabled)]")
        }
        out.append("")
        out.append(contentsOf: resolvedHooks.map { hook in
            hook.detail.isEmpty
                ? "  [\(hook.status)] \(hook.name)"
                : "  [\(hook.status)] \(hook.name) — \(hook.detail)"
        })
        out.append("")
        out.append("Rolling Log (\(resolvedLines.count) lines):")
        out.append(contentsOf: resolvedLines)
        return out.joined(separator: "\n")
    }

    func flushAsync() {
        guard directory != nil else { return }
        queue.async { [weak self] in
            self?.drainPendingToDisk()
        }
    }

    func flushSync() {
        guard directory != nil else { return }
        queue.sync {
            drainPendingToDisk()
        }
    }

    // MARK: - Private

    private func appendLine(category: String, message: String) {
        let timestamp = Self.formatTimestamp()
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(timestamp) [\(category)] \(sanitized)"
        state.withLock { state in
            state.ring.append(line)
            if state.ring.count > maxRingLines {
                state.ring.removeFirst(state.ring.count - maxRingLines)
            }
            if directory != nil {
                state.pendingLines.append(line)
            }
        }
    }

    private func scheduleFlushIfNeeded() {
        guard directory != nil else { return }
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.flushScheduled, !state.pendingLines.isEmpty else { return false }
            state.flushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.drainPendingToDisk()
        }
    }

    private func drainPendingToDisk() {
        let (batch, needsDir): ([String], Bool) = state.withLock { state in
            state.flushScheduled = false
            let lines = state.pendingLines
            state.pendingLines.removeAll(keepingCapacity: true)
            let needsDir = !state.directoryCreated
            return (lines, needsDir)
        }
        guard !batch.isEmpty, let directory, let fileURL = logFileURL else { return }

        let fm = FileManager.default
        do {
            if needsDir {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                state.withLock { $0.directoryCreated = true }
            }
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = (attrs[.size] as? NSNumber)?.intValue,
               size >= maxFileBytes {
                let prevURL = directory.appending(path: Self.rotatedFileName, directoryHint: .notDirectory)
                try? fm.removeItem(at: prevURL)
                try? fm.moveItem(at: fileURL, to: prevURL)
            }

            let payload = Data((batch.joined(separator: "\n") + "\n").utf8)
            if fm.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: fileURL, options: .atomic)
            }
        } catch {
            state.withLock { $0.directoryCreated = false }
            Self.log.error("diagnostics flush failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func formatTimestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var sec = tv.tv_sec
        var tm = tm()
        gmtime_r(&sec, &tm)
        let ms = Int(tv.tv_usec / 1000)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1, Int(tm.tm_mday),
            Int(tm.tm_hour), Int(tm.tm_min), Int(tm.tm_sec), ms
        )
    }

    static func jitModeLabel(_ mode: Int) -> String {
        switch mode {
        case 1: return "JIT · BrowserEngineCore"
        case 2: return "JIT · Native MAP_JIT"
        case 3: return "JIT · TXM Split-W^X"
        default: return "Jitless · DrumBrake Wasm"
        }
    }

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "diagnostics")
}
