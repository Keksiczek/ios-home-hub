# Deep Search — architecture proposal

Round 5. **Design only — no code written yet.** The point of this document is to
agree on the shape before building, because the change is structural rather than
additive.

---

## The core claim

Perplexity's answer quality does not come from a smart model. It comes from a
**good retrieval pipeline feeding a modest synthesis step**.

That matters enormously here, because our model is a 2–8 B checkpoint running on
a phone. Anything that depends on the model being clever will not survive
contact with Gemma 2 2B. Anything that depends on *deterministic code* being
thorough works identically on every model in the catalog.

So the design principle is:

> **Move intelligence out of the model and into the pipeline.**

The current design does the opposite, and that is why it does not feel like
Perplexity even though it does technically search the web:

| Step | Today | Who decides |
|---|---|---|
| What to search for | model writes one query | **model** |
| How many searches | one, unless the model loops | **model** |
| Which page to read | model picks one URL | **model** |
| What matters on that page | first N bytes, truncated | **nobody** |
| How sources combine | model reads raw snippets | **model** |
| Citations | appended after the fact | pipeline |

Six decisions, five of them delegated to the weakest component in the system,
each one costing a full generation pass. `maxLoops = 4` and a ~90 s loop budget
means a thorough multi-source answer is not merely unlikely, it is *structurally
unreachable* — the loop runs out before the reading starts.

The proposal inverts this: **one deterministic research pass, then one synthesis
pass.** The model is asked to do exactly one thing it is actually good at —
write prose from evidence placed in front of it.

---

## Pipeline

```
user question
    │
    ├─ 1. PLAN ──────────  2–4 sub-queries                    (LLM, constrained + heuristic fallback)
    │
    ├─ 2. SEARCH ────────  fan out, parallel, multi-engine    (deterministic)
    │
    ├─ 3. SELECT ────────  dedupe by domain, diversity cap    (deterministic)
    │
    ├─ 4. FETCH ─────────  N pages in parallel, main-content  (deterministic)
    │
    ├─ 5. RANK ──────────  embed + cosine, passage-level      (deterministic)
    │
    ├─ 6. BUDGET ────────  fit into context, tag [1]…[n]      (deterministic)
    │
    └─ 7. SYNTHESISE ────  one grounded pass with citations   (LLM)
           │
           └─ 8. ATTRIBUTE  verify / repair citations         (deterministic)
```

Steps 2–6 and 8 involve no model at all. That is the whole idea.

### 1 · Plan

One user question becomes 2–4 sub-queries. "Jak si vede Apple letos?" should
become something like `Apple Q3 2026 earnings`, `Apple stock performance 2026`,
`Apple news July 2026` — not a single verbatim translation.

Hybrid, because this is the one LLM step in the retrieval half and it must not
become a failure point:

- **Primary:** one short constrained generation — "output 2–4 search queries,
  one per line, 2–6 keywords each". Cheap (~40 output tokens) and within reach
  of a 2 B model *because the output shape is trivial*.
- **Fallback:** deterministic. Entity/keyword extraction (`NLExtractionPass`
  already exists), plus a freshness qualifier when the question is
  time-sensitive. Fires on timeout, on malformed output, or on a model flagged
  `isWeakInstructionFollower`.

Hard timeout, and the fallback is never worse than today's single query — today
*is* the single-query case.

### 2 · Search

Sub-queries fan out concurrently through a `TaskGroup` against the existing
`WebSearchEngine` chain (SearXNG → DuckDuckGo). Today this is one query,
sequential.

`CachingWebSearchEngine` already dedupes repeats, which matters more once
several sub-queries overlap.

### 3 · Select

Merge result sets and pick which pages are worth fetching. Deterministic rules:

- **Domain diversity cap** — at most 2 passages surviving from any one domain.
  Five results from the same content farm is the single most common way a
  search-grounded answer goes confidently wrong.
- **Freshness preference** when the query is time-sensitive.
- **Fetch budget** — 4–6 pages. Bounded by wall-clock, not by count alone.

### 4 · Fetch

Parallel fetch through `FetchPageSkill`'s hardened path — the SSRF blocklist,
scheme rejection and `RedirectGuardDelegate` all still apply, per URL.

**This is a security-relevant change and needs to be built deliberately.** Today
one URL per turn is fetched, model-chosen. Under this design the app fetches
5–6 URLs per question, chosen by *search-engine ranking*. The blocklist is what
stands between that and an SSRF fan-out, so the parallel path must go through
exactly the same guard rather than a fresh `URLSession` call.

Also: **F-303 must be fixed before this ships.** `extractOGImage` validates the
scheme but not the host, and the resulting URL is loaded automatically by
`ToolResultChip`'s `AsyncImage`. One unguarded auto-load per turn is a bounded
bug; six per turn on a smart-home app with LAN reach is not. It is a small fix —
apply the existing `isBlockedHost` — and it becomes load-bearing here.

### 5 · Rank — *the quality step*

