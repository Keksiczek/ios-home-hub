# Improvement register

Opportunities noticed while working, kept separate from `01-FINDINGS.md` because
these are **not defects** — the app is correct without them. They are places
where current platform or MLX capability would materially raise quality.

Each entry marks what was **verified in this repo** versus what still **needs
checking against the library**. I have not run any of these on hardware; MLX
behaviour claims in particular are marked where they rest on general knowledge
rather than on this tree.

Baseline facts, verified:

| | |
|---|---|
| Deployment target | **iOS 17.0** (`project.yml:29-30`) |
| Device in use | iOS 26.5.2 |
| mlx-swift | 0.31.3 |
| Embeddings | `NLContextualEmbedding` |
| Speech | `SFSpeechRecognizer` (`VoiceService.swift:32`) |
| Apple Foundation Models | wired, availability-gated (`AppContainer.swift:1363-1377`) |

The iOS 17 floor is the recurring theme below: the owner's device is nine major
versions ahead of the minimum, so several capabilities are simply unused rather
than unavailable. None of the suggestions require raising the floor — all are
`if #available` opportunities.

---

## A · Would structurally fix existing findings

> **Library verification done — 2026-07-24.** A1, A2 and A3 were all filed as
> "needs checking against mlx-swift 0.31.3". All three are **confirmed present**,
> read from the pinned checkout at
> `DerivedData/HomeHub-*/SourcePackages/checkouts/mlx-swift-lm`. Exact symbols
> are cited per entry. A fourth capability was found that was not on the list at
> all — see C1.

### A1 · Grammar-constrained decoding for tool calls and structured output
**Impact: high · Effort: medium · API CONFIRMED**

`public protocol LogitProcessor` — `MLXLMCommon/Evaluate.swift:34`, with
`prompt(_:)`, `process(logits:) -> MLXArray` and `didSample(token:)`. The
generation loop calls it as `logits = processor?.process(logits:) ?? logits`
before `sampler.sample(logits:)`, which is exactly the hook constrained decoding
needs. `RepetitionContext`, `PenaltyProcessor` et al. (`:365-457`) are working
in-tree examples of the protocol.

So this is implementable today: a `LogitProcessor` that masks tokens which
cannot continue a valid tool-call JSON.

`ModelCapabilityProfile.swift:23` already names this as an aspiration —
*"grammar-constrained output for families that support it"* — and it is not
implemented.

Today, correctness of tool calls depends on a 2 B model emitting well-formed
`<tool_call>` JSON by imitation. The codebase is visibly built around that not
working: `ChatTextSanitizer.swift:112` cleans up output "when its tool-call
grammar misfires", `ToolCallEnvelope` parses defensively, and F-204 exists
*because* stop sequences are used as a crude structural guard and truncate
ordinary replies as collateral.

Constrained decoding makes malformed output **impossible** rather than unlikely,
by masking invalid tokens at sample time. That removes a whole class of defect
instead of mitigating it, and it is what would make the deep-search query planner
(`06-DEEP-SEARCH-DESIGN.md` step 1) reliable on weak models.

### A2 · Quantized KV cache
**Impact: high · Effort: low-medium · API CONFIRMED**

`QuantizedKVCache` / `public protocol QuantizedKVCacheProtocol` —
`MLXLMCommon/KVCache.swift:94`, exposing `groupSize`, `bits`, `mode` and
`updateQuantized(keys:values:)`. There is a ready-made conversion at `:407`:

```swift
public func toQuantized(groupSize: Int = 64, bits: Int = 4) -> QuantizedKVCache
```

Several shipped models already consume it (`GPTOSS.swift:228`,
`MiMoV2Flash.swift:34`, `Gemma4.swift:688`), so the path is exercised upstream
rather than theoretical.

Directly targets F-104 and the memory pressure work. KV cache at 8-bit or 4-bit
cuts cache memory roughly 2–4×, which is the difference between the moderate
tier's 4096 window being tight and being comfortable — and it would let the
generous tier's 8192 window actually be used rather than being a number the
budget arithmetic fears.

