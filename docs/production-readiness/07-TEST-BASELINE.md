# Test baseline — pristine failing set

**Established:** 2026-07-24, session 5
**Commit:** `5449523` (merge of PR #58 — `production-readiness/2026-07` into `main`)
**How:** full suite in a detached `git worktree`, no working-tree changes
**Destination:** `platform=iOS Simulator,name=iPhone 17` (Xcode 26.2, iPhoneSimulator26.2 SDK)

| | |
|---|---|
| Passed | **652** |
| Failed | **25** (unique test methods) |
| Runner restarts | 0 |

---

## Why this file exists

`01-FINDINGS.md` (F-007) and `04-NEXT-ROUND.md` both instruct the next round to
compare failing-test **names** against the baseline rather than trusting an exit
code — the suite is red at baseline, so pass/fail says nothing.

Neither document recorded the names. Following the instruction therefore required
reproducing a full clean build first, which is roughly 25 minutes of wall clock
spent rediscovering a fact that fits on one screen. This file is that screen.

**Regenerate with:**

```bash
xcodebuild test -project HomeHub.xcodeproj -scheme HomeHub \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tee /tmp/t.log
grep -oE "Test Case '-\[HomeHubTests\.[A-Za-z]+ [a-zA-Z_0-9]+\]' failed" /tmp/t.log \
  | sed "s/Test Case '-\[HomeHubTests\.//;s/\]' failed//;s/ /./" | sort -u
```

The anchored regex matters: log lines interleave with test output, so a naive
`grep failed` produces garbled entries. A mangled line cost a false "new
regression" scare in session 4.

> **Caveat — these are machine-dependent.** `ModelCapabilityProfileTests` and
> friends assert on `safeHistoryTokenBudget`, which `dynamicHistoryBudget` scales
> by device memory tier — and on a simulator that follows the *host Mac's* RAM.
> This baseline was taken on an 8 GB / 8-core Mac. On different hardware the set
> will differ, so regenerate rather than trusting this list blindly.

---

## The 25 (sorted)

- `ConversationServiceTests.testLRU_EvictsColdestEntryAtCap`
- `ConversationServiceTests.testTimeoutMarksMessageAsFailed`
- `DiagnosticReportTests.testReportNeverEncodesUnexpectedKeys`
- `HuggingFaceAPIClientTests.testIsNeededForMLXInference_AcceptsBPETokenizer`
- `MLXIntegrationTests.testLoadSuccess_TransitionsToReady`
- `MemoryExtractionTests.testHeuristicRunsWhenNoModelLoaded`
- `MemoryExtractionTests.testHeuristicRunsWithoutRuntime`
- `MemoryServiceTests.testAcceptEpisodeCandidateFromStructuredExtraction`
- `MemoryServiceTests.testAcceptFactCandidateFromStructuredExtraction`
- `MemoryServiceTests.testConsiderWithHeuristicTriggerProducesCandidates`
- `MemoryServiceTests.testRejectRemovesCandidate`
- `MemoryServiceTests.testRelevantEpisodesKeywordScoring`
- `ModelCapabilityProfileTests.testResolveMistral`
- `ModelRouterClassifyTests.testCaseInsensitiveMarkerMatch`
- `ModelRouterClassifyTests.testDepthMarkersRouteToSmart`
- `ModelRouterClassifyTests.testTypicalQuestionRoutesToBalanced`
- `ModelRouterClassifyTests.testWhitespaceOnlyDoesNotMatchCodeMarkers`
- `PromptAssemblyTests.testLayerOrdering`
- `PromptBuilderRailSplitTests.testStableRailContainsLanguageToolPolicyStyleLocation`
- `PromptModeAssemblyTests.testToolFollowupHasShortToolReminder`
- `PromptTokenBudgeterTests.testCodeSnippetIsMoreExpensiveThanProseOfSameLength`
- `SkillManagerTests.testCalculatorDecimalResult`
- `SwiftDataStoreTests.testStoreInitializesSuccessfully`
- `ToolCallEnvelopeTests.testMissingInputFieldReturnsNil`
- `ToolCallEnvelopeTests.testOpenTagWithoutCloseTagReturnsNil`

---

## Grouped by suspected cause

Grouping is from the F-007 write-up plus session-4 notes; the per-test
diagnosis is in `09-F007-DIAGNOSIS.md`.

| Group | Tests | Note |
|---|---|---|
| `MemoryServiceTests` structured extraction | 4 | runs heuristic path where structured expected; `RuntimeManager.activeModel` nil after `load(stubModel)` |
| `ModelRouterClassifyTests` | 4 | uninvestigated before this round |
| `ToolCallEnvelopeTests` | 2 | uninvestigated |
| `MemoryExtractionTests` | 2 | heuristic-vs-runtime path |
| `ConversationServiceTests` | 2 | uninvestigated |
| Singles | 11 | `PromptAssemblyTests.testLayerOrdering` likely predates F-201 layer shedding |

---

## After session 5's F-007 work

| | Baseline `5449523` | After session 5 |
|---|---|---|
| Passed | 652 | **665** |
| Failed | 25 | **14** |
| Runner restarts | 0 | **0** |
| New regressions | — | **none** (compared by name) |

Eleven fixed. One was a real product defect (`ModelRouter` depth-marker
ordering — see `02-PROGRESS.md`); the rest were tests left behind by three
deliberate redesigns.

> Two entries left the failing set by being **renamed**, not merely fixed:
> `ToolCallEnvelopeTests.testMissingInputFieldReturnsNil` →
> `testMissingInputFieldParsesToEmptyInput`, and
> `testOpenTagWithoutCloseTagReturnsNil` → `testOpenTagWithoutCloseTagIsSalvaged`.
> Both now assert the current (deliberate) contract, and a new
> `testUnbalancedJSONIsNotSalvaged` pins the boundary the salvage path must not
> cross. Noting it so the name-diff is not mistaken for coverage quietly
> disappearing.

### The remaining 14

- `ConversationServiceTests.testLRU_EvictsColdestEntryAtCap`
- `ConversationServiceTests.testTimeoutMarksMessageAsFailed`
- `DiagnosticReportTests.testReportNeverEncodesUnexpectedKeys`
- `HuggingFaceAPIClientTests.testIsNeededForMLXInference_AcceptsBPETokenizer`
- `MLXIntegrationTests.testLoadSuccess_TransitionsToReady`
- `MemoryExtractionTests.testHeuristicRunsWhenNoModelLoaded`
- `MemoryExtractionTests.testHeuristicRunsWithoutRuntime`
- `MemoryServiceTests.testRelevantEpisodesKeywordScoring`
- `ModelCapabilityProfileTests.testResolveMistral`
- `PromptBuilderRailSplitTests.testStableRailContainsLanguageToolPolicyStyleLocation`
- `PromptModeAssemblyTests.testToolFollowupHasShortToolReminder`
- `PromptTokenBudgeterTests.testCodeSnippetIsMoreExpensiveThanProseOfSameLength`
- `SkillManagerTests.testCalculatorDecimalResult`
- `SwiftDataStoreTests.testStoreInitializesSuccessfully`

`SkillManagerTests.testCalculatorDecimalResult` and
`SwiftDataStoreTests.testStoreInitializesSuccessfully` were traced in detail and
**no source-level cause was found** — both depend on runtime behaviour
(`NSExpression` numeric promotion; a real on-disk `ModelContainer` opened in the
host app's process). They need a diagnosis from a live run, not another source
pass. Specifically do **not** "fix" the SwiftData one by switching it to
`isStoredInMemoryOnly: true`: that would delete the only coverage of the
production initializer while making the symptom disappear.

### After the hybrid-retrieval work (still session 5)

| | After F-007 | After retrieval |
|---|---|---|
| Passed | 665 | **677** |
| Failed | 14 | **14** (same names) |
| New tests | — | +12 `LexicalRetrievalTests`, all pass |
| New regressions | — | **none** (name-diff identical to the 14 above) |

The 14 failing names are unchanged from the F-007 result — the retrieval feature
added twelve passing tests and broke nothing. Confirmed by comparing sorted
failing-test names, not exit codes.

### After review-hardening (final, session 5)

| | Baseline | Final |
|---|---|---|
| Passed | 652 | **685** |
| Failed | 25 | **14** (same names as post-F-007) |
| New tests | — | +20 (12 `LexicalRetrievalTests`, 8 `KnowledgeBaseRetrievalFusionTests`) |
| New regressions | — | **none** |

Net session movement: **+33 passing, −11 failing**, twenty new tests, zero
regressions. The 14 remaining failures are byte-identical to the pre-existing
baseline set minus the eleven F-007 fixes.
