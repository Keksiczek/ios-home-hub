# Progress Log

Chronological. Each entry names the finding IDs it closes so `01-FINDINGS.md`
and this file stay cross-referenceable.

**Verification standard used throughout:** a change is only marked FIXED when
the build is green *and* the effect was observed (built `Info.plist` inspected,
entitlements dumped with `plutil`, guardrail script run). "It compiles" is not
evidence that a build-configuration fix worked — that is precisely how F-001,
F-002 and F-304 survived this long.

---

## Session 1 — 2026-07-23

### Baseline established

| Check | Result |
|---|---|
| Cold build, iPhone 17 simulator | **BUILD SUCCEEDED** (exit 0) |
| Unit tests | **613 passed, 32 failed — already red at baseline** |
| Warnings | 1 in baseline build output |
| Git | `git init` on branch `production-readiness/2026-07`, remote added |
| Local tree vs `origin/main` (271a7f6) | **identical** apart from new docs |

Baseline commit: `e4db4b2`.

> **Method note.** The test suite was initially misread as passing because the
> shell reported the exit status of a trailing `echo` rather than of
> `xcodebuild`. Always read the `** TEST FAILED **` / `** TEST SUCCEEDED **`
> line from the log, or capture `xcodebuild`'s status directly. The failure set
> was then established properly by running the full suite against the baseline
> commit in a separate git worktree, and diffing the failing-test names.

### Pre-existing test failures (F-007)

32 tests fail on the **untouched baseline** (`e4db4b2`), 613 pass. The failing
set is byte-identical before and after every change in this session — verified
by `diff` of the sorted failing-test names. So the suite is a usable regression
signal even though it is red, provided you compare sets rather than exit codes.

Three distinct causes, none introduced here:

1. **`ModelCapabilityProfileTests` (8 tests)** assert hardcoded
   `safeHistoryTokenBudget` values (e.g. gemma 1200), but `dynamicHistoryBudget`
   scales by the *device* tier — which on a simulator depends on the host Mac's
   RAM. The tests were written against the unscaled base values and never
   updated when tier scaling landed. They are machine-dependent and would pass
   or fail differently on another Mac.
2. **`MemoryPolicyTests.testFeasibilityCannotLoadWhenAvailableBelowRawWeights`**
   expects `.cannotLoad` and gets `.risky`. This is the test asserting the *old*
   feasibility gate; `MLXRuntime`'s comments document the deliberate loosening
   (raw weights are mmap-backed, so the old `× 1.35` rule refused models that
   run fine). The test was not updated with the behaviour change.
3. **`MLXHardeningTests` / others** hit
   `FakeMLXLoader.swift:79`'s deliberate `fatalError` —
   *"MockMLXModelContainer.perform was invoked"* — which crashes the test
   runner and forces a restart (7 restarts in a full run). The mock is
   load/unload-lifecycle only, and some tests drive `generate()` against it.
   A crashing mock also makes the rest of the run unreliable, so this one is
   worth fixing first.

**These should be fixed**, but as their own piece of work: they are stale
assertions and a broken test double, not product defects, and repairing them
inside a change that also alters memory tiers would make both harder to review.

Owner's answers that shaped scope:
- Distribution is **App Store**, paid account, all users. So the entitlements
  ship to everyone — the free-tier path becomes a safety fallback, not the
  design centre.
- Target devices: **iPhone 16/17 Pro (8 GB)** and **iPad M1**. Both are
  `generous`-tier candidates.

---

### Commit `141b393` — kernel entitlements + Info.plist privacy keys
Closes **F-001**, **F-002**, **F-003**, **F-102**, **F-104**, **F-101 (partial)**

**F-001 — privacy usage descriptions never reached `Info.plist`.**
Prefixed all seven `NS*UsageDescription` keys with `INFOPLIST_KEY_`.
*Verified:* `plutil -p` on the built `HomeHub.app/Info.plist` now lists all
seven. Before the fix they were absent. Also rewrote the strings to explain
*why* each permission is needed and to state the on-device guarantee, since
App Review reads these.

**F-002 — `HOMEHUB_HAS_KERNEL_ENTITLEMENTS` was unreachable.**
- Added both kernel entitlement keys to the target's `entitlements.properties`.
  *Verified:* `plutil -p HomeHub/HomeHub.entitlements` shows
  `increased-memory-limit => 1` and `extended-virtual-addressing => 1`.
- Added `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) HOMEHUB_HAS_KERNEL_ENTITLEMENTS"`
  directly in `project.yml`, *not* via the xcconfig that had been dead.
- Set `DEVELOPMENT_TEAM: 8Y755TXDN8`. The old comment claimed Xcode stores team
  selection in xcuserdata; it actually writes to `project.pbxproj`, which
  `xcodegen generate` overwrites — so device signing was silently lost on every
  regeneration. Comment corrected in place.

**Runtime entitlement verification (design decision D1).**
`DeviceMemoryProvider.kernelEntitlementsEnabled` is now
`declared && granted`, where `granted` derives the real jetsam limit:

```
limit = task_vm_info.phys_footprint + os_proc_available_memory()
granted = limit / physicalMemory >= 0.48
```

Two approaches were tried and rejected first, both worth recording so nobody
re-attempts them:

1. **`SecTaskCopyValueForEntitlement`** — the obvious "just read the signature"
   answer. Rejected: the symbol exists in `Security.tbd` but `SecTask.h` ships
   **macOS-only**, so `import Security` does not expose it on iOS. Confirmed by
   test-compiling against the iOS 26.2 SDK:
   `error: cannot find 'SecTaskCreateFromSelf' in scope`.
2. **Parsing `embedded.mobileprovision`** — rejected: App Store builds have no
   embedded profile, so it fails exactly in the distribution case that matters.

The footprint+available identity is time-invariant (as the app allocates,
footprint rises and available falls by the same amount), so it can be evaluated
at any point in the lifecycle — unlike sampling `os_proc_available_memory()`
alone at launch, which is meaningless once a model is resident.

