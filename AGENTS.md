# Curium

Curium (`com.appautomaton.curium`) is a native iOS browser: a Liquid Glass shell on a Chromium engine (Blink, V8, Manifest V3 extensions) with none of Google's UI. All work lands on `main`.

Open work, live engine hooks, and pinned versions live in [.agents/TODO.md](.agents/TODO.md). Read it before planning; update it in the same change that moves the work.

## Roles

- **GitHub Actions builds the engine (`build-ipa.yml`).** It fetches and prunes upstream Chromium, applies `patches/`, then compiles, links, and packages the engine IPA (Stages 0–5).
- **Xcode 27.2 builds and releases the app (`build-curium.yml` / `scripts/build_curium_ipa.sh`).** All experimentation and iteration happens in `Curium/`, `Curium.xcodeproj`, and `EngineContract/`, against the prebuilt engine pinned in `Kernel.lock`. Push a `curium-v*` tag or dispatch `build-curium.yml` to build, verify (`sdk 27.2`, inside-out ad-hoc signing), and publish the arm64 IPA to GitHub Releases.

## Iteration lifecycle

Iterate on the engine that `Kernel.lock` pins. Rebuild Chromium only to make a proven fix permanent or to reach what the app cannot.

1. **Fix downstream.** Reach the pinned engine from the app: Swift, `EngineContract`, `Info.plist` keys, launch switches, bundled extensions, and Objective-C runtime hooks in `Curium/Engine/`. A hook checks the engine's class layout, fails closed, and is listed under Live hooks in `.agents/TODO.md` with its exit.
2. **Validate on the pinned engine.** Simulator first; `ac_duo` only for device-only behavior, with a Release build and explicit approval.
3. **Translate to `patches/`** a proven hook worth making permanent, and whatever the app cannot reach: GN args, C++ with no Objective-C entry point, and code that must leave the binary.
4. **Bank, then build once.** `patches/`, `args/`, `version.lock`, and the `COMMON` scripts in `scripts/plan_pipeline.py` key all 18 compile partitions and their `ccache` buckets, so engine changes wait in the Engine wave of `.agents/TODO.md`. When the wave is complete and approved, gate it with `graph-diagnose.yml`, then run `build-ipa.yml`. After repinning `Kernel.lock`, delete the hooks the new engine retires.

## Engine constraints

- **One process, many threads.** iOS and LiveContainer cannot spawn helper processes, so the browser, renderer, GPU, and network work all run in the app process. Never add work that needs a separate process or app extension.
- **JIT is optional.** V8 runs jitless with DrumBrake Wasm by default and switches to JIT only when an external debugger, such as StikDebug over a local VPN, enables it at launch (patches 0001 and 0092). Any JIT path must fail closed to jitless.

## No local Chromium

The upstream tree is far too large for this machine. Never run `fetch`, `gclient sync`, or `git clone` for Chromium or V8, and never compile or link Chromium locally. To investigate, use single-file excerpts (`scripts/check_remote_patches.py --local-excerpts`), build graphs from `graph-diagnose.yml`, the engine's Objective-C metadata (`xcrun dyld_info -objc`), and small native helpers.

## Engine handoff

- **Two independent build numbers:** `Kernel.lock` owns the monotonic **Kernel build** (`KERNEL_BUILD`, bumped only when repinning a new engine wave — never `build-ipa.yml`'s `github.run_number` CI counter); `Version.xcconfig` owns the **Curium app** version & build (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`). `scripts/sync_curium_engine.py` + `Curium/Engine/embed-frameworks.sh` embed `CuriumKernelManifest.json` into `Curium.app` so Settings, Diagnostics, Profiles, and `build-curium.yml` Releases display both unambiguously.
- `Kernel.lock` pins the engine artifact. `scripts/sync_curium_engine.py` assembles it into the untracked `Vendor/CuriumEngine/`; `--status` checks it offline. Reserve `--skip-sha256` for an explicit local test IPA.
- CI compiles the engine with Xcode 27.1 (`version.lock`), as intended. The app must link against SDK 27.2: `vtool -show-build` on the Curium binary reports `sdk 27.2`.
- Each Release build bumps `CURRENT_PROJECT_VERSION` by `+1` in `Version.xcconfig` while holding `MARKETING_VERSION` steady across iterations within a cycle (bump `MARKETING_VERSION` only for version milestones). Release tags and artifacts use `curium-v<version>-b<build>` and `Curium-<version>-b<build>-arm64.ipa`.

## Read before

| Task | Read |
| --- | --- |
| Pipeline, checkpoints, repository setup | [README](README.md) |
| App build modes and engine linking | [Curium/README](Curium/README.md) |
| Shell–engine ABI | [EngineContract/README](EngineContract/README.md) |
| `Curium/` UI or simulator driving | Workspace skills [`iphone-duo-liquid-glass`](../.agents/skills/iphone-duo-liquid-glass/SKILL.md) and [`axe`](../.agents/skills/axe/SKILL.md) |
| Deploying to `ac_duo` under LiveContainer | Workspace skill [`livecontainer-guest`](../.agents/skills/livecontainer-guest/SKILL.md) |
| Standalone Chromium IPA diagnostics | [Simulator guide](docs/simulator.md) |

`docs/research/` holds dated research records, not current guidance.
