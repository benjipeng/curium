# Curium TODO

The single ledger of open work. Check an entry against git before acting on it, and
update this file in the same change that starts, finishes, or reshapes the work.
Entries follow the [iteration lifecycle](../AGENTS.md#iteration-lifecycle): fix on
the pinned engine first, translate to `patches/` once proven.

## Pinned

- **Repository:** `benjipeng/curium` (renamed from `benjipeng/chromium-blink-ios`).
- **Engine:** Build 42, `Kernel.lock` → `29fd035` (run `45112215845`, artifact
  `14792713617`, Chromium `160.0.8171.0`), patches `0001`–`0110`, with separate
  unstripped symbols artifact (`Chromium-Blink-160.0.8171.0-arm64-symbols`, ID
  `14793005935`). GHCR cache packages migrated to `ghcr.io/benjipeng/curium/*`.
- **App / On `ac_duo`:** `Curium-0.1.11-b15-arm64.ipa` (Build 40, `eb127cb`) /
  `Curium-0.1.13-b23-arm64.ipa` (Build 41 staged in LiveContainer `Documents/`).
- **Local candidate:** `Curium-0.1.13-b24` on `feat/build-41-engine-wave`
  (Build 42 pinned + `httpMethod`/`.ts`/`.m4s` Media Radar filtering +
  `Sendable` isolated-world JS evaluator wrapper; verified live with real Blink
  on `iphone_duo_27_2` Simulator, `sdk 27.2`, `39/39` `CuriumTests` passing,
  `21/21` real-Blink Build 42 assertions passing, Release ARM64 IPA packaged at
  `dist/Curium-0.1.13-b24-arm64.ipa`).

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
| `-[NSProcessInfo arguments]` (`CuriumRuntime.m`) | Adds launch switches: Google features off, `--disable-sync`, JIT mode, Skia Graphite off on Simulator, `--enable-features=GlobalPrivacyControlApi` strictly when the active profile opts into GPC, and legacy `0105` switches only in unconfigured Build 39 default mode. | Permanent channel. |
| `V8IOSJitPrepareForProcess` pre-`ChromeMain` probe (`CuriumRuntime.m`) | Prepares V8's iOS TXM / Simulator JIT pool before Crashpad installs exception handlers. | Permanent: shell-controlled JIT preference. |
| `+[MetricsMediator logLaunchMetricsWithStartupInformation:connectedScenes:]` (`CuriumRuntime.m`) | No-op. Launch metrics walk Chrome's tab model for uploads Curium never makes. | None planned. |

## Engine wave (Build 42 landed & pinned in `Kernel.lock`)

Built in run `45112215845` (`29fd035`) after green `graph-diagnose.yml` (`45111093963`, `172 device objects`, `0` errors).

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