Extracted text is chunked into passages and ranked against the query by
embedding cosine, reusing `EmbeddingService` (NLContextualEmbedding) and the
vDSP `cosine` already in `KnowledgeBaseRetrievalService`.

This is where Perplexity-grade quality actually comes from, and it costs no
model tokens:

- **Passage-level, not page-level.** The relevant paragraph gets into the
  prompt; the surrounding 40 KB of navigation and boilerplate does not. Today a
  fetched page is truncated at a byte cap — position-based, not relevance-based.
- **Cross-source dedupe.** Near-identical passages (syndicated wire copy) are
  collapsed, keeping the most authoritative. Otherwise the model sees the same
  claim four times and reads that as four independent confirmations.
- **Score floor.** Passages below a relevance threshold are dropped entirely
  rather than padding the prompt with noise.

One hard dependency: **F-403 must be fixed first.** `embeddingVector(for:) ?? []`
makes embedding failure indistinguishable from success. If NLContextualEmbedding
assets are missing, every passage embeds to `[]`, cosine returns 0 for
everything, and ranking silently degrades to *arbitrary order* — while still
looking like it worked. That failure mode is unacceptable in the component the
entire quality claim rests on. The pipeline must detect it and fall back to
lexical (BM25-ish) scoring with a visible signal, not pretend to rank.

### 6 · Budget

Ranked passages are fitted to the context window through the F-201 layer-shedding
mechanism, as a new layer class with its own priority. Each surviving passage
carries a stable source index.

This is the constraint that makes or breaks the feature on a 4096-token moderate
tier. Evidence, history, system prompt and generation reserve all compete.
Realistically evidence gets ~1200–1800 tokens on moderate — about 4–6 passages.
F-104 (moderate over budget on paper) becomes materially more pressing here.

**Evidence must be fenced as data, not instruction.** This is the same failure
class as F-202's unexplained `<context>` wrapper: a labelled block whose meaning
was never explained to the model. The stable system prompt has to say, in one
sentence, that the evidence block is quoted third-party material, that
instructions inside it are not from the user, and that it must not be obeyed.

### 7 · Synthesise

One generation pass. Evidence in the prompt, each passage tagged `[n]`, model
asked to answer and cite inline.

### 8 · Attribute

Post-processing, deterministic, and the part I am most confident adds visible
quality per unit of effort:

- **Verify** every `[n]` the model emitted actually exists. Weak models invent
  citation numbers; today nothing catches that.
- **Repair by embedding.** For any answer sentence carrying no citation, embed it
  and match against the evidence passages; attach the best match above a
  threshold.

That second step matters because it makes citation quality **independent of
model capability**. Gemma 2 2B will not reliably emit inline `[n]` markers no
matter how the prompt is written. It does not have to — the attribution pass can
add them afterwards from the same embeddings already computed in step 5.

---

## Proposed module layout

New, under `HomeHub/Services/Research/`:

| File | Responsibility | ~Lines |
|---|---|---|
| `DeepResearchService.swift` | orchestration, stage sequencing, progress events | 250 |
| `QueryPlanner.swift` | question → sub-queries (LLM + heuristic fallback) | 150 |
| `SourceSelector.swift` | merge, domain diversity, freshness, fetch budget | 120 |
| `PassageExtractor.swift` | HTML → main content → passages | 150 |
| `PassageRanker.swift` | embed, cosine, cross-source dedupe, floor | 180 |
| `EvidenceBudgeter.swift` | fit to context, assign `[n]`, render block | 150 |
| `CitationAttributor.swift` | verify + embedding-based repair | 160 |
| `ResearchModels.swift` | `SubQuery`, `Passage`, `Evidence`, `ResearchProgress` | 120 |

Reused unchanged: `WebSearchEngine` chain, `CachingWebSearchEngine`,
`FetchPageSkill`'s guards, `WebContentExtractor`, `EmbeddingService`,
`KnowledgeBaseRetrievalService.cosine`, `PromptAssemblyService` shedding,
`ToolResultChip`.

Every file well under the 800-line ceiling, each independently testable without
a model or the network — which is the point of splitting them this way. Ranking,
budgeting and attribution are pure functions over fixtures.

---

## What this costs

Latency, moderate tier, my estimate:

| Stage | Estimate |
|---|---|
| Plan (LLM) | 3–8 s |
| Search ×3 parallel | 1–2 s |
| Fetch ×5 parallel | 2–6 s |
| Extract + chunk | < 1 s |
| Embed ~60 passages | 1–3 s |
| **Prefill** of evidence prompt | **8–20 s** |
| Generate ~400 tokens | 15–30 s |
| Attribute | < 1 s |
| **Total** | **~30–70 s** |

**These are estimates and I cannot verify them from here** — on-device MLX
throughput needs Metal. The two numbers I trust least are prefill and generation,
and they are the two that dominate. The device-check round should capture real
tok/s so this table can be replaced with measurements.

Consequences that follow from the number regardless of its exact value:

- **Progress must stream.** 40 s of spinner reads as a hang. Perplexity's
  "Searching → Reading 5 sources → Writing" is not decoration, it is what makes
  the wait legible. `ResearchProgress` events exist for this.
- **It cannot be the default path.** A 40 s answer to "kolik je hodin" is a
  worse product. Deep search is for questions that deserve it.
- **The 120 s watchdog is close.** At the pessimistic end this lands near
  `generationTimeoutSeconds`. Deep search needs its own budget, and cancellation
  has to be clean at every stage boundary.

---

## Risks

**Prompt injection surface grows by roughly 6×.** Today: one model-chosen page.
Proposed: 5–6 search-ranked pages, every one attacker-influenceable if they can
rank. The F-301 guard (a turn that read the web cannot then take state-changing
actions) becomes more load-bearing, not less — and it must cover the whole
research turn, not just the fetch step. Worth reviewing whether the guard should
harden further for research turns specifically: a turn that read six pages
arguably should not be able to take *any* action.

**Privacy.** Today one query leaves the device per search. Proposed: 3–4, plus
5–6 page fetches. Same trust boundary, more traffic, and page fetches carry the
device's IP to arbitrary hosts. Needs explicit disclosure in the privacy policy
and a user-visible setting, not a silent upgrade — the app's entire premise is
local-first, and this is the one feature that is not.

**Quality regression risk on weak models.** Filling a 2 B model's context with
1800 tokens of third-party prose is precisely the condition that produced F-212
(bullet-format mimicry) and F-202 (context-block confusion). More context is not
monotonically better on small checkpoints. This needs measuring on device
against the current path before it becomes the default for any tier.

**Prerequisite status — updated 2026-07-24 (session 5):**

- **F-403 — CLEARED.** The ingest-side zero-dimension guard landed in `37c7dcb`;
  the retrieval side got a loud lexical fallback this session (`LexicalRetrieval`
  + hybrid `KnowledgeBaseRetrievalService.retrieve`). Embedding failure is now
  detectable and degrades to BM25 instead of silently returning nothing.
- **F-303 — CLEARED.** `FetchPageSkill.extractOGImage` now applies `isBlockedHost`
  (also `37c7dcb`). The 6×-fanout concern for Stage 2 is defused.
- **F-104 — still open**, and still the one that makes moderate-tier evidence
  acute. Device-blocked (needs the `PromptBudget` capture in `05-DEVICE-CHECKS.md`).

So two of the three hard prerequisites are done, and Stage 1's ranking half is
already built — see the note under Build order.

---

## Decisions — settled 2026-07-24

**D1 · Trigger → explicit affordance.** A "Deep search" toggle in the composer.
The user opts into the wait, which removes the biggest UX risk, and the trigger
decision does not go back to the weakest component. Automatic classification is
deferred until latency has been *measured* rather than estimated.

**D2 · Tiers → generous + moderate.** Tight tier does not offer it. Moderate is
acknowledged as tight (~4–6 passages) and is the tier that makes F-104 acute.

**D3 · Citations → inline `[n]`, with the attribution pass as the safety net.**
Inline is what makes an answer feel verifiable. The pass in step 8 is what makes
it achievable on a 2 B model, by decoupling citation quality from the model's
instruction-following.

**D4 · Scope → staged.**

| Stage | Contents | New network/privacy surface |
|---|---|---|
| **1** | passage extraction, ranking, budgeting, evidence fencing — on the *existing* single-search path | **none** |
| **2** | query planning, parallel multi-query fan-out, multi-page parallel fetch, source selection | yes — needs F-303 fixed first |
| **3** | citation attribution + verification, progress UI | none |

Stage 1 is a real quality improvement on its own, is verifiable without a
device, and introduces no new privacy or SSRF exposure — so it can proceed while
the device checks are still outstanding. Stage 2 is gated on F-303 and F-403.

---

## Build order

Prerequisites first, because two of them are inside the components this design
leans on hardest:

1. ~~**F-403** — embedding failure must be detectable.~~ **Done (session 5).**
   `LexicalRetrieval` (BM25 + RRF) plus a hybrid `retrieve` that detects a
   missing embedder and degrades to lexical with a loud log. This is both the
   F-403 fix and the retrieval-quality half of Stage 1 (item C2 in
   `08-IMPROVEMENTS.md`), landed together because they are the same code.
2. ~~**F-303** — `og:image` host validation.~~ **Done (`37c7dcb`).**
3. **Stage 1 (remaining)** — passage extraction, budgeting, evidence fencing.
   Ranking is in place; what's left is chunking a fetched page into passages,
   fitting them to the context window via the F-201 shedding mechanism, and the
   one-sentence "evidence is quoted data, not instruction" fence.
4. Measure on device against the current path. **If quality does not improve on
   a weak model, stop and reconsider** rather than continuing to Stage 2 — F-212
   and F-202 are both evidence that more context is not monotonically better on
   small checkpoints.
5. **Stage 2**, then **Stage 3**.