Threshold 0.48 sits in the gap between the measured bands: unentitled ≈ 33–40 %
of physical RAM, entitled ≈ 55–75 %. Simulator is excluded (it inherits the host
Mac's limits) and falls back to the declared flag.

> ⚠️ **Superseded in Session 2 — this ratio test was wrong and was removed.**
> Device data from an iPhone 16 Pro on iOS 26.5.2 shows an *unentitled* app
> getting 74.9 % of physical RAM, so the 0.48 threshold produced a false
> "granted". The 33–40 % figure was from older iOS versions. Tier selection now
> reads the measured limit directly instead of inferring the entitlement.
> See the Session 2 entry below.

**F-102 — `HardwareCapabilities` capped A18/M-series at 256 MB** while the
comment on that very line read "no SoC-side cap". Since call sites take
`min(memoryBudget, hardwareBudget)`, `min(512, 256)` defeated the generous
tier's GPU pool on exactly the owner's two devices. Now entitlement-aware:
768 MB entitled (headroom above the tier's 512 MB so it stays a guard, not a
budget), 256 MB otherwise.

**F-104 — generous tier declared the same 4096-token context as moderate**
while `dynamicHistoryBudget` doubled the history budget on that tier. Since MLX
constructs `ChatSession` with no `n_ctx`, nothing enforced the window and the
assembled prompt could exceed it unnoticed. Raised generous to **8192**, which
makes the declared window match what the budgeting already permits
(llama generous: 2800 history + 1024 reserve + ~2000 system = 5824 ≤ 8192).
Also fixed the `dynamicHistoryBudget` doc comment, which claimed moderate was
"100 % of base" while the code did `base * 1.5` (**F-108**).

> **A clamp was tried here first and reverted — do not re-add it without
> measurement.** `historyCeilingForTier(...)` derived a history ceiling from
> `contextWindow − reserve − 2000`. It was correct arithmetic and a real
> regression: measured against the baseline, it cut the Gemma history budget on
> the **moderate** tier from **1800 to 1072 tokens**, a 40 % silent loss of
> conversational memory on every 6 GB device — exactly the "assistant ignores
> what I said earlier" symptom this work exists to fix. On the tight tier it was
> worse (600 → 400), because that tier's reserve alone already equals its whole
> declared window.
>
> The tiers' shipped numbers are tested; a ceiling derived from a *guessed*
> 2000-token system-prompt allowance is not. Trading tested behaviour for an
> untested formula is the wrong direction, so the clamp is now a
> `.debug`-level diagnostic (`reportContextBudgetIfOverrun`) that reports the
> overrun without correcting it.
>
> **Moderate is still over budget on paper** (llama: 2100 + 1024 + ~2000 ≈ 5124
> against a 4096 window) and has been for some time. Fixing it properly needs
> on-device measurement of real assembled-prompt sizes — the diagnostic now
> emits exactly that data. Left open under F-104.

**F-101 (partial) — `MLXRuntime` data races.** `container` and `loadedModel`
were documented as lock-guarded and were not. Both now have lock-guarded
accessors over `_container` / `_loadedModel` backing storage, with the
convention that backing storage is touched directly *only* inside a held lock
(`NSLock` is not recursive). `unload()` now snapshots and tears down in a single
critical section instead of four separate acquisitions, so an observer can no
longer catch a half-unloaded runtime.

*Still open under F-101:* `baselineCacheLimitBytes` and `currentCacheTier` are
mutated from three contexts and remain unguarded. Deferred because the fix
touches the pressure-tier state machine and deserves its own change plus a
Thread Sanitizer pass.

---

### Commit `f095bba` — BGProcessingTask, privacy manifest, guardrail
Closes **F-304**, **F-004**, task "privacy manifest"

**A guardrail found a bug the reviews had not.** `scripts/check-infoplist-keys.sh`
asserts against the **built** `Info.plist`, and on its first run reported
`BGTaskSchedulerPermittedIdentifiers` and `UIBackgroundModes` as MISSING —
even though both were set *and correctly prefixed*.

Root cause, which is subtler than F-001: `INFOPLIST_KEY_` maps a **fixed
allowlist** of keys, not every key of a supported type.
`INFOPLIST_KEY_UISupportedInterfaceOrientations` (array of strings) is on the
list and works; `UIBackgroundModes` and `BGTaskSchedulerPermittedIdentifiers`
are not. The settings are accepted by xcodebuild and appear in
`-showBuildSettings`, so nothing looks wrong anywhere except the bundle.

Confirmed live in the test log against the pre-fix build:

```
[Framework] Registration rejected; cz.keksiczek.homehub.ingest
is not advertised in the application's Info.plist
```

So the Knowledge Base background ingest has **never run**. `IngestScheduler`
catches and logs the throw, which is why it stayed invisible.

Fixed with a partial `Info.plist` via xcodegen's `info:` block. `project.yml`
had explicitly rejected that approach, believing a real plist "drops all the
INFOPLIST_KEY_* auto-injection" — untrue since Xcode 13, which *merges*
generated keys into an existing file. *Verified:* all seven privacy strings
still land alongside the two new array keys.

**Privacy manifest.** Added `HomeHub/PrivacyInfo.xcprivacy` declaring the three
required-reason API categories actually used (UserDefaults `CA92.1`, file
timestamps `DDA9.1`, disk space `85F4.1` + `E174.1` — two distinct uses), no
tracking and no collected data. The last is accurate rather than optimistic:
there is no HomeHub backend.

**F-004 — `Makefile` pinned `iPhone 16`,** which Xcode 26.2 does not ship, so
`make build` and `make test` failed before compiling anything. `build` now uses
a generic simulator destination; `test` resolves the newest installed iPhone at
invocation time. Added `make check-plist`.

---

### Uncommitted at time of writing — answer quality + silent failures

**F-202 — the `<context>` envelope is now explained to the model.**
`MLXRuntime` prepends volatile context to the user's turn wrapped in
`<context>…</context>` so per-turn churn doesn't invalidate the cached KV
prefix. Sound design, but nothing ever told the model what the tag meant, so
app-supplied background arrived looking exactly like something the user typed,
immediately before their real question, on **every multi-turn message**.

Added three lines to the *stable* chunk (one cache entry, not one per turn)
instructing the model to use the block but never quote, repeat or answer it.
This codebase already documents the identical failure shape one layer down —
verbatim recall is dropped for weak models because it is "the single largest
source of prompt-injection-style confusion we've seen on Gemma 3n".

**F-204 — tool-envelope stop sequences no longer fire on tool-less turns.**
`</tool_call>`, `</function_call>` and `[/TOOL_CALLS]` were registered as hard
stops on *every* generation. A stop-sequence hit yields `finishReason == .stop`,
indistinguishable from a natural ending, and the "Pokračovat" button is gated on
`.length` — so a reply cut this way was truncated with no signal and no way to
continue. Trivially triggered by asking the app about its own tool-call format.
Now gated on `!enabledTools.isEmpty`.

*Residual:* a tools-enabled turn can still hit this. The complete fix needs a
distinct `FinishReason` for stop-sequence matches, which means touching the
shared `RuntimeEvent` enum and both backends. Left open under F-204.

**F-401 / F-402 — conversation persistence no longer fails silently.**
Added `ConversationService.persist(_:_:)`, mirroring the
`MemoryService.persist(_:_:)` helper that already solved this on the memory side.

The completion save is the consequential one: the heartbeat save has already
written the message as `.streaming`, and `loadMessages` rewrites leftover
`.streaming` messages to `.failed` on next launch. So a failed final save turned
a **successful** turn into a **permanently mislabelled failure** with its text
lost. It now retries once and logs explicitly if both attempts fail.

`loadMessages` was a bare `try?` with no logging at all — the user saw an empty
chat with no error and no breadcrumb. Now `do`/`catch` with the conversation ID.

**F-405 — a corrupt `UserMemory` blob no longer wipes user memory.**
Decode failure reset to `.empty` with no log and no backup, and the next
`persist()` destroyed the original permanently. Since this feeds every system
prompt via `promptBlock()`, the symptom was the assistant abruptly forgetting
the user's name, location and notes. Now the undecodable bytes are quarantined
under `<key>.corrupt` (written once, so a second bad launch can't overwrite the
good copy) and the failure is logged at `.error`.

**F-403 — Knowledge Base documents can no longer be marked "Indexed" with dead vectors.**
`DocumentEmbedder` maps embedding failure to `[]`. The existing uniformity guard
caught *partial* corruption but was blind to *uniform* failure: if the embedder
was unavailable for the whole run (NLContextualEmbedding assets not yet
downloaded — documented and real), every chunk embedded to `[]`, `expected`
became 0, nothing mismatched, and the document was marked `.indexed`.
`cosine()` then scored it 0.0 against every query forever. The user saw
"Indexed" and the model answered as if the document didn't exist.

Added a `dimension > 0` check that fails the document with an actionable Czech
message, plus a backstop in `KnowledgeBaseStore.saveVectors` so no caller can
persist a zero-dimension index. `DocumentEmbedder`'s doc comment already claimed
this behaviour existed; now it does.

**F-303 — `og:image` no longer bypasses the SSRF blocklist.**
`FetchPageSkill`'s primary request is well hardened (host blocklist, scheme
rejection, redirect guard). `extractOGImage` validated only the *scheme*, and
the resulting URL is rendered by `ToolResultChip` with a plain `AsyncImage` —
no blocklist, no redirect guard, no tap. So a fetched page could point
`og:image` at `http://192.168.1.1/...` and the device would issue that GET
against the user's own LAN automatically. Now runs through the same
`isBlockedHost` that was already sitting in the same file.

