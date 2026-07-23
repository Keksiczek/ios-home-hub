# Handover — Round 5

Written at the end of session 4 (2026-07-24). Everything below is either
verified on device, verified by test, or explicitly marked unverified.

Branch `production-readiness/2026-07` is pushed and **fast-forward mergeable**
into `main` (11 commits, `2036235`…`cd0e0b0`).

---

## Read these first

| File | What it holds |
|---|---|
| `01-FINDINGS.md` | Every issue found, with severity and status. The register. |
| `02-PROGRESS.md` | What changed each session and *why*, including reverted attempts. |
| `03-ENTITLEMENTS.md` | Kernel entitlement design + two approaches that do not work on iOS. |

---

## Verified state

| Check | Result |
|---|---|
| Build (iPhone 17 simulator) | green |
| Test suite | **653 pass / 25 fail** — baseline was 613/32 |
| Runner restarts | **1** — was 6 |
| Regressions introduced | none (failing set compared by name against baseline `2036235`) |
| Device | iPhone 16 Pro (iPhone17,1), iOS 26.5.2, 6137 MB process budget |

The 25 remaining failures are pre-existing. **Compare failing-test names, never
exit codes** — the suite is red at baseline, so a plain pass/fail tells you
nothing.

```bash
xcodebuild test -project HomeHub.xcodeproj -scheme HomeHub \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tee /tmp/t.log
grep -oE "Test Case '-\[HomeHubTests\.[A-Za-z]+ [a-zA-Z_]+\]' failed" /tmp/t.log \
  | sed 's/.*HomeHubTests\.//;s/\].*//' | sort -u
```

> Log lines interleave with test output, so a naive `grep "failed"` produces
> garbled entries. The anchored regex above is what to use — a mangled line
> cost a false "new regression" scare in session 4.

---

## Blocking on hardware — do this first

**F-011 · Load Qwen3-VL 2B on the device and watch the smoke test.**

Session 4 withdrew Gemma 3 4B QAT after it hard-crashed five times. The cause is
structural, not Gemma-specific: `shouldUseVisionInputPath(hasImages:modelSupportsVision:)`
returns false whenever a turn has no images, so **every** VLM gets driven
through the text-only `ChatSession` path — on the post-load smoke test and on
every text-only chat turn.

Qwen3-VL was kept only because `Qwen2-VL-2B` predates this work and shipped
`recommendedFor: [.iPhone]`. That is weak evidence. Neither Qwen3-VL entry has
been run on hardware, and **it cannot be checked from a simulator** — MLX
inference needs Metal.

- **Passes** → the Qwen VLM path tolerates text-only sessions; close F-011.
- **Crashes** → withdraw both entries like Gemma 3 4B, then make routing
  container-aware (ask the container what factory produced it rather than
  inferring from the capability profile).

Also worth confirming now that the watchdog fix is in: **do downloads complete?**
Session 4 raised the pre-first-tick budget 45 s → 150 s and the Metal-compile
budget 45 s → 180 s. If `-999 "cancelled"` still appears, the budgets are still
too tight and the real numbers are in the breadcrumb timings.

---

## Ranked work

### 1. F-007 — finish the red tests (~15 remaining)
Session 4 fixed the crashing mock and 8 stale assertions. What is left:

- **`MemoryServiceTests` structured extraction (4 tests).** Now runs the
  *heuristic* path where the test expects *structured*, so
  `RuntimeManager.activeModel` is still nil after
  `await runtimeManager.load(stubModel)`. Trace `_performLoad` — the stub
  probably never reaches the `activeModel = model` assignment at
  `RuntimeManager.swift:386`. Half-fixed in session 4; the crash is gone but the
  wiring is not.
- **`ModelRouterClassifyTests` (4), `ToolCallEnvelopeTests` (2),
  `PromptAssemblyTests testLayerOrdering`, `SkillManagerTests`,
  `SwiftDataStoreTests`, others.** Not yet investigated.

Do this before large refactors — a red suite hides regressions.

