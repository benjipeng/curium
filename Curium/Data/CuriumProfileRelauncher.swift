import Darwin
import Foundation
import UIKit

/// Coordinates cold relaunch handoff after flushing profile selection, tabs, SQLite WAL,
/// and diagnostics — supporting LiveContainer 1/2/3+ URL-scheme relaunch and standalone exit.
enum CuriumProfileRelauncher {
    static var isRunningInLiveContainer: Bool {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"]?.isEmpty == false
    }

    static var primaryRelaunchButtonTitle: String {
        isRunningInLiveContainer ? "Save & Relaunch" : "Save & Close to Switch"
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

    @MainActor
    static func relaunchAfterFlush(customHandler: (@MainActor () -> Void)? = nil) {
        if let customHandler {
            customHandler()
            return
        }
        if isRunningInLiveContainer, let url = liveContainerRelaunchURL() {
            UIApplication.shared.open(url, options: [:]) { success in
                if !success {
                    exit(0)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                exit(0)
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            exit(0)
        }
    }
}
