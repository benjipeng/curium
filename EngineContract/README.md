# Curium Engine Contract

This Clang module defines the versioned Objective-C ABI (`v1`–`v4`) between Curium (`com.appautomaton.curium`) and its embedded Blink engine. Add `EngineContract/` to the module search path and import `CuriumEngineContract` in Swift (`@import CuriumEngineContract;` in Objective-C; use `-fcxx-modules` or `#include "CuriumEngineContract.h"` in Objective-C++). The module contains declarations; `chrome_framework` provides the implementations.

## Module, Threading & Probing

- **Bootstrap registration:** Register the `CrIOSShellBootstrapDelegate` on the main thread before calling `ChromeMain`. `CrIOSEngineBootstrap` retains the registration until replaced or cleared and calls the delegate per scene with a `CrIOSBrowserHostV1` and optional `CrIOSExtensionManagingV1`. In standby builds without `chrome_framework`, resolve `CrIOSEngineBootstrap` and additive v4 classes (e.g. `CrIOSNetworkFetchRequestV1`) dynamically via `NSClassFromString`.
- **Main-thread contract:** Call all UI contract methods and expect delegate callbacks, completions, and notifications on the main thread (new UI declarations import `@MainActor` in Swift; legacy extension declarations preserve their Swift signatures and must still be called on the main actor). Every request completion fires exactly once, including on cancellation.
- **Additive capability probing:** All post-V1 selectors and properties are `@optional` or probed via `respondsToSelector:` / `fingerprintCapabilities` before calling.

## Host, Tabs & Streaming Fetch

The shell and Blink share one process and one regular browsing context (V1 exposes no off-the-record context). The engine owns browser state and tab/popup views; the shell owns its root controller, mounts/detaches those views, holds a weak delegate on the browser host, treats tab lists as snapshots, and discards closed tab references. Use a tab's string ID with the browser host and its numeric extension tab ID with per-tab extension calls.

- **Compositor top controls (`CrIOSTabBrowserControlsV1`):** Give `tab.webView` its full viewport with `scrollView.contentInset.top == 0`, set a fixed `topControlsHeight` in points (`0` disables), and KVO-observe `topControlsShownRatio` on the main thread to morph chrome as Blink shifts the page. Static `scrollView.contentInset` remains available as fallback.
- **Navigation commits:** Record history from the optional navigation-commit callback (fires once per main-frame commit, excludes error pages, covers fragment/History API same-document commits, marks reloads via `isReload`) rather than coalesced tab updates.
- **Tab discard (`-discardTabWithID:`):** Discards inactive, non-audible, non-PiP background tabs under memory pressure while preserving `NavigationManager` history.
- **Download metadata (`CrIOSDownloadTaskV1`):** Optional `finalURL`, `acceptRanges`, `eTag`, `lastModified`, and `contentDisposition` enable zero-probe multi-lane upgrade without burning single-use tokens.
- **Streaming fetch (`CrIOSNetworkFetchV1`, `-startFetchRequest:delegate:callbackQueue:`):** Exposes an off-`@MainActor` `SharedURLLoaderFactory` + `mojo::SimpleWatcher` credit-window pipe using BoringSSL TLS/HTTP2/HTTP3, `CookieMonster` + CHIPS (`isolationTopFrameURL`), Chromium proxy rules, and a post-DNS SSRF guard.

## Extensions

For extension queries taking an `NSError **`, a `nil` return indicates failure; an empty collection or `0` indicates a successful empty result.

| Query | Value |
| --- | --- |
| Action presentation | Immutable dictionary: boolean `NSNumber` keys `isEnabled` and `hasPopup`; optional `title`, `badgeText` (`NSString`; absent/empty = no badge), `icon` (`UIImage`), `badgeBackgroundColor` (`UIColor`). |
| DNR block count | Nonnegative `NSNumber` for the extension and tab. |
| Commands | Array of `{name, description, shortcut}` string dictionaries (empty `shortcut` = unbound); dispatch by `name`. |

Retain action observation tokens to receive updates and release them on the main thread (`nil` ID means re-read all snapshots). Retain presented popups; on dismissal or `onRequestClose`, clear the handler, detach the view, and call `close`.

## Profiles, Hot-Swap & Runtime Policy (`v1`–`v4`)

### Launch Bootstrap (`configureLaunchFingerprintConfigJSON:error:`)

