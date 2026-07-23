# Findings Register

Status legend: `OPEN` · `FIXED` · `WONTFIX` · `NEEDS-DEVICE` (only verifiable on hardware)

Severity: **CRITICAL** (crash / data loss / store rejection) · **HIGH** (broken
feature or the reported OOM / bad-answer symptoms) · **MEDIUM** (correctness or
maintainability) · **LOW** (polish).

---

## Round 0 — own analysis

### F-001 · CRITICAL · Privacy usage descriptions never reach `Info.plist`
**Status:** OPEN
**Where:** `project.yml:256-269`

Seven privacy strings are declared as bare build settings:

```yaml
NSMicrophoneUsageDescription: "…"
NSSpeechRecognitionUsageDescription: "…"
NSHomeKitUsageDescription: "…"
NSCalendarsUsageDescription: "…"
NSCalendarsFullAccessUsageDescription: "…"
NSRemindersUsageDescription: "…"
NSRemindersFullAccessUsageDescription: "…"
```

The target uses `GENERATE_INFOPLIST_FILE: YES`. Xcode's generated-plist mechanism
only injects build settings whose name starts with **`INFOPLIST_KEY_`**. Every
other key in this file that needs to reach the plist has the prefix
(`INFOPLIST_KEY_UILaunchScreen_Generation`, `INFOPLIST_KEY_BGTaskScheduler…`,
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`, …). These seven do not, so they
land in the pbxproj as inert build settings and never appear in the bundle:

```
$ grep -n NSMicrophoneUsageDescription HomeHub.xcodeproj/project.pbxproj
1501:  NSMicrophoneUsageDescription = "Potřebujeme mikrofon…";   ← build setting, not plist
```

**Consequences**
- `VoiceService` requesting mic or `SFSpeechRecognizer` authorisation → iOS
  terminates the process immediately (`TCC` crash, not a catchable error).
- The HomeKit / Calendar / Reminders skills crash on first invocation — and the
  comment at `project.yml:258-264` explicitly states the app relies on these
  being present because *the prompt assembler advertises the skills to the model*,
  so the model can trigger them unprompted.
- Automatic App Store rejection.

The irony: the comment block above these lines correctly explains why the keys
are mandatory, and then declares them in the one form that does nothing.

**Fix:** prefix all seven with `INFOPLIST_KEY_`, regenerate, and assert the keys
are present in the built `Info.plist` in `make check`.

---

### F-002 · CRITICAL · `HOMEHUB_HAS_KERNEL_ENTITLEMENTS` is unreachable
**Status:** OPEN
**Where:** `project.yml:123-136` + `KERNEL_ENTITLEMENTS.md` step 4 + `LocalOverride.xcconfig.template:81`

Both documents instruct the developer to set the flag in `LocalOverride.xcconfig`.
`project.yml` removed the `configFiles:` wiring that would make that file part of
the build, and the generated project confirms nothing is attached:

```
$ grep -c baseConfigurationReference HomeHub.xcodeproj/project.pbxproj
0
```

So the documented procedure is a no-op. `DeviceMemoryProvider.kernelEntitlementsEnabled`
is permanently `false`, which means:

- `MemoryTier.generous` is **unreachable** (`DeviceMemoryProvider.swift:195-198`) —
  an 8 GB iPhone 16 Pro is silently demoted to `moderate`.
- `imageTokenBudget` is pinned at 70 instead of 256 (`DeviceMemoryProvider.swift:237`).
- `mlxGPUCacheLimitBytes` is 200 MB instead of 512 MB (`:234` vs `:250`).
- `batchSizeTokens` 256 instead of 512, `microBatchSizeTokens` 64 instead of 128.
- The 2.1 GB single-shard mmap refusal in `MLXRuntime.swift:559-575` **always**
  fires, so large single-shard models are rejected with a Czech error telling
  the user to buy a paid account — which they now have.

This is the root cause of "the paid account unlocked nothing".

**Fix:** Round 1 — see `03-ENTITLEMENTS.md`.

---

### F-003 · HIGH · `LocalOverride.xcconfig.template` would clobber its own flags
**Status:** OPEN
**Where:** `LocalOverride.xcconfig.template:81` and `:88`

Both the kernel-entitlements block and the llama.cpp block assign
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`. In xcconfig semantics `$(inherited)`
resolves against *lower-priority configuration layers*, **not** against an
earlier assignment in the same file — the later line simply wins. A developer
following the comments and uncommenting both would silently lose
`HOMEHUB_HAS_KERNEL_ENTITLEMENTS` and never know.

Moot once F-002 is fixed by removing the xcconfig path entirely, but the
template must stop teaching the broken pattern.

---

### F-004 · MEDIUM · `Makefile` targets a simulator that does not exist
**Status:** OPEN
**Where:** `Makefile:15`

```make
DEST = platform=iOS Simulator,name=iPhone 16
```

Xcode 26.2 on this machine has iPhone 17, 17 Pro, 17 Pro Max, Air, 16e — no
plain "iPhone 16". `make build` and `make test` fail before compiling anything.
CI presumably pins its own destination, so this only bites local development —
which is exactly where it costs the most time.

**Fix:** resolve a destination dynamically, or pin to a generic simulator
destination that does not name a device.

---

### F-005 · MEDIUM · No version control
**Status:** OPEN

`/Users/keks/Developer/ios-home-hub-main` is not a git repository, yet the repo
ships `.gitignore`, `.github/`, a CI drift guard, and `git`-oriented docs. A
multi-round refactor with no diff/revert is a standing risk.

**Fix:** `git init` + baseline commit before further changes land.

---

### F-006 · LOW · Lint tooling documented but absent
**Status:** OPEN

`.swiftlint.yml` is committed; `swiftlint` and `swiftformat` are not installed on
this machine, so no style gate runs locally.

---

*(Findings F-1xx from the memory/OOM agent, F-2xx from the answer-quality agent,
F-3xx from the security agent and F-4xx from the silent-failure agent are appended
as those reviews land.)*

---

## Round 0 — parallel review agents

Four read-only reviewers were run against the tree. Their raw conclusions are
condensed here; nothing below was auto-applied.

### F-1xx · Memory / OOM subsystem

#### F-101 · CRITICAL · `sessionLock` does not protect the fields its own docs claim
**Status:** OPEN
**Where:** `HomeHub/Runtime/MLXRuntime.swift:58-71` (the claim) vs. the reality below

The class header states *"all mutable fields are protected by `sessionLock`"* and
*"`container` and `activeSession` are both guarded"*. Neither holds:

| Field | Unguarded writes | Unguarded reads |
|---|---|---|
| `container` | `:670` (success path of the detached load task) | `:918`, `:1022` (inside `generate()`'s Task) |
| `loadedModel` / `_loadedModel` (`:78-82`) | `:692`, `:733`, `:741`, `:846` | `:827`, `:897`, `:951`, `:1028`, `:1422`, `:1514`, `:1648` |
| `baselineCacheLimitBytes` (`:330`), `currentCacheTier` (`:353`) | `:421-451`, `:463-470`, `:1508` — three concurrent contexts | same |

`:1619` (`realTokenCount`) shows the correct pattern — it snapshots via
`sessionLock.withLock { container }`. The hot paths do not.

The justification at `:417-420` ("pressure helpers run on the same `@MainActor`-rooted
call chain as `loadWithProgress`") is **factually wrong**: `loadWithProgress` runs
inside `Task.detached` spawned at `RuntimeManager.swift:318`, which is by
definition not MainActor-rooted, and `MLXRuntime` is a plain class, so
`await runtime.handleMemoryPressure()` does not hop to the main actor either.

**Reachable, not theoretical.** `RuntimeManager.handleSoftMemoryPressure()`
(`RuntimeManager.swift:983-996`) is *deliberately designed* to run without waiting
for `operationTask`. The hard path (`:964-981`) waits only
`awaitOperation(timeout: 1.5)` and then proceeds regardless. The code's own
comments put Metal pipeline compilation at 10–60 s (`RuntimeManager.swift:297-299`,
`MLXRuntime.swift:755`). So *any* memory-pressure event during a 4 GB model load —
the default first-run experience — races `unload()` and `adjustGPUCacheLimit`
against the in-flight load.

`@unchecked Sendable` (`:72`) suppresses Swift 6's race diagnostics, so the
compiler will never flag this. Symptoms: torn reads of the `container` existential
(corrupt witness-table pointer → crash inside `container.perform`), or
`loadedModel` disagreeing with `container` (UI says loaded, container is nil).

**Fix:** put all of these under `sessionLock` consistently, or convert `MLXRuntime`
to an `actor`. Run one QA pass with Thread Sanitizer against "start big load, then
background the app".

#### F-102 · HIGH · `HardwareCapabilities` silently caps the generous GPU pool at 256 MB
**Status:** OPEN
**Where:** `HomeHub/Services/HardwareCapabilities.swift:88-97`

```swift
case .a18, .mSeries:    return 256 * 1024 * 1024     // no SoC-side cap
```

The comment says "no SoC-side cap" and then returns a cap. `DeviceMemoryProvider.swift:250`
sets the entitled generous tier to **512 MB**, but both `MLXRuntime.init` (`:388-390`)
and `DeveloperDiagnosticsView.swift:116` take `min(memoryBudget, hardwareBudget)`.

iPhone 16 Pro is `.a18`; iPad Pro M-series is `.mSeries` — so
`min(512, 256) = 256 MB` on **exactly the two devices the owner uses**. The value
is not gated on `kernelEntitlementsEnabled` at all; it predates the entitlement
work. The single biggest lever the generous tier exists to pull is inert.

#### F-103 · HIGH · Catalog gating is not entitlement-aware; two models mislabelled
**Status:** OPEN
**Where:** `HomeHub/Services/ModelCatalogService.swift`

`recommendedFor: [.iPadMSeries]` is hardcoded for Gemma 3n E2B (`:562`), E4B (`:632`),
Mistral 7B v0.3 (`:661`), Llama 3.1 8B (`:678`), Qwen2-VL 7B (`:768`), Phi 3.5 Mini
(`:510`). Comments at `:488-498`, `:538-550`, `:607-616`, `:643-647` all say the
models load fine once entitled — `:497` literally says *"revisit the gating when
entitlements ship"*. That is now.

Runtime gating is already correct (`MLXRuntime.swift:559` checks
`!kernelEntitlementsEnabled`; `evaluateFeasibility` uses live
`os_proc_available_memory()`), and `ModelsView.swift:909-911` already hides the
"Vyžaduje placený účet" pill when entitled. But the "doporučeno pro iPad" /
risky-on-phone copy (`ModelsView.swift:254`) still fires for an entitled iPhone.

**Separate correctness bug:** Gemma 3n E4B (`:647`) and Qwen2-VL 7B (`:775`) set
`requiresLargeMmapAddressing: true`; **Mistral 7B v0.3 (`:650-665`, 4.1 GB) and
Llama 3.1 8B (`:667-682`, 4.5 GB) do not** (defaults false, `LocalModel.swift:120`).
If either ships an unsharded 4-bit repo, a non-entitled user downloads 4+ GB before
hitting the hard runtime refusal with no prior warning.

#### F-104 · HIGH · Generous tier's context window never grew, but its history budget doubled
**Status:** OPEN
**Where:** `DeviceMemoryProvider.swift:231` vs `:247`; `ModelCapabilityProfile.swift:649-664`

Both moderate and generous set `contextWindowTokens: 4096`. Meanwhile
`dynamicHistoryBudget` scales the history budget **1.5× moderate, 2.0× generous**
(llama family: 1400 base → 2100 → 2800). `ModelCatalogService.adjustContextLength`
(`:175-185`) clamps every model to `min(base, contextWindowTokens)` — flat 4096 for
both tiers.

MLX has **no secondary hard clamp**: `ChatSession` is constructed with no `n_ctx`
(`MLXRuntime.swift:1094-1098`), unlike the llama.cpp path
(`LlamaContextHandle.swift:89-90`). So `safeHistoryTokenBudget` is the *only* bound
on assembled prompt size, and therefore on KV-cache size. On generous:
2800 history + 1024 `generationReserveTokens` (not tier-scaled) + 600–2000 system
prompt can exceed the 4096 the model was clamped to.

#### F-105 · MEDIUM · `_performLoad`'s single `Task.yield()` doesn't guarantee release
**Status:** OPEN · **Where:** `RuntimeManager.swift:228-241`

Matters for model-switching between two 4 GB models: the feasibility preflight
(`:258-260`) and `recomputeCacheLimitForLoad`'s `os_proc_available_memory()` read
(`MLXRuntime.swift:423`) can both sample before Metal's pool actually drains.

#### F-106 · MEDIUM · Zero-token reply is indistinguishable from success
**Status:** OPEN · **Where:** `MLXRuntime.swift:1415-1511`

`.finished` is yielded unconditionally even when `tokensGenerated == 0`.
`RuntimeManager.runSmokeTest` (`:924-925`) treats 0 tokens as "checkpoint may be
corrupted" — but real user turns have no such guard. User sees a blank bubble, no
error, no retry. The `RuntimeWarning` type needed to fix this already exists
(used at `MLXRuntime.swift:960-964`).

#### F-107 · MEDIUM · Per-token `autoreleasepool` probably doesn't do what its comment says
**Status:** OPEN · **Where:** `MLXRuntime.swift:1204-1219`, `:1359-1368`

The pool wraps only the post-`await` bookkeeping. The decode step runs during the
`await` on the stream's `next()` — before control returns to the loop body — so a
consumer-side pool cannot drain producer-side temporaries. Needs Instruments
verification before either keeping or removing.

#### F-108 · MEDIUM · Doc/code drift in `dynamicHistoryBudget`
**Status:** OPEN · **Where:** `ModelCapabilityProfile.swift:643-648` vs `:658-660`
Comment says moderate is "100% of base (unmodified)"; code is `base * 1.5`.

#### F-109 · MEDIUM · `recomputeCacheLimitForLoad` may double-subtract weights
**Status:** OPEN · **Where:** `MLXRuntime.swift:421-441`
`os_proc_available_memory()` is read at `:423`, *after* `loader.load()` at `:670`
already mapped the weights, then `weightsBytes` is subtracted again at `:431`.
Direction of error is conservative (smaller pool than intended), so it's a
perf risk not a safety one — but it compounds F-102.

#### F-110 · LOW · Dead flag `hasLoggedSamplerWarnings`
**Where:** `MLXRuntime.swift:212`, written at `:688`, never read.

#### F-111 · LOW · `OOMTelemetryService` raw payloads grow without bound
**Where:** `OOMTelemetryService.swift:248-255`. Breadcrumbs are capped at 200
(`:56`, `:159-161`); raw MetricKit JSON files are not. Disk, not RAM.

#### F-112 · LOW · Undebounced `Task {}` per memory warning
**Where:** `HomeHubApp.swift:29-33`. Serialised in practice by `@MainActor` +
`AppContainer`'s own debounce (`:911-928`), so currently benign.

**Verified correct (checked because entitlements could have broken them):**
`MLXRuntime.swift:559-575` mmap gate · `RuntimeManager.evaluateFeasibility` safety
factors (self-adjusting, proportional to `os_proc_available_memory()`) ·
`AppContainer.handleMemoryPressure` ratio-based multipliers ·
`sandboxedSingleShardCeilingBytes` single-source-of-truth · KV-cache reuse has no
accumulation bug.

---

### F-2xx · Answer quality

#### F-201 · CRITICAL · No unified prompt-size budget; only history is bounded
**Status:** OPEN
**Where:** `ModelCapabilityProfile.swift:326-334`; `PromptAssemblyService.swift:47-161`

`ModelCapabilityProfile.gemma3n`'s own comment: *"quality degrades on prompts
> ~1700 effective tokens"* — and its `safeHistoryTokenBudget` is 1600, which covers
**history only**. The system prompt (persona, tone, profile, user memory, stable
rail, skills, privacy — plus volatile date/summary/recall/facts/episodes/excerpts)
is assembled with no cross-check against that number *or* against `contextLength`.
`PromptAssemblyService.build` only *reports* token counts (`:119-134`); it never
trims. The profile's own doc says the L1–L7 stack is 1500–2500 tokens
(`ModelCapabilityProfile.swift:157-161`), which alone blows the 1700 ceiling before
any history is added.

The only enforced ceiling (`ConversationService.swift:1629-1637`) checks the *hard*
`contextLength` (32k+ on gemma3n — effectively never fires) to clamp `maxTokens`.
Nothing checks the prompt.

**This is the most likely single root cause of the reported bad answers.**

#### F-202 · CRITICAL · Unexplained `<context>` block glued to the front of the user's turn
**Status:** OPEN · **Where:** `MLXRuntime.swift:1132-1143`

Volatile context is wrapped in `<context>…</context>` and prepended to the user's
actual message. Nothing in the stable system prompt ever explains that tag to the
model. The inner chunks are self-labelled, but the outer wrapper — and the fact
that app-supplied background arrives as if the *user* typed it — is undocumented
to the model.

The codebase already knows this failure shape: `PromptAssemblyService.swift:364-370`
drops verbatim recall for weak models because it is *"the single largest source of
prompt-injection-style confusion we've seen on Gemma 3n"*, with a field example of
the model echoing recalled fragments instead of answering. The `<context>` wrapper
is architecturally the same thing and fires on **every** multi-turn message.

**Fix:** one sentence in the stable hard-rules chunk explaining the tag.

#### F-203 · CRITICAL · Tool results are delivered in a role no model was trained on
**Status:** OPEN · **Where:** `LocalLLMRuntime.swift:274`; `ConversationService.swift:1859-1865`

`RuntimeMessage.Role` is `system | user | assistant` — there is no `.tool` case.
Tool observations are appended as a **`.user`** message literally reading
`"<Observation>\n…\n</Observation>"`. Models fine-tuned with a real tool protocol
(Llama 3.1 `ipython`, Qwen ChatML `tool`, Mistral `[TOOL_RESULTS]`) see this as
user input — structurally out of distribution.

The code already documents the symptom: *"toolFollowup is the one place where small
models routinely produce a single word or a bare noun after seeing the
`<Observation>` tag"* (`PromptAssemblyService.swift:470-476`). The minimum-length
guard bolted on right after that comment treats the symptom, not the cause.

#### F-204 · HIGH · Tool-envelope stop sequences truncate ordinary replies invisibly
**Status:** OPEN · **Where:** `ConversationService.swift:999-1003`; `MLXRuntime.swift:1233-1240`, `:1476-1477`

`["</tool_call>", "</function_call>", "[/TOOL_CALLS]"]` are registered as hard stops
on **every** generation, not just tool turns. A stop-sequence hit produces
`finishReason == .stop`, indistinguishable from a natural ending. The "Pokračovat"
button is gated on `finishReason == "length"` (`Message.swift:94`,
`MessageBubbleView.swift:305-312`), so a reply cut this way has **no visible signal
and no continuation affordance**. Trivially triggered by asking the app about its
own tool-calling format.

#### F-205 · HIGH · Summarizer input is uncapped and skips the context guard
**Status:** OPEN · **Where:** `SummarizationService.swift:36-42`; `PromptMode.swift:130-142`

Transcript built with no per-message or total cap — unlike the extractive fallback
`LightweightSummarizer`, which byte-caps everything (`:63-65`, `:117-128`). Fixed
`maxTokens: 200` never runs through the dynamic context-aware clamp (that logic is
private to `performSend`). Success is judged by `!initial.isEmpty`
(`ConversationService.swift:2053`), so a truncated summary is indistinguishable
from a good one — and it is then injected into **every** subsequent turn.

#### F-206 · HIGH · Phi-3 rendered with the wrong chat template in the fallback path
**Status:** OPEN · **Where:** `ChatTemplate.swift:70-71`

`case "qwen2", "qwen3", "phi3", "phi2": rendered = renderChatML(prompt)`. Phi-3's
real format is `<|system|>…<|end|><|user|>…<|end|><|assistant|>`. The codebase
already knows this — `ChatTextSanitizer.swift:41-42` lists exactly those markers
as "Phi-4 / Phi-3 mini". Only affects the fallback and llama.cpp paths, but
`ModelCapabilityProfile.phi` is already flagged `isWeakInstructionFollower` with a
documented repetition-loop history (`:375-401`), consistent with template confusion.

#### F-207 · MEDIUM · Sanitizer can delete legitimate content
**Where:** `ChatTextSanitizer.swift:29-52`. `<s>`, `</s>`, `<pad>`, `<unk>` are
matched as bare substrings with no boundary check, on every render
(`MessageBubbleView.swift:66`). `<s>`/`</s>` are also real HTML and plausible
tokenizer notation — an on-topic subject for this app's own chat.

#### F-208 · MEDIUM · Unknown family → no stop sequences at all
**Where:** `ConversationService.swift:983-993` (`default: return []`).

#### F-209 · MEDIUM · Tool-loop turns force a full KV rebuild every iteration
**Where:** `PromptAssemblyService.swift:56-58` — `.toolFollowup` returns its whole
system prompt as "stable" with an empty volatile half, textually different from
`.chat` mode's stable chunk. So the reuse check always reports
*"different stable systemPrompt (hash mismatch)"* (`MLXRuntime.swift:1050-1060`),
forcing full re-prefill each iteration and eating into `loopBudgetSeconds` and the
120 s watchdog.

#### F-210 · LOW · Dead sampling knobs
`RuntimeParameters.frequencyPenalty` / `presencePenalty` (`LocalLLMRuntime.swift:323-329`)
are never read in `GenerateParameters(...)` (`MLXRuntime.swift:1000-1008`).

#### F-211 · LOW · Retrieved facts discarded before reaching the model
`adaptiveRetrievalLimits` retrieves up to 12 (`ConversationService.swift:2533-2540`);
`appendFacts` hard-caps rendering at 8 strong / 3 weak (`PromptAssemblyService.swift:386`).

**Already fixed upstream (do not re-fix):** the Russian/Spanish token-bleed sampler
bug (all knobs now wired, `MLXRuntime.swift:979-1008`) and the invented
`<start_of_turn>system>` Gemma role (`ChatTemplate.swift:143-184`).

---

### F-4xx · Silent failures

#### F-401 · CRITICAL · The entire assistant-reply save chain is `try?` with no logging
**Status:** OPEN · **Where:** `ConversationService.swift:1116, 1137, 1730, 1760, 1788, 1905, 1918`

Every write on the hot send/stream path — user message, placeholder, **completion
save**, failure save, empty-response fallback, both finalize paths — is `try?` with
no log line anywhere.

Worst interaction: the heartbeat save has already persisted the message as
`.streaming`. `loadMessages` (`:393-396`) rewrites leftover `.streaming` messages to
`.failed` on next launch. So a **successful** turn whose final save failed becomes a
**permanently mislabelled failure**, with no trace. Disk-full and jetsam windows are
exactly when this fires.

`MemoryService.persist(_:_:)` (`MemoryService.swift:66-72`) already implements the
correct pattern in this same codebase.

#### F-402 · CRITICAL · `loadMessages(for:)` swallows read errors with zero logging
**Where:** `ConversationService.swift:388`. User opens a chat, sees it empty. No
error, no retry, no breadcrumb. `load()` at `:249` at least logs.

#### F-403 · CRITICAL · Knowledge-Base documents marked "Indexed" with zero-dimension vectors
**Status:** OPEN
**Where:** `DocumentEmbedder.swift:64` → `IngestPipeline.swift:359-367, 383` →
`KnowledgeBaseStore.swift:95-108` → `KnowledgeBaseRetrieval.swift:163-164`

`embeddingVector(for:) ?? []` makes failure indistinguishable from success. The
dimension guard only catches a *mismatch*, so if **every** chunk embeds to `[]`
(NLContextualEmbedding assets not downloaded — a real, documented condition), then
`expected == 0`, nothing mismatches, no throw, and the document is marked `.indexed`.
`saveVectors` accepts `dim == 0`. At retrieval, `cosine()`'s length guard returns 0
forever, so the document can never clear `minRelevance`.

User imports a document, sees "Indexed", and the model answers every future question
as if it doesn't exist. `DocumentEmbedder.swift:16-20`'s doc comment claims the
pipeline "treats those as indexing failures and surfaces them on the document
record" — **no such logic exists**.

#### F-404 · CRITICAL · KB retrieval failure double-swallowed via Siri/Shortcuts
**Where:** `KnowledgeBaseRetrieval.swift:56-59` (returns `[]`, no log) then
`HomeHubIntents.swift:372, 460` (`try? … ?? []`, then asks the model anyway with an
empty context string). 30 lines below the silent one, `:89-94` logs at `.error` with
the comment *"Log loudly — a silent skip masked a real bug for too long"*. The right
pattern is known and simply wasn't applied here.

#### F-405 · CRITICAL · Corrupt `UserMemory` blob silently wipes all user memory
**Where:** `UserMemoryStore.swift:72-79`. Decode failure → `.empty`, no log, no
backup. This feeds every system prompt via `promptBlock()`. The next `persist()`
destroys the recoverable blob permanently.

#### F-406 · HIGH · `FileStore` can duplicate a message record on a transient read failure
**Where:** `FileStore.swift:185`. `FileStore` is confirmed the **default production
store** (`AppContainer.swift:1380-1394`). A failed JSONL read → `?? []` → the ID
"isn't found" → append instead of rewrite → two records with the same ID.
iCloud placeholder files that haven't materialised are a real trigger.

#### F-407 · HIGH · `resetAllModels()` can orphan multi-GB files while the UI says they're gone
**Where:** `ModelDownloadService.swift:798-806`. `try?` with no log, then catalog
entries flipped to `.notInstalled` unconditionally. `deleteModel` (`:285-300`)
already got the correct `lastDeleteError` treatment; this function never did.

#### F-408 · HIGH · Background downloader drops unrecognised delegate callbacks silently
**Where:** `MLXBackgroundDownloader.swift:442-446, 490-493, 589-592`. Contrast the
correctly-logged `reconnect()` at `:242`. A multi-GB download can complete at the
OS level while the app has no record — row stuck on "Downloading…" forever, nothing
in Console.

#### F-409 · HIGH · Auto-router load failure has no chat-visible signal
**Where:** `ConversationService.swift:1177-1189`. The comment claims failures "show
up in the chat surface via the standard error path"; `lastGenerationError` /
`state == .failed` are only read by `DeveloperDiagnosticsView` and `ModelInfoSheet`.

#### F-410 · HIGH · Conversation lifecycle writes are all unlogged `try?`
**Where:** `ConversationService.swift:463, 471, 487, 501, 546, 646, 658, 665, 697, 703, 720, 726, 760-762, 846`.
Rename/pin/archive/delete/trim/clear mutate in-memory state first. Failures surface
next launch as zombie conversations, with nothing to correlate against.

#### F-411 · MEDIUM · Embedding failure scores as `0.0` instead of being excluded
**Where:** `EmbeddingService.swift:162-167`. A fact that trips an embedding error is
permanently the lowest-ranked candidate, indistinguishable from genuinely irrelevant.

#### F-412 · MEDIUM · Attachment silently dropped when extraction yields no chunks
**Where:** `ConversationService.swift:1256-1261`. `.notice` is Console-only; the user
gets an answer as if they never attached the file.

#### F-413 · MEDIUM · Memory extraction failures logged at `.warning`, candidate lost forever
**Where:** `MemoryExtractionService.swift:68-75`. Fire-and-forget, called once per
message, no retry.

#### F-414 · MEDIUM · `SDMessage` attachment re-encode failure *overwrites* saved metadata with nil
**Where:** `SwiftDataStore.swift:332`.

#### F-415 · MEDIUM · `flushPendingChanges()` — the pre-backgrounding last-chance write — only logs
**Where:** `SwiftDataStore.swift:238-245`. This exists specifically to prevent the
OOM-adjacent data loss being complained about.

#### F-416 · MEDIUM · Web-search failure invisible to both user and model
**Where:** `ConversationService.swift:1282-1295`. Logs at `.error` (good) but the
model is never told, while the tool policy (`PromptBuilder.swift:311-323`) told it
it MUST search.

**Judged correct, no action:** `MLXRuntime.prewarm()` best-effort swallow
(`:769-823`) · `URL+StaticLiteral.swift:13` `preconditionFailure` (traps in all
configs) · `FakeMLXLoader.swift:79` (test-only mock) · `SkillManager.swift:186-213`
(feeds errors back to the model as observations).

**Cited as internal reference standards:** `ModelDownloadService.swift`'s install
validation pipeline and `RuntimeManager.swift`'s error handling — both consistently
pair `state = .failed` with `.error` logging and humanised messages.
