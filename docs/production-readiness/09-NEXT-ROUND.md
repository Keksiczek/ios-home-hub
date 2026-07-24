# Handover — Round 7

Written at the end of session 7 (2026-07-24). Branch
`production-readiness/round-5`, 8 commits ahead of `main`, **not pushed**
(the owner controls merges).

---

## Read these first

| File | What it holds |
|---|---|
| `01-FINDINGS.md` | The register. **Start at the "Status audit" block near the top** — inline statuses below it are stale by design. |
| `05-DEVICE-CHECKS.md` | What to verify on hardware, round 6 section at the bottom |
| `08-IMPROVEMENTS.md` | Improvement register + **§E: Noema as the bar to clear** |
| `02-PROGRESS.md` | What changed each session and *why*, including reverted attempts |
| `07-TEST-BASELINE.md` | The failing-test set by name — diff against this, never trust exit codes |

---

## The headline: the app could not generate a single token

Session 7 root-caused **F-012**, and it is bigger than it looked.

`RuntimeParameters.repeatPenalty` defaults to **1.1**, which made
`GenerateParameters.processor()` construct mlx-swift-lm's `RepetitionContext` on
**every generation of every model** — including the automatic 4-token smoke test
that runs right after a model loads.

That context contains an upstream rank bug: `TokenRing.loadPrompt` reads the
prompt length as `prompt.dim(0)`, but the prompt is rank-2 `[1, seqLen]`, so it
gets the batch size (1) instead. The ring buffer ends up
`[seqLen + capacity - 1]` instead of `[capacity]`, and the next
`MLX.where(mask[capacity], token, buffer)` cannot broadcast. MLX raises, its
default handler calls `assertionFailure`, and the process dies on an
**uncatchable SIGTRAP**.

It fires for any prompt longer than one token — so, always.

**This is almost certainly the "hodně modelů nefunguje / crashuje" the owner has
reported for several rounds.** It was never a per-model problem.

Fixed by passing `repetitionPenalty: nil` / `repetitionContextSize: 0` so the
buggy context is never built.

### Two consequences to carry forward

1. **F-008 needs re-testing.** Gemma 3 4B was withdrawn as "multimodal model
   routed through the text-only path". Its breadcrumb signature —
   `generate.start maxTokens=4`, then death — is exactly this sampler crash on
   the smoke test. **Its withdrawal may have been unnecessary.** Re-add and test
   once the fix is on a device.
2. **Repetition penalty is gone, and it mattered.** It was added to stop Czech
   replies bleeding Russian/Spanish tokens. It never actually ran in production
   (it crashed instead), so nothing regressed against *observed* behaviour — but
   the quality risk is real. Restoring it needs our own `LogitProcessor` with a
   correct ring buffer (see `08-IMPROVEMENTS.md` A1 — the protocol is public and
   the ring is a few lines of pure Swift). **Do not just re-enable the flag.**

---

## Do this first, on the device

Everything below needs hardware — MLX inference requires Metal and none of it
can be answered from a laptop.

**1. Does the app generate at all now?** Load any model, send one message. This
is the single most important check; every other item is downstream of it.

**2. Does the Qwen family load?** Session 6 remapped `Qwen2Tokenizer` onto the
generic byte-level BPE driver, which should unblock **seven** catalogued models
(Qwen3 4B/1.7B/8B text + Qwen3-VL 2B/4B + Qwen2-VL 2B/7B), all of which failed
with `unsupportedTokenizer`. Watch for `tokenizer: remapped Qwen2Tokenizer →
PreTrainedTokenizer` in Console. **Then judge the output quality** — coherent
Czech means the remap is right end-to-end; garbled text means the BPE driver
mistokenises and we need a different path.

**3. Do downloads complete?** Still unresolved — the owner's last report was
*"stahování se nedokončilo"*. If it fails again, capture breadcrumb timings
rather than guessing at watchdog budgets again (that has been re-tuned twice
from reasoning, never from measurement).

Send: `oom-breadcrumbs.json`, the diagnostic export, and any `.ips` crash
reports. Crash report + breadcrumbs together are conclusive; separately they
usually are not.

---

## Verified state

