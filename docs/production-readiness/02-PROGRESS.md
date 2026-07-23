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