---

## Open, ranked — for the next round

| ID | Severity | Why it is still open |
|---|---|---|
| **F-301** | CRITICAL | Prompt injection → unconfirmed HomeKit / Reminders writes. Needs a **product decision** (see `00-PLAN.md` Q4) — a confirmation UI changes the agentic UX. Do not fix silently. |
| **F-201** | CRITICAL | No unified prompt-size budget; only history is bounded. The most likely single root cause of bad answers. Needs a `qualityCeilingTokens` per profile plus progressive volatile-layer shedding. |
| **F-203** | CRITICAL | Tool results delivered as a `.user` turn — no `.tool` role exists in `RuntimeMessage.Role`. Structurally out-of-distribution for every model with a real tool protocol. |
| **F-101 rest** | CRITICAL | Cache-tier fields still unguarded; needs a TSan pass. |
| **F-302** | HIGH | Lock Screen widget leaks replies + personal facts, no opt-out. Needs a Settings toggle and a redaction decision. |
| **F-103** | HIGH | Catalog `recommendedFor` still hardcoded to iPad for models that now work on an entitled iPhone. Also: verify shard layout for Mistral 7B and Llama 3.1 8B and set `requiresLargeMmapAddressing`. |
| **F-205** | HIGH | Summarizer input uncapped, skips the context guard, success judged by `!isEmpty`. |
| **F-206** | HIGH | Phi-3 rendered as ChatML in the fallback template path. |
| **F-406..F-410** | HIGH | Remaining silent-failure sites (FileStore duplicate-record, `resetAllModels`, downloader delegate drops, router failure, lifecycle writes). |
| F-105..F-112, F-207..F-211, F-305..F-308 | MED/LOW | See `01-FINDINGS.md`. |

## Notes for whoever picks this up

- **Do not trust a build-configuration change until you have inspected the
  artifact.** Three separate Info.plist bugs shipped because the declaration
  looked right everywhere except the bundle. `make check-plist` after `make build`.
- The `HomeHub.xcodeproj` is generated. Edit `project.yml`, never the pbxproj.
- `swiftlint` / `swiftformat` are in `.swiftlint.yml` but not installed locally,
  so no style gate is running (**F-006**).
- Three of the four review agents independently converged on the missing
  `INFOPLIST_KEY_` prefix. When multiple reviewers find the same thing, prefer
  a guardrail over a point fix — that is what caught the third instance.

---

## Session 2 — 2026-07-23 (afternoon)

Owner supplied device diagnostics from an **iPhone 16 Pro (iPhone17,1,
iOS 26.5.2)** running Gemma 2 2B, plus a reproducible complaint: *"pořád píše
tři bullet pointy"*. Both turned into corrections of Session 1 work.

### Two Session-1 assumptions falsified by device data

**The entitlement ratio test was wrong, in the dangerous direction.**
`kernelEntitlementsGranted` inferred the grant from
`processLimit / physicalRAM`, assuming unentitled ≈ 33–40 %. The device
reports **6137 MB available at launch — 74.9 % of its 8 GB, with no kernel
entitlements**. The 0.48 threshold would have said "granted" on an unentitled
build: generous budgets unlocked with no headroom behind them, i.e. exactly the
jetsam kill this work exists to prevent.

Removed. The two concerns it conflated are now separate:

| Entitlement | Governs | How we know |
|---|---|---|
| `extended-virtual-addressing` | single contiguous mmap ceiling (~2 GB) | declared build flag only — a virtual-addressing limit is invisible to any memory measurement |
| `increased-memory-limit` | how much memory we may use | `os_proc_available_memory()`, measured directly |

**The generous tier was unreachable on the target hardware.** Thresholds were
applied to `physicalRAM × 0.75`. On an 8 GB iPhone that is 6.44 GB → `moderate`.
Generous needed > 9.3 GB physical, i.e. 12/16 GB iPads only — while the tier's
own comment names "iPhone 16 Pro / iPad Pro M2+" as its target. So Session 1's
entitlement fix alone would **not** have given the owner the generous tier.

Tiers now key off the measured limit, sized by what each must hold:

| Tier | Measured limit | Fits |
|---|---|---|
| `.tight` | < 3.0 GB | 2B 4-bit |
| `.moderate` | 3.0 – 5.5 GB | 3B–4B 4-bit |
| `.generous` | ≥ 5.5 GB | 7B–8B 4-bit + full KV |