Also compounds well with `06-DEEP-SEARCH-DESIGN.md`, where evidence passages are
exactly the kind of long-prefix content that makes KV cache dominant.

### A3 · Speculative decoding
**Impact: high on latency · Effort: medium-high · API CONFIRMED**

`public struct SpeculativeTokenIterator: TokenIteratorProtocol` —
`MLXLMCommon/Evaluate.swift:733`, a documented port of `speculative_generate_step()`
from Python `mlx-lm`. Driven via
`generate(input:cache:parameters:context:draftModel:draftCache:numDraftTokens:wiredMemoryTicket:)`.

A small draft model proposing tokens for a larger target typically yields
1.5–2.5× throughput on memory-bandwidth-bound decode, which is exactly the regime
a phone is in.

Relevant because `06-DEEP-SEARCH-DESIGN.md` estimates 15–30 s for the synthesis
pass alone, and generation is the dominant term in a 30–70 s total. The catalog
already carries plausible draft/target pairs (Qwen3 1.7B + Qwen3 8B; Qwen3 0.6B
class + 4B).

Costs a second resident model, so it is a generous-tier-only feature at best —
and that trade-off, not API availability, is now the open question.

### A4 · `MLXRuntime` → `actor`
**Impact: correctness · Effort: medium · Verified in-repo**

F-101 documents unguarded concurrent access to `baselineCacheLimitBytes` and
`currentCacheTier` from three contexts, with `@unchecked Sendable` (`:72`)
ensuring the compiler stays silent.

