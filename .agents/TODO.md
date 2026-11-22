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
- **Local candidate:** `Curium-0.1.11-b16-arm64.ipa` (Build 40 with the permission
  element workaround). No physical deployment.

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
- [ ] **Floating PiP button over the playing video.** Requested. Open question:
  placement over the in-page video or in the top chrome.

## Live hooks

Permanent shell-side runtime guards in `Curium/Engine/CuriumRuntime.m`. All five
temporary Build 35 engine hooks were retired in Build 37 (`0099`–`0104`).

| Hook | Effect | Exit |
| --- | --- | --- |
| `CrIOSEngineBootstrap` launch fingerprint bridge (`CuriumRuntime.m`) | Probes Build 40 capabilities, sends bounded `schemaVersion: 1` JSON before `ChromeMain`, fails closed on rejection, and queries live `activeFingerprintStatus`. | Permanent: shell ↔ engine launch contract. |
| `-[NSProcessInfo arguments]` (`CuriumRuntime.m`) | Adds launch switches: Google features off, `--disable-sync`, JIT mode, Skia Graphite off on Simulator, `--enable-features=GlobalPrivacyControlApi` strictly when the active profile opts into GPC, and legacy `0105` switches only in unconfigured Build 39 default mode. Also disables the affected Blink permission elements on the pinned engine. | Permanent channel; remove each permission element workaround after validating its label and prompt on a new pinned engine. |
| `V8IOSJitPrepareForProcess` pre-`ChromeMain` probe (`CuriumRuntime.m`) | Prepares V8's iOS TXM / Simulator JIT pool before Crashpad installs exception handlers. | Permanent: shell-controlled JIT preference. |
| `+[MetricsMediator logLaunchMetricsWithStartupInformation:connectedScenes:]` (`CuriumRuntime.m`) | No-op. Launch metrics walk Chrome's tab model for uploads Curium never makes. | None planned. |

## Engine wave (Build 40 landed & pinned in `Kernel.lock`)

Built in run `44939797575` (`8b550ce`) after green `graph-diagnose.yml` (`44938172892` graph + `44938715790` `compile_extensions=true`).

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
- [ ] **Package Blink's localized permission element strings (deferred to next engine wave).**
  On `iphone_duo_27_2`, navigating to `google.com` in `0.1.11-b15` with Build 40
  triggered a renderer `SIGTRAP` in `ui::ResourceBundle::GetLocalizedStringImpl`
  for resource `47053` (absent from `resources.pak`). Mitigated downstream on
  Build 40 via `--disable-blink-features=CameraAndMicrophoneElements,UserMediaElement,GeolocationElement`
  in `CuriumRuntime.m`; standard media capture and geolocation APIs stay active.
  Deferred: repack `permission_element_generated_strings.pak` and
  `permission_element_strings_en-US.pak` into `resources.pak` (with a `link.sh`
  data-pack check) in the next full engine wave.
- [ ] **Flip geolocation prompt order & harden cross-origin iframe media checks (deferred to next engine wave).**
  Build 40 already supports location (iOS prompt first, then site prompt) and
  delegates camera/microphone prompts to Swift (`CuriumBrowserStore`). Defer
  moving iOS `GeolocationSystemPermissionManager::RequestSystemPermission()`
  after site approval and adding `IsCurrentMediaOrigin` in `content_web_state.mm`
  to the next engine wave. Note: before running Pipeline 1 under `benjipeng/curium`,
  copy the existing GHCR source/stub/ccache images from
  `ghcr.io/benjipeng/chromium-blink-ios/*` to `ghcr.io/benjipeng/curium/*`.
- [ ] **Drop `helpers/extensions_ui` from packaging.** Deferred to next engine wave.

## Environment

- The `iPhone Duo` simulator device type has `PiPOverlay` and `PiPPinned` set to
  `true` (original saved as `capabilities.plist.orig`). Xcode updates overwrite it.
- Simulator PiP always fails with `-1003` because its renderer never produces a
  frame; verify PiP on `ac_duo`.
- Simulator SpringBoard shows no Now Playing island for in-simulator audio; use
  `tools/simulator/island-probe` to widen the island.
