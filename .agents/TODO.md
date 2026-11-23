# Curium TODO

The single ledger of open work. Check an entry against git before acting on it, and
update this file in the same change that starts, finishes, or reshapes the work.
Entries follow the [iteration lifecycle](../AGENTS.md#iteration-lifecycle): fix on
the pinned engine first, translate to `patches/` once proven.

## Pinned

- **Repository:** `benjipeng/curium` (renamed from `benjipeng/chromium-blink-ios`).
- **Engine:** Build 40, `Kernel.lock` → `8b550ce` (run `44939797575`, artifact
  `14723972534`, Chromium `160.0.8171.0`), patches `0001`–`0106`, with separate
  unstripped symbols artifact (`Chromium-Blink-160.0.8171.0-arm64-symbols`, ID
  `14724061921`).
- **App / On `ac_duo`:** `Curium-0.1.11-b15-arm64.ipa` (Build 40 + native Swift
  Fingerprint Profile Studio, `eb127cb`, verified on `iphone_duo_27_2` Simulator
  and tested on `ac_duo` via LiveContainer).
- **Local candidate:** `Curium-0.1.13-b22` (universal per-video floating PiP
  button + universal anti-PiP & background-pause MV3 guard + Build 40 4-bug
  HLS/VOD skip-stall fix + iOS 27.2 AVKit `setPlaying:` coalescing so forward/rewind
  skip never pauses playback + `MappableBufferIOSurface` zero-copy fallback for
  software-decoded AV1/VP9/Simulator frames + `AVAudioSessionCategoryPlayback`
  activation for muted PiP; removed address-bar PiP button & refusal banner).
  Previous `0.1.11-b17` (`57a095c`) verified on `ac_duo`.

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
- [ ] **Dysprosium-inspired media stream sniffer & multi-lane downloader (on Build 40).**
  Next milestone after `0.1.12` PiP checkpoint.

## Live hooks

Permanent shell-side runtime guards in `Curium/Engine/CuriumRuntime.m` plus
scoped Build 40 bridge hooks in `Curium/Engine/CuriumPiPHooks.m`. All five
temporary Build 35 engine hooks were retired in Build 37 (`0099`–`0104`).

| Hook | Effect | Exit |
| --- | --- | --- |
| `CuriumPiPBridge` skip controls (`CuriumPiPHooks.m`) | Enables VOD `requiresLinearPlayback = NO`, native `SeekTo` on `skipByInterval:completionHandler:`, render-queue seek guard against stale pre-seek frames/positions, and offset-contained `timeRangeForPlayback:`. Fails closed on any Build 40 layout drift. | Retire once `0089` wires `OnAVKitSkipByInterval` + seek-epoch timebase handling directly in `ios_video_overlay_window.mm` in the next engine wave. |
| `CrIOSEngineBootstrap` launch fingerprint bridge (`CuriumRuntime.m`) | Probes Build 40 capabilities, sends bounded `schemaVersion: 1` JSON before `ChromeMain`, fails closed on rejection, and queries live `activeFingerprintStatus`. | Permanent: shell ↔ engine launch contract. |
| `-[NSProcessInfo arguments]` (`CuriumRuntime.m`) | Adds launch switches: Google features off, `--disable-sync`, JIT mode, Skia Graphite off on Simulator, `--enable-features=GlobalPrivacyControlApi` strictly when the active profile opts into GPC, and legacy `0105` switches only in unconfigured Build 39 default mode. Also disables the affected Blink permission elements on the pinned engine. | Permanent channel; remove each permission element workaround after validating its label and prompt on a new pinned engine. |
| `V8IOSJitPrepareForProcess` pre-`ChromeMain` probe (`CuriumRuntime.m`) | Prepares V8's iOS TXM / Simulator JIT pool before Crashpad installs exception handlers. | Permanent: shell-controlled JIT preference. |
| `+[MetricsMediator logLaunchMetricsWithStartupInformation:connectedScenes:]` (`CuriumRuntime.m`) | No-op. Launch metrics walk Chrome's tab model for uploads Curium never makes. | None planned. |

## Engine wave (Build 40 landed & pinned in `Kernel.lock`)

Built in run `44939797575` (`8b550ce`) after green `graph-diagnose.yml` (`44938172892` graph + `44938715790` `compile_extensions=true`).

- [ ] **Verify smaller initial Wasm reservations on TXM (next engine, `0001`).**
  Target at most 8 MiB for a module's first reservation; jump tables can require
  more. Build 40 on Simulator reported the explicit flag with both JITs enabled
  and passed JS ↔ Wasm calls on a page and three workers. On device, compare a
  large module and repeated tab/worker loads against Build 40 before resizing
  the 64 MiB pool. This V8 pin requires global jitless for DrumBrake; crossing
  its committed-code cap is fatal.
- [x] **Unstripped framework symbols artifact (`0098`).** Landed Build 37.
- [x] **Single-process extension coexistence (`0099`).** Landed Build 37.
- [x] **Extension APIs & native permissions prompt (`0100`).** Landed Build 37.
- [x] **Blink clipboard UTI conformance & trusted paste (`0101`).** Landed Build 37.
- [x] **Multi-touch cancellation `SIGTRAP` guard (`0102`).** Landed Build 37.
- [x] **Hide `inputAccessoryView` for hardware keyboards (`0103`).** Landed Build 37.
- [x] **PiP close crash & start-when-ready (`0104`).** Landed Build 37.
- [x] **Authentic Chrome dual identity, Client Hints delegate & `Accept-Language` (`0105`).** Landed Build 38/39.
- [x] **Modular launch-scoped fingerprint contract, isolated profile roots, Zstd baseline, OOPIF Desktop inheritance & optional native-first hardware/GPU overrides (`0106`).**
  Landed Build 40 (`8b550ce`, run `44939797575`) and verified end-to-end on `iphone_duo_27_2` Simulator (Zstd HTTPS decode + Range `identity` control, cross-origin OOPIF + nested `about:blank`/`srcdoc`/Worker + sync `window.open('')`/`window.open('about:blank')`, cold `A → B → A → Default` 4-store isolation, Win11 x64 partial `majorVersion=158` coherence + Window/Worker HW/GPU/TZ parity, DNT/GPC, fail-closed recovery, and fixed-proxy `<-loopback>` zero-direct-leak).
- [ ] **Package Blink's localized permission element strings (Build 41 wave, `0107`).**
  On `iphone_duo_27_2`, navigating to `google.com` in `0.1.11-b15` with Build 40
  triggered a renderer `SIGTRAP` in `ui::ResourceBundle::GetLocalizedStringImpl`
  for resource `47053` (absent from `resources.pak`). Mitigated downstream on
  Build 40 via `--disable-blink-features=CameraAndMicrophoneElements,UserMediaElement,GeolocationElement`
  in `CuriumRuntime.m`; standard media capture and geolocation APIs stay active.
  Drafted in `0107` on `feat/build-41-engine-wave`: repacks
  `permission_element_generated_strings.pak` and localized
  `permission_element_strings_<locale>.pak`, with a DataPack v5 assertion for
  resource `47053` in `scripts/stages/link.sh`.
- [ ] **Flip geolocation prompt order & harden cross-origin iframe media checks (Build 41 wave, `0107`).**
  Drafted in `0107` on `feat/build-41-engine-wave`: handles
  `GEOLOCATION_APPROXIMATE`, requests iOS geolocation authorization after site
  approval, and adds `IsCurrentMediaOrigin` in `content_web_state.mm`. Note:
  before running Pipeline 1 under `benjipeng/curium`, copy the existing GHCR
  source/stub/ccache images from `ghcr.io/benjipeng/chromium-blink-ios/*` to
  `ghcr.io/benjipeng/curium/*`.
- [ ] **Drop `helpers/extensions_ui` from packaging (Build 41 wave).**
  Removed `helpers/extensions_ui/`, its `package_ipa.sh` build/inject step, and
  `plan_pipeline.py` entry on `feat/build-41-engine-wave`.
- [ ] **Downloads/PDFKit handoff & Media Radar engine contract (Build 41 wave, `0108`).**
  Drafted in `0108` + `EngineContract/CrIOSBrowserHostV1.h`: keeps
  `enable_pdf = false`, adds `@optional` `isExplicitDownload`/`isMainFrame`/
  `httpMethod` on `CrIOSDownloadTaskV1`, fixes `CuriumBrowserHost._downloads`
  retention leak with terminal snapshots, adds `@optional` `effectiveUserAgent`
  on `CrIOSTabHostingV1`, and adds pre-filtered `browserHost:tab:didLoadResourceEvent:`.
- [ ] **Universal PiP upstreaming & native Blink C++ PiP guard (Build 41 wave, `0109`).**
  Drafted in `0109`: folds `CuriumPiPHooks.m` HLS/VOD skip fixes, iOS 27.2
  `setPlaying:` coalescing, `ClientSharedImage::CloneGpuMemoryBufferHandle()`
  IOSurface fallback, and muted `MixWithOthers` audio session into
  `ios_video_overlay_window.mm`/`ios_pip_frame_hub.mm`; prioritizes iOS PiP in
  `ShouldPausePlaybackWhenHidden`; adds native Blink C++ PiP guard
  (`disablePictureInPicture`, `AttributeChanged`, `exitPictureInPicture`,
  `pauseForBindings` with `MediaSession` pause-action timestamp preservation) so
  `MAIN`-world `pip_guard.js` can be retired after Build 41 pins.
- [ ] **Native Blink C++ anti-fingerprinting (`schemaVersion: 2`, Build 41 wave, `0110`).**
  Drafted in `0110`: backward-compatible `schemaVersion: 1|2` launch config,
  per-`ExecutionContext` `HMAC-SHA256(seed, top_level_site)` farbling across
  Canvas 2D & `OffscreenCanvas`, `measureText`, `OfflineAudioContext` &
  `AnalyserNode`, subtractive/clamped WebGL + client-memory `readPixels`,
  OS-profile `FontCache` filtering & `0005` Apple alias gating, Duo-coherent
  Web-only `Screen`/`MediaValues`/`outer*`/`ScreenOrientation`, desktop
  `DOMPluginArray::IsPdfViewerAvailable()`, and non-Apple `speechSynthesis`
  voice hiding.

## Environment

- The `iPhone Duo` simulator device type has `PiPOverlay` and `PiPPinned` set to
  `true` (original saved as `capabilities.plist.orig`). Xcode updates overwrite it.
- Simulator PiP always fails with `-1003` because its renderer never produces a
  frame; verify PiP on `ac_duo`.
- Simulator SpringBoard shows no Now Playing island for in-simulator audio; use
  `tools/simulator/island-probe` to widen the island.
