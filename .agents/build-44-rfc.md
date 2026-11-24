# Curium Build 44 Master RFC

> Synthesized from Build 44 Architecture Swarm (`b44-scout-profile`, `b44-scout-net-dl`, `b44-scout-ux-gaps`, `b44-oracle`) against pinned Chromium `160.0.8171.0` (Build 43c, `patches/0001`–`0112`), iOS 27.2 SDK, and LiveContainer `MH_DYLIB` constraints on iPhone Duo (`iPhone19,4`).

## Architectural Invariants & Rejected Traps

1. **Preserve macOS ANGLE Metal WebGL Extensions (`0110:958-960`):** Real Google Chrome on Apple Silicon macOS (M1–M5 ANGLE Metal) natively exposes `WEBGL_compressed_texture_pvrtc`, `etc`, `etc1`, and `astc`. Do **not** strip them on `kDesktopMacOS`.
2. **Single-Process `RenderProcessHostImpl` Pinning:** Under `--single-process`, `ApplicationContextImpl::local_state_` is process-lifetime and destroying `RenderProcessHostImpl` triggers either `MiraclePtr` `DanglingPtr` traps or `InProcessRendererThread` `ChildThreadImpl::OnChannelError() -> _exit(0)`. Pillar 1 keeps `ApplicationContextImpl` intact and uses `DetachFromBrowserContextForHotSwap()` → `~ProfileIOSImpl()` → `RebindToBrowserContextForHotSwap()`.
3. **Preserve `WebTouchEvent` Pipeline (`0102`):** Do **not** suppress `WebTouchEvent` in `web_input_event_builders_ios.mm`; `RenderWidgetHostViewIOS` feeds `FilteredGestureProvider` to drive 120 Hz `kGestureScroll*` and pinch-zoom gestures.
4. **Incremental CI First (`TODO.md`):** Before building Build 44 in CI, land incremental `patches/` hashing in `scripts/plan_pipeline.py` (separating `.gn`/`.gni`/`.mojom`/`.idl`/`.json5`/`.grd`/`.py`/`tabs.json` from `.cc`/`.mm`/`.h` hunks) so `.cc`/`.mm` iterations skip Stage 1 Codegen + Stage 2 Apple tools (~50 min saved per run).

---

## Pillar 1: Zero-Restart Cross-Profile Hot-Swap (`0113-ios-curium-zero-restart-profile-hotswap.patch`)

### Strategy
Sequential **Quiesce → `RenderProcessHostImpl` Detach → `ProfileIOSImpl` Teardown → In-Process Renderer & CoreText Font Purge → Explicit-Path `ProfileIOSImpl` Recreate & `RenderProcessHostImpl` Rebind**.
- **Steady-state RSS:** Strictly 1× profile (`0 MiB` permanent overhead; `< +15 MiB` transient peak during swap), preserving LiveContainer `192 MiB` admission headroom.
- **Disk Compatibility:** `default` remains at `<AppSupport>/Chromium/Default`; custom `<slug>` remains at `<AppSupport>/ChromiumProfiles/<slug>/Default`. `ApplicationContextImpl::local_state_` remains at its launch path while `paths.mm` updates active profile root and advisory `flock` (`com.apple.runningboard.can-suspend-locked`).
- **Launch-Only Boundary:** V8 `jitMode` (`--jitless` vs TXM pool) remains `activationScopes.jitMode = "launch"`. Color gamut moves into dynamic `media_values.cc` (Pillar 3).

