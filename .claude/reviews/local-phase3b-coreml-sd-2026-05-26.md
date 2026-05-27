# Local Review: Phase 3b — Core ML Stable Diffusion Runtime

**Reviewed:** 2026-05-26
**Scope:** Replace `StubImageGenerationRuntime` with real Core ML SD via Apple's
`StableDiffusionPipeline`. Carry-over fixes M1 (image timeout) and M2
(explicit `cancel()` API). Catalog entry for SD 2.1 base palettized.
**Focus:** Sendable correctness under Swift 6 strict concurrency, build hygiene
across enum extensions, cancellation reaching synchronous Core ML predicts,
SPM fork plumbing.
**Decision:** APPROVE with one HIGH carry-over (model-download flow) and two
MEDIUM follow-ups.

## Summary

Build green (`xcodebuild ... build` succeeds; warnings only in pre-existing
files unrelated to this change). The protocol surface from Phase 3a is
unchanged — the stub still ships and is the test substitute; the real Core ML
runtime drops in via `AppContainer` so all chat plumbing works identically.

Notable design decisions:

1. **Fork over vendor.** Apple's `ml-stable-diffusion` Package.swift pins
   `swift-transformers` to `.exact("0.1.8")`; HomeHub already uses `0.1.14`
   transitively via WhisperKit + mlx-swift-lm. After verifying the upstream
   directory is 28+3 files (~110 KB Swift), forking and loosening the one
   pin line to `"0.1.8"..<"0.2.0"` proved smaller than vendoring (single-line
   diff vs. ~17 files of source attribution + future merge work).
2. **PipelineBox / `@unchecked Sendable`.** `StableDiffusionPipeline` isn't
   Sendable (owns mutable Core ML model contexts). It crosses three isolation
   boundaries in our code (detached load Task → actor → detached generate
   Task), so we wrap it in a final class that's `@unchecked Sendable`.
   Safety is guaranteed by `ConversationService` serialising image turns —
   the wrapper is documented inline.
3. **Nonisolated atomic cancellation flag.** The progress handler runs on
   SD's compute thread, NOT inside the actor. An `actor`-based flag would
   require an `await` inside the handler, which (a) the autoclosure of `||`
   can't accept and (b) would re-enter the cooperative pool from Core ML's
   synchronous predict — recipe for stalls. `OSAllocatedUnfairLock<Bool>`
   gives O(ns) polling with no actor hop.

---

## Findings

### CRITICAL

None.

### HIGH

**[H1] Download path is not wired for SD bundles.**
`HomeHub/Runtime/CoreMLStableDiffusionRuntime.swift:131-139`,
`HomeHub/Services/ModelDownloadService.swift` (no change)

