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