The device measures ≈ 6.3 GB → correctly reaches `generous`.

### The three-bullet-points bug (F-212)

Reproduced from the diagnostics rather than guessed. Cause is **format
mimicry**, not one bad instruction: `PromptBuilder.toolPolicyBlock` emits 4–6
lines all starting with `- ` when WebSearch is on, and at
`totalPromptTokens: 1570` that is a large share of what a 2B model sees. Small
checkpoints reproduce the dominant surface structure of their context.

Two fixes: a formatting rail for weak models that **names the cause** (small
models follow rules with a reason far better than bare prohibitions), and
inverting the non-weak Balanced block, which said "Use bullet lists for
enumerations" — balanced guidance to a large model, a standing order to a
small one.

### Architectural: F-201 — prompt budget with priority shedding

Replaced the binary `isWeakInstructionFollower` on/off gating of context layers
with an explicit budget.

Before, **only history was budgeted**. `build` measured stable and volatile
token counts purely to publish a diagnostic report, then sent whatever had
accumulated. Layer inclusion was decided by one boolean — a proxy for "will
this fit?", wrong in both directions: a weak model with a two-line prompt was
stripped for no reason, and a strong model on a long thread blew past its
window unchecked.

Now `PromptAssemblyService.ContextLayer` tags each volatile block with a
shedding priority, and `fitVolatileLayers` drops lowest-priority layers until

```
stable + history + userInput + generationReserve + volatile ≤ contextWindow
```

Shedding order: `fileExcerpts → episodes → verbatimRecall → facts → summary`.
`essential` (the date/time rail) is never shed — an oversized prompt is
recoverable, a model that does not know what day it is answers wrongly.

The weak-model heuristics remain (they encode real behavioural knowledge —
verbatim recall genuinely confuses Gemma 3n) but now decide *what to offer*,
while the budget decides *what fits*. Only volatile layers are shed, so the
cached KV prefix — built from the stable half — is untouched.

> **A test caught a real bug in the first implementation.** Removal was by
> layer *name*, but a category can emit several layers (`appendFacts` produces
> one chunk per fact block). Removing "all layers called facts" while
> subtracting one layer's tokens corrupted the running total and shed far more
> than the budget required. Now removal is by index, one layer at a time.

### Architectural: F-203 — tool results get a real `.tool` role

`RuntimeMessage.Role` was `system | user | assistant`, so tool observations
were delivered as **user** turns reading `"<Observation>…</Observation>"` —
out-of-distribution for every model trained with a real tool protocol
(Llama 3.1 `ipython`, Qwen/ChatML `tool`, Mistral `[TOOL_RESULTS]`). The
codebase already recorded the symptom: *"toolFollowup is the one place where
small models routinely produce a single word or a bare noun after seeing the
`<Observation>` tag"*. The minimum-length guard added there treated the
symptom.

`MLXLMCommon.Chat.Message.Role` has a native `tool` case, so this could be
fixed properly rather than worked around:

- `RuntimeMessage.Role` gains `.tool`.
- `MLXChatInput.toNative` maps it to `Chat.Message.tool(_:)`, so it reaches
  the model's **own Jinja chat_template** and is rendered in whatever wire
  format that checkpoint was actually trained on.
- `ChatTemplate` (llama.cpp / fallback) maps per family: ChatML `tool`,
  Llama 3 `ipython`, and for Gemma — which has no tool role — a user turn
  prefixed with an explicit `[Tool result — automated output, not written by
  the user]` label.

`Message.Role` (the **persisted** enum) is deliberately unchanged. Adding a
case would force a storage migration on every device to represent a turn that
is never persisted. `ToolObservationEnvelope` carries the signal instead, as
the single source of truth for both the writer and the recogniser. Its
`matches` is anchored at both ends so a user *asking about* `<Observation>`
tags is not silently reclassified as a machine-generated result — covered by
test.

### Tests added

`HomeHubTests/PromptBudgetSheddingTests.swift` — 8 tests, all passing:
shedding order, essential-never-shed, priority order independent of input
order, empty input, and four envelope-recognition cases.

### A bug I introduced, and how it surfaced (worth reading)

The measured-limit change broke **10 tests** that had been passing. Root cause:

`os_proc_available_memory()` returns **0 on the iOS Simulator** — the process is
not under a jetsam limit there at all. My `processMemoryLimitBytes()` guarded
against `task_info` failing but treated a 0 availability as a real reading, so
the sum collapsed to `phys_footprint` alone (a few hundred MB). That classified
the machine with the *most* memory into the *tightest* tier, giving a
1024-token context window, which made the new budget negative and shed every
context layer out of the prompt.

Evidence was sitting in the logs the whole time — every simulator breadcrumb
reads `avail=0MB`, while the same build on the iPhone logs `avail=6137MB`.

Fixed by treating 0 as "unknown" and falling back to the 0.75 × physical
estimate. All 10 tests returned to their baseline state.

Two lessons recorded because they generalise:

- **A guard on the API call is not a guard on the value.** `KERN_SUCCESS` from
  `task_info` said nothing about whether `os_proc_available_memory()` had an
  answer.
- **The failure was inverted, not just inaccurate.** Under-reporting memory did
  not make the app slightly conservative; it made the tier *classification* pick
  the opposite extreme. Anything that derives a category from a measurement
  should be checked against a bad reading, not only a missing one.

---

### F-103 — catalog gating is entitlement-aware

`recommendedFor` is a compile-time literal, so it could never know whether the
running build was entitled. `LocalModel.effectiveRecommendedFor` resolves it at
runtime, adding `.iPhone` only when the build declares the entitlements **and**
the device measures into the `generous` tier. It only ever widens the list.

Consumed by `ModelsView.isRiskyOnPhone` and the browser's "iPhone safe" filter.
Advisory only — the binding checks stay in `MLXRuntime`'s per-shard pre-flight
and `RuntimeManager.evaluateFeasibility`.

Also set `requiresLargeMmapAddressing: true` on Mistral 7B v0.3 and Llama 3.1 8B,
which lacked it while same-size-class siblings had it. Erring towards `true` on
an unverified shard layout is the safe direction: a false positive costs one
advisory line, a false negative costs a 4 GB download to a guaranteed failure.

---

## Session 3 — 2026-07-23 (evening)

