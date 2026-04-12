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

### Option A: XcodeGen (recommended)

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate the Xcode project
cd ios-home-hub
xcodegen generate

# Open in Xcode
open HomeHub.xcodeproj
```

Select an iOS 17+ simulator or device, then **Cmd+R** to build and run.

### Option B: Open Package.swift

Double-click `Package.swift` to open in Xcode. This builds the library
target (everything except `HomeHubApp.swift`) and lets you run tests.
To run the app itself, use Option A or C.

### Option C: Manual Xcode project

1. Open Xcode → File → New → Project → iOS App (SwiftUI, Swift).
2. Set deployment target to iOS 17.0.
3. Delete the auto-generated `ContentView.swift` and app entry file.
4. Drag the `HomeHub/` folder into the project navigator (Create groups,
   Add to target: HomeHub).
5. Drag the `HomeHubTests/` folder and add to the test target.
6. Build (**Cmd+B**) — it should compile with zero errors.
7. Run (**Cmd+R**) on an iOS 17 simulator.

### Running tests

In Xcode: **Cmd+U** or Product → Test. All 8 test files should pass.

## Integrating the real llama.cpp runtime

The app is designed so the real C++ inference engine can be plugged in
with minimal changes:

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

### 2. Add to the Xcode project

- Drag `llama.xcframework` into the project under
  *Frameworks, Libraries, and Embedded Content*.
- Create a bridging header or a separate SPM target that imports `llama.h`.

### 3. Enable the real runtime

Add `HOMEHUB_REAL_RUNTIME` to **Swift Active Compilation Conditions** in
your Xcode build settings (or uncomment the line in `project.yml`).
This switches `AppContainer.live()` from `MockLocalRuntime` to
`LlamaCppRuntime`.

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
