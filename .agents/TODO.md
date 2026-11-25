# Curium TODO

The single ledger of open work. Check an entry against git before acting on it, and
update this file in the same change that starts, finishes, or reshapes the work.
Entries follow the [iteration lifecycle](../AGENTS.md#iteration-lifecycle): fix on
the pinned engine first, translate to `patches/` once proven.

## Pinned

- **Repository:** `benjipeng/curium` (single branch `main`).
- **Kernel:** `Kernel 44` (`Kernel.lock` → commit `3139702`, CI run `45489802926`, artifact `14971351535`, IPA SHA-256 `1f590eaca9e7913159463c332959033127a9ca0e868bf332380b46001fefd649`, Chromium `160.0.8171.0`), patches `0001`–`0115` (109 active patches), `EngineContract` v4, incremental GHCR anchor index `stage-cache:index-2f01f813d23787a206ff` (run `45523774592`).
- **App Release:** `curium-v0.1.21-b34` (`Curium 0.1.21`, build `34`, `sdk 27.2`).

## Open Work

- [ ] **Verify smaller initial Wasm reservations on TXM (`ac_duo`, `0001`).**
  `0001` targets at most 8 MiB for a module's first reservation (Simulator verified `256` JS ↔ Wasm calls under `Native MAP_JIT`). On physical `ac_duo`, compare a large module and repeated tab/worker loads against Build 40 before resizing the 64 MiB pool. This V8 pin requires global jitless for DrumBrake; crossing its committed-code cap is fatal.
- [ ] **Pure-Swift MPEG-DASH (`.mpd`) downloader (deferred from Kernel 44).**
  Standalone app-side PR gated upfront on `avc1`/`hvc1` + `mp4a` fMP4 codecs (rejecting VP9/AV1+Opus incompatible with `AVAssetExportPresetPassthrough`).
- [ ] **`extensions/tabs.json` schema expansion (next engine wave).**
  Deferred from Kernel 44 to avoid `ios_api_json_strings` codegen churn; batch into Kernel 45 when a new engine wave opens.

## Live Hooks

Permanent shell-side runtime guards in `Curium/Engine/CuriumRuntime.m` (all temporary Build 35 and Build 40 workarounds are retired).

| Hook | Effect | Exit |
| --- | --- | --- |
| `CrIOSEngineBootstrap` launch, hot-swap & policy bridge | Probes `EngineContract` v4 capabilities, configures bounded launch JSON (schema v1..3; `EngineContract` v4 accepts 1..4) before `ChromeMain` (failing closed on rejection), drives hot runtime privacy policy (`policySchemaVersion: 1`, `applyRuntimePolicyJSON:error:`) and zero-restart `switchToProfile`. | Permanent shell ↔ engine contract. |
| `-[NSProcessInfo arguments]` | Adds launch switches: Google features off, `--disable-sync`, JIT mode, Skia Graphite off on Simulator, desktop zero-touch macOS switches (`--touch-events=disabled`, `--disable-blink-features=TouchEventFeatureDetection`, `--enable-blink-features=KeyboardLock`, `--js-flags=--max-old-space-size=2048`), and legacy Build 39–42 fallbacks. | Permanent channel. |
| `V8IOSJitPrepareForProcess` pre-`ChromeMain` probe | Prepares V8's iOS TXM / Simulator JIT pool before Crashpad installs exception handlers. | Permanent: shell-controlled JIT preference. |
| `+[MetricsMediator logLaunchMetricsWithStartupInformation:connectedScenes:]` | No-op. Launch metrics walk Chrome's tab model for uploads Curium never makes. | None planned. |

## Environment

- The `iPhone Duo` simulator device type has `PiPOverlay` and `PiPPinned` set to `true` (original saved as `capabilities.plist.orig`). Xcode updates overwrite it.
- Simulator PiP fails with `-1003` when its renderer produces no frame; verify PiP playback on `ac_duo`.
- Simulator SpringBoard shows no Now Playing island for in-simulator audio; use `tools/simulator/island-probe` to widen `.occlusion`.