The catalog entry `coreml-sd-2-1-base-palettized` declares a HuggingFace
`downloadURL`, but `ModelDownloadService` has special-cased paths for
`.gguf` (single file) and `.mlx` (HF snapshot via swift-transformers' Hub).
SD bundles are a third shape: a tree of `.mlmodelc` directories +
`vocab.json` + `merges.txt`, ~10–20 files spanning ~1.6 GB.

Right now `CoreMLStableDiffusionRuntime.load(modelID:)` will throw
"Resources pro model '…' nejsou nainstalovány" until the user manually drops
the bundle into `Application Support/Models/coreml-sd/<id>/` (sideload).

**Action before user-facing release:** extend `ModelDownloadService` to
handle `.coreMLPackage` format — enumerate the HF repo's
`split_einsum_v2/` subdirectory and snapshot each file individually. This
should live in a dedicated `Phase 3c` task.

### MEDIUM

**[M1] Cancellation poll latency on long denoise steps.**
`HomeHub/Runtime/CoreMLStableDiffusionRuntime.swift:225-241`

The progress handler fires once per denoise step. For SD 2.1 base at 20
steps that's ~1–2 s between polls — fine for user UX. But SDXL or Flux
variants (not in v1) can land 4–8 s per step, which would noticeably
delay a Stop tap. Documenting here so a future SDXL entry adds an internal
`async let` cancel-checker if needed. No action for v1.

**[M2] Static error strings are Czech-only.**
`HomeHub/Runtime/CoreMLStableDiffusionRuntime.swift:137, 270, 278`

User-facing copy in `CoreMLStableDiffusionRuntime` is hardcoded Czech
("Resources pro model '…' nejsou nainstalovány", "Pipeline vrátila nil
obrázek"). Consistent with the rest of HomeHub (`ImageGenerationError`
case strings are Czech too), but worth flagging for any future i18n
sweep — these would need to move through `Localizable.strings`.

### LOW

**[L1] `StableDiffusionPipeline.Configuration` is initialised from defaults
then mutated.**
`HomeHub/Runtime/CoreMLStableDiffusionRuntime.swift:218-229`

```swift
var config = StableDiffusionPipeline.Configuration(prompt: parameters.prompt)
config.stepCount = max(parameters.steps, 1)
config.guidanceScale = Float(parameters.guidanceScale)
// ...
```

Five `var` writes after the init. Per
`rules/ecc/swift/coding-style.md` — "Prefer `let`" — this could be a
builder helper. Trade-off: SD's `Configuration` is a `struct` with `var`
fields exposed by the upstream API, so we can't init it with all fields
without dropping into the no-argument initializer path. Acceptable as-is;
the alternative is heavier.

**[L2] Deterministic seed via FNV-1a may collide across long prompts.**
`HomeHub/Runtime/CoreMLStableDiffusionRuntime.swift:305-313`

FNV-1a is fast but not collision-resistant for long inputs. Two
1,000-character prompts could in principle hash to the same UInt32 seed,
producing the same image despite differing text. For v1's typical
20-character prompts this is fine; if users start pasting essay-length
prompts, swap to SipHash via `Hasher`.

**[L3] Stub `cancellationRequested` reset path doesn't cover failure exits.**
`HomeHub/Runtime/ImageGenerationRuntime.swift:225-227, 244-246`

`resetCancel()` runs at the top of `generate(...)` so a previous cancel
doesn't poison the next run. But if `renderGradient` returns nil
(line 244), the flag is not reset before the error finishes — and on
the NEXT generate it WILL be reset, so this is actually fine. Worth
documenting that the next call's entry reset is the source of truth.

---

## Concurrency / Sendable

✅ `CoreMLStableDiffusionRuntime` is a `final class` conforming to
   `ImageGenerationRuntime: Sendable`. All stored properties are
   `Sendable`: the `State` actor, the `OSAllocatedUnfairLock<Bool>`
   flag, the `@Sendable` closure resolver, and the `Logger`.
✅ `PipelineBox: @unchecked Sendable` is the ONE escape hatch.
   Documented with the invariant that makes it safe (serial usage
   via ConversationService gate).
✅ Progress handler does NOT hop actors. Both cancel signals
   (`Task.isCancelled`, `cancellationFlag.withLock`) are nonisolated
   atomic reads.
✅ `continuation.yield(...)` is safe from any thread (documented in
   Apple's AsyncThrowingStream docs).
✅ `withTaskCancellationHandler` in `ConversationService.performImageGeneration`
   bridges parent-Task cancel → runtime `cancel()`.

## Build hygiene

Adding `.coreML` to `ModelBackend` and `.coreMLPackage` to `ModelFormat`
forced exhaustive-switch fixes in 7 sites:

- `OnboardingModelPickerView.swift` (2 switches)
- `ModelsView.swift` (2 switches)
- `ModelInfoSheet.swift` (1 switch)
- `RoutingRuntime.swift` (1 switch — throws `backendUnavailable` because
  SD doesn't participate in LLM routing)
- `RuntimeManager.swift` (1 switch — log-only)
- `LocalLLMRuntime.swift` (1 switch — error string)
- `LocalModel.swift` (1 switch — `unavailableReason`)

Plus one pre-existing build break surfaced and fixed: `import MLXVLM` in
`MLXRuntime.swift` had no matching product dependency in `project.yml` or
`Package.swift`. The previous PR's incremental Xcode build resolved it from
cache; clean SPM didn't. Added `MLXVLM` to both manifests.

## Cancellation contract

| Channel | Stub | Core ML SD |
|---|---|---|
| `Task.isCancelled` | Polled between progress ticks | Polled at start of progress handler |
| Explicit `cancel()` flag | Actor `cancellationRequested` | `OSAllocatedUnfairLock<Bool>` |
| Continuation `.onTermination` | n/a (stub finishes fast) | Sets flag + cancels detached Task |
| Reset on entry | `state.resetCancel()` | `cancellationFlag.withLock { $0 = false }` |

Both runtimes surface cancelled runs as `ImageGenerationError.cancelled` →
Czech "Generování bylo zrušeno." in chat.

## Tests

| Test class | Cases | Notes |
|---|---|---|
| `ImagePromptCommandTests` | 12 | Happy paths, whitespace, lookalikes (`/imagery`), case sensitivity, empty body, missing slash |
| `StubImageGenerationRuntimeTests` | 5 | Determinism (same prompt → same PNG), lifecycle (load/unload), explicit cancel surfaces `.cancelled`, cancel flag resets between runs |

Both classes use XCTest to match the project's existing convention (the
Swift Testing migration is a separate workstream and out of scope here).
Tests for the real `CoreMLStableDiffusionRuntime` are deliberately
omitted — they would require a multi-GB SD model download per CI run,
which is infeasible at this layer.

## Files Reviewed

### New
- `HomeHub/Runtime/CoreMLStableDiffusionRuntime.swift` — 313 LOC
- `HomeHubTests/ImagePromptCommandTests.swift` — 97 LOC
- `HomeHubTests/StubImageGenerationRuntimeTests.swift` — 145 LOC

### Modified
- `HomeHub/Runtime/ImageGenerationRuntime.swift` — protocol +
  `cancel()`, stub gains dual-channel cancellation + actor-isolated flag
- `HomeHub/Models/AppSettings.swift` — `imageGenerationTimeoutSeconds: Int = 240`
- `HomeHub/Services/ConversationService.swift` — image-aware watchdog +
  `withTaskCancellationHandler` wrapping the for-await
- `HomeHub/Models/LocalModel.swift` — `ModelBackend.coreML`, `ModelFormat.coreMLPackage`
- `HomeHub/Services/ModelCatalogService.swift` — SD 2.1 base palettized entry
- `HomeHub/App/AppContainer.swift` — default `imageRuntime = CoreMLStableDiffusionRuntime()`
- `project.yml` + `Package.swift` — fork dep + MLXVLM product (pre-existing miss)
- 5 view / runtime files — `.coreML` switch cases

---

## Recommended action order

1. **H1 (download path)** — file as Phase 3c task, do NOT block this PR
2. **L2 (FNV-1a vs SipHash)** — defer to a future "long prompts" sweep
3. **L1 (Configuration builder)** — defer; not worth the upstream-API friction
4. **L3 (cancel reset documentation)** — add a one-line comment
5. **M2 (i18n)** — track with the rest of the app

Everything HIGH-or-above is documented. Merge.

---

# Batch 2 — Polish + L2/L3 carry-overs (2026-05-26)

Follow-up pass after the initial batch landed. Build green, test build
green, no new warnings on touched files.

## What changed

### Surfaced progress in chat
`ConversationService.performImageGeneration` previously consumed
`.progress` events with `continue` — users saw a static "Generuju…"
for the full 20-90 s diffusion run. Now the assistant message content
flips to `"Generuju obrázek… <step>/<total>"` each step boundary,
throttled to one visible UI refresh per 250 ms (so SDXL-class
runtimes emitting events faster than the refresh budget don't thrash
SwiftUI). The status stays `.streaming` — only `.finished` flips to
`.complete` and replaces text with the duration caption + PNG
artifact.

### Slash-command flags (`--steps`, `--guidance`)
New `ImageCommand` struct + `parseImageCommand(_:)` parser. Power
users can now type:
```
/image --steps 30 --guidance 9.0 a moonlit fox
```
to override the SD defaults (20 steps / 7.5 guidance). The eater
chews tokens left-to-right and stops at the first non-flag token,
treating everything from that point as the prompt body. Malformed
or out-of-range values (`--steps abc`, `--steps 200`) bail the
eater and roll the flag back into the prompt — protects users from
silent magic-number clamps and lets them ask the LLM about literal
flag-shaped text.

`parseImagePromptCommand(_:)` survives as a thin wrapper returning
only the prompt body, for callers that only care about the branching
decision (the watchdog-timeout picker on line ~1001).

### CryptoKit SHA256 seed
`CoreMLStableDiffusionRuntime.deterministicSeed(for:)` switched from
hand-rolled FNV-1a to `SHA256.hash(data:)` + first 4 bytes
big-endian → `UInt32`. Three wins:
1. **Cross-process determinism.** Swift's `Hasher` is per-launch
   randomised; not suitable. SHA256 is a standardised primitive.
2. **Collision resistance for essay-length prompts.** L2 from the
   prior review.
3. **No magic constants in source.** FNV-1a needs the offset basis
   and prime to be repeated at every caller wanting to reproduce
   the seed.

Made the method `internal` (was `private`) so the test target can
pin the determinism contract without a full Core ML round-trip.

### New tests
- **`CoreMLStableDiffusionRuntimeTests`** (9 cases) — resolver
  injection, missing-resources error path, generate-without-load
  surfaces `.modelNotLoaded`/`.notImplemented`, deterministic seed
  contract (stability, distribution, empty + long-prompt edges,
  purity stress), default URL convention.
- **`ImagePromptCommandTests`** — 9 new cases for the flag parser
  on top of the original 12 (total 21).

`ResolverObserver` is a `@unchecked Sendable` class — the resolver
closure is `@Sendable` and can't capture mutable `var` locals under
strict concurrency. Documented inline.

### L3 doc — cancel reset on failure exit
One-line comment on `StubImageGenerationRuntime.renderGradient` nil
fall-through clarifying that the next `generate(...)` entry's
`resetCancel()` is the source of truth — failure-path reset would
be defensive but redundant.

## Files changed in batch 2

### New
- `HomeHubTests/CoreMLStableDiffusionRuntimeTests.swift` — 145 LOC

### Modified
- `HomeHub/Services/ConversationService.swift` — progress emit, new
  `ImageCommand` struct + `parseImageCommand`, `performImageGeneration`
  takes `ImageCommand` instead of plain `String`
- `HomeHub/Runtime/CoreMLStableDiffusionRuntime.swift` — SHA256 seed,
  CryptoKit import, internal access on seed function
- `HomeHub/Runtime/ImageGenerationRuntime.swift` — L3 comment
- `HomeHubTests/ImagePromptCommandTests.swift` — +9 flag-parser tests

## Outstanding (unchanged from batch 1)

- **H1 — Download path for SD bundles.** Still requires
  `ModelDownloadService` extension for `.coreMLPackage` repo
  snapshots. Standalone Phase 3c task.
- **M2 — i18n sweep.** Czech strings remain hardcoded — out of scope.

## Build hygiene

| Check | Result |
|---|---|
| `xcodebuild build` (Debug, iphonesimulator) | ✅ Pass |
| `xcodebuild build-for-testing` | ✅ Pass |
| New warnings on touched files | 0 |
| `xcrun simctl list devices available` | No simulators installed; tests didn't execute, only built |

To actually run the test suite, install an iOS simulator runtime via
Xcode → Settings → Platforms.

---

# Batch 3 — UX-smoothness review + fixes (2026-05-26)

Architecture review surfaced three UX dead-ends in the model-routing
surface. All addressed in this batch.

## Friction findings (from `code-explorer` exploration)

1. **Silent image drop on text-only model.**
   `PromptAssemblyService:90-92` filters `userImages` to `nil` when the
   active model's profile lacks `.supportsVision`. The composer showed
   a small text hint but nothing blocked send — the user got an
   "answer" with no awareness the photo was never seen by the model.

2. **No auto-load of SD model on first `/image`.**
   `AppContainer` constructs `CoreMLStableDiffusionRuntime` but never
   calls `load(modelID:)`. First `/image PROMPT` of every app launch
   would fail with `.modelNotLoaded` and a cryptic "Resources pro
   model '…' nejsou nainstalovány" error.

3. **No actionable failure when no SD model installed.**
   Even after the auto-load lands, a fresh install with no SD model
   downloaded would hit the same cryptic error. No tap-through to
   the download flow.

## Search-offload analysis

User asked whether WebSearch should run through a smaller model. Mapped
the search path:

- `WebSearchService.search(query:)` runs synchronously before LLM
  inference (`ConversationService.performSend:1181-1194`)
- Result snippets land in `PromptContextPackage.fileExcerpts` as plain
  text — no separate processing model
- Same `runtime.generate(...)` handles the merged prompt

**Verdict: defer.** Adding a search-summarizer model would require
a 3-step load cycle (main → tiny → main, each 45-90 s cold) on an
8 GB iPhone — net latency WORSE than just running search results
through the main model. The only memory profile that benefits is
"keep both resident simultaneously", which exceeds budget. Reopen if
we ever land RAM headroom for two models (M-series iPad).

## What changed

### Vision soft-block in composer
`MessageComposerView` previously rendered a small grey hint when
`hasImageAttachment && !activeModelSupportsVision`. Replaced with:

1. **Amber warning tint** on the icon + text (was grey/secondary). Hard
   to miss now.
2. **Confirmation dialog on send.** Tapping send with image + text-only
   model surfaces a `.confirmationDialog` with two options:
   - "Pošli stejně (jen OCR text)" — proceed
   - "Zrušit" — keeps attachments staged so user can swap model and
     retry without re-picking photos

The dialog is the gate; the hint is the heads-up. Staged attachments
survive a cancel so model-swap-and-retry is cheap.

### Auto-load on first `/image`
`ConversationService.performImageGeneration` now checks
`await imageRuntime.loadedModelID == nil` at the top. If nothing is
loaded:

1. Query the catalog for installed `.coreMLPackage` models via the new
   `installedImageModelIDsProvider` closure (`@MainActor () -> [String]`)
2. If list is empty: write a localized actionable failure into the
   assistant placeholder ("Pro generování obrázků si nejdřív stáhni
   model. Otevři Nastavení → Modely…") and return
3. If list is non-empty: surface "Načítám model pro obrázky…" in the
   placeholder, call `imageRuntime.load(modelID: firstID)`
4. On load failure: write the underlying LocalizedError into the
   placeholder via the new `writeAssistantFailure(...)` helper

The closure stays in `AppContainer` and weakly captures the catalog so
the chat service has no direct catalog dependency.

### Reusable assistant-failure helper
Refactored failure-writing in `performImageGeneration` into
`writeAssistantFailure(conversationID:assistantIndex:message:previewIcon:)`.
Single place that:
- Mutates the assistant message content + status to `.failed`
- Persists via `store.save(message:)`
- Updates conversation preview + persists `store.save(conversation:)`

Previously this logic was duplicated; now the three failure exits
(no-model-installed, load-failed, generation-failed) all go through
the same write path.

## Files changed in batch 3

### Modified
- `HomeHub/Features/Chat/MessageComposerView.swift` — amber warning
  icon/text, `@State` for pending payload, `.confirmationDialog`
  modifier wrapping the soft-block send path
- `HomeHub/Services/ConversationService.swift` — auto-load logic,
  `installedImageModelIDsProvider` field + init param,
  `writeAssistantFailure` helper, three failure-exit refactors
- `HomeHub/App/AppContainer.swift` — wire closure that filters
  catalog → installed Core ML SD model IDs

## Outstanding (carry-forward)

- **H1 — Download path for SD bundles.** Still the biggest gap. Once
  this batch lands, fresh installs see the actionable
  "Stáhni SD model" copy — but the download path itself (multi-file
  HF snapshot for `.coreMLPackage`) is still Phase 3c.
- **Search-offload model.** Documented as "defer" above.
- **Per-conversation model selection.** `selectedModelID` remains
  global. Worth revisiting after H1 lands — separate "per-task
  default model" workstream.

## Build hygiene

| Check | Result |
|---|---|
| `xcodebuild build-for-testing` (Debug, iphonesimulator) | ✅ Pass |
| Errors | 0 |
| New warnings on touched files | 0 |


---

# Batch 4 — Apple Intelligence + UX chip suite (2026-05-27)

Driven by user observation of competing local-LLM apps shipping
zero-download Apple Intelligence, animated search chips, memory
transparency, and per-turn diagnostics. `code-explorer` agent mapped
the current model-switching / search / memory architecture in
parallel; surface the 3 friction points listed below.

## What changed

### A — Apple Intelligence integration
- **`HomeHub/Runtime/AppleFoundationModelsRuntime.swift`** (new) —
  LocalLLMRuntime conformance backed by `FoundationModels` framework.
  Per-conversation `LanguageModelSession` cache for prompt-prefill
  amortisation. `#if canImport(FoundationModels)` build gate + iOS-26
  `if #available` runtime gate; falls back to MLX cleanly on older
  builds/devices. Translates `SystemLanguageModel.Availability`
  unavailable reasons (deviceNotEligible, appleIntelligenceNotEnabled,
  modelNotReady) into Czech actionable error strings.
- `ModelBackend.appleFoundationModels` + `ModelFormat.builtIn` enum
  cases — 8 exhaustive-switch sites updated (RoutingRuntime,
  RuntimeManager, LocalLLMRuntime error string, ModelInfoSheet,
  ModelsView, OnboardingModelPickerView, LocalModel.unavailableReason).
- `RoutingRuntime` accepts optional `AppleFoundationModelsRuntime`;
  `AppContainer` instantiates it gated by
  `RuntimeBackendAvailability.appleFoundationModelsAvailable`.
- Catalog entry `apple-foundation-1` at the TOP of the curated
  list — `installState = .installed` synthetically, no downloadURL
  semantics (the runtime's `load()` does the real
  Apple-Intelligence-enabled check).
- `PipelineBox`-equivalent isn't needed: Apple's
  `LanguageModelSession.streamResponse(to:)` emits
  `ResponseStream<String>.Snapshot` which isn't Sendable — we use a
  generic `string<S>(from snapshot: S) -> String` helper rather than
  `any Sendable` so the for-await iteration stays within one actor.

### B — WebSearch / FetchPage rotating phase labels
- `ToolPresenter.Style` gains optional `streamingPhases: [String]?`.
  WebSearch cycles `Hledám na webu… → Čtu výsledky… → Shrnuju…`;
  FetchPage cycles `Stahuju HTML… → Čistím obsah… → Extrahuju text…`.
- New `RotatingPhaseLabel` view in `MessageBubbleView` — 1.6 s
  per-phase crossfade via `contentTransition(.opacity)`. Timer runs
  in `.task` so it stops when the bubble leaves the hierarchy.

### C — Memory transparency chips
- `Message.appliedMemoryFactIDs: [UUID]?` field. ConversationService
  stamps it before the agentic loop (after `relevantFacts(for:)`)
  with the fact IDs being injected into the prompt.
- `MessageBubbleView` resolves IDs back to `MemoryFact` via injected
  `MemoryService`; renders a `🧠 Použil X fakt` chip with proper
  Czech plural declension (1 → `fakt`, 2-4 → `fakta`, 5+ → `faktů`).
- Tap → bottom sheet with the live fact bodies + categories. Facts
  the user deleted since the turn drop out at resolve time — chip
  count and sheet stay consistent.

### D — Generation stats footer
- `Message.GenerationStats` value type (`tokensGenerated`,
  `tokensPerSecond`, `totalDurationMs`) decoded permissively for
  forward compat.
- `ConversationService` captures stats from
  `RuntimeEvent.finished(reason, stats)` — was previously discarded.
  Skipped for `.cancelled` (partial-generation numbers are
  misleading).
- `MessageBubbleView` renders `12 tok · 9.4 t/s · 1.3 s` footer
  under completed assistant messages with secondary tint.

### E — Follow-up suggestion chips
- 3 static heuristic prompts: `Vysvětli to detailněji`,
  `Shrň to do 3 bullet pointů`, `Co bys mi k tomu doporučil?`
- Render ONLY on the most recent completed (`.complete`, not
  `.length`-truncated) assistant message — gated by
  `showFollowUpSuggestions: Bool` from ChatDetailView.
- Tap → `onFollowUpTap(suggestion)` callback injects the text into
  the composer draft via `draft = suggestion`. User can edit before
  send — chips are starters, not auto-fire shortcuts.

## Files changed in batch 4

### New
- `HomeHub/Runtime/AppleFoundationModelsRuntime.swift` — 354 LOC

### Modified
- `HomeHub/Models/LocalModel.swift` — `appleFoundationModels` backend +
  `builtIn` format + 2 new switch arms in `unavailableReason` /
  `isAvailable`
- `HomeHub/Models/Message.swift` — `appliedMemoryFactIDs`,
  `generationStats` + `GenerationStats` value type
- `HomeHub/Runtime/RoutingRuntime.swift` — optional AFM dependency
  injection + `.appleFoundationModels` dispatch case
- `HomeHub/Runtime/LocalLLMRuntime.swift` — backend-unavailable Czech
  copy for AFM
- `HomeHub/Services/ConversationService.swift` — fact-ID stamping +
  stats capture from `.finished`
- `HomeHub/Services/ModelCatalogService.swift` — Apple Intelligence
  catalog entry at top of curated list
- `HomeHub/Services/RuntimeManager.swift` — `.builtIn` template-source
  log line
- `HomeHub/App/AppContainer.swift` — conditional AFM instantiation
- `HomeHub/Features/Chat/MessageBubbleView.swift` — memory chip,
  stats footer, follow-up suggestions, RotatingPhaseLabel
- `HomeHub/Features/Chat/ChatDetailView.swift` — follow-up wire-up
  (draft injection)
- `HomeHub/Features/Chat/ToolPresenter.swift` — `streamingPhases`
- `HomeHub/Features/Models/ModelInfoSheet.swift` — `.builtIn` arm
- `HomeHub/Features/Models/ModelsView.swift` — AFM badge tint
- `HomeHub/Features/Onboarding/OnboardingModelPickerView.swift` —
  AFM badge tint

## Build hygiene

| Check | Result |
|---|---|
| `xcodebuild build` | ✅ Pass |
| `xcodebuild build-for-testing` | ✅ Pass |
| New warnings on touched files | 0 |
| Architecture gates | `if #available(iOS 26, *)` + `#if canImport(FoundationModels)` on every AFM-specific call site |

## Outstanding

- **H1** (Phase 3c): SD bundle download path. Unchanged from earlier
  batches.
- **Search offload to smaller model**: examined, deferred. On 8 GB
  iPhone the 3× load cycle (main → tiny → main) is slower than
  letting the loaded model digest the search snippets directly.
  Worth reopening for M-series iPad where memory headroom permits
  keeping both resident.
- **i18n sweep**: all new strings remain Czech-only. Consistent with
  existing surface; future Localizable.strings migration is a
  separate workstream.

## Code-explorer agent findings

The architecture map (run before any edits) flagged three baseline
issues that batch 4 addresses directly:

| Pre-batch friction | Resolved by |
|---|---|
| Silent image drop on text-only model | Already fixed in batch 3 (`MessageComposerView` confirmation dialog) |
| No SD model picker / cryptic `modelNotLoaded` | Already fixed in batch 3 (auto-load + actionable failure) |
| No automatic per-task routing | Apple Intelligence catalog entry default — iOS 26+ users get instant TTFT without manual model picking |

Search-offload to smaller-model summarisation was considered and
deferred (see Outstanding above).

---

# Batch 5 — Auto-routing + batch-4 audit fixes (2026-05-27)

User feedback: a competing app auto-switches between three model tiers
based on task shape, with an experimental "fast helps smart" toggle.
Plus a request to verify the batch-4 UX additions actually work
end-to-end. We ran two parallel agents — `code-reviewer` audited the
batch-4 diff, `code-explorer` mapped the catalog for the auto-routing
design — and synthesised both into this batch.

## What changed

### Stage 1 — Batch-4 audit fixes
- **[HIGH] `_lastError` stale across turns** —
  `AppleFoundationModelsRuntime.runGeneration` now clears
  `_lastError = nil` at the success path entry. Mirrors MLX's
  contract; without this any prior turn's failure stayed visible
  through `lastGenerationError` indefinitely.
- **[HIGH] AFM session-rebuild corrupted role alternation** — the
  earlier draft looped `session.respond(to:)` over every prior
  `RuntimeMessage`, which fed past assistant outputs back to Apple
  as new USER turns. Removed the replay loop entirely; sessions
  now start fresh and rely on (a) the system prompt's embedded
  conversation summary, (b) session-cache reuse within a single
  conversation, (c) the current user turn going through
  `respond(to:)` as the only role-correct path. Rationale
  documented in the source.
- **[MED] `@EnvironmentObject MemoryService` crash** in
  `MessageBubbleView` — doc comment incorrectly claimed nil-safety.
  Updated to spell out the production injection points
  (`HomeHubApp.swift:20`, `MainTabView.swift:135`) and the preview
  requirement (`.environmentObject(AppContainer.preview().memoryService)`).
- **[MED] Follow-up chips bleeding onto `.length`-truncated replies**
  — `ChatDetailView` gating expanded with `!message.wasTruncatedByLength`
  so the "Pokračovat" affordance is exclusive with the chip strip.
- **[MED] `appliedMemoryFactIDs` persisted late** — moved the
  `messagesByConversation[...]` write + `store.save(...)` immediately
  after the stamp instead of waiting for the first token, so crash
  recovery doesn't lose the audit trail.
- **[LOW] `RotatingPhaseLabel.index` unbounded** — `index = (index + 1) % phases.count`.
- **[LOW] `string<S>(from:)` Mirror brittleness** — added a
  beta-tracker TODO so a future SDK rename doesn't silently corrupt
  responses.

### Stage 2 — Auto-routing
- **`AppSettings`** gained `routingPolicy: RoutingPolicy`,
  `fastModelID`, `balancedModelID`, `smartModelID`. All
  `decodeIfPresent`-safe; migration silent.
- **`RoutingPolicy` enum** — `.manual` (default, legacy behaviour) /
  `.automatic` (heuristic router) / `.experimental` (router +
  "fast helps smart" co-residency).
- **`ModelRouter`** — new MainActor service. Pure heuristic
  classifier (length, code markers, depth-marker phrases) → tier.
  Resolution honours user's explicit tier picks, Apple-Intelligence
  priority for FAST/BALANCED, smallest-fit-first inside the tier,
  device-class downgrade for iPad-only models, vision override for
  attached photos. `coResidentFastModelID` set only under
  `.experimental` + budget headroom.
- **`ConversationService`** auto-route hook — closure-injected
  `routePickProvider` consulted at turn-start when
  `routingPolicy != .manual`. Loads the picked model via
  `RuntimeManager.load(_:)` before LLM prompt assembly hits the
  runtime so prefill uses the right tokeniser.
- **`AppContainer`** wires the closure to a freshly-instantiated
  `ModelRouter`. Weak captures on catalog + settings keep the
  service-graph lifetime contract intact.
- **Settings UI** — new `routingSection` under "Generation Engine".
  Policy picker + three per-tier model pickers (disabled when
  `policy == .manual`). Help footer explains Apple Intelligence
  priority + Auto behaviour.

## Files changed in batch 5

### New
- `HomeHub/Services/ModelRouter.swift` — 305 LOC

### Modified
- `HomeHub/Models/AppSettings.swift` — 3 fields + `RoutingPolicy` enum
- `HomeHub/Services/ConversationService.swift` — closure field +
  auto-route block in `performSend`, persistence fix for
  `appliedMemoryFactIDs`
- `HomeHub/App/AppContainer.swift` — `routePickProvider` wire
- `HomeHub/Features/Settings/SettingsView.swift` — `routingSection`,
  `tierModelPicker`, `routingTierCandidates`
- `HomeHub/Runtime/AppleFoundationModelsRuntime.swift` — `_lastError`
  clear, session-rebuild simplified, Mirror TODO
- `HomeHub/Features/Chat/MessageBubbleView.swift` —
  `RotatingPhaseLabel` modulo, MemoryService env doc
- `HomeHub/Features/Chat/ChatDetailView.swift` — follow-up gating

## Build hygiene

| Check | Result |
|---|---|
| `xcodebuild build-for-testing` | ✅ Pass |
| `xcrun simctl list devices available` | None — tests build but don't execute on this machine |
| New warnings on touched files | 0 |
| Sendable / Swift 6 strict concurrency | All paths typed |
| Backwards-compat decoding | All new AppSettings fields are `decodeIfPresent` with defaults |

## Open follow-ups

- **"Fast helps smart" actually consuming `coResidentFastModelID`** —
  the router signals "OK to keep fast warm" but ConversationService
  doesn't yet pre-summarise search results / OCR text through the
  fast model. Next batch: thread the second runtime instance into
  `PromptAssemblyService` so `.experimental` policy compresses
  long `fileExcerpts` before they hit the smart model.
- **Manual override sticky after first auto-pick** — when the user
  toggles policy to `.automatic` mid-conversation, the next turn
  loads a router-picked model; subsequent turns might re-pick on
  every input. A small hysteresis ("once we've loaded model X, only
  swap if classify drops two tiers below X") would smooth this. v1
  is acceptable because the load watchdog avoids thrashing.
- **No router tests yet** — `ModelRouter.classify` is `nonisolated static`
  precisely so it's trivially testable. Skipped this batch to keep
  scope contained; a follow-up should add the standard parameterised
  test suite (greetings → fast, code → smart, etc.).

---

# Batch 6 — Concurrency hardening + UI nits (2026-05-27)

Spawned two parallel agents (`swift-reviewer` for concurrency,
`code-reviewer` for broad integration) on Stage 2 / batch 5 work.
swift-reviewer flagged a real data race risk in
`AppleFoundationModelsRuntime`; code-reviewer surfaced a `.disabled`
scope nit. Both addressed here.

## swift-reviewer findings

**[HIGH] AFM `@unchecked Sendable` with 5 mutable fields touched from
both `@MainActor` (observers) and cooperative-pool `Task` inside
`generate(...)`**. The "single-thread access enforced by RuntimeManager"
claim wasn't actually enforced — `RuntimeManager.operationTask`
serialises `load()` / `unload()` against each other but doesn't gate
observer reads of `lastGenerationError` / `isCurrentlyGenerating`
against writes in `runGeneration`.

**[HIGH] `_sessionsAny: Any?` had dual write paths** — raw
`_sessionsAny = nil` direct assignment vs. computed setter
`sessions.removeAll()`. Fragile under future edits.

**[LOW] `Mirror` reflection fallback** — already TODO'd.

## code-reviewer findings

**[MED] `send()` vs `sendAndWait()` contract asymmetry** — documented
in source as carry-over; UI paths are gated correctly, only
non-UI callers (widgets, voice) could fire turns with no model.
Accepted as-is.

**[LOW] `.disabled` scope on Picker only, not VStack** — only the
control greyed out; label + help stayed opaque. Fixed.

## Fixes applied

### 1. AFM state locked under `OSAllocatedUnfairLock<MutableState>`

Replaced 5 separate `private var` fields with a single
`MutableState` struct held in `OSAllocatedUnfairLock`. All reads
(`loadedModel`, `isCurrentlyGenerating`, `lastGenerationError`,
`activeSessionConversationID`) go through `lockedState.withLock { $0.field }`.
All writes (load/unload/runGeneration burst) wrap their mutations
in a single `withLock` block so observers never see a half-
unloaded runtime.

**Why a lock, not an actor.** The protocol surface
(`var loadedModel: LocalModel? { get }`) is synchronous + nonisolated.
Migrating to an actor would force `async` on every call site — far
wider surgery than the value of the change. `OSAllocatedUnfairLock`
gives O(ns) reads from any isolation context with identical
getter ergonomics.

### 2. `SessionBox: @unchecked Sendable` wrapper

`LanguageModelSession` isn't Sendable. Putting it directly into
`MutableState.sessionsAny: Any?` works (`@unchecked Sendable` on
the struct), but mutating the typed dictionary via a closure
captured by `OSAllocatedUnfairLock.withLock { ... }` (which is
`@Sendable`) tripped strict concurrency — the closure captured
non-Sendable `LanguageModelSession`. Solution mirrors
`CoreMLStableDiffusionRuntime.PipelineBox`: wrap each session in
a tiny `@unchecked Sendable` class, then the dictionary's value
type is Sendable and closures cross cleanly.

### 3. Session cache API now three narrow ops

Dropped the closure-based `mutateSessions(_:)` helper that had
the dual-write footgun. Replaced with three direct functions:
- `session(for conversationID:) -> LanguageModelSession?`
- `setSession(_:for:)`
- `removeSession(for:)`

Plus `clearSessionCache()` for the unload/background/trim paths.
Single source of truth; future edits can't accidentally bypass
the lock.

### 4. `tierModelPicker` `.disabled` moved to VStack

The whole row (label + control + help text) now greys out under
`.manual` policy. Matches iOS Settings convention.

### 5. ModelRouter classifier tests

New `HomeHubTests/ModelRouterClassifyTests.swift` — 12 cases
covering greetings → fast, code markers → smart, depth phrases
→ smart, length thresholds, vision attachment override, edge
cases (empty input, case-insensitive matches, marker boundary
regression).

## Files changed in batch 6

### New
- `HomeHubTests/ModelRouterClassifyTests.swift` — 149 LOC

### Modified
- `HomeHub/Runtime/AppleFoundationModelsRuntime.swift` — locked
  state refactor, `SessionBox` wrapper, narrow session API,
  cleaned orphaned brace block left over from earlier edit
- `HomeHub/Features/Settings/SettingsView.swift` — `.disabled`
  on VStack

## Build hygiene

| Check | Result |
|---|---|
| `xcodebuild build-for-testing` | ✅ Pass |
| New errors | 0 |
| New warnings on touched files | 0 |
| Sendable / Swift 6 strict concurrency | All paths typed |

## Open follow-ups (unchanged from batch 5)

- **Fast helps smart actually consuming `coResidentFastModelID`** —
  router signals "OK to keep fast warm" but ConversationService
  doesn't pre-summarise search results / OCR text through the
  fast model yet. Standalone batch.
- **Router hysteresis** to prevent rapid model thrashing on
  borderline prompts.
- **Phase 3c**: ModelDownloadService extension for SD bundles.

---

# Batch 7 — Fast helps smart + router hysteresis (2026-05-27)

Spawned an `architect` agent for the cross-service design check
before any code landed. Their plan went straight into
implementation — captured below alongside the build-time gotchas
that hit during execution.

## Design (per architect)

| Decision | Rationale |
|---|---|
| Compression in `performSend`, not `PromptAssemblyService.build` | Builder is sync + pure; `performSend` already owns async cancellation context |
| Closure-injected `excerptCompressorProvider`, not protocol or direct AFM dep | Matches existing `routePickProvider` / `installedImageModelIDsProvider` idiom; keeps the AFM availability fence at the composition root |
| 6 KB byte threshold | Below: AFM round-trip cost > prefill saving. Above: smart-model verbatim prefill grows visibly slower |
| Cancellation: native `Task.isCancelled` checkpoints + soft 4 s timeout | AFM's `respond(to:)` honours task cancellation natively; the 4 s deadline guards against AFM hangs |
| Failure: skip compression, inject verbatim, log only | Verbatim path is functionally correct — no user action available. UI warnings would train users to ignore them |

## What changed

### `HomeHub/Services/ExcerptCompressor.swift` (new, 197 LOC)
- `@MainActor` class with one public `static func compress(excerpts:language:) async -> String?`
- Race AFM `LanguageModelSession.respond(to:)` against a 4 s soft timeout via `withTaskGroup` — first to finish wins, loser is cancelled
- Per-language strict instructions block (Czech / English) demanding one paragraph, no bullets, name/number/date preservation
- Multiple gates short-circuit to `nil`: iOS < 26, `SystemLanguageModel.default.availability != .available`, AFM throw, timeout, cancelled
- `nonisolated` on `logger`, `timeoutSeconds`, `responseText`, `instructions` because the `withTaskGroup` children run on the cooperative pool, not MainActor

### `HomeHub/Services/ConversationService.swift`
- New `excerptCompressorProvider` closure on `init` (default `{ _, _ in nil }`)
- `static let excerptCompressionByteThreshold = 6_000`
- Capture `routerDecision` in `performSend` so the downstream compression step gates without re-classifying
- **Hysteresis**: skip the runtime swap when current model and decision share a tier — prevents thrashing between same-tier models on borderline classifier flips
- Compression gate runs after `topExcerpts` is fully assembled (post WebSearch), before prompt-context-package construction. All four gates: `.experimental` policy + SMART tier + bytes > threshold + non-nil compressor result

### `HomeHub/Services/ModelRouter.swift`
- `tierFor(model:)` promoted from `private` to `nonisolated static` so `ConversationService` can apply hysteresis without re-instantiating the router
- Internal call sites updated to `Self.tierFor(...)`

### `HomeHub/App/AppContainer.swift`
- Wires `excerptCompressorProvider` to `ExcerptCompressor.compress(...)` — stateless thin adapter, no AFM branching here (compressor self-gates)

## Build hygiene

| Check | Result |
|---|---|
| `xcodebuild build-for-testing` | ✅ Pass |
| New errors | 0 |
| New warnings on touched files | 0 |

## Gotchas hit during execution

1. **`@MainActor` class + nonisolated static usage** — initial draft had `logger`, `timeoutSeconds`, `responseText` as actor-isolated statics, but the `withTaskGroup` children run on the cooperative pool and tripped strict concurrency. Marked them `nonisolated` (and `nonisolated(unsafe)` for the Logger). Pattern: anything called from inside `TaskGroup.addTask { ... }` must be reachable from any actor.

## Open follow-ups (unchanged)

- Phase 3c: ModelDownloadService extension for `.coreMLPackage` repo snapshots.
- Tests for the compressor gating logic (would need to stub AFM availability — feasible but deferred).
- Telemetry: track how often compression fires vs. skips so the 6 KB threshold can be tuned with field data.
