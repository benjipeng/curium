# Curium · 96 Cm

Curium (`com.appautomaton.curium`) is a native iOS browser shell for embedded Chromium Blink, V8, Manifest V3 extensions, and isolated profiles. Build with Xcode 27.2 (`iphoneos27.2` / `iphonesimulator27.2`). Deployment floor is iOS 26.0; `84 pt` vertical bars and reserved fold (`.division`) regions activate on iOS 27.1+.

## Build Modes

`CURIUM_USE_ENGINE_XCFRAMEWORK` in [`Version.xcconfig`](../Version.xcconfig) selects the build mode:

- **`NO` (Standby / Unit Testing):** Builds without `Vendor/CuriumEngine/` and runs `CuriumTests` in seconds. Never substitutes WebKit for Blink.
- **`YES` (Embedded Blink):** Links `EarlyMallocZoneRegistration.xcframework` first, followed by `chrome_framework.xcframework` and `Lottie.xcframework`, copies `EngineResources/`, and embeds `CuriumKernelManifest.json` from `Kernel.lock` via `Curium/Engine/embed-frameworks.sh`.

```sh
python3 scripts/sync_curium_engine.py          # Verify and assemble Vendor/CuriumEngine/
python3 scripts/sync_curium_engine.py --status # Offline manifest check
./scripts/build_curium_ipa.sh --output-dir dist # Ad-hoc signed Release arm64 IPA
```

Always `unset SDKROOT` before invoking `xcodebuild`. The embed script verifies that `EarlyMallocZoneRegistration` is the first strong Mach-O `LC_LOAD_DYLIB` load command and signs embedded frameworks inside-out before signing the app.

## Modules

| Directory | Role |
| --- | --- |
| `Curium/App/` | Entry point (`CuriumApp.swift`), pre-`ChromeMain` fail-closed profile bootstrap gate, dedicated UIKit recovery scene delegate, and scene lifecycle WAL checkpoints. |
| `Curium/Browser/` | Liquid Glass address bar, 120 Hz compositor scroll collapse, `.occlusion` / `.division` fold adaptation, Blink viewport host, inline `PDFKit` preview, media permission coordinator, and Picture in Picture state machine. |
| `Curium/Design/` | Shared Liquid Glass design tokens, spacing, typography, and color primitives (`CuriumTokens.swift`). |
| `Curium/Profiles/` | Profile switcher & hot-swap UI (`CuriumProfileSwitcherSheet.swift`), creation/import sheets, and identity/fingerprint editors. |
| `Curium/Fingerprint/` | Launch schema v3 (`EngineContract` v4) config models, 2 creation templates (`macos-desktop`, `privacy-hardened`) plus migrated M3 macOS `default`, `CuriumMacOSManifold` SKU/panel coherence, `CuriumProfileFontManager` process-scoped CoreText fonts, durable JSON store, and `flock`/symlink-hardened storage hygiene. |
| `Curium/Transfers/` | Multi-lane HTTP `206` Range engine (`CuriumRangeTransferEngine`), AIMD HLS downloader (`CuriumHLSTransferEngine`), pure-Swift MP4 remuxer (`CuriumNativeMP4Remuxer`), fail-closed proxy pool, SQLite WAL transfer ledger, and iPhone Duo dual-pane Transfer Inspector UI. |
| `Curium/Sheets/` | Settings, Diagnostics (App + Kernel version/contract inspector), Extensions manager & popups, Tabs, Downloads, Media Radar, Bookmarks, and History. |
| `Curium/Data/` | LiveContainer-durable SQLite library (`curium.sqlite` with `0xdead10cc` `can-suspend-locked` xattr protection), external download bookmarks, session persistence, and rolling diagnostics log. |
| `Curium/Engine/` | Objective-C runtime bridge (`CuriumRuntime.m`) for launch switches, V8 JIT pool setup, `CrIOSEngineBootstrap` capability/hot-swap/runtime-policy bridges, Media Radar, and built-in PiP extension. |

## Shell ↔ Engine Lifecycle

Curium validates and registers its launch fingerprint profile before calling `ChromeMain`. If an explicitly selected profile is missing, invalid, unsupported, or locked, Curium fails closed to a dedicated recovery screen without touching Chromium or the default cookie jar.

After startup, the engine owns the single regular browsing context, scene lifecycle, and live tab/popup views; the Swift shell mounts those views, owns native chrome, confirms extension permissions, and coordinates zero-restart profile hot-swaps via `switchToProfile` (`EngineContract` v4).
