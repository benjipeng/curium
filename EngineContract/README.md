# Curium Engine Contract

This Clang module is the Objective-C boundary between Curium
(`com.appautomaton.curium`) and its embedded Blink engine. Add this directory to
the module search path and use `import CuriumEngineContract` in Swift or
`@import CuriumEngineContract;` in Objective-C. In Objective-C++, enable
`-fcxx-modules` for `@import`, or include `CuriumEngineContract.h` directly.
The module contains declarations; `chrome_framework` supplies the implementations.

On the main thread, register the shell bootstrap delegate before calling
`ChromeMain`. The bootstrap class retains the registration until replacement or
explicit clearing. The engine calls the delegate for each scene that needs a
root controller, supplying its browser host and, when available, an extension
manager. In standalone previews where the framework may not export
`CrIOSEngineBootstrap`, resolve it with `NSClassFromString("CrIOSEngineBootstrap")`
and dispatch dynamically only if present. A direct class reference needs the
framework export, an appropriate weak link, or a preview stub.

The engine owns browser state and creates the views exposed by tab and popup
hosts. The shell owns its root controller, attaches and detaches those views,
and retains the browser host's weak delegate for as long as it needs updates.
Treat the tab list as a snapshot and re-read it on a list update. A tab's string
ID identifies it in the browser host; only its assigned numeric extension tab
ID belongs in per-tab extension calls. After a tab closes, discard its tab
reference and view.

Call the contract and deliver UI delegate callbacks, completions, and observer
notifications on the main thread. New UI declarations and blocks import with
Swift main actor isolation. The legacy extension declarations preserve their
existing Swift import signatures; call them on the main actor too. Completions
for a single request must be called once, including when an accepted request is
cancelled.

The shell and Blink run in one process and share the engine's regular browsing
context. V1 does not expose an off-the-record (Incognito) context. The tab's
`webView` is the live engine view. When using the optional compositor controls
on a tab, give `webView` its full viewport, leave `scrollView.contentInset.top`
at zero, and set `topControlsHeight` to the full address bar band in points.
Keep that height fixed while scrolling. Observe `topControlsShownRatio` via
KVO on the main thread to morph the shell's chrome; the engine moves the page.
A height of zero disables the band. These selectors are additive to V1. In
Swift, conditionally cast the tab to `CrIOSTabBrowserControlsV1` to read and
write the properties. Objective-C callers on `CrIOSTabHostingV1` can probe
the two getters and the height setter. For an older engine, the tab's
`scrollView.contentInset` remains available for static chrome insets.

Record history from the optional navigation-commit callback rather than from
tab updates, which are coalesced. It reports each main-frame commit once, after
it happens, and excludes error pages. Same-document commits cover fragment and
History API changes; `isReload` marks reloads, including script reloads.

Probe each optional extension selector before calling it. Use the module or
the legacy helper header as the declaration source in a given translation unit.
For new extension queries with an error out parameter, a nil return indicates
failure; use an empty collection or a zero count for a successful empty result.

| Result | Values |
| --- | --- |
| Action presentation | Immutable dictionary. `isEnabled` and `hasPopup` are boolean `NSNumber` values. Optional keys: `title` and `badgeText` (`NSString`), `icon` (`UIImage`), and `badgeBackgroundColor` (`UIColor`). An absent or empty badge text means no badge. |
| DNR block count | `NSNumber` holding a nonnegative count for the extension and tab. |
| Commands | Array of string dictionaries with `name`, `description`, and `shortcut`. An empty shortcut means no binding. Pass the name to the command dispatcher. |

Retain an action observation token to receive updates; release it on the main
thread to end observation. A nil ID in a notification means re-read all
snapshots. The shell retains a popup while it is presented. When dismissing it,
including in response to `onRequestClose`, clear the handler, detach the view,
and call `close`.

### Launch Fingerprint & Profile Bootstrap (Additive to V1)

Probe `CrIOSEngineBootstrap` with `respondsToSelector:` for
`fingerprintCapabilities`, `configureLaunchFingerprintConfigJSON:error:`, and
`activeFingerprintStatus` before calling `ChromeMain`. Passing `nil` or empty
bytes preserves Build 39 (`0105`) default behavior. Passing bounded UTF-8 JSON
(`schemaVersion: 1..3`, <= 64 KiB) validates all fields, binds and locks the
selected isolated profile root under `<Application Support>/ChromiumProfiles/<profileId>`
(or `<Application Support>/Chromium` for `"default"`), and freezes the launch
configuration once before threads start. Explicit invalid or unavailable
profiles fail closed and return `NO` with a `CrIOSFingerprintErrorDomain` error
rather than silently opening the default profile. Query `activeFingerprintStatus`
after startup for the engine's authoritative `appliedProfileId`,
`profileDirectoryOpened`, `appliedConfigRevision`, `state`, and `hardwareOverridesActive`.

#### Launch Schema v3 Additions (Build 43+, Backward-Compatible with v1–v2)

Negotiate `schemaVersion = min(3, max(1, contractVersion))` from
`fingerprintCapabilities` before encoding launch JSON so older engines never
receive unknown keys:

- **`ScreenOverrideConfig` (`mobile.screen` / `desktop.screen`):** Adds three
  optional fields — `availTop` (integer `[0, 256]`), `availLeft` (integer
  `[0, 512]`), and `devicePixelRatio` (finite number `[1.0, 4.0]`, applied only
  to web-exposed `window.devicePixelRatio` and CSS media queries while keeping
  native UIKit scale and touch geometry untouched).