### 2. F-101 (rest) — `MLXRuntime` data races
`container` and `loadedModel` are now lock-guarded.
`baselineCacheLimitBytes` and `currentCacheTier` are **not**, and are mutated
from three concurrent contexts (load task, pressure handlers, generation
epilogue). `@unchecked Sendable` means the compiler will never flag it.

Repro to run under Thread Sanitizer: start a large model load, background the
app mid-load, return.

### 3. F-302 — Lock Screen widget leaks private content
`.accessoryRectangular` renders `entry.lastMessage`; the Home Screen variants
render the top 5 memory facts **untruncated**. There is no setting to disable or
redact, and `memoryEnabled` / `autoExtractMemory` both default to `true` — so
tapping through onboarding is enough to put personal facts on a lock screen.
Contradicts the onboarding privacy promise.

### 4. F-104 — moderate tier is over budget on paper
Projects 2100 history + 1024 reserve + ~2000 system ≈ 5124 against a 4096
window. Generous was fixed by raising the window to 8192; moderate was not.

**Do not "fix" this with arithmetic.** A clamp was tried and reverted in session
2 after measurement: it cut Gemma's moderate-tier history budget 1800 → 1072
(−40 %), a large silent loss of conversational memory. Collect the real numbers
first — `ModelCapabilityProfile.reportContextBudgetIfOverrun` logs the
projection at `.debug` under subsystem `HomeHub`, category `PromptBudget`, and
`PromptBudgetReport` carries measured stable/volatile/history counts.

### 5. Smaller, well-understood
- **F-205** — summariser input uncapped, skips the context guard, success judged
  by `!isEmpty`, and its output is injected into every later turn.
- **F-206** — Phi-3 rendered as ChatML in the fallback template path; the real
  format (`<|system|>…<|end|>`) is already known to `ChatTextSanitizer`.
- **F-406…F-410** — remaining silent-failure sites (FileStore duplicate records,
  `resetAllModels` orphaning multi-GB files, downloader delegate drops, router
  failure invisible in chat, unlogged lifecycle writes).
- **Skill naming** — `RemindersSearch` *creates* reminders and `HomeKitSearch`
  *controls* devices. Both read as read-only in Settings and both default on.
  Renaming needs an `AppSettings.enabledTools` migration;
  `ToolInjectionGuardTests.testRegisteredNameIsMisleading` pins the current
  values so the change is deliberate.

---

## The web-search / Perplexity-quality idea

Raised in session 3, not started. Worth its own round because it is a feature,
not a fix, and it touches retrieval, prompting and UI together.

What exists: `WebSearchSkill` (DuckDuckGo), `FetchPageSkill` (hardened —
SSRF blocklist, redirect guard), `CachingWebSearchEngine`, and citation
rendering in `ToolResultChip`.

What Perplexity-grade would need, roughly in dependency order:
1. **Multi-query decomposition** — one user question becomes 2–4 searches.
2. **Fetch several results, not the first hit** — currently `FetchPage` is one
   URL at a time, driven by the model.
3. **Rank and dedupe passages** across sources before they reach the prompt —
   `KnowledgeBaseRetrieval` already has embeddings and cosine scoring to reuse.
4. **Grounded synthesis with per-claim citations**, not a citation list bolted
   on at the end.
5. **Budget awareness** — this multiplies context, and the layer-shedding
   budget from F-201 is what keeps it from blowing the window.

Constraint to respect: the F-301 injection guard means a turn that reads the web
cannot then take a state-changing action. Deep search will read *more* untrusted
content, so the guard matters more, not less.

---

## Two habits this project earned the hard way

**A build-configuration change is not verified until you inspect the artifact.**
Three separate `Info.plist` bugs shipped while looking correct in `project.yml`,
in the pbxproj, and in `xcodebuild -showBuildSettings`. Only the bundle tells the
truth. `make check-plist` after `make build`.

**A catalog entry claims the app can run the model — and that needs hardware.**
Session 3 added eight models with sizes taken from a listing rather than checked,
and asserted otherwise in the commit message. All eight happened to be correct;
one of them was multimodal, was catalogued as text-only, and crashed a user's
phone five times. Repo existence and shard layout are checkable from a laptop.
"It loads and generates" is not.