### 6-Step Atomic C++/ObjC Sequence
1. **Preflight (Non-Destructive):** Validate `jsonData` (`schemaVersion: 1..4`, `<= 64 KiB`); acquire target `.curium_profile.lock` before mutating state (fail closed while Profile A remains live).
2. **Browser Drain:** Shut down `CuriumBrowserHost` (cancel all `CuriumDownloadTask`s and `CrIOSNetworkFetchTaskV1`s), close extension popups, detach `_headlessBrowser` from `BrowserListFactory`, close all `WebState`s, stop Service Workers, and drain main + IO + `InProcessRendererThread` until `RenderFrameHost` count is `0`.
3. **`RenderProcessHostImpl` Detach (`render_process_host_impl.{h,cc}`):** Pin single-process `RenderProcessHostImpl` and call `DetachFromBrowserContextForHotSwap()` (clears `storage_partition_impl_`, `browser_context_`, old `URLLoaderFactory`, and `ChildProcessSecurityPolicyImpl` / `ProcessMap` locks).
4. **Outgoing `ProfileIOSImpl` Teardown:** `ShutdownIOSExtensionsForProfile` → `DestroyProfileServices` → `~ContentBrowserContext` → `~StoragePartitionImpl` (closes `NetworkContext`, `CookieMonster` SQLite, HTTP/QUIC/HSTS/DNS caches, `PrefService`). Swap `paths.mm` `lock_fd`.
5. **Config Swap, Renderer Purge & CoreText Font Swap:**
   - `HotSwapLaunchConfig(parsed)` updates `LaunchConfigStorage`, seeds `RuntimePolicySnapshot`, resets `ApproximatedDeviceMemory`, calls `base::i18n::SetICUDefaultLocale`, and replaces/clears `TimeZoneController`'s `curium_tz_override`.
   - `PurgeProfileRuntimeCaches()` barrier on `InProcessRendererThread`: `WebCache::Clear()`, `MemoryCache::EvictResources()`, `FontCache::Get().Invalidate()`, `SkGraphics::PurgeFontCache()`, sync `WebRuntimeFeatures`, and V8 `DateTimeConfigurationChangeNotification` / `LocaleConfigurationChangeNotification` / `MemoryPressureNotification(kCritical)`.
   - Synchronously invoke `beforeProfileCreate()` on `@MainActor`: `CuriumProfileFontManager` unregisters old `.process` CoreText fonts (`CTFontManagerUnregisterFontsForURL`), removes old temp `.ttf`s, and registers target profile SFNT clones.
6. **Target `ProfileIOSImpl` Boot & Rebind:** Construct target `ProfileIOSImpl` at explicit `<profile_root>/Default`, call `RenderProcessHostImpl::RebindToBrowserContextForHotSwap(new_ctx, new_partition)`, create new `Browser` + `CuriumBrowserHost`, and invoke `completion(newHost, extManager, nil)`.

### `EngineContract` v4 Additions (`EngineContract/CuriumEngineMain.h`)
```objc
// Additive CrIOSFingerprintErrorCode values:
CrIOSFingerprintErrorHotSwapUnsupported = 9,
CrIOSFingerprintErrorHotSwapInProgress = 10,
CrIOSFingerprintErrorTeardownIncomplete = 11,

// Additive selector on CrIOSEngineBootstrap (probe via respondsToSelector:):
+ (void)switchToProfileWithConfigJSON:(NSData *)jsonData
                  beforeProfileCreate:(nullable void (^NS_SWIFT_UI_ACTOR)(void))beforeProfileCreate
                           completion:(void (^NS_SWIFT_UI_ACTOR)(
                                          id<CrIOSBrowserHostV1> _Nullable browserHost,
                                          id<CrIOSExtensionManagingV1> _Nullable extensionManager,
                                          NSError *_Nullable error))completion
    NS_SWIFT_NAME(switchToProfile(configJSON:beforeProfileCreate:completion:));
```

---

## Pillar 2: Chromium-Native Network Stack Bridge (`0114-ios-curium-network-fetch-bridge-and-download-headers.patch`)

### 1. Zero-Probe `CrIOSDownloadTaskV1` Metadata + Slice-1 Tail Handoff
Extend `DownloadItemData` (`download_item_utils.{h,cc}`, `download_manager_impl.cc`) and `ContentDownloadTask` (`0013` + `0108`, fixing `originalURL` vs `finalURL`) with `@optional` properties on `CrIOSDownloadTaskV1`:
- `finalURL`, `acceptRanges`, `eTag`, `lastModified`, `contentDisposition`.
- When `acceptRanges == YES && totalBytes >= 512 KiB` (including `POST -> 302/303 -> GET`), skip `probe()`, keep `blinkTask` parked, and launch **Slice 1 (`[mid..end]`) first** via `CrIOSNetworkFetchV1`. Cancel `blinkTask` only after Slice 1 returns `HTTP 206`; otherwise let `blinkTask` finish on its already-open socket (preserving single-use tokens).

### 2. `CrIOSNetworkFetchV1` (`EngineContract/CrIOSNetworkFetchV1.h`)
- Off-`@MainActor` streaming bridge backed by `StoragePartition::GetURLLoaderFactoryForBrowserProcess()->Clone()` + `mojo::SimpleWatcher(ArmPolicy::MANUAL)` on a background `SequencedTaskRunner`.
- Provides BoringSSL TLS/HTTP2/HTTP3/Zstd parity, `CookieMonster` `HttpOnly` + CHIPS (`isolationTopFrameURL`) + `Set-Cookie` writeback, Chromium PAC/HTTP-auth/`https://` proxy parity, and post-DNS SSRF blocking (`head->remote_endpoint`).
- Strict **4-chunk (`256 KiB`) per-lane credit window** (`-setSuspended:` -> Mojo DataPipe -> TCP/H2 flow control), capping total in-flight RAM across 16 lanes at `<= 12 MiB`.
- `CuriumBrowserHost -shutdown` cancels all live `CrIOSNetworkFetchTaskV1` instances before `~ProfileIOSImpl()`.