Owner confirmed **full Apple Developer access is now active** and asked for the
model catalog to be refreshed ("app was built several months ago, and we no
longer have the limits").

### Catalog refresh — verified, not guessed

Every figure below was read from
`https://huggingface.co/api/models/<repo>/tree/main`, because a wrong repo id is
a 404 and a wrong `requiresLargeMmapAddressing` is a multi-GB download that ends
in a refusal. The catalog was a generation behind: Llama 3.1/3.2, Gemma 2,
Qwen2-VL, Phi-3.5, SmolLM2. Missing entirely: the **Qwen3** line, **Gemma 3**,
LFM2.5, and the current Qwen3-VL vision models.

| Added | Repo | Weights (verified) | Needs entitlement |
|---|---|---|---|
| Qwen3 4B Instruct 2507 | `Qwen3-4B-Instruct-2507-4bit` | 2.263 GB | yes |
| Qwen3 1.7B | `Qwen3-1.7B-4bit` | 968 MB | no |
| Qwen3 8B | `Qwen3-8B-4bit` | 4.608 GB | yes |
| Gemma 3 1B QAT | `gemma-3-1b-it-qat-4bit` | 733 MB | no |
| Gemma 3 4B QAT (vision) | `gemma-3-4b-it-qat-4bit` | 2.995 GB | yes |
| LFM2.5 1.2B | `LFM2.5-1.2B-Instruct-4bit` | 659 MB | no |
| Qwen3-VL 2B | `Qwen3-VL-2B-Instruct-4bit` | 1.782 GB | no |
| Qwen3-VL 4B | `Qwen3-VL-4B-Instruct-4bit` | 3.094 GB | yes |

All ship a **single** `model.safetensors` (the accompanying
`model.safetensors.index.json` indexes that one file), so the largest shard is
the whole weight file — which is what the ~2.1 GB sandboxed mmap ceiling applies
to. `sizeBytes` is weights + tokenizer assets, i.e. what actually downloads.

Nothing was removed: users may have older models installed.

### Three prerequisites the new names would have broken silently

Adding entries alone would have shipped three quiet failures:

1. **`familyEndOfTurnStops` matched family names by exact equality** — so
   `"Qwen3"` fell to `default: []` and got **no end-of-turn stops at all**.
   That is F-208. Now substring-matched, which also means the next generation
   (Qwen4, Gemma5) keeps working without a code change.
2. **Qwen VLM detection was an exact list** (`"qwen-vl"`, `"qwen2-vl"`), so
   `Qwen3-VL` — now the most-downloaded VLM on mlx-community — resolved to the
   *text-only* profile with `supportsVision: false`.
   `shouldUseVisionInputPath` would then refuse the VLM path and **silently
   drop the attached image**, leaving the user with an OCR-only answer.
3. **`recommendedStarter` depended on array order.** It returned the first
   iPhone-safe MLX model, so inserting a modern 1.7B near the top silently made
   onboarding default to a *weak* instruction follower, forcing lean prompt
   mode. Only the catalog consistency test caught it. Now a predicate
   (`!isWeakInstructionFollower`) rather than an ordering convention — the
   invisible contract is written down and enforced.

### F-301 — prompt injection can no longer drive real-world writes

Implemented as an **information-flow rule**, not injection detection.

`Skill` gained two members: `isStateChanging(input:)` (per-invocation, because
`HomeKitSearch "status"` reads while the same skill with a payload writes) and
`producesUntrustedContent` (true for `WebSearch` and `FetchPage`). Once a turn
runs a skill of the second kind, `SkillManager` refuses skills of the first kind
for the rest of that turn.

Why this framing: detecting the injection in page text is not reliable and never
will be. Tracking *where the content came from* is reliable, because it is a
property of our own call graph rather than of the attacker's prose. Reading the
web stays always allowed; acting on the world after reading the web does not.

Cost to legitimate use is near zero — "add milk to my reminders" involves no web
content and runs untouched. Only "read this page, then change something" is
refused, and the user can still do it in two messages. The taint is **turn**-
scoped, not conversation-scoped, for exactly that reason.

Two details the tests forced:

- **The guard runs before the permission check.** It was initially placed after,
  so on a device without Reminders access an injected write returned
  "permission missing" — actively misleading, and behaviour would have differed
  between a device that had granted access and one that had not. Whether a call
  is *allowed* does not depend on whether it would have *succeeded*.
- **`CalendarSkill` is read-only.** The security review listed it as a write
  path; the code has no `EKEvent(` or `.save(` anywhere. Left unrestricted
  rather than adding a limit the code does not need.

A full per-action confirmation UI would still be better, and
`Skill.isStateChanging(input:)` exists as its foundation. This closes the
demonstrated hole without blocking on a UX decision.

> **Noted, not fixed:** the reminder-*creating* skill is registered as
> `"RemindersSearch"` and the HomeKit control skill as `"HomeKitSearch"`. Both
> read as read-only in the Settings tool list, and both are on by default. The
> names are load-bearing — they are the tag the model emits and are persisted in
> `AppSettings.enabledTools` — so renaming needs a migration.
> `ToolInjectionGuardTests.testRegisteredNameIsMisleading` pins the current
> values so the rename, when it happens, is deliberate.

### Tests added

`HomeHubTests/ToolInjectionGuardTests.swift` — 12 tests: state-changing
classification for each skill, untrusted-source marking, the registry lookup,
and the guard itself (refuses a write on a tainted turn, still allows a read).

---

## Session 5 — 2026-07-24

### Housekeeping first: `main` was 12 commits stale

The round opened on the assumption that `production-readiness/2026-07` was
merged. It was — as PR #58 on the remote — but the local `main` still pointed at
`271a7f6`, so `docs/production-readiness/` did not exist in the working tree and
the handover could not be read from disk. Fast-forwarded before anything else.

Worth recording because the failure mode is silent: every file the handover
referenced was present on the *branch* and absent from the *checkout*, which
reads as "the docs were never written" rather than "you are on the wrong commit".

### The failing-test names were never written down

`01-FINDINGS.md` (F-007) and `04-NEXT-ROUND.md` both instruct the next round to
compare failing-test **names** against the baseline. Neither records the names.
So the instruction could not actually be followed without first reproducing a
baseline run.

Fixed by capturing the pristine set into `07-TEST-BASELINE.md` (see below) from
a run in a detached worktree at `5449523`. Future rounds diff against that file
instead of spending a full clean build rediscovering it.

### `mlx.generate.prefillStart` breadcrumb

Added in `MLXRuntime.swift`, between "generation requested" and "the model is
decoding".

Motivated by how F-008 failed rather than by a new defect. When Gemma 3 4B killed
the process, the last breadcrumb was `mlx.generate.start` — which is written
*before the ChatSession is constructed*. The trail therefore could not separate
"crashed building the session" from "crashed in prefill", and that ambiguity is
what made the F-011 follow-up necessary as a separate device round.

With the crumb, a crash locates itself:

| Last crumb | Fault domain |
|---|---|
| `mlx.generate.start` | ChatSession construction / KV setup |
| `mlx.generate.prefillStart` | prefill or decode inside MLX |

It carries `supportsVision` and `path`, which is precisely the open F-011
question. Scalars are snapshotted into locals before the `Task { @MainActor }`
hop so the closure captures no non-Sendable `[Chat.Message]`.

### Deep Search — design agreed, no code yet

`06-DEEP-SEARCH-DESIGN.md`. The governing claim: Perplexity-grade quality comes
from the retrieval pipeline, not from a clever model — which is what makes it
reachable on a 2 B on-device checkpoint at all.

The current design delegates five of six retrieval decisions to the model, each
costing a generation pass, against `maxLoops = 4` and a ~90 s budget. A thorough
multi-source answer is not unlikely under that arrangement, it is structurally
unreachable. The proposal replaces the agentic search loop with one deterministic
research pass plus one synthesis pass.

Decisions settled with the owner: explicit trigger (not model-invoked, not
auto-classified); generous + moderate tiers only; inline `[n]` citations with a
deterministic attribution pass as the safety net; **staged delivery**.

Stage 1 (passage extraction, ranking, budgeting, evidence fencing on the existing
single-search path) adds **no new network or privacy surface**, so it is not
blocked on the outstanding device checks. Stage 2 is gated on F-303 and F-403 —
both are inside components the design leans on, and both fail silently today.

### F-007 — one real defect, the rest was test rot

A source-only diagnosis pass was run against the 25-test baseline before
touching anything. The instruction it was given mattered: decide **per test**
whether the TEST is stale or the PRODUCT is wrong, and do not paper over a
defect by adjusting an assertion.

That distinction paid for itself exactly once, and it was worth the whole pass.

#### The defect: `ModelRouter` depth markers were unreachable

`ModelRouter.classify` evaluates in order: image → backticks → code markers →
**`charCount < 60 → .fast`** → `> 500 → .smart` → **depth markers** → `.balanced`.

The depth-marker block sat *after* the short-input early return, so it could
never fire for a short prompt. Its own comment two lines above read *"even a
short prompt with these wants the bigger model"*, and the class header states
the rule as a disjunction — *"> 500 chars **OR** contains explicit … markers"*.
Both descriptions were correct; the ordering contradicted them.

Effect on the product: `"vysvětli detailně proč je nebe modré"` is 36 characters,
so a user explicitly asking for depth was routed to the **smallest** model. The
block was only reachable in the 60–500 char band — where it matters least.

`"porovnej Swift a Rust ohledně paměti"` passed only by accident: `"swift "` is
in `codeMarkers`.

Fixed by moving the depth-marker check ahead of the length gate. Two tests went
green with no test change, which is the signal that they were pinning real
behaviour rather than rotting.

> Also corrected a doc/code disagreement found alongside it: the comment claimed
> "normal questions land in 40–500 chars" while the code used 60.

#### The rot: three deliberate redesigns, tests never adapted

| Redesign | Commit | Tests left behind |
|---|---|---|
| extraction pipeline inverted to cheapest-first | `093f6f7` | 4 × `MemoryServiceTests` |
| universal tool-call parser | `bc8a21c` | 2 × `ToolCallEnvelopeTests` |
| stable/volatile prompt split | `1f49369` | `PromptAssemblyTests.testLayerOrdering` |

**`MemoryServiceTests`** — the fixtures could not reach Layer 3. Structured
extraction now requires `candidates.isEmpty && content.count >= 40`;
`"I work at Apple on the SwiftUI team"` is 35 characters *and* fires the
`"i work at"` keyword trigger, so it failed both halves. The tests asserted
`.structured` against a `.heuristic` candidate. New fixtures clear both gates.

Two further `MemoryServiceTests` were brittle rather than wrong: Layer 2
(`NLTagger`) runs *additively*, so `"Alex"` adds a `.relationships` candidate
alongside the Layer-1 one. `allSatisfy { == .heuristic }` and
`XCTAssertTrue(candidates.isEmpty)` after a single `reject` both depended on
NLTagger's OS-version behaviour. Rewritten to assert the contract instead: that
the cheap layers answered and Layer 3 did not run, and that `reject` removed
exactly the candidate it was given.

**`ToolCallEnvelopeTests`** — both relaxations are correct and now documented:

- *Missing `input` → empty input, not nil.* `DeviceInfoSkill.execute` ignores
  its input entirely, so `{"name": "DeviceInfo"}` is a well-formed call.
  Requiring the field would reject every no-argument skill.
- *Dropped closing tag → salvaged.* Small models drop tags routinely. The safety
  argument rests on brace **balance**: a generation truncated mid-JSON cannot be
  recovered. Rather than delete the coverage, a new
  `testUnbalancedJSONIsNotSalvaged` pins that boundary — the two tests are only
  meaningful as a pair.

**`PromptAssemblyTests.testLayerOrdering`** — was asserting ordering *across* the
stable/volatile halves via the legacy concatenating `systemPrompt` getter. The
privacy guardrail moved to the stable half deliberately (KV-prefix reuse), and
in production the volatile half is not appended to the system prompt at all —
`MLXRuntime` injects it into the user turn inside `<context>`. The old
assertion measured an artifact of the legacy getter. Now asserts ordering
*within* each half.

Stale prose corrected in the same pass: `SkillManager.parseAction`'s doc still
claimed a missing `input` returned nil.

#### Not touched, deliberately

`SkillManagerTests` and `SwiftDataStoreTests` were traced and **no source-level
cause was found**. `SwiftDataStoreTests.testStoreInitializesSuccessfully` builds
a real on-disk `ModelContainer` in the host app's process; the plausible causes
are on-disk or simulator state, not source. The tempting fix — switch it to
`isStoredInMemoryOnly: true` — would silently delete the only coverage of the
production init path, so it was left alone pending a confirmed diagnosis.

### Disk exhaustion masqueraded as a build failure

A test run failed with `ld: write() failed, errno=28` and
`clang: error: linker command failed`. Read literally that is a linker problem;
`errno 28` is **ENOSPC**. The volume had **169 MB free of 113 GB**.

Cause was self-inflicted: the pristine-baseline worktree got its own
`DerivedData` (1.2 GB of MLX build products) alongside the main tree's 2.5 GB.
Both worktree and its DerivedData removed once the baseline set was extracted.

Worth recording because the presenting symptom points at the wrong layer
entirely — nothing in that error mentions disk, and the natural next move is to
go looking for a code defect that isn't there.

> `~/Library/Developer/Xcode/iOS DeviceSupport` holds 5.7 GB for
> `iPhone17,1 26.5.2` and `CoreSimulator/Devices` another 8.5 GB. Both are
> reclaimable but belong to the owner's active debugging setup — deleting the
> DeviceSupport for the device currently under test would force a slow symbol
> re-download on next attach. Left alone.

### F-403 (retrieval half) + hybrid retrieval — the deep-search Stage 1 quality step

F-403 was marked OPEN in the register but its **ingest half was already fixed**
in `37c7dcb` (the pipeline throws code -5 when every chunk embeds to a
zero-dimension vector). The **retrieval half was still silent**: if the query
itself could not be embedded, `retrieve` returned `[]` with no log — the same
"documents answer as if they don't exist" failure, one layer down.

Closed both by making retrieval hybrid rather than dense-only.

**`LexicalRetrieval.swift`** — BM25 + Reciprocal Rank Fusion as a pure `enum` of
static functions. Design choices worth recording:

- **BM25, not TF-IDF.** Chunks vary in length; BM25's `b` term stops a short
  chunk that repeats a term from burying a long one that discusses it. `k1=1.2`,
  `b=0.75` are the standard TREC defaults.
- **Non-negative IDF.** The textbook IDF goes negative for terms in more than
  half the corpus, which on a small corpus would let a common word *subtract*
  from a score. The `log(1 + …)` form prevents it. Pinned by
  `testCommonTermNeverContributesNegativeScore`.
- **Diacritic folding, no stemming.** Czech users type "hlaseni" for "hlášení",
  so folding is required. Stemming ("pracoval"/"práce") is deliberately left to
  the embedder — a hand-rolled Slavic stemmer trades a real false-positive risk
  (wrong passages in the prompt) for a benefit the dense half already provides.
- **RRF over weighted sum.** BM25 is unbounded, cosine is [-1, 1]; any weighted
  sum needs a normalisation that drifts with corpus size. RRF consults only
  positions, so it is scale-invariant and tuning-free. Pinned by
  `testFusionIsScaleInvariant`.

**`KnowledgeBaseRetrievalService.retrieve`** now attempts dense, always computes
lexical, and fuses. `minRelevance` stays a dense-only cosine threshold (applying
it to a BM25 or fused score compares unrelated scales). A missing embedder
degrades to lexical with an `.error` log; a corpus of all-zero vectors (indexed
before the ingest guard) is named explicitly. `RetrievedChunk` gained
`matchKind` and `rank` so a caller can distinguish "corpus empty" from
"lexical-only fallback".

**Verification:** 12 new tests, all pass. Full suite 677 pass / 14 fail, and the
14 are *byte-identical* to the post-F-007 failing set — the retrieval work added
zero failures. Confirmed by name-diff, not exit code.

> One build lesson re-learned: `Logger.error(_:)` takes an `OSLogMessage` built
> from a **string literal**. A message assembled with `+` concatenation is a
> runtime `String` and does not conform — it compiles nowhere near the call site
> in the error message ("cannot convert value of type 'String' to expected
> argument type 'OSLogMessage'"). Long log lines must be a single literal.

This is the ranking half of deep-search Stage 1 (`06-DEEP-SEARCH-DESIGN.md`).
What remains for Stage 1: passage-level chunking of a fetched page, fitting
passages to the window via the F-201 shedding mechanism, and the one-sentence
evidence fence.

### Review response — hybrid retrieval hardened before commit

An independent `swift-reviewer` pass over the retrieval diff returned **no
CRITICAL/HIGH**; it hand-verified the BM25 math, the RRF fusion, the
dense/lexical index alignment, and the `matchKind` classification as correct,
and confirmed no Sendable/data-race issues. The MEDIUM/LOW items were addressed:

- **Lexical-only cap (the one that mattered).** Dense hits must clear
  `minRelevance`; a lexical hit needs only to share a token, and RRF lets a
  chunk survive on one ranker alone. Unbounded, that widens the injection
  surface: an imported web page crafted to be keyword-dense in likely-asked
  vocabulary could take several `maxChunks` slots on `.lexical` matches with no
  topical support, displacing relevant chunks. Now lexical-**only** survivors
  are capped (default 2) *when dense scoring is available*; the cap lifts when
  the embedder is unavailable, because then lexical is the only signal and
  capping it would cripple the fallback. An absolute BM25 floor was rejected for
  the same reason RRF beats a weighted sum — BM25 is unbounded and corpus-scaled,
  so a fixed threshold drifts.
- **Extracted `fuseAndRank` as a pure, tested function.** The fuse + cap +
  classify logic — which owns the index-alignment invariant — was inline in the
  actor's `retrieve`, where it could only be hand-verified. It is now a static
  function with 8 unit tests (`KnowledgeBaseRetrievalFusionTests`) covering
  hybrid/dense-only/lexical-only classification, the cap, the degraded path, and
  bounds. This closes the reviewer's "riskiest invariant has no automated
  coverage" finding without a DI refactor.
- **Doc-comment correctness.** `RetrievedChunk.similarity` claimed "0 for a
  `.lexical` match" unconditionally; that only holds when dense scoring never
  ran. When dense ran, a lexical-surfaced chunk carries its real sub-threshold
  cosine (more informative than zero). Comment corrected to match.
- **Cancellation.** A `Task.checkCancellation()` was restored before the lexical
  pass, so a task cancelled during the dense pass does not also pay for BM25.
- Complexity doc-comment corrected (`O(tokens) + O(queryTerms × docs)`).

**Deferred, with reason:** a full integration test *through* `retrieve` needs
`KnowledgeBaseStore` and `EmbeddingService` behind protocols — both are concrete
actors today. That DI refactor is worth doing but widens the blast radius past a
retrieval change, so it is left for its own round. Extracting `fuseAndRank`
captures the risky logic in the meantime. A web-page-specific (vs. global)
lexical cap was also considered and left out as premature — the global cap
bounds the exposure regardless of source.

---

## Session 6 — 2026-07-24 · device diagnosis + two fixes

Štěpán ran the device checks and sent crash reports, breadcrumbs, and a
diagnostic export. The data reframed two findings and produced two fixes.

### The Qwen family cannot load — tokenizer, not vision (F-011 resolved, F-013)

F-011 predicted Qwen3-VL would crash on the text-path smoke test. It doesn't — it
fails earlier and cleanly, at tokenizer load:
`unsupportedTokenizer("Qwen2Tokenizer")`. swift-transformers 0.1.14's
`knownTokenizers` has no `Qwen2Tokenizer`, and **the entire Qwen 2/2.5/3 family
declares it** — confirmed by fetching all seven catalog repos' tokenizer_config
(3 text + 4 vision, all `"tokenizer_class": "Qwen2Tokenizer"`). This is the same
wall that already sank Qwen 2.5 3B (documented at `ModelCatalogService.swift:686`);
the catalog refresh re-hit it, the F-010 lesson recurring.

**Fixed by remap, not withdrawal** (owner's call). `Qwen2Tokenizer` is byte-level
BPE — structurally identical to the GPT-2/Llama/Gemma tokenizers swift-transformers
*does* support, all of which are literally empty `: BPETokenizer {}` subclasses. A
tokenizer's behaviour comes entirely from `tokenizer.json`; the class name only
picks the driver. So `SwiftTransformersTokenizerLoader` now rewrites
`Qwen2Tokenizer → PreTrainedTokenizer` before construction, using the identical
code path swift-transformers would run if it registered the class itself. The
remap is an allowlist of one (a blanket "unknown → BPE" could mistokenise a
SentencePiece model). Verified sound by reading swift-transformers'
`PreTrainedTokenizer.init` (all pipeline stages built from `tokenizer.json`,
`Tokenizer.swift:233-240`).

Six CPU unit tests (`TokenizerRemapTests`) cover the decision table. End-to-end
tokenisation correctness (does the remapped tokenizer produce coherent Qwen
output) is a device check — a faithful fixture would need the real ~7 MB Qwen
`tokenizer.json`, and a hand-built one risks a `fatalError`-on-missing-merges
runner crash for less confidence than the source proof already gives.

### F-012 · uncatchable SIGTRAP in the repetition-penalty sampler

The three `.ips` are one crash, not OOM and not the vision path:
`RepetitionContext.didSample → TokenRing.append → MLX.where → _mlx_error →
assertionFailure → brk 1`. MLX's default error handler turns an internal `where()`
broadcast error into an uncatchable SIGTRAP. It is activated by our config —
`repeatPenalty` defaults to 1.1, applied even on the 4-token post-load smoke test —
so it can brick the app on model load. **This likely re-diagnoses F-008**: Gemma 3
4B's "generate.start maxTokens=4 → died" pattern matches a smoke-test sampler
crash, not the multimodal-container routing originally hypothesised.

**Fix: `MLX.withErrorHandler` wrap.** The native decode loop now runs inside a
scoped handler that records MLX-internal errors; the loop throws on the next
iteration, dropping the (poisoned) session, and the existing generation `catch`
turns it into a clean `.failed` turn. The wrap is **strictly ≥ current behaviour**:
if the error fires outside the handler's thread scope, MLX aborts exactly as it
does today — the box just never fills. It can rescue, never regress, which is why
it is safe to ship before device confirmation. **Whether it actually catches this
crash is device-pending** (`05-DEVICE-CHECKS.md` Check B) — the F-008/F-010 rule
means the *efficacy* claim waits on hardware, even though the change is safe.

Not shipped: a blind sampler change (removing repetition penalty). The trigger is
strongly evidenced but unconfirmed, and the project rule is to say so rather than
guess. The device round confirms it (smoke test with `repeatPenalty = 1.0`).

---

## Session 7 — 2026-07-24 · F-012 root-caused; Noema set as the bar

### The app could not generate a single token

Four more crash reports arrived from a build that **already contained session
6's `withErrorHandler` wrap**. Identical stack, four crashes in 25 seconds. Both
halves of that were informative.

**The scoped wrap was ineffective, and the stack said why.** MLX evaluates inside
`ChatSession.streamMap`'s own detached task (`completeTaskWithClosure` on
`com.apple.root.default-qos.cooperative`, under `SerialAccessContainer.update` →
`AsyncMutex.withLock`) — a different task from the consumer loop the handler was
scoped around, so it was never active where the error was raised. Session 6 had
flagged exactly this as a possible outcome and shipped it anyway because the wrap
was strictly ≥ current behaviour; the device settled it. Replaced with a
process-wide handler via `MLX.setErrorHandler` in `MLXRuntime.init`, which has no
scope gap.

**The cause was an upstream rank bug.** `TokenRing.loadPrompt` reads the prompt
length as `prompt.dim(0)`, but the prompt is rank-2 `[1, seqLen]` — so it takes
the batch size (1). The ring becomes `[seqLen + capacity - 1]` instead of
`[capacity]`, and `TokenRing.append`'s
`MLX.where(mask[capacity], token, buffer)` cannot broadcast. MLX raises, its
default handler `assertionFailure`s, process dies on an uncatchable SIGTRAP.

The deduction closes without needing to run anything: `where` here can only fail
when `buffer.count != capacity`, and a **1-D prompt cannot produce that** — short
prompts pad to exactly `capacity`, long prompts slice to exactly `capacity`. The
rank-2 branch is the only path that can fail, and it fails for every prompt over
one token.

**Severity was higher than session 6 assessed.** `repeatPenalty` defaults to 1.1
and `processor()` builds the context whenever `repetitionPenalty != nil &&
repetitionContextSize > 0`, so this fired on *every generation of every model*,
including the post-load smoke test. Generation was impossible app-wide. That is
almost certainly the "hodně modelů nefunguje" reported across several rounds — it
was never per-model.

**It also re-diagnoses F-008.** Gemma 3 4B's breadcrumb signature
(`generate.start maxTokens=4` → death) is this sampler crash on the smoke test,
not the multimodal-container routing originally inferred. Its withdrawal may have
been unnecessary; flagged for re-test.

Fixed by passing `repetitionPenalty: nil` / `repetitionContextSize: 0`.

> **Cost, stated plainly.** The anti-repetition pressure that targeted Czech
> replies bleeding Russian/Spanish tokens is gone. It never actually ran in
> production — it crashed — so nothing regressed against observed behaviour, but
> the underlying quality risk returns. Restoring it needs our own
> `LogitProcessor` with a correct ring buffer (A1), **not** re-enabling the flag.

### Noema recorded as the bar to clear

The owner found **Noema — Local AI & Offline LLM** and set it as the standard
HomeHub has to reach *as a whole product*, not as a feature checklist. Written up
in `08-IMPROVEMENTS.md` §E with a side-by-side table and an ordering by ground
covered.

The honest conclusion from that comparison: **the top of the list is reliability,
not features.** Their entire feature set presupposes that generation works, which
until this session ours did not. Their user-facing Benchmarking Center is
explicitly *low* priority — our own measurement needs (F-104's real budgets, the
deep-search latency table) are better served by targeted instrumentation.

Also recorded: where HomeHub is already ahead (the F-301 information-flow
injection guard, the SSRF-hardened fetch path, entitlement-aware memory tiers,
the silent-failure work) so those are not traded away while chasing breadth.

### Verification

Suite 691 pass / 14 fail, failing set byte-identical to the previous run — zero
regressions. Disk hit ENOSPC mid-session again; scratch logs are now deleted
after extracting the failing-name sets.
