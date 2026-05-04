# HomeHub

A private, offline-first personal AI assistant for iPhone and iPad.
Local LLM inference, personal memory, onboarding, and a clean
native SwiftUI interface. No cloud, no accounts, no data leaving the device.

## Status

**Functional MVP** — buildable and runnable with `MockLocalRuntime` (simulated
inference). The full end-to-end flow works: onboarding → model selection →
model install/load → chat with streaming → memory extraction → persistence
across restarts.

| Layer | Status |
|-------|--------|
| SwiftUI views (15+ screens) | Production-ready |
| App entry / DI container | Complete |
| Persistence (FileStore JSON) | Complete |
| Runtime abstraction | Complete |
| LlamaCppRuntime façade | Complete — C++ bridge implemented, xcframework must be built |
| MockLocalRuntime | Complete — used for development builds |
| PromptAssemblyService | Complete — layered L0-L2 + guardrails |
| MemoryExtractionService | Complete — structured + heuristic fallback |
| ConversationService | Complete — streaming, cancel, persistence |
| Model catalog / download | Complete — real URLSession, Wi-Fi-only, resume on interruption |
| Chat templates | Complete — Llama 3 header format + ChatML (Qwen, Phi) |
| Lifecycle (background/memory) | Wired — scenePhase + memory-pressure hooks |
| Tests (8 files, 50+ cases) | Covering services, persistence, runtime |

### What's mock / limited

- **MLX runtime** — the primary path; always linked and used by default.
  `MLXRuntime` loads model containers via `MLXLMCommon.loadModelContainer`,
  with `swift-transformers` providing the tokenizer bridge.
- **LlamaCppRuntime** — secondary; only compiled when the build opts in
  via `HOMEHUB_LLAMA_RUNTIME` AND ships with `llama.xcframework`. Without
  the flag, the C++ bridge files compile to empty translation units and
  the runtime is not constructed.
- **MockLocalRuntime** — used by SwiftUI previews and unit tests. Streams
  canned responses without touching any model file.
