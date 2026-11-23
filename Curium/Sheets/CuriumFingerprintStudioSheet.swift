import SwiftUI

/// Compatibility forwarding wrapper delegating to `CuriumProfileSwitcherSheet`.
struct CuriumFingerprintStudioSheet: View {
    var browserStore: CuriumBrowserStore?
    var store: CuriumFingerprintStore
    var onSelectionChanged: (() -> Void)?

    init(
        browserStore: CuriumBrowserStore? = nil,
        store: CuriumFingerprintStore = .shared,
        onSelectionChanged: (() -> Void)? = nil
    ) {
        self.browserStore = browserStore
        self.store = store
        self.onSelectionChanged = onSelectionChanged
    }

    var body: some View {
        CuriumProfileSwitcherSheet(
            browserStore: browserStore,
            fingerprintStore: store,
            onSelectionChanged: onSelectionChanged
        )
    }
}