- **Top-level `personaSeed`:** Optional `16..64` ASCII hex string supplying a
  deterministic per-profile seed for non-farbled surfaces (e.g. native desktop
  `SpeechSynthesis` voice catalogs) even when `fingerprintSeed` is omitted.
- **Additive `v3` capabilities:** `contractVersion: 3`,
  `supportedSchemaVersions: [1, 2, 3]`, `runtimePolicyVersion: 1`,
  `maxRuntimePolicyBytes: 16384`, `activationScopes` (`farbling`, `webrtcPolicy`,
  `doNotTrack`, `globalPrivacyControl`, `speechVoiceHiding` = `"runtime_hot"`),
  and `features` (`hotRuntimePrivacyPolicy`, `stealthEdgeCanvasFarbling`,
  `nativeDesktopParityV1`, `coherentWebDPR`, `gcrwebSuppressedAtSource`,
  `nativeKeyboardLayoutMap`, `nativeSpeechSynthesisVoices`,
  `nativeWindowChromeSurface`, `profileCachePurgeHook`).

#### Hot-Mutable Runtime Privacy Policy (Build 43+, `policySchemaVersion: 1`)

Probe `CrIOSEngineBootstrap` with `respondsToSelector:` for
`applyRuntimePolicyJSON:error:` and `activeRuntimePolicyStatus` (and verify
`fingerprintCapabilities.features.hotRuntimePrivacyPolicy == YES`) to hot-toggle
the six runtime-mutable privacy controls across live tabs without restarting
the process:

- **Payload (`<= 16384` bytes, strict allowlist):**
  - `policySchemaVersion` (required integer `1`)
  - `policyRevision` (optional uint64 `<= 9007199254740991`)
  - `fingerprintSeed` (optional `null` or 64-character ASCII hex string)
  - `farbling` (optional `null` or `{canvas, audio, webgl, textMetrics}` booleans)
  - `webrtcIpHandlingPolicy` (optional string: `default`,
    `default_public_and_private_interfaces`, `default_public_interface_only`,
    or `disable_non_proxied_udp`)
  - `enableDoNotTrack` (optional boolean)
  - `enableGlobalPrivacyControl` (optional boolean)
  - `hideSpeechVoices` (optional `null` or boolean; `null` preserves per-slot `"Auto"` platform behavior)
- **Status (`activeRuntimePolicyStatus`):** Returns `runtimePolicyVersion`,
  `appliedPolicyRevision`, `farblingActive`, `farbling`,
  `webrtcIpHandlingPolicy`, `enableDoNotTrack`, `enableGlobalPrivacyControl`,
  and `hideSpeechVoices`. On Build 43+, `GlobalPrivacyControlApi` is toggled
  dynamically by the runtime policy rather than via a launch command-line flag.

#### Build 44 Additions (`contractVersion: 4`, Backward-Compatible with v1–v3)

All Build 44 selectors and properties are strictly additive and `@optional` (or
probed via `respondsToSelector:` / `NSClassFromString`):

- **Zero-Restart Cross-Profile Hot-Swap (`CuriumEngineMain.h`):**
  - `fingerprintCapabilities` advertises `contractVersion: 4`,
    `supportedSchemaVersions: [1, 2, 3, 4]`, `activationScopes.profileHotSwap = "runtime_hot"`,
    and `features.zeroRestartProfileHotSwap = YES` (`jitMode` remains `"launch"`).
  - `+switchToProfileWithConfigJSON:beforeProfileCreate:completion:` atomically
    quiesces outgoing tabs/fetches/extensions, detaches the single-process
    `RenderProcessHost`, tears down the outgoing `ProfileIOS`, purges renderer/V8/font
    caches, invokes `beforeProfileCreate` on `@MainActor` for CoreText `.process` font
    swap, boots the target `ProfileIOS` and rebinds the renderer before services/extensions
    start, and delivers fresh `browserHost` + `extensionManager`.
  - Additive `CrIOSFingerprintErrorCode`: `HotSwapUnsupported = 9`,
    `HotSwapInProgress = 10`, `TeardownIncomplete = 11`.
- **Chromium-Native Streaming Fetch & Download Metadata (`CrIOSNetworkFetchV1.h`, `CrIOSBrowserHostV1.h`):**
  - `@optional` `CrIOSDownloadTaskV1` properties: `finalURL`, `acceptRanges`,
    `eTag`, `lastModified`, `contentDisposition` (enabling zero-probe multi-lane
    upgrade without burning single-use tokens).
  - `@optional` `CrIOSBrowserHostV1` `-startFetchRequest:delegate:callbackQueue:`
    exposes an off-`@MainActor` `SharedURLLoaderFactory` + `mojo::SimpleWatcher`
    credit-window streaming pipe (BoringSSL TLS/HTTP2/HTTP3, `CookieMonster` + CHIPS
    via `isolationTopFrameURL`, Chromium proxy rules, post-DNS SSRF guard). Always
    resolve `CrIOSNetworkFetchRequestV1` via `NSClassFromString` when linking against
    pre-Build-44 frameworks.
  - `@optional` `CrIOSBrowserHostV1` `-discardTabWithID:` discards inactive,
    non-audible, non-PiP background tabs while preserving `NavigationManager` history.
