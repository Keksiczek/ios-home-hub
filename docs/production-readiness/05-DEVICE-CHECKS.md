# Device checks — Round 5

Written at the start of round 5. Everything here needs **real hardware**: MLX
inference requires Metal, so none of it can be answered from a simulator or from
reading the code.

Target device: iPhone 16 Pro (iPhone17,1), iOS 26.5.2, 6137 MB process budget.
Secondary: iPad M1 (for the 4B entries gated to `.iPadMSeries`).

---

## Before you start: one code change landed

`MLXRuntime` now writes a `mlx.generate.prefillStart` breadcrumb between
"generation requested" and "the model is decoding".

This exists because of how F-008 failed. When Gemma 3 4B killed the process, the
last breadcrumb was `mlx.generate.start` — which is written *before the
ChatSession is even constructed*. So the trail could not distinguish "crashed
building the session" from "crashed in prefill", and that ambiguity is what made
the diagnosis take a whole round.

With the new crumb, a crash report locates itself:

| Last breadcrumb | Where it died |
|---|---|
| `mlx.generate.start` | ChatSession construction / KV setup |
| `mlx.generate.prefillStart` | prefill or decode, inside MLX |

The crumb carries `supportsVision` and `path`, which is exactly the F-011
question.

Build and install as usual (Xcode → your device). Nothing else changed.

---

## Check 1 — F-011 · Qwen3-VL 2B (BLOCKING)

**The question:** does a vision model survive being driven through the
text-only `ChatSession` path?

This is not a Qwen question, it is a structural one.
`shouldUseVisionInputPath(hasImages:modelSupportsVision:)` returns
`hasImages && modelSupportsVision`, so **every turn without an image** — including
the automatic post-load smoke test — routes a VLM container through
`ChatSession`. That is what killed Gemma 3 4B five times.

Qwen3-VL was kept in the catalog only because `Qwen2-VL-2B` predates this work
and shipped `recommendedFor: [.iPhone]`. That is weak evidence and neither
Qwen3-VL entry has ever run on hardware.

### Steps

1. Models → download **Qwen3-VL 2B (MLX, vision)** (`mlx-qwen3-vl-2b-it`, 1.8 GB).
   It fits under the sandboxed mmap ceiling, so entitlements are not a factor.
2. Load it. **Do not type anything yet.** The smoke test runs automatically on
   load — `"Hi"`, 4 tokens, temperature 0. This is the exact moment Gemma died.
3. Wait ~30 s. Either the app is still alive, or it isn't.

### Outcomes

| What you see | Meaning | Next |
|---|---|---|
| App alive, model shows as loaded | smoke test survived | go to step 4 |
| App vanishes to home screen | same crash as F-008 | stop, send breadcrumbs |

4. **Text-only chat turn.** Ask something ordinary with no attachment, e.g.
   `Ahoj, co umíš?`. This is the real-world case — every text turn on a VLM takes
   the same path as the smoke test. A model that survives the 4-token smoke test
   can still die on a longer prefill.
5. **Image turn.** Attach a photo, ask `Co je na obrázku?`. This exercises the
   *other* branch (`UserInput` / vision path) and confirms vision actually works
   rather than merely not crashing.

### If it crashes

Send the breadcrumbs (below). The fix is decided by the last crumb:

- **Died at `mlx.generate.start`** → the VLM container cannot be wrapped in
  `ChatSession` at all. Routing must become container-aware — ask the container
  what factory produced it instead of inferring from the capability profile.
- **Died at `mlx.generate.prefillStart`** → the session builds but the processor
  rejects a prompt with no image scaffolding. Same fix, different layer.

Either way both Qwen3-VL entries get withdrawn like Gemma 3 4B until the routing
fix is in, and `Qwen2-VL 2B` should be re-tested too — its `[.iPhone]` marking
would then be equally unproven.

---

## Check 2 — F-009 · do downloads actually complete now?

Session 4 raised two watchdog budgets after downloads were being cancelled at
45 s with `NSURLErrorDomain -999 "cancelled"`:

| Budget | Was | Now | Why |
|---|---|---|---|
| pre-first-tick (`connectStallTimeoutSeconds`) | 45 s | 150 s | before the first progress tick a cold load is doing *network* work, not local prep |
| `prepareStallTimeoutSeconds` | 45 s | 180 s | the codebase documents Metal pipeline compilation as 10–60 s on iPhone |

**Unverified on hardware.** The numbers were reasoned from breadcrumb timings,
not measured.

### Steps

Download 3–4 models you have not installed, ideally including one large one
(Qwen3 8B, 4.6 GB, iPad). Cold cache — if a model is already partially
downloaded, delete it first.

Watch for any row that fails with a `-999` / "zrušeno" error.

- **All complete** → F-009 confirmed fixed.
- **Still `-999`** → the budgets are still too tight. The breadcrumb timings
  carry the real numbers; send them and I will set the budgets from data instead
  of another guess.

---

## Check 3 — F-104 · collect real prompt-budget numbers

This one is *only* data collection — nothing to judge on the device.

F-104 (moderate tier projects ~5124 tokens against a 4096 window) is deliberately
unfixed. An arithmetic clamp was tried in session 2 and **reverted after
measurement**: it cut Gemma's moderate-tier history budget 1800 → 1072 (−40 %),
a large silent loss of conversational memory in exchange for an untested formula.

So the budgets need to come from measurement. The instrumentation already exists
and just needs a device log capture.

### Steps

1. Connect the iPhone to the Mac, open **Console.app**, select the device.
2. Filter: subsystem `HomeHub`, category `PromptBudget`.
   Console hides `.debug` by default — turn on **Action → Include Debug Messages**.
3. In the app, have a **real conversation of 8–10 turns** with a model you
   actually use day to day. Long enough that history pressure is real; mixed
   questions so retrieval and facts fire.
4. Export the log (**File → Export**) or select-all and copy.

What I need from it: `reportContextBudgetIfOverrun`'s projection and
`PromptBudgetReport`'s measured stable / volatile / history counts, on a real
conversation rather than a synthetic one.

---

## What to send me

From **Settings → Developer Diagnostics**:

1. **`oom-breadcrumbs.json`** — the share button at the bottom. This is the
   single most valuable artifact; it is what diagnosed both F-008 and F-009.
2. **The diagnostic report** (text export) — tier, budgets, active model,
   guardrails.
3. **Console log** for check 3, if you get that far.

If the app crashes, also: **Settings → Privacy & Security → Analytics &
Improvements → Analytics Data**, find `HomeHub-2026-…-.ips`, share it. The crash
report says which thread and which frame; the breadcrumbs say what the app was
doing. Together they are conclusive; separately they are usually not.

---

## Priority if you are short on time

Check 1 steps 1–4 is the blocker. Everything else can wait a round.

Checks 2 and 3 are cheap to bundle in while you already have the device out —
but they are not blocking anything.
