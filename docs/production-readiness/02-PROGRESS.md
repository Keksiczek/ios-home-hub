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