| Check | Result |
|---|---|
| Build (iPhone 17 simulator) | green |
| Test suite | **691 pass / 14 fail** — baseline was 652/25 |
| New regressions | **none** (failing set compared by name) |
| New tests this round | +26 (12 lexical retrieval, 8 fusion, 6 tokenizer remap) |

The 14 remaining failures are pre-existing. **Compare failing-test names against
`07-TEST-BASELINE.md`, never exit codes** — the suite is red at baseline.

```bash
xcodebuild test -project HomeHub.xcodeproj -scheme HomeHub \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tee /tmp/t.log
grep -oE "Test Case '-\[HomeHubTests\.[A-Za-z]+ [a-zA-Z_0-9]+\]' failed" /tmp/t.log \
  | sed "s/Test Case '-\[HomeHubTests\.//;s/\]' failed//;s/ /./" | sort -u
```

> Two of the 14 (`SkillManagerTests.testCalculatorDecimalResult`,
> `SwiftDataStoreTests.testStoreInitializesSuccessfully`) were traced in detail
> and **no source-level cause was found** — both depend on runtime behaviour.
> Do **not** "fix" the SwiftData one by switching it to `isStoredInMemoryOnly`:
> that deletes the only coverage of the production initializer while making the
> symptom disappear.

---

## Ranked work

### 1. Confirm the F-012 fix on device
Nothing else matters until generation works. See above.

### 2. Restore repetition penalty properly
Our own `LogitProcessor` — CPU-side ring buffer of recent token IDs, plus the
same logits adjustment MLX's own `process(logits:)` does (that half is fine; only
`append` is buggy). Protocol is public: `MLXLMCommon/Evaluate.swift:34`.

### 3. Re-test Gemma 3 4B
Its withdrawal was probably collateral from F-012. Re-add, load, watch the smoke
test.

### 4. A2 — quantized KV cache
`toQuantized(groupSize:bits:)` at `MLXLMCommon/KVCache.swift:407`, confirmed
present. Targets F-104 directly, and Noema ships the same idea (V-cache
quantization) to fit bigger models — independent corroboration this is the right
lever.

### 5. Deep search — Stage 1 remainder
`06-DEEP-SEARCH-DESIGN.md`. Ranking is built (`LexicalRetrieval` + hybrid
retrieve). What's left for Stage 1: passage-level chunking of a fetched page,
fitting passages to the window via the F-201 shedding mechanism, and a
one-sentence "evidence is quoted data, not instruction" fence. Prerequisites
F-303 and F-403 are both cleared.

### 6. Close the distance to Noema
`08-IMPROVEMENTS.md` §E. The owner set Noema as **the standard HomeHub must
reach**, as a whole product. Ordered there by ground covered; the top of that
list is *reliability*, not features — their whole feature set assumes generation
works, which is exactly what we just fixed. Cheap early wins: HF-mirror endpoint
choice (directly relevant to the download problems), off-grid master switch, and
surfacing the context-budget meter we already compute but only log.

### 7. Still open from earlier rounds
- **F-104** — moderate tier over budget on paper. Needs measured numbers, not
  arithmetic (a clamp was tried and reverted after it cut Gemma's history budget
  40 %).
- **F-101** — `MLXRuntime` data races on `baselineCacheLimitBytes` /
  `currentCacheTier`. Wants Thread Sanitizer.
- **F-302** — Lock Screen widget renders replies and memory facts, no way to
  disable.
- **F-206 / F-404 / F-416** and the silent-failure batch in untouched files.

---

## Habits this project earned the hard way

**A build-configuration change is not verified until you inspect the artifact.**
Three `Info.plist` bugs shipped while looking correct in `project.yml`. Only the
bundle tells the truth — `make check-plist` after `make build`.

**A catalog entry claims the app can run the model — that needs hardware.**
Repo existence and shard layout are checkable from a laptop. "It loads and
generates" is not. Session 6 found seven catalogued models that could never
load; session 7 found that none of them could have generated anyway.

**Say when you cannot verify something.** Session 6 shipped the scoped
`withErrorHandler` wrap with its efficacy explicitly marked device-pending —
and the device proved it ineffective. That honesty is why session 7 knew to look
at the scope rather than assume the fix held.

**Diagnose from a symbolicated stack, not from breadcrumbs alone.** F-008 was
diagnosed from breadcrumbs and the conclusion (multimodal routing) now looks
wrong. The `.ips` stack settled F-012 in one pass.