- **Memory extraction** — structured extraction via the local model falls back
  to heuristic keyword triggers when using `MockLocalRuntime` (the mock
  doesn't produce valid JSON for extraction prompts).

## Target devices

- iPhone 16 Pro (8 GB RAM, A18 Pro)
- iPad with M-series chip (8–16 GB RAM)
- Minimum: iOS 17.0 / iPadOS 17.0, Swift 5.10+

## Architecture

```
UI (SwiftUI)
   │
App state / view models
   │
Services (orchestration, side-effects)
   │
┌──────────────┬─────────────┬─────────────┐
│ RuntimeMgr   │ Memory      │ Persistence │
│  LocalLLM    │  Facts +    │  FileStore  │
│  Runtime     │  Episodes + │  (JSON v1)  │
│  (protocol)  │  Extraction │             │
└──────────────┴─────────────┴─────────────┘
```

- **Runtime abstraction**: `LocalLLMRuntime` protocol → `MLXRuntime`
  (primary, always linked) or `LlamaCppRuntime` (opt-in via
  `HOMEHUB_LLAMA_RUNTIME`). `RoutingRuntime` dispatches by
  `LocalModel.backend`. `MockLocalRuntime` is used by previews and tests.
- **Prompt assembly**: `PromptAssemblyService` builds layered system prompts:
  L0 (persona + user profile) → L1 (durable facts) → L2 (episodic context)
  → privacy guardrails.
- **Memory**: opt-in, user-controlled. Extraction runs heuristically by
  default, with structured LLM extraction when a real model is loaded.
  Facts and episodes are proposed as candidates the user can accept/reject.
- **Persistence**: JSON files under `Application Support/HomeHub/` via
  `FileStore`. Pluggable behind the `Store` protocol for future SwiftData
  migration.
- **DI**: Single `AppContainer` owns all services, injected via
  `@EnvironmentObject`. Factory methods: `.live()` (production) and
  `.preview()` (SwiftUI previews + tests).

## Folder layout

```
HomeHub/
├── App/              # @main entry, AppContainer, AppState, RootView, tabs
├── DesignSystem/     # HHTheme, buttons, cards, empty states
├── Features/
│   ├── Onboarding/   # 6-step onboarding flow
│   ├── Chat/         # Chat list, detail, message bubbles, composer
│   ├── Memory/       # Facts browser, candidates, add fact sheet
│   ├── Models/       # Model catalog, download states, load/unload
│   └── Settings/     # Personalization, generation params, privacy
├── Models/           # Domain entities (13 types)
├── Runtime/          # LocalLLMRuntime protocol, LlamaCpp, Mock, Actor, Telemetry
├── Persistence/      # Store protocol, FileStore, InMemoryStore
├── Services/         # RuntimeManager, Conversation, Memory, Prompt, Settings, ...
└── PreviewContent/   # Sample data for SwiftUI previews

HomeHubTests/         # 8 test files, 50+ test cases
```

## Getting started

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Xcode | 15.4+ | App Store |
| xcodegen | any | `brew install xcodegen` |
| llama.xcframework | _OPTIONAL_ — only needed if you opt in to llama.cpp | see [Optional: llama.cpp opt-in](#optional-llamacpp-opt-in) |

The default build is MLX-only and has no native binary dependencies — every
package is resolved through SPM. `llama.xcframework` is OFF by default and
only required if you flip `HOMEHUB_LLAMA_RUNTIME` on (see below).

If you do opt in, place `llama.xcframework` as a **sibling of the repo root**:

```
~/Developer/          (or wherever you keep repos)
  llama.xcframework/  ← binary framework here
  ios-home-hub/       ← this repo
```

Build it once (see [Integrating the real llama.cpp runtime](#integrating-the-real-llamacpp-runtime))
and it stays in place across branches and clones.

### Option A: XcodeGen (recommended — fully reproducible)

```bash
# 1. Install xcodegen if needed
brew install xcodegen

# 2. Clone the repo
git clone https://github.com/Keksiczek/ios-home-hub
cd ios-home-hub

# 3. Regenerate the Xcode project from project.yml (source of truth)
xcodegen generate

# 4. Resolve Swift packages (uses committed Package.resolved — no network surprises)
xcodebuild -resolvePackageDependencies -project HomeHub.xcodeproj -scheme HomeHub

# 5. Open in Xcode
open HomeHub.xcodeproj
```

Or use the Makefile shortcut: `make setup && open HomeHub.xcodeproj`

Select an iOS 17+ simulator or device, then **Cmd+R** to build and run.

**Code signing:** `project.yml` does not set a development team. Xcode will
prompt you to select your own team on first build — change it in
*Signing & Capabilities* or set `DEVELOPMENT_TEAM` in a local `.xcconfig`.

#### Re-running xcodegen

Run `xcodegen generate` (or `make generate`) again whenever:
- `project.yml` changes (new targets, packages, build settings)
- you pull a commit that modifies `project.yml`

The committed `project.pbxproj` is kept in sync for developers who open the
project without running xcodegen first, but `project.yml` is the authoritative
source — never edit the `.pbxproj` directly.

#### Keeping Package.resolved up to date

The file `HomeHub.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
is committed and tracks the exact SPM versions used in CI.  If you update a
package (e.g. bump `mlx-swift-lm` revision), run:

```bash
make sync-resolved   # copies root Package.resolved → xcshareddata/
```

Then commit both `Package.resolved` and the `xcshareddata/…/Package.resolved`.

#### Updating package versions — SOP

`project.yml` is the single authoritative source for every dependency. Follow
this sequence to avoid silent version mismatches:

1. **Edit `project.yml`** — change the `from:` / `branch:` / `exactVersion:`
   under the relevant key in the `packages:` section.

2. **Validate** — run `make ci` before doing anything else.  This catches
   duplicate YAML keys, broken package references, URL collisions, intra-target
   dep duplicates, and version drift between `project.yml`, `Package.swift`,
   `project.pbxproj`, and `Package.resolved` before XcodeGen silently swallows
   them.

3. **Regenerate** — run `make generate` to apply the change to `project.pbxproj`.

4. **Resolve** — open `HomeHub.xcodeproj` in Xcode → `File > Packages >
   Resolve Package Dependencies`.  Xcode writes the actual resolved versions
   back into the Xcode `Package.resolved`.

5. **Sync** — run `make sync-resolved` to mirror the Xcode-resolved lockfile
   back to the root `Package.resolved`.

6. **Verify** — run `make check`.  All checks must pass (including SHA-256
   identity between the two `Package.resolved` files) before committing.

7. **Commit** — stage and commit `project.yml`, `project.pbxproj`, and both
   `Package.resolved` files together.

> **Critical invariants**
> - Each package must appear **exactly once** in the `packages:` mapping.
>   YAML duplicate keys are silently resolved by "last wins" — the wrong
>   version will be used without any error.
> - Each target must have **exactly one** `dependencies:` block.  A second
>   block at the same indentation overwrites the first.
> - `SwiftTransformers` (the package key in `project.yml`) must be `>= 0.1.14`
>   and `WhisperKit` must be `>= 0.11.0`.  Earlier combinations produce
>   `Unable to find module dependency: 'TensorUtils'` at build time.
> - The correct product name for `swift-transformers` is `Transformers`
>   (not `Hub` or `Tokenizers` — those are internal targets).  Referencing them
>   as products causes `product 'Hub' not found in package 'swift-transformers'`.
>   Run `make verify-transformers` to catch this class of mistake automatically.

#### Version constraint rationale

| Package | Constraint | Reason |
|---------|-----------|--------|
| `WhisperKit` | `from: 0.11.0` | 0.9.x imports `TensorUtils` as a standalone module that was removed from swift-transformers in 0.1.x |
| `SwiftTransformers` | `from: 0.1.14` | Minimum version compatible with WhisperKit 0.11.0; exports `Transformers` library product (`Hub` and `Tokenizers` are internal targets, not standalone products) |
| `MLX` | `from: 0.21.0` | Minimum version tested with the MLXRuntime implementation |
| `MLXLM` | `branch: main` | No stable tag series yet; pinned via `Package.resolved` revision |

### Option B: Open Package.swift

Double-click `Package.swift` to open in Xcode. This builds the library
target (everything except `HomeHubApp.swift`) and lets you run tests.
To run the app itself, use Option A.

`Package.swift` does **not** include `llama.xcframework`; it is for tests
and CI only. Swift packages cannot embed pre-built xcframeworks.

### Running tests

```bash
make test
# or in Xcode: Cmd+U
```

### Smoke-checking portability

```bash
make check   # validates project.yml + greps for hardcoded paths, verifies key files exist
make ci      # same set of guardrails CI runs (no Xcode required)
```

`make check` runs both layers:

1. `scripts/validate-project-spec.py` — parses `project.yml`, `Package.swift`,
   `project.pbxproj`, `Package.resolved` and cross-checks them. Catches:
   duplicate YAML keys, duplicate package URLs, intra-target duplicate
   dependencies, version drift between any two sources of truth, missing
   `import` ↔ `product:` declarations.
2. `scripts/check-clean-build.sh` — repository hygiene checks: hardcoded
   `/Users/...` paths, missing required files, tracked `xcuserdata`/`.DS_Store`
   leakage, missing shared schemes, dangling AppIcon references, hardcoded
   `DEVELOPMENT_TEAM`.

The same script runs in CI on every push (`.github/workflows/validate-spec.yml`)
on Ubuntu — no Xcode needed.

## Sources of truth (what is and isn't authoritative)

| Artefact | Source of truth? | Edit by hand? | Regenerated by |
|----------|-----------------|---------------|----------------|
| `project.yml` | ✅ yes | ✅ yes | — |
| `Package.swift` | ✅ yes (CI/`swift build` only) | ✅ yes | — |
| `HomeHub.xcodeproj/project.pbxproj` | ❌ no | ❌ never | `xcodegen generate` |
| `HomeHub.xcodeproj/xcshareddata/xcschemes/*.xcscheme` | ❌ no | ❌ never | `xcodegen generate` |
| `Package.resolved` (root) | ❌ no | ❌ never | `xcodebuild -resolvePackageDependencies` then `make sync-resolved` |
| `…/xcshareddata/swiftpm/Package.resolved` | ❌ no | ❌ never | Xcode (Package > Resolve Package Dependencies) |

If `project.yml` and `Package.swift` ever disagree, fix `project.yml` first
and mirror the change to `Package.swift`. The validator will tell you exactly
which line drifted.

## Clean checkout — sanity ladder

If something goes wrong after a fresh clone or a tricky merge, work through
these steps in order and stop at the first one that reproduces the issue:

```bash
git clone https://github.com/Keksiczek/ios-home-hub
cd ios-home-hub

# 1. Spec is structurally sound (works on Linux too — no Xcode required)
make ci

# 2. Sources of truth are in sync
make generate                     # regenerates project.pbxproj from project.yml
git diff --quiet HomeHub.xcodeproj/project.pbxproj || \
  echo "pbxproj changed — commit the regeneration"

# 3. Packages resolve against the committed lockfile
make resolve

# 4. App target compiles (needs llama.xcframework sibling and macOS+Xcode)
make build
```

If `make ci` passes but `make build` fails, the root cause is almost always
either (a) `llama.xcframework` is not placed as a sibling of the repo, or
(b) Xcode's local SourcePackages cache is stale — see the table below.

## Known failure modes — quick diagnosis

| Symptom | Almost certainly caused by | Fix |
|---------|---------------------------|-----|
| `Unable to find module dependency: 'TensorUtils'` | A WhisperKit version older than 0.11.0 was resolved (often via a duplicate YAML key in `project.yml` that silently downgraded the pin). | `make validate` — it flags duplicate keys and version drift. Then re-pin to `from: 0.11.0` and `make sync-resolved`. |
| `Missing package product 'Hub'` / `'Tokenizers'` | `project.yml` or `Package.swift` references `product: Hub` or `product: Tokenizers` — those are internal targets, not exported library products. The only exported product is `Transformers`. | Make sure `project.yml` has `product: Transformers` under the HomeHub target and `Package.swift` uses `.product(name: "Transformers", package: "swift-transformers")`. Run `make verify-transformers` to verify. |
| `xcodebuild: error: The project ... does not contain a scheme named 'HomeHub'` | The committed shared scheme is missing. | Check `HomeHub.xcodeproj/xcshareddata/xcschemes/HomeHub.xcscheme` exists. If not, `make generate` will recreate it. |
| `error: 'AppIcon' image asset is missing` warning on every build | `Assets.xcassets/AppIcon.appiconset/Contents.json` references a file that doesn't exist. | The set is intentionally empty in this repo. Drop a real 1024×1024 PNG into the appiconset and add `"filename": "<name>.png"` back to `Contents.json`. |
| Local diff in `project.pbxproj` you didn't make | Either (a) you opened the project in Xcode without running `xcodegen generate` first, or (b) someone hand-edited it. | Run `make generate` to bring it back to canonical form, then commit. |
| `xcodebuild: error: code signing failed: no team selected` | The repo intentionally ships without a `DEVELOPMENT_TEAM`. | Set your team in *Signing & Capabilities* in Xcode, or override `DEVELOPMENT_TEAM` via a local `.xcconfig` not committed to git. |
| Diff includes `xcuserdata/` or `.DS_Store` | Someone re-added them after the cleanup. | `git rm --cached <path>`. Both are in `.gitignore` — they should never reappear. |
| Package.resolved pins differ between the two locations | Manual edit / Xcode resolved against a different lockfile. | `make sync-resolved` then commit both. The smoke-test verifies SHA-256 identity. |
| `'llama.h' file not found` | The bridging header tried to include `<llama.h>` but the framework isn't on the header search path. | Default builds should NOT include `<llama.h>` — the header is wrapped in `#ifdef HOMEHUB_LLAMA_RUNTIME`. If you see this, you set the Swift flag without setting the matching `GCC_PREPROCESSOR_DEFINITIONS` (or vice versa). `make ci` flags this. |
| `Model 'X' is a GGUF / llama.cpp model, but this build ships with the MLX-only runtime` | You picked a GGUF catalog entry without opting in to llama.cpp. | Either pick an MLX entry (`backend: .mlx`) or follow the [llama.cpp opt-in](#optional-llamacpp-opt-in) procedure. |
| `Undefined symbol: _llama_*` at link time | Swift sources call `llama_*` but the framework wasn't linked. | Same as above — the flag must be set on both sides. The bridging header AND the framework dep + search paths must be uncommented in `project.yml`. |

### Diagnosing why a model didn't load (in-app)

Open `Settings → Developer Diagnostics`. The **Build Configuration** section
shows:
- **Primary runtime** — always "MLX".
- **Available backends** — the comma-separated list of linked backends
  (e.g. `MLX-only (llama.cpp opt-in disabled)` or
  `MLX (default) + llama.cpp opt-in`).
- **Active runtime** — the identifier of whatever the app is currently
  routing through (`router`, `mlx`, `llama.cpp`, or `mock`).

If a load failed, the failure reason is shown directly under the runtime
state with the same actionable copy as the error toast. For GGUF entries
on an MLX-only build, this is always: *"…je GGUF / llama.cpp model. Tento
build podporuje pouze MLX. Pro načtení zapni `HOMEHUB_LLAMA_RUNTIME` a
přidej `llama.xcframework`. Viz README → Optional: llama.cpp opt-in."*

## Runtime backends — MLX is primary, llama.cpp is opt-in

**MLX is the primary on-device runtime.** It uses Apple's MLX framework
(`mlx-swift` + `mlx-swift-lm`, resolved through SPM) and Metal compute
shaders directly, with no native binary dependency. The default build runs
out-of-the-box on a fresh clone — no `llama.xcframework` on disk, no
opt-in flag, no manual steps. Onboarding selects an MLX model by default,
the catalog ships MLX entries marked usable on iPhone, and runtime errors
point users back to MLX paths first.

`LlamaCppRuntime` is the **secondary, opt-in path** behind the
`HOMEHUB_LLAMA_RUNTIME` compile flag. With the flag off (the default):
- The bridging header skips `<llama.h>`.
- `LlamaContextHandle` / `LlamaCppRuntime` / `LlamaRuntimeActor` Swift
  sources compile to empty TUs via `#if HOMEHUB_LLAMA_RUNTIME`.
- `RoutingRuntime` rejects `.llamaCpp` models with
  `RuntimeError.backendUnavailable(...)` carrying actionable copy
  ("requires HOMEHUB_LLAMA_RUNTIME and llama.xcframework").
- The catalog still lists GGUF entries (so users see what the opt-in
  unlocks), but every UI surface that could let them pick one — the
  onboarding picker, the Models tab Load button, the Add-from-URL sheet —
  shows a "needs opt-in" hint and gates the action.

### Format / backend / build-support matrix

| Model format | Runtime backend | Default build | `HOMEHUB_LLAMA_RUNTIME` build | Where it comes from |
|--------------|-----------------|---------------|--------------------------------|---------------------|
| **MLX** | `MLXRuntime` | ✅ Loads + runs | ✅ Loads + runs | `mlx-community/*` repos on Hugging Face |
| **GGUF** | `LlamaCppRuntime` | ⛔ Visible in catalog with "Requires opt-in" hint; load is gated | ✅ Loads + runs (needs `llama.xcframework`) | `bartowski/*` and similar GGUF repos |
| **User-added (Add from URL)** | Always `LlamaCppRuntime` (`.gguf` only) | ⛔ Sheet shows a notice that imports won't load | ✅ Imported and loadable | Direct `.gguf` URL pasted by the user |

**Single source of truth.** UI gating queries
`RuntimeBackendAvailability.isAvailable(_:)` (in `LocalModel.swift`) via
the convenience accessor `LocalModel.isUsableInThisBuild`. Runtime gating
goes through `RoutingRuntime`. Both produce identical wording so the
diagnostics screen, error toasts, and onboarding hints stay in lockstep.

### What works out of the box

On a clean MLX-default checkout you can:

- ✅ Open the app and run onboarding without touching any flags.
- ✅ Pick the recommended starter (an MLX model marked iPhone-safe).
- ✅ Download / load / chat / unload, with progress reported from the Hub
  downloader and Metal compile phases.
- ✅ See in `Settings → Developer Diagnostics` exactly which backends are
  linked into the build and what the active runtime is.

What you can't do without opting in to llama.cpp:

- ❌ Load curated GGUF entries (visible but gated with a clear hint).
- ❌ Import GGUF files via "Add from URL" (sheet shows a notice; the
  download still works for completeness, but loading throws
  `RuntimeError.backendUnavailable`).

### Optional: llama.cpp opt-in

Re-enabling llama.cpp is a one-time, three-step procedure:

1. **Build `llama.xcframework`** (see [the build script below](#1-build-the-xcframework)) and place it as a sibling of the repo root.
2. **Edit `project.yml`** — uncomment every block tagged `[llama.cpp opt-in]`:
   - The `framework: ../llama.xcframework` dependency and its five system frameworks.
   - `FRAMEWORK_SEARCH_PATHS`, `HEADER_SEARCH_PATHS`, `OTHER_LDFLAGS`.
   - `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `GCC_PREPROCESSOR_DEFINITIONS` (both must be set together — the validator fails the build if only one is set).
3. **Run `make generate`** to regenerate the pbxproj, then `make ci` to verify the bridging header, Swift sources and project.yml all agree.

`make ci` will fail-fast if you set the flag in only one place — it cross-checks `project.yml`, the bridging header, every llama Swift source and the test file.

### Building the xcframework

Only relevant if you opted in above.

### 1. Build the xcframework

```bash
# Clone llama.cpp
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp

# Build for iOS with Metal
cmake -B build-ios \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DGGML_METAL=ON \
  -DBUILD_SHARED_LIBS=OFF

cmake --build build-ios --config Release

# Create xcframework from the static libraries
# (see llama.cpp docs for exact steps)
```

### 2. Place the xcframework

Put the built `llama.xcframework` **one directory above the repo root**
(sibling layout described in the prerequisites above). `project.yml`
references it as `../llama.xcframework` relative to the project file
once you uncomment the `[llama.cpp opt-in]` blocks.

### 3. Enable the runtime

Uncomment every block tagged `[llama.cpp opt-in]` in `project.yml`:
the framework dependency, the framework / header search paths, and the
compile flag pair (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` AND
`GCC_PREPROCESSOR_DEFINITIONS`). Run `make generate` to regenerate the
pbxproj, then `make ci` — the validator confirms the bridging header,
Swift sources and project.yml all agree on the flag.

### 4. Verify download URLs

The download URLs in `ModelCatalogService.swift` point to real Hugging
Face GGUF endpoints. The `URLSession` implementation handles:
- **Wi-Fi-only** via `allowsCellularAccess = false`
- **Resume on interruption** — resume data stored in UserDefaults, picked up
  automatically when the user retries a failed download
- **SHA-256 verification** — populate `sha256` on each `LocalModel` after
  verifying a known-good download to enable integrity checks

## RAM guidelines

| Model | Size on disk | RAM needed | Recommended device |
|-------|-------------|------------|-------------------|
| Llama 3.2 3B Q4_K_M | ~2.1 GB | ~3.5 GB | iPhone 16 Pro, iPad M-series |
| Phi 3.5 Mini Q4_K_M | ~2.4 GB | ~4.0 GB | iPhone 16 Pro, iPad M-series |
| Qwen 2.5 3B Q5_K_M | ~2.5 GB | ~4.2 GB | iPhone 16 Pro, iPad M-series |
| Llama 3.1 8B Q4_K_M | ~4.8 GB | ~7.0 GB | iPad M-series only |

The app automatically unloads the model on background transition and
memory pressure to avoid OOM termination by the OS.

## License

See individual model licenses in the catalog. The app code itself is
not yet published under a specific license.