Lock-guarding the remaining fields closes the specific bug. Converting the class
to an `actor` closes the *category* — and would have prevented the original
issue, since the incorrect justification at `:417-420` ("pressure helpers run on
the same `@MainActor`-rooted call chain") is exactly the kind of hand-reasoning
about isolation that an actor makes unnecessary.

Larger change, so it belongs in its own round with a Thread Sanitizer pass.

---

## B · Platform capability, available and unused

### B1 · Use Apple Foundation Models for the cheap structured steps
**Impact: high · Effort: medium · Verified partially in-repo**

`AppleFoundationModelsRuntime` exists and is routed
(`AppContainer.swift:1363-1377`), but it is treated as *an alternative chat
model* — one more backend the user might pick.

The stronger framing: AFM is a **free, always-resident, system-managed ~3 B model
that costs no download and no app memory budget**. That makes it ideal for the
auxiliary steps that currently either burn the big model's time or degrade on
weak checkpoints:

| Step | Today | With AFM |
|---|---|---|
| Query planning (deep search) | costs a full MLX pass | AFM, ~free |
| Conversation summarisation (F-205) | MLX pass, uncapped input | AFM |
| Memory extraction | MLX or heuristic | AFM structured output |
| Title generation | MLX pass | AFM |

AFM's guided generation gives schema-valid structured output natively, which
overlaps with A1 and would deliver much of that benefit without waiting on MLX
sampler support.

Net effect: the downloaded MLX model does only what it is uniquely good at —
long-form synthesis in Czech — and everything structural moves to a model that
is already there. On an iOS 26 device this is a large win for both latency and
quality, and it degrades cleanly to the current behaviour on iOS 17–25.

### B2 · `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26)
**Impact: medium-high for Czech · Effort: low-medium · Verified in-repo**

`VoiceService.swift:32` uses `SFSpeechRecognizer` with `cs-CZ`, and `:55` already
handles the case where that locale is unsupported — a warning path that exists
because the old API's language coverage is uneven.

iOS 26's replacement runs a substantially better on-device model with wider
language support and no server round-trip. Availability-gated addition, old path
retained below iOS 26. For a Czech-first voice assistant this is one of the
higher user-visible quality gains available for the effort.

### B3 · Background Assets framework for model downloads
**Impact: high reliability · Effort: high · Verified absent in-repo**

No `BackgroundAssets` usage anywhere. Model downloads run through a hand-rolled
`MLXBackgroundDownloader` + `URLSession` background stack, and that stack is the
source of F-009 (watchdog cancelling at 45 s), F-407 (orphaned multi-GB files)
and F-408 (dropped delegate callbacks).

Background Assets is the Apple-supported path for exactly this: large model
assets, downloaded by the system, surviving app termination, with system-managed
retry and scheduling. It would replace the component that has produced three
separate findings.

Genuinely large change and it interacts with Hugging Face as the source rather
than the App Store, so it needs its own design round — flagged as the strategic
answer to a recurring problem, not a quick fix.

### B4 · Liquid Glass (iOS 26)
**Impact: visual · Effort: medium · Verified absent in-repo**

No `glassEffect` usage. The design system predates iOS 26. Availability-gated
adoption would make the app look current on the owner's device. Cosmetic, listed
for completeness — well below the correctness items.

---

## C · Retrieval quality

### C1 · Replace `NLContextualEmbedding` for retrieval
**Impact: high · Effort: LOW (revised down) · API CONFIRMED**

> **This entry was filed at "effort: medium" on the assumption that an embedding
> model would have to be wired by hand. That was wrong, and pleasantly so.**
>
> `MLXEmbedders` is a **product of the already-pinned `mlx-swift-lm` package**
> (`Package.swift:26-27`, target at `:82-88`). The project links `MLXLLM`,
> `MLXLMCommon` and `MLXVLM` from that same package but not `MLXEmbedders`, so
> adding it is one entry under `dependencies:` in `project.yml` — **no new
> package, no new pin, no `Package.resolved` churn.**
>
> The registry (`MLXEmbedders/ModelFactory.swift:42-73`) already names the
> models this app would want:
>
> | Symbol | Repo | Why it matters here |
> |---|---|---|
> | `multilingual_e5_small` | `intfloat/multilingual-e5-small` | multilingual, small — the Czech retrieval candidate |
> | `bge_m3` | `BAAI/bge-m3` | multilingual, multi-granularity, stronger |
> | `qwen3_embedding` | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` | current generation, already 4-bit quantized |
>
> `EmbedderModelContainer`, `ModelFactory` and `Pooling` ship with it, so the
> download/load/pool plumbing is not ours to write either.

`NLContextualEmbedding` is a general-purpose contextual encoder, not a model
trained for semantic *retrieval*. Two concrete problems in this tree:

1. **It can be absent.** Its assets download separately, and F-403 exists
   precisely because a missing asset produces `[]` vectors that are
   indistinguishable from success. A bundled or app-downloaded model has no such
   failure mode.
2. **Czech.** Retrieval quality in Czech is the whole point here, and a
   multilingual retrieval model (e5 / BGE-M3 family, ~100–200 MB quantized)
   would substantially outperform it on exactly the query→passage matching that
   `06-DEEP-SEARCH-DESIGN.md` step 5 depends on.

Given how cheap the plumbing turned out to be, this moves up the order: it is
the fix for F-403's root cause (an embedding backend that can silently be
absent) *and* the biggest single lever on retrieval quality, and it is now a
small change rather than a project.

### C2 · Hybrid retrieval — BM25 alongside dense
**Impact: medium-high · Effort: low · ✅ DONE (session 5)**

~~`KnowledgeBaseRetrievalService` is pure dense cosine.~~ Landed. Dense
retrieval reliably misses exact-match cases: proper nouns, error codes, model
numbers, rare terms — and Czech morphology makes this worse, not better. It is
now fused with lexical BM25.

**What shipped:**
- `LexicalRetrieval.swift` — BM25 scoring (`k1=1.2`, `b=0.75`, non-negative IDF)
  plus Reciprocal Rank Fusion. A pure `enum` of static functions, no model, no
  network, no shared state. Diacritic-folding tokenizer for Czech; deliberately
  *no* stemming (that is the embedder's job — hand-rolled Slavic stemming risks
  false-positive passages).
- `KnowledgeBaseRetrievalService.retrieve` is now hybrid: it attempts dense,
  always computes lexical, and fuses by RRF. A missing embedder no longer
  returns silent nothing — it degrades to lexical and logs loudly. This is the
  **retrieval half of the F-403 fix** (the ingest half was `37c7dcb`).
- `RetrievedChunk` gained `matchKind` (`hybrid`/`dense`/`lexical`) and `rank`, so
  callers can tell "corpus has nothing" from "running lexical-only".
- 12 unit tests, all passing; zero regressions against baseline.

RRF over a weighted score sum is deliberate: BM25 is unbounded and cosine is
[-1, 1], so any weighted sum needs a normalisation that drifts as the corpus
grows. RRF consults only positions, so it needs no tuning.

### C3 · Cross-encoder reranking
**Impact: medium · Effort: high**

The quality ceiling above C1/C2, and the remaining gap to Perplexity-grade
ranking. Costs a model pass per candidate, so it is likely out of budget on a
phone. Recorded as the known next step, not recommended now.

---

## D · Product and privacy

### D1 · Per-action confirmation for state-changing skills
F-301's proper fix. The information-flow guard closed the demonstrated hole;
`Skill.isStateChanging(input:)` already exists as the foundation. Blocked on a
UX decision, not on engineering.

### D2 · Widget privacy controls
F-302. Lock Screen renders `lastMessage`; Home Screen renders memory facts
untruncated; there is no setting to disable or redact, and both memory defaults
are `true`. Needs a setting and truncation — and arguably an opt-in rather than
opt-out default, given the onboarding privacy promise.

### D3 · Skill naming migration
`RemindersSearch` creates reminders; `HomeKitSearch` controls devices. Both read
as read-only in Settings and both default on. Needs an `AppSettings.enabledTools`
migration, which is why it has not happened;
`ToolInjectionGuardTests.testRegisteredNameIsMisleading` pins the current values
so the change stays deliberate.

### D4 · Pinned-hash verification of downloaded weights
F-307. `DownloadError.checksumMismatch` exists and is never produced. Structural
validation is thorough; provenance is not checked. Relevant as the catalog grows.

---

## Suggested order

Revised after the library verification — A1/A2/A3 no longer need a scouting
step, and C1 turned out to be small rather than medium.

1. **C1 + C2 together** — the retrieval pair. `MLXEmbedders` gives a real
   retrieval model for a one-line dependency change, and BM25 is the lexical
   fallback for when embeddings are unavailable. Together they are the complete
   fix for F-403 (whose current failure mode is *silent* degradation) and the
   foundation of deep-search Stage 1. Highest value, now lowest cost.
2. **A2 (quantized KV cache)** — `toQuantized(groupSize:bits:)` is a ready-made
   call. Directly relieves F-104, which every other context-hungry feature is
   currently blocked behind.
3. **B1 (Apple Foundation Models for auxiliary steps)** — largest quality-per-
   effort ratio of the platform items; no new dependency, degrades cleanly.
4. **A1 (constrained decoding)** — `LogitProcessor` is confirmed; this removes a
   whole defect class rather than mitigating it. More design work than A2
   because the grammar itself has to be written.
5. **B2 (SpeechAnalyzer)** — high user-visible value for a Czech-first assistant.
6. **A3 (speculative decoding)** — real, but costs a second resident model, so
   it needs the device latency measurements first.
7. **A4, B3** — own rounds, both large.

**Nothing here is blocked on a library question any more.** The remaining
unknowns are all measurements that need the device: decode throughput, prefill
cost, and whether more context helps or hurts a 2 B checkpoint.

---

## E · The bar to clear — Noema (studied 2026-07-24)

The owner found **Noema — Local AI & Offline LLM** (App Store id6751169935) on
their phone and set it as **the benchmark in the sense of a standard**: this is
the level HomeHub has to reach, as a whole product. Not a list of features to
copy one at a time — the point is that Noema is a finished, coherent app in
exactly our category, and the distance between it and HomeHub is the real
backlog.

It is a close competitor by construction — llama.cpp + MLX + CoreML + Apple
Foundation Models, on-device RAG, web search with citations, model routing,
multi-platform. That overlap is what makes it a fair yardstick: where it has
something we don't, the gap is a genuine product gap rather than a difference in
taste.

### Where it currently stands (from its listing + release notes)

| Area | Noema | HomeHub today |
|---|---|---|
| Runtimes | GGUF, MLX, ExecuTorch, CoreML, Apple Foundation Models | MLX (+ llama.cpp opt-in, AFM wired) |
| Platforms | iPhone, iPad, Mac, visionOS | iPhone, iPad |
| RAG | PDF/EPUB/text ingest, curated **Knowledge Packs** | ingest works; no packs |
| Web | search + opens pages, citations in chat | search + FetchPage, citations |
| Routing | **Autopilot** — routes by message difficulty, local *or* remote | `ModelRouter` (local only) |
| Remote | OpenRouter, LM Studio, **MCP servers** | none |
| Memory fit | FlashAttention + **V-cache quantization** | neither (A2 is exactly this) |
| Long chats | **context compaction** | layer shedding (F-201) |
| Voice | on-device voice mode (beta) | `SFSpeechRecognizer` only |
| Reach | 11 languages, Siri intents | Czech-first, intents present |
| Exotic | **"Overfit"** — streams experts from storage to exceed RAM | — |
| Network | **Off-grid master switch**, HF-mirror endpoint choice | per-feature toggles only |
| Settings | Simple/Advanced split, device+thermal overview | one flat advanced surface |
| Chat UI | context-budget meter in status drawer | computed but Console-only |

### What actually closes the distance

Ordered by how much ground each covers, not by ease:

1. **Reliability first — we are not yet at the starting line.** Noema's whole
   list assumes generation works. HomeHub currently cannot generate at all
   (F-012), and the Qwen family could not load (F-013). Nothing else on this
   page matters until the owner can hold a conversation without a crash. This is
   the single biggest gap and it is not a feature gap.
2. **Model breadth that actually runs.** Their advantage is not the runtime
   count, it is that models load and produce tokens. Our catalog is larger on
   paper and smaller in practice. The F-010 rule (a catalog entry must be run on
   hardware) is what converts one into the other.
3. **Memory fit — A2 (quantized KV cache).** They ship V-cache quantization to
   make bigger models fit on more devices; we have the same capability available
   and unused, and it is also the lever on F-104. Independent corroboration that
   A2 is correctly prioritised.
4. **Off-grid switch + HF mirror (E-net).** Both are small. The mirror is
   directly relevant to the unresolved download problems; the off-grid switch is
   the clearest possible statement of a local-first promise.
5. **Context-budget meter in chat.** We already compute every number
   (`PromptBudgetReport`); it only goes to Console. Surfacing it is cheap and
   makes F-104's behaviour self-explaining to the user.
6. **Knowledge Packs.** Curated public-domain corpora (survival, first aid,
   emergency prep, World Factbook). Our KB can already ingest; packs make it
   useful on first launch and fit an offline-first product.
7. **Simple/Advanced settings split.** Our settings have grown a lot of developer
   surface. A segmented control keeps it without overwhelming a normal user.
8. **Later, deliberately:** remote endpoints + MCP, context compaction, voice
   mode, localisation, "Overfit". Each is real work and none of it helps until
   1–3 are done.

**Explicitly low priority: their Benchmarking Center.** Noted only because it
exists. Our own need for measurement (F-104's real budgets, the deep-search
latency table, proving A2/A3 are worth it) is better served by targeted
instrumentation on the owner's device than by a user-facing benchmark tab.

### Where HomeHub is already ahead

Worth stating so the comparison stays honest, and so these are not traded away
while chasing breadth: the information-flow prompt-injection guard (F-301), the
SSRF-hardened fetch path (F-303), entitlement-aware memory tiers, and the
silent-failure work have no visible counterpart in their listing. The security
posture is ours to keep.
