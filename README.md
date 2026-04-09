# HomeHub

A private, offline-first personal AI assistant for iPhone and iPad.
Local LLM inference, personal memory, simple onboarding, and a clean
native UI. No cloud, no accounts, no data leaving the device.

> **Status**: product design + Swift/SwiftUI skeleton.
> Drop the `HomeHub/` folder into a new iOS app target in Xcode
> (iOS 17+/iPadOS 17+, Swift 5.10+).

## Target devices

- iPhone 16 Pro (8 GB RAM, Neural Engine + A18 Pro)
- iPad with M-series chip (8–16 GB RAM)

## Architecture at a glance

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
│  Runtime     │  Extraction │  (JSON v1)  │
└──────────────┴─────────────┴─────────────┘
```

- **Runtime abstraction**: `LocalLLMRuntime` protocol with a
  `LlamaCppRuntime` implementation targeting a llama.cpp xcframework
  with Metal backend. `MockLocalRuntime` is used for previews/tests.
- **Personalization**: a `UserProfile` + `AssistantProfile` are
  assembled together with selected `MemoryFact`s and recent messages
  into a `PromptContextPackage` by `PromptAssemblyService`.
- **Memory**: opt-in. Extraction runs heuristically in v1 and is
  designed to later switch to an on-device structured extraction
  pass. Every fact is user-editable and deletable.
- **Persistence**: JSON files under Application Support in v1
  (`FileStore`), pluggable behind the `Store` protocol so SwiftData
  can take over later without touching service code.

## Folder layout

```
HomeHub/
├── App/              // entry point, container, root, tabs
├── DesignSystem/     // theme, buttons, cards, empty states
├── Features/
│   ├── Onboarding/   // 5-step onboarding flow
│   ├── Chat/         // chat list + detail + composer
│   ├── Memory/       // facts browser + candidates
│   ├── Models/       // model catalog + download states
│   └── Settings/     // personalization + privacy controls
├── Models/           // domain entities
├── Runtime/          // LocalLLMRuntime protocol + impls
├── Persistence/      // Store protocol + FileStore
├── Services/         // RuntimeManager, Conversation, Memory, ...
└── PreviewContent/   // sample data for SwiftUI previews
```

See the individual source files for documented responsibilities.
