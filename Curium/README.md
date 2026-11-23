# Curium · 96 Cm

Curium (`com.appautomaton.curium`) is a native iOS browser shell for embedded Chromium Blink, V8, Manifest V3 extensions, and isolated fingerprint profiles. Build it with Xcode 27.2 (`iphoneos27.2` / `iphonesimulator27.2`). The deployment floor is iOS 26.0; the `84 pt` system vertical bar and reserved fold (`.division`) regions activate on iOS 27.1 and later.

## Build Modes

`CURIUM_USE_ENGINE_XCFRAMEWORK` in [`Version.xcconfig`](../Version.xcconfig) selects the build mode:

- **`NO` (Standby / Unit Testing):** Builds without `Vendor/CuriumEngine/` and runs `CuriumTests` in milliseconds. Standby keeps the address bar and tab history in memory and never substitutes WebKit for Blink.
- **`YES` (Embedded Blink):** Links `EarlyMallocZoneRegistration.xcframework` first, followed by `chrome_framework.xcframework` and `Lottie.xcframework`, and copies `EngineResources/` into the app bundle.

### Local Setup with Blink

1. Assemble and SHA-256 verify the engine pinned in [`Kernel.lock`](../Kernel.lock) into `Vendor/CuriumEngine/`:
   ```sh
   python3 scripts/sync_curium_engine.py
   python3 scripts/sync_curium_engine.py --status
   ```
2. Set `CURIUM_USE_ENGINE_XCFRAMEWORK=YES` (default in `Version.xcconfig`) and build `Curium.xcodeproj` with `unset SDKROOT`.
3. The embed phase checks that `EarlyMallocZoneRegistration` is the first strong Mach-O `LC_LOAD_DYLIB` load command and signs embedded frameworks inside-out before signing the app.

### Packaging & Releases

Build an ad-hoc signed Release `arm64` IPA locally against the pinned engine:

```sh
./scripts/build_curium_ipa.sh --output-dir dist
```

On GitHub Actions, [`.github/workflows/build-curium.yml`](../.github/workflows/build-curium.yml) runs the same script on `xcode-27` (`/Applications/Xcode_27.2.app`), uploads the IPA and `.sha256` artifact, and publishes a GitHub Release on `curium-v*` tag pushes or manual `workflow_dispatch`.

## Architecture & Modules

| Directory | Role |
| --- | --- |
| `Curium/App/` | Entry point (`CuriumApp.swift`), pre-`ChromeMain` fail-closed profile bootstrap gate, dedicated UIKit recovery scene delegate (`CuriumRecoveryApplicationDelegate`), and scene lifecycle WAL checkpoints. |
| `Curium/Browser/` | Liquid Glass address bar, 120 Hz compositor scroll collapse, `.occlusion` / `.division` fold adaptation, Blink viewport host, and Picture in Picture state machine. |
| `Curium/Fingerprint/` | Schema v2 anti-fingerprinting config models, 3 empirically verified Chrome 158 Stable archetypes (`macos-desktop` with M1–M5 Max / 8–32 GB RAM pools, `default` Mobile Chrome, and `privacy-hardened`), structural + coherence validator, durable JSON store, and symlink/`flock`-hardened profile storage inspection & wipe helpers. |
| `Curium/Sheets/` | Settings, native `NavigationStack` Fingerprint Profile Studio & Editor (`CuriumFingerprintStudioSheet.swift`), Diagnostics contract & hook inspector, Extensions manager & popups, Tabs, Downloads, Bookmarks, and History. |
| `Curium/Data/` | LiveContainer-durable SQLite library (`curium.sqlite` with WAL `0xdead10cc` `can-suspend-locked` xattr protection) and rolling diagnostics log (`curium-diagnostics.log`). |
| `Curium/Engine/` | Objective-C runtime bridge (`CuriumRuntime.m`) for launch switches (including profile-gated `GlobalPrivacyControlApi`), early V8 JIT probe, extension calls, and `CrIOSEngineBootstrap` capability/status queries. |

## Shell ↔ Engine Lifecycle

Curium validates and registers its launch fingerprint profile before calling `ChromeMain`. If an explicitly selected profile is missing, invalid, unsupported, or locked, Curium fails closed to a dedicated recovery screen without touching Chromium or the default cookie jar.

When launch succeeds, Curium registers its `CrIOSShellBootstrapDelegate` and enters `ChromeMain`. The engine owns the single regular browsing context, scene lifecycle, and live tab/popup views; the Swift shell mounts those views, owns native chrome, and confirms extension permissions before installation.
