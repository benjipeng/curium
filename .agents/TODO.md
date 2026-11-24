# Curium TODO

The single ledger of open work. Check an entry against git before acting on it, and
update this file in the same change that starts, finishes, or reshapes the work.
Entries follow the [iteration lifecycle](../AGENTS.md#iteration-lifecycle): fix on
the pinned engine first, translate to `patches/` once proven.

## Pinned

- **Repository:** `benjipeng/curium` (renamed from `benjipeng/chromium-blink-ios`).
- **Engine:** Build 43c, `Kernel.lock` → `5cca78a` (`feat/build-43-engine-wave`, run `45378018050`, artifact `14917643362`, IPA SHA-256 `18e72648cd07b539bd6612751b930a094b69582a0a71ff1d05f47eea84ddf7c7`, Chromium `160.0.8171.0`), patches `0001`–`0112` (106 total), with separate unstripped symbols artifact (`Chromium-Blink-160.0.8171.0-arm64-symbols`, ID `14918400531`). GHCR cache packages live at `ghcr.io/benjipeng/curium/*`.
- **App / Latest release:** `Curium-0.1.18-b31` (`cf78b18`, tag `curium-v0.1.18-b31`, GitHub Actions run `45322479070`, `Curium-0.1.18-b31-arm64.ipa` SHA-256 `2841113340a4611ab5ed1c285c1745fea2b59f344c043921167a7d991749d0d7`, Build 42 pinned + `CuriumMacOSManifold` continuous Apple Silicon macOS identity sampler).
- **Ready on `feat/build-43-engine-wave` (pending merge/release & `ac_duo` approval):** Build 43c pinned + `EngineContract` v3 + zero-restart hot Privacy Hardening + native C++ desktop parity (retiring `CuriumDesktopParityExtension` on Build 43+); `106/106` `CuriumTests` passing under `-warnings-as-errors`, `Release arm64` `sdk 27.2`, and `26/26` live dual-simulator real-Blink assertions passing.

## App (on the pinned engine)

- [x] **Modular Fingerprint Profile Studio & Diagnostics Contract UI (`eb127cb`).**
  Added 7 built-in presets (`default`, `ios-blink`, `macos-desktop`,
  `win11-workstation`, `linux-desktop`, `pixel-android`, `privacy-hardened`),
  native iOS 27.2 `NavigationStack` Profile Studio & dual-slot `IdentitySpec`
  editor (`CuriumFingerprintStudioSheet.swift`), native-first Hardware & GPU
  override toggle, structural + coherence validator, APFS case-insensitive &
  `lstat`/`flock`-hardened isolated storage sizing/wipe (`CuriumFingerprintStorage.swift`),
  JSON/wire import & export, full Build 40 contract & capability readout in
  Diagnostics, `GlobalPrivacyControlApi` runtime feature bridge (`CuriumRuntime.m`),
  and UIKit `CuriumRecoveryApplicationDelegate` self-healing fail-closed recovery
  UI (`CuriumApp.swift`). Verified on `iphone_duo_27_2` Simulator (`sdk 27.2`,
  19/19 `CuriumTests` passing) and on `ac_duo`.
- [x] **PiP in one tap.** Upstreamed into `0104-ios-curium-pip-start-when-ready.patch`.
- [x] **Dark Reader and uBlock Origin Lite coexistence in one session.** Upstreamed into `0099` + `0100`.
- [x] **Blink web-page paste UTI conformance & trusted paste.** Upstreamed into `0101`.
- [x] **Multi-touch cancellation `SIGTRAP` guard.** Upstreamed into `0102`.
- [x] **Form accessory hidden for hardware keyboards.** Upstreamed into `0103`.
- [x] **Readable guest logs on `ac_duo`** (`CuriumDiagnostics.swift`, 128 KB rolling file + Copy/ShareLink).
- [x] **Address bar buttons accessible** (`.overlay` controls above `.glassEffect`).
- [x] **Swift/Obj-C shell stability, 120 Hz scroll smoothness & idle-efficiency sweep** (`CuriumTests` target).
- [x] **Top chrome follows `.occlusion` / `.division` reserved regions.**
- [x] **Avoid the missing permission label crash on Build 40.** Temporarily
  disable Blink's in-page camera, microphone, user media, and geolocation
  elements in `CuriumRuntime.m`. The standard web APIs remain exposed. Add
  fallback iOS usage descriptions for standalone installs.
- [x] **Native Swift website camera & microphone prompts on Build 40.**
  Implemented `CrIOSBrowserHostDelegateV1.requestMediaPermissions` in
  `CuriumBrowserStore.swift` backed by `CuriumMediaPermissionCoordinator.swift`:
  asks site permission first via SwiftUI `.alert`, then requests `AVCaptureDevice`
  authorization, coalesces/queues concurrent requests without poisoning the
  engine's page-scoped cache, and automatically dismisses/denies prompts on
  navigation, origin change, tab switch, or tab close. Under LiveContainer, iOS
  authorization still belongs to the host.
- [x] **Native Swift inline tab PDF reader & persistent Downloads (`b17`).**
  PDF links stream automatically into isolated `Caches/CuriumPDFPreview/` (never
  polluting `Documents/Curium/Downloads/`) and render inline inside the tab via
  `PDFKit` with page counter, async Find-in-PDF (top-chrome-clear highlighting),
  embedded Table of Contents, in-tab link routing, one-tap Save to durable
  Downloads, ShareLink, and automatic temp-cache cleanup on Back / navigation /
  tab close / launch. Non-PDF downloads present a floating Liquid Glass prompt
  banner and save flat (collision-safe, no random UUID folders) with disk-backed
  Saved Files persistence, Open-in-Tab / QuickLook preview, Share, and symlink-safe
  deletion.
- [x] **Universal Picture in Picture overhaul: floating per-video button, anti-PiP/background-pause guard, AVKit skip-keeps-playing fix & SharedImage IOSurface bridge (`0.1.13-b22`).**
  Removed the address-bar PiP button and refusal banner; added hidden built-in
  MV3 extension (`CuriumVideoPiPExtension.swift`, deterministic ID
  `kogjboefmhkckeddcmekebknpjlhkhid` materialized into
  `TrustedUnpackedExtensions/curium_video_pip/`) with universal `MAIN`-world
  `pip_guard.js` (locks `disablePictureInPicture = false`, blocks unsolicited
  `exitPictureInPicture()`, shields active PiP from `visibilitychange`/`blur`
  background-pause scripts without altering normal tabs) and `ISOLATED`-world
  `pip_overlay.js` (closed-ShadowDOM floating Liquid Glass PiP pill on every
  eligible playing/recently-paused `<video>`, muted or unmuted, multi-video,
  ShadowDOM, cross-origin iframes, pinch-zoom aware, zero idle rAF). Fixed all
  Build 40 `CuriumPiPBridge` playback/skip bugs in `CuriumPiPHooks.m`:
  (1) replaced `updatePlaybackPaused:position:` to preserve high-PTS HLS
  timebases and `rate > 0` during buffering, synchronous `[renderer flush]` on
  skip & PTS discontinuities, zero-leak pre-seek stale-frame drop via
  `_isFlushing`, `3.5s` HLS guard window, and `isReadyForMoreMediaData`
  self-heal; (2) fixed iOS 27.2 `AVSampleBufferDisplayLayerPlayerController`
  pausing on every forward/rewind skip by synchronously updating
  `_mainPlaybackPaused` in `setPlaying:`, invoking `completionHandler()` before
  `invalidatePlaybackState`, and coalescing same-runloop-turn `NO -> YES`
  transitions so transient seek toggles cancel to a zero-pause no-op while
  genuine user Pause/Play dispatches immediately; (3) added fail-closed
  zero-copy `ClientSharedImage -> MappableBufferIOSurface -> CVPixelBufferRef`
  bridge for `STORAGE_OPAQUE` software-decoded AV1/VP9/Simulator frames and
  `AVAudioSessionCategoryPlayback` activation for muted videos. Verified live
  with real native iOS 27.2 SpringBoard Pegasus PiP on `iphone_duo_27_2`
  Simulator (`42/42` `CuriumTests` passing).
- [x] **Build 41 downstream integration & Build 40 workaround retirement (`0.1.13-b23`).**
  Repinned `Kernel.lock` to Build 41 (`45092671606`), deleted temporary
  `CuriumPiPHooks.{h,m}`, dropped the `--disable-blink-features` permission
  element workaround from `CuriumRuntime.m`, retired `MAIN`-world `pip_guard.js`
  from `CuriumVideoPiPExtension` (`manifestVersion = "1.1.0"`, `ISOLATED`-world
  floating pill only with clean legacy upgrade), wired `schemaVersion: 2`
  anti-fingerprinting presets/validator/Studio UI (`CuriumFingerprint*`), gated
  inline `PDFKit` preview on `!isExplicitDownload && isMainFrame && httpMethod == "GET"`,
  and added `CuriumMediaRadar.swift` consuming `didLoadResourceEvent:` +
  `effectiveUserAgent`. Verified live with real Blink on `iphone_duo_27_2`
  Simulator (`sdk 27.2`, `38/38` `CuriumTests` passing).
- [x] **Pure Apple Silicon macOS Settings/Profile overhaul & downstream desktop anti-tampering parity (on Build 42).**
  Consolidated global Settings (`CuriumSheetHeader.swift`) to single-owner global
  controls (Profile, global Downloads, JavaScript Engine, Runtime & Diagnostics),
  retired Android emulation and dead Build 38 UA pickers, streamlined the profile
  editor (`CuriumFingerprintEditorView.swift`) into 4 consumer sections + Advanced,
  and aligned default `Personal` and all 8 Apple Silicon presets to coherent 30-bit
  M1–M5 macOS Chrome 158 configs (default Apple M3 `1512×982`, `8c`, `16 GB`,
  `colorDepth: 30`) with automatic legacy profile upgrade. Landed three-layer
  downstream desktop parity without rebuilding Chromium: (1) `embed-frameworks.sh`
  excludes unused `gcrweb.js`, `send_webkit_message.js`, `language_detection.js`,
  and `translate_ios.js` (removing `window.__gCrWeb` and
  `window.__proto__.webkit.messageHandlers`); (2) `CuriumRuntime.m` injects native
  desktop Blink/V8 switches (`--touch-events=disabled`,
  `--disable-blink-features=TouchEventFeatureDetection`,
  `--enable-blink-features=KeyboardLock`, `--force-color-profile=extended-srgb`,
  `--js-flags=--max-old-space-size=2048`, `--force-effective-connection-type=4G`);
  (3) hidden built-in MV3 extension `CuriumDesktopParityExtension.swift`
  (deterministic ID `igckbhkefpgcfcijbdhbkalaofkagpom`, zero Widevine/DRM spoofing,
  zero `getComputedStyle`/`matchMedia`/`performance.memory` proxies, pass-through-first,
  `MacIntel`-guarded) closes `PresentationRequest.prototype.reconnect`
  (`"Route not found"`), dynamic `Screen.prototype.availTop`, `@2x` DPR,
  `KeyboardLayoutMap`, macOS/Google TTS voice metadata, `MediaCapabilities`,
  `PublicKeyCredential.getClientCapabilities()`, `window.chrome`, and Chrome 138+
  `LanguageDetector`/`Summarizer` availability. Verified on fresh `Curium.app`
  install on `iphone_duo_27_2` Simulator (`sdk 27.2`, `95/95` `CuriumTests` passing
  under `-warnings-as-errors`; live `demo.fingerprint.com/playground`:
  `bot: not_detected`, `tampering: false` (`high` confidence, `anomaly_score: 0`,
  `anti_detect_browser: false`), `virtual_machine: false`, `suspect_score: 11`;
  both built-in extensions hidden in Extensions sheet).
- [x] **Same-IP multi-profile `Visitor ID` independence (on Build 42).**
  Root-caused cross-profile and cross-device `Visitor ID` collapse onto identical
  high-weight signals (iOS's fixed 3-font `s20` list, identical unseeded `s52`
  TTS voices, beta `27.2.1` `platformVersion`, and `0110` solid-rect `±1 LSB`
  canvas pixel noise triggering `tampering_ml_score > 0.96`). Added
  `CuriumProfileFontManager.swift` (pre-`ChromeMain` in-process SFNT cloning via
  `CTFontManagerRegisterFontsForURL(.process)` registering hardware-tier-disjoint
  4–6 font pure macOS/Office/Adobe/Design suites including `Arial Unicode MS`,
  zero JS hooks), `CuriumFarblingSettings.stealthSafe` (Audio + WebGL farbling
  by default on `Personal` and `macos-desktop`, keeping `Privacy Hardened` on
  `.allEnabled`, with automatic untouched `b29` upgrade), seeded `s52` voices
  and Dock-safe `availTop = min(38, height - availHeight)` in
  `CuriumDesktopParityExtension` (`manifestVersion = "1.1.0"`, reload-on-change),
  coherent `--force-color-profile=srgb|extended-srgb` in `CuriumRuntime.m`, and
  mainstream `macOS 26.3.1` / `15.5`–`26.3.1` + Chrome `156`–`158` + Dock frame
  diversity across the 8 Apple Silicon pool variants. Verified live on
  `iphone_duo_27_2` Simulator (`sdk 27.2`, `97/97` `CuriumTests` passing under
  `-warnings-as-errors`; 4/4 distinct `Visitor ID`s on the exact same IP, real
  local timezone, and real language, all `bot: not_detected` and `tampering: false`).
- [x] **Optional Build 43+ upstream polish:** Moved `RenderWidgetHostViewIOS::GetKeyboardLayoutMap()`, `Screen::availTop` / `availLeft` macOS menu bar & Dock offsets, `ContentJavaScriptFeatureManager` / `ContentWebFramesManager` `__gCrWeb` suppression, and all remaining desktop parity surfaces into C++ (`0110` + `0112`), completely gating off `CuriumDesktopParityExtension` (`0` `MAIN`-world JS scripts) on Build 43+.
- [ ] **Pure-Swift `CuriumMacOSManifold` SKU/panel coherence polish:** Restrict `1728×1117` (16-inch MacBook Pro panel) to 10+ core Pro/Max Apple Silicon SKUs (never base `Apple M2` or 8-core `M1 Pro`), since `1728×1117 + 8c` triggered `tampering_ml_score > 0.97` on `iphone_17_27_2` whereas `2048×1152 + 12c M2 Pro` scored `tampering: false` (`0.4692`).
- [ ] **CI pipeline fine-grained cache keys (`scripts/plan_pipeline.py`):** Split `patches/` content hashing into graph/codegen inputs (`*.gn`, `*.gni`, `*.mojom`, `*.idl`, `*.json5`, `*.grd`, `*.swift`, resources) vs pure C++/ObjC implementation hunks (`.cc`/`.mm`/`.h`) so `.cc`-only iterations skip `1 Codegen` + `2 Apple tools` + `2.5 Verify` (~50 min saved per build).
- [ ] **Dysprosium-inspired media stream sniffer & multi-lane downloader (on Build 41).**
  Backed by `0108` `CuriumMediaRadar` (`didLoadResourceEvent:` +
  `effectiveUserAgent`); next UI/downloader milestone after Build 41 checkpoint.

## Live hooks

Permanent shell-side runtime guards in `Curium/Engine/CuriumRuntime.m`. All
temporary Build 35 (`0099`–`0104`) and Build 40 (`CuriumPiPHooks.m` → `0109`,
permission element disable flag → `0107`) workarounds are retired.

| Hook | Effect | Exit |
| --- | --- | --- |
| `CrIOSEngineBootstrap` launch fingerprint bridge (`CuriumRuntime.m`) | Probes engine capabilities (`v1` / `v2`, 17 features on Build 41), sends bounded `schemaVersion: 1|2` JSON before `ChromeMain`, fails closed on rejection, and queries live `activeFingerprintStatus`. | Permanent: shell ↔ engine launch contract. |
| `-[NSProcessInfo arguments]` (`CuriumRuntime.m`) | Adds launch switches: Google features off, `--disable-sync`, JIT mode, Skia Graphite off on Simulator, `--enable-features=GlobalPrivacyControlApi` when the active profile opts into GPC, desktop zero-touch macOS switches (`--touch-events=disabled`, `--disable-blink-features=TouchEventFeatureDetection`, `--enable-blink-features=KeyboardLock`, `--force-color-profile=extended-srgb`, `--js-flags=--max-old-space-size=2048`, `--force-effective-connection-type=4G`), and legacy `0105` switches only in unconfigured Build 39 default mode. | Permanent channel. |
| `V8IOSJitPrepareForProcess` pre-`ChromeMain` probe (`CuriumRuntime.m`) | Prepares V8's iOS TXM / Simulator JIT pool before Crashpad installs exception handlers. | Permanent: shell-controlled JIT preference. |
| `+[MetricsMediator logLaunchMetricsWithStartupInformation:connectedScenes:]` (`CuriumRuntime.m`) | No-op. Launch metrics walk Chrome's tab model for uploads Curium never makes. | None planned. |

## Engine wave (Build 43c landed & pinned in `Kernel.lock`)

Built in run `45378018050` (`5cca78a`, `feat/build-43-engine-wave`) after green `graph-diagnose.yml` (`45376297422`, `0` errors).

- [x] **Build 43c engine wave: hot Runtime Privacy Policy v3, stealth farbling, Retina DPR/screen ladder & native C++ desktop parity (`0110`–`0112`, run `45378018050`).**
  - `0110`: `schemaVersion: 3` (`availTop`, `availLeft`, `devicePixelRatio`, `personaSeed`), 7-panel canonical `@2x` Apple Retina ladder + authentic `availTop`/`availLeft`, zoom-preserving web-only `@2x` DPR across `LocalDOMWindow` & CSS `MediaValues`, $3\times 3$ $\ge 3$-RGB-gradient `FarbleRGBA8Pixels` + flat-run-guarded `FarbleAudioSamples`, dynamic `ExecutionContext` site-key re-derivation.
  - `0111`: Lock-free `curium_runtime_policy` (`applyRuntimePolicyJSON:error:`, `activeRuntimePolicyStatus`, `v3` `fingerprintCapabilities`), live browser observer syncing `RendererPreferences` across live `WebContents`, dynamic `Sec-GPC: 1` (`global_privacy_control_util.cc`) + per-context native V8 `globalPrivacyControl` accessor on `Navigator.prototype` & `WorkerNavigator.prototype` (Window + Dedicated/Shared/Service Workers) using Blink's pristine `NavigatorOnLine.onLine` getter for CppHeap-safe WebIDL brand checking, and Build-44-ready `PurgeProfileRuntimeCaches()` / `profileHotSwap: "planned_build_44"`.
  - `0112`: Native C++ desktop parity (`__gCrWeb`/`webkitMessageHandler` suppression at source, `window.chrome.{csi,loadTimes,app}` with `SetClassName` + `ConstructorBehavior::kThrow`, `Notification.permission === "default"` via `BlinkNotificationServiceImpl` + `ContentPermissionManager`, 48-key macOS ANSI `GetKeyboardLayoutMap`, 199-voice seeded `speechSynthesis`, `MediaCapabilities`, `PublicKeyCredential` capabilities, `PresentationRequest`, `NetworkInformation.rtt`, `LanguageDetector`/`Summarizer`), completely gating off `CuriumDesktopParityExtension` when `nativeDesktopParityV1 == true`.
  - Verified live with real Blink on BOTH `iphone_duo_27_2` (PID `23336`, unchanged across OFF → ON → OFF, `0` restart banners, `26/26` assertions passing: `Sec-GPC: 1`, `navigator.globalPrivacyControl === true`, cross-realm iframe, Blob Worker, all 9 `Illegal invocation` brand checks, bit-exact solid Canvas/WebGL/flat Audio, per-origin gradient Canvas/sine Audio farbling & exact revert, `Notification.permission === "default"`, `0` `MAIN`-world JS extensions; live `demo.fingerprint.com/playground`: BOTH Hardening OFF & Hardening ON scored `bot: not_detected`, `tampering: false`, `anomaly_score: 0`, `anti_detect_browser: false`, `suspect_score: 34`) and `iphone_17_27_2` (`bot: not_detected`, distinct `visitor_id`); `106/106` `CuriumTests` passing under `-warnings-as-errors`, `Release arm64` `sdk 27.2`.
- [ ] **Build 44 engine wave (planned): full zero-restart cross-profile hot-swap (`ProfileIOS` + `RenderProcessHostImpl` rebinding + `PurgeProfileRuntimeCaches`).** Built on top of Build 43c's `curium_runtime_policy` & `profileCachePurgeHook` foundations.

- [ ] **Verify smaller initial Wasm reservations on TXM (`ac_duo`, `0001`).**
  Landed in Build 41/42 (`0001` targets at most 8 MiB for a module's first
  reservation; jump tables can require more). Simulator verified `256` JS ↔ Wasm
  calls under `Native MAP_JIT`. On physical `ac_duo`, compare a large module and
  repeated tab/worker loads against Build 40 before resizing the 64 MiB pool.
  This V8 pin requires global jitless for DrumBrake; crossing its committed-code
  cap is fatal.
- [x] **Build 42 kernel polish & Media Radar wave (`0108` + `0110`, run `45112215845`).**
  Landed and verified live with real Blink on `iphone_duo_27_2` Simulator (`21/21`
  real-Blink assertions passing):
  1. `0110` `canvas_async_blob_creator.cc`: Metal `HTMLCanvasElement.toBlob()`,
     `toDataURL()`, and `OffscreenCanvas.convertToBlob()` match byte-for-byte on
     both `127.0.0.1` and `localhost` and diverge across sites (HDR/`F16` untouched).
  2. `0110` `base_rendering_context_2d.cc`: `Menlo`, `Avenir`, and `__NoSuchFont__`
     all match `monospace` to exact `0.0000 px` via `PrimaryFont()->PlatformData().Typeface()->getFamilyName()`.
  3. `0110` `screen.cc` + `curium_fingerprint_config.{h,cc}` + `local_dom_window.cc`:
     `RootWindowRect` physical DIPs report exact `1920×1080` (`avail 1920×1040`,
     `landscape-primary`, `outerH = 1040 <= availHeight`, `mqDeviceWidth1920 && mqDeviceHeight1080`)
     even on folded portrait outer display without `<meta viewport>`.
  4. `0110` `font_cache_ios.mm`: `"PingFang SC", Arial` matches `"__NoSuchFont__", Arial`
     to exact `0.0000 px` on CJK/emoji with clean rendering and zero tofu.
  5. `0110` `webgl_rendering_context_base.cc` + `analyser_node.cc`: `PACK_ROW_LENGTH`/
     `PACK_SKIP_*` bounds + `GetError()`/`synthetic_errors_` preservation landed;
     `AnalyserNode` frequency/time-domain tail sentinels verified 100% untouched.
  6. `0108` `curium_tab_host.mm` + `CrIOSBrowserHostV1.h` + `download_item_utils.{h,cc}` + `download_manager_impl.cc`:
     `httpMethod=GET` logged by Media Radar (filtering `POST` and `.ts`/`.m4s`),
     `<form method="GET">` PDF opens directly in inline `PDFKit` preview (`Page 1 of 1`),
     and `@optional` `evaluateJavaScriptInIsolatedWorld:allFrames:completion:` selector
     compiled and wrapped in `CuriumTabModel`.
- [x] **Unstripped framework symbols artifact (`0098`).** Landed Build 37.
- [x] **Single-process extension coexistence (`0099`).** Landed Build 37.
- [x] **Extension APIs & native permissions prompt (`0100`).** Landed Build 37.
- [x] **Blink clipboard UTI conformance & trusted paste (`0101`).** Landed Build 37.
- [x] **Multi-touch cancellation `SIGTRAP` guard (`0102`).** Landed Build 37.
- [x] **Hide `inputAccessoryView` for hardware keyboards (`0103`).** Landed Build 37.
- [x] **PiP close crash & start-when-ready (`0104`).** Landed Build 37.
- [x] **Authentic Chrome dual identity, Client Hints delegate & `Accept-Language` (`0105`).** Landed Build 38/39.
- [x] **Modular launch-scoped fingerprint contract, isolated profile roots, Zstd baseline, OOPIF Desktop inheritance & optional native-first hardware/GPU overrides (`0106`).**
  Landed Build 40 (`8b550ce`, run `44939797575`).
- [x] **Package Blink's localized permission element strings (`0107`).**
  Landed Build 41 (`45092671606`): verified resource `47053` across 10,167 packed
  resources at link time; `<geolocation>` and `<usermedia type="camera">` render
  natively on `iphone_duo_27_2` with zero `SIGTRAP`.
- [x] **Flip geolocation prompt order & harden cross-origin iframe media checks (`0107`).**
  Landed Build 41 (`45092671606`) after migrating all 21 GHCR cache tags to
  `ghcr.io/benjipeng/curium/*`.
- [x] **Drop `helpers/extensions_ui` from packaging.**
  Landed Build 41 (`45092671606`).
- [x] **Downloads/PDFKit handoff & Media Radar engine contract (`0108`).**
  Landed Build 41 (`45092671606`) and verified live on `iphone_duo_27_2`:
  `Content-Disposition: attachment` PDFs stay in Download Banner, inline PDFs
  open in `PDFKit`, and `.m3u8`/`.mp4` fetches fire `didLoadResourceEvent:`.
- [x] **Universal PiP upstreaming & native Blink C++ PiP guard (`0109`).**
  Landed Build 41 (`45092671606`) and verified live on `iphone_duo_27_2`:
  `disablePictureInPicture`, `pause()`, and `exitPictureInPicture()` stay
  100% `[native code]` with zero `MAIN`-world JS footprint.
- [x] **Native Blink C++ anti-fingerprinting (`schemaVersion: 2`, `0110`).**
  Landed Build 41 (`45092671606`) and verified live on `iphone_duo_27_2` across
  `127.0.0.1` vs `localhost` (`win11-lab`, 17 engine capabilities, `v2` contract;
  3 micro-fixes tracked above for Build 42).

## Environment

- The `iPhone Duo` simulator device type has `PiPOverlay` and `PiPPinned` set to
  `true` (original saved as `capabilities.plist.orig`). Xcode updates overwrite it.
- Simulator PiP always fails with `-1003` because its renderer never produces a
  frame; verify PiP on `ac_duo`.
- Simulator SpringBoard shows no Now Playing island for in-simulator audio; use
  `tools/simulator/island-probe` to widen the island.
