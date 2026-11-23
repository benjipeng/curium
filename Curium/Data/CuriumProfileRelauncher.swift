import Darwin
import Foundation

/// Coordinates clean cold-switch handoff after flushing profile selection, tabs, SQLite WAL,
/// and diagnostics so reopening Curium launches into the target isolated Blink profile.
enum CuriumProfileRelauncher {
    static var isRunningInLiveContainer: Bool {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"]?.isEmpty == false
    }

    static var primaryRelaunchButtonTitle: String {
        "Save & Close to Switch"
    }

    static var shortActionButtonTitle: String {
        "Close & Switch"
    }

    static var primaryApplyButtonTitle: String {
        "Save & Close to Apply"
    }

    static var shortApplyButtonTitle: String {
        "Close & Apply"
    }

    static var recoveryCloseButtonTitle: String {
        "Close Curium"
    }

    static func switchHandoffDescription(
        activeProfileName: String,
        targetProfileName: String
    ) -> String {
        if isRunningInLiveContainer {
            return "Curium will save open tabs and library data for \(activeProfileName), then close cleanly. Reopen Curium from LiveContainer to launch straight into \(targetProfileName) in a fresh isolated Blink process."
        }
        return "Curium will save open tabs and library data for \(activeProfileName), then close cleanly. Reopen Curium to launch straight into \(targetProfileName) in a fresh isolated Blink process."
    }

    /// Reads LiveContainer's dynamic URL scheme (`livecontainer`, `livecontainer2`, etc.)
    /// from `+[NSUserDefaults lcAppUrlScheme]`, falling back to `"livecontainer"`.
    static func liveContainerAppURLScheme() -> String {
        let sel = NSSelectorFromString("lcAppUrlScheme")
        if (UserDefaults.self as AnyObject).responds(to: sel),
           let unmanaged = (UserDefaults.self as AnyObject).perform(sel),
           let scheme = unmanaged.takeUnretainedValue() as? String {
            let trimmed = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "livecontainer"
    }

    static func liveContainerBundleName(bundlePath: String = Bundle.main.bundlePath) -> String {
        let last = URL(fileURLWithPath: bundlePath).lastPathComponent
        if last.hasSuffix(".app"), last.count > 4 {
            return last
        }
        return "com.appautomaton.curium.app"
    }

    static func liveContainerRelaunchURL(
        bundlePath: String = Bundle.main.bundlePath,
        scheme: String? = nil
    ) -> URL? {
        let resolvedScheme = (scheme ?? liveContainerAppURLScheme())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedScheme.isEmpty else { return nil }
        let bundleName = liveContainerBundleName(bundlePath: bundlePath)
        var components = URLComponents()
        components.scheme = resolvedScheme
        components.host = "livecontainer-launch"
        components.queryItems = [
            URLQueryItem(name: "bundle-name", value: bundleName),
        ]
        return components.url
    }

    static func liveContainerMenuURL(scheme: String? = nil) -> URL? {
        let resolvedScheme = (scheme ?? liveContainerAppURLScheme())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedScheme.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = resolvedScheme
        components.host = "livecontainer-launch"
        components.queryItems = [
            URLQueryItem(name: "bundle-name", value: "ui"),
        ]
        return components.url
    }

    @MainActor
    static func relaunchAfterFlush(customHandler: (@MainActor () -> Void)? = nil) {
        if let customHandler {
            customHandler()
            return
        }
        // Always close cleanly after flushing rather than self-opening
        // `livecontainer://livecontainer-launch?bundle-name=<self>`, which races
        // against LiveContainer's running-guest focus/confirmation prompt and exit(0).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            exit(0)
        }
    }
}
