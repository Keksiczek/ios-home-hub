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

- **LlamaContextHandle** — the C++ bridge (`load`, `stream`, `close`) is fully
  implemented behind `#if HOMEHUB_REAL_RUNTIME`. When the flag is not set the
  app uses `MockLocalRuntime` which streams canned responses without touching
  any model file. Set `HOMEHUB_REAL_RUNTIME` and link the xcframework to use
  real inference.
- **Model downloads** — real `URLSession` implementation behind
  `HOMEHUB_REAL_RUNTIME`: Wi-Fi-only, resume data on interruption, SHA-256
  verification. Development builds use a simulated progress loop.
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

- **Runtime abstraction**: `LocalLLMRuntime` protocol → `LlamaCppRuntime`
  (production) or `MockLocalRuntime` (development). Selected at compile time
  via the `HOMEHUB_REAL_RUNTIME` flag.
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
| llama.xcframework | built from llama.cpp | see below |

`llama.xcframework` must be placed as a **sibling of the repo root**:

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

2. **Validate** — run `make validate` before doing anything else.  This catches
   duplicate YAML keys and broken package references before XcodeGen silently
   swallows them.

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

#### Version constraint rationale

| Package | Constraint | Reason |
|---------|-----------|--------|
| `WhisperKit` | `from: 0.11.0` | 0.9.x imports `TensorUtils` as a standalone module that was removed from swift-transformers in 0.1.x |
| `SwiftTransformers` | `from: 0.1.14` | First release where `Hub` and `Tokenizers` are stable products; `TensorUtils` is not a standalone import |
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
make check   # greps for hardcoded paths, verifies key files exist
```

## Integrating the real llama.cpp runtime

The app is designed so the real C++ inference engine can be plugged in
with minimal changes.

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
(sibling layout described in the prerequisites above).  `project.yml`
references it as `../llama.xcframework` relative to the project file —
this is already wired; no drag-and-drop needed.

### 3. Enable the real runtime

`HOMEHUB_REAL_RUNTIME` is set by default in `project.yml`
(`SWIFT_ACTIVE_COMPILATION_CONDITIONS`).  No manual toggle needed.

### 4. Verify download URLs

The download URLs in `ModelCatalogService.swift` already point to real
Hugging Face GGUF endpoints. The real `URLSession` implementation (behind
`HOMEHUB_REAL_RUNTIME`) handles:
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