Probe `fingerprintCapabilities`, `configureLaunchFingerprintConfigJSON:error:`, and `activeFingerprintStatus` on `CrIOSEngineBootstrap` before `ChromeMain`. Passing `nil`/empty preserves Build 39 (`0105`) defaults. Bounded UTF-8 JSON (`schemaVersion: 1..4`, `<= 64 KiB`; `v4` uses the `v3` wire payload unchanged, so the shell negotiates `min(3, max(1, contractVersion))`) validates all fields, locks `<Application Support>/ChromiumProfiles/<profileId>` (or `<Application Support>/Chromium` for `"default"`), and freezes configuration before threads start. Invalid or unavailable explicit profiles fail closed (`NO` + `CrIOSFingerprintErrorDomain`). `activeFingerprintStatus` reports `appliedProfileId`, `profileDirectoryOpened`, `appliedConfigRevision`, `state`, and `hardwareOverridesActive`.

- **Schema v3+ fields:** `ScreenOverrideConfig` adds `availTop` (`[0, 256]`), `availLeft` (`[0, 512]`), and web-only `devicePixelRatio` (`[1.0, 4.0]`, leaving native UIKit scale/touch untouched). Top-level `personaSeed` (`16..64` ASCII hex) deterministically seeds non-farbled surfaces (e.g. native desktop `SpeechSynthesis` voices) even without `fingerprintSeed`.
- **Capabilities (`fingerprintCapabilities`):** Reports `contractVersion` (`4` on Kernel 44), `supportedSchemaVersions` (`[1, 2, 3, 4]`), `runtimePolicyVersion` (`1`), `maxRuntimePolicyBytes` (`16384`), `activationScopes` (`farbling`, `webrtcPolicy`, `doNotTrack`, `globalPrivacyControl`, `speechVoiceHiding`, `profileHotSwap` = `"runtime_hot"`; `jitMode` = `"launch"`), and `features` (`hotRuntimePrivacyPolicy`, `stealthEdgeCanvasFarbling`, `nativeDesktopParityV1`, `coherentWebDPR`, `gcrwebSuppressedAtSource`, `nativeKeyboardLayoutMap`, `nativeSpeechSynthesisVoices`, `nativeWindowChromeSurface`, `profileCachePurgeHook`, `zeroRestartProfileHotSwap`).

### Zero-Restart Profile Hot-Swap (`v4`, `CuriumEngineMain.h`)

`+switchToProfileWithConfigJSON:beforeProfileCreate:completion:` atomically quiesces outgoing tabs, fetches, and extensions, detaches the single-process `RenderProcessHost`, tears down the outgoing `ProfileIOS`, purges renderer/V8/font caches, invokes `beforeProfileCreate` on `@MainActor` for CoreText `.process` font swap, boots the target `ProfileIOS`, rebinds the renderer before services/extensions start, and delivers fresh `browserHost` and `extensionManager` instances. Additive `CrIOSFingerprintErrorCode` values: `HotSwapUnsupported = 9`, `HotSwapInProgress = 10`, `TeardownIncomplete = 11`.

### Live Runtime Privacy Policy (`policySchemaVersion: 1`)

Probe `applyRuntimePolicyJSON:error:` and `activeRuntimePolicyStatus` (gated on `features.hotRuntimePrivacyPolicy == YES`) to hot-toggle privacy controls across live tabs without restart (`<= 16384` bytes, strict allowlist):

- **Payload keys:** `policySchemaVersion` (required `1`), `policyRevision` (optional uint64 `<= 9007199254740991`), `fingerprintSeed` (`null` or 64-char ASCII hex), `farbling` (`null` or `{canvas, audio, webgl, textMetrics}` booleans), `webrtcIpHandlingPolicy` (`default`, `default_public_and_private_interfaces`, `default_public_interface_only`, `disable_non_proxied_udp`), `enableDoNotTrack` (bool), `enableGlobalPrivacyControl` (bool), `hideSpeechVoices` (`null` for per-slot `"Auto"` or bool).
- **Status (`activeRuntimePolicyStatus`):** Returns `runtimePolicyVersion`, `appliedPolicyRevision`, `farblingActive`, `farbling`, `webrtcIpHandlingPolicy`, `enableDoNotTrack`, `enableGlobalPrivacyControl`, and `hideSpeechVoices`. On Kernel 43+, `GlobalPrivacyControlApi` is toggled dynamically by runtime policy rather than a launch switch.