---

## Pillar 3: Selective Stealth, Media & Jetsam Polish (`0115-ios-curium-stealth-locale-pip-and-tab-discard.patch`)

1. **`Intl.*` ICU Locale Parity:** Call `base::i18n::SetICUDefaultLocale` from `LaunchConfig::languages[0]` on boot and hot-swap (`cr_ios_engine_bootstrap.mm`).
2. **Dynamic Display Color-Gamut / HDR (`media_values.cc`):** Derive `color-gamut` / `dynamic-range` from active slot `screen.colorDepth` (`30` vs `24`), retiring `--force-color-profile` from `CuriumRuntime.m`.
3. **Client Hints Dynamic Coherence (`content_browser_context.mm`):** Resolve `GetUserAgentMetadata()` dynamically per active slot, clear `origin_hints_` on hot-swap, and expose coherent `50 ms / 10 Mbps / 4G` hints.
4. **PiP Audio Session Release & Background `<audio>` (`ios_video_overlay_window.mm`, `web_media_player_impl.cc`):** Restore `.mixWithOthers` / `NotifyOthersOnDeactivation` in `stopPiPAndDetach:` and exempt audible audio-only `<audio>` in `ShouldPausePlaybackWhenHidden()`.
5. **Single-Process Jetsam Tab Discard (`curium_browser_host.mm`, `CrIOSBrowserHostV1.h`):** `@optional - (BOOL)discardTabWithID:(NSString *)tabID` to shed inactive background `WebState` memory while retaining back/forward history.
6. **Media Radar Header Enrichment (`curium_tab_host.mm`):** Add `contentDisposition`, `contentRange`, `eTag`, and `redirectChain` to `didLoadResourceEvent:`.

---

## Patch & Incremental CI Blast-Radius Map

| Patch | Chromium Files Touched | `.h` / `BUILD.gn` / `.mojom` Impact | Incremental CI Cost |
| --- | --- | --- | --- |
| `0113` | `paths.{h,mm}`, `cr_ios_engine_bootstrap.mm`, `curium_engine_contract_internal.h`, `scene_controller.mm`, `render_process_host_impl.{h,cc}`, `curium_fingerprint_config.{h,cc}`, `curium_runtime_policy.{h,cc}`, `approximated_device_memory.cc`, `timezone_controller.cc`, `ios_content_renderer_client.cc` | Narrow `.h` only (`0` `BUILD.gn`, `0` `.mojom`) | ~5–7 compile shards |
| `0114` | `ios/chrome/browser/curium/{BUILD.gn,DEPS,curium_network_fetch.{h,mm},curium_browser_host.mm,curium_download_task.{h,mm},curium_engine_contract_internal.h}`, `download_task.h`, `content_download_task.{h,mm}`, `download_item_utils.{h,cc}`, `download_manager_impl.cc` | 2 new files in `ios/chrome/browser/curium/BUILD.gn` (`0` Blink/Mojo `.h`) | ~2–3 compile shards |
| `0115` | `cr_ios_engine_bootstrap.mm`, `curium_browser_host.mm`, `curium_tab_host.mm`, `curium_engine_contract_internal.h`, `content_browser_context.mm`, `ios_video_overlay_window.mm`, `media_values.cc`, `web_media_player_impl.cc` | `.cc`/`.mm` only outside `curium_engine_contract_internal.h` | ~1–3 compile shards |

---

## Deferred Beyond Build 44
- **Pure-Swift MPEG-DASH (`.mpd`) Downloader:** Standalone downstream PR gated upfront on `avc1`/`hvc1` + `mp4a` fMP4 codecs (rejecting VP9/AV1+Opus incompatible with `AVAssetExportPresetPassthrough`).
- **`extensions/tabs.json` schema expansion:** Deferred to Build 45 to avoid `ios_api_json_strings` codegen churn in Build 44.
- **V8 64 MiB TXM pool sizing (`0001`/`0092`):** Measure multi-tab Wasm on physical `ac_duo` before altering pool geometry.
