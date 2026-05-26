# Local Review: Phase 3 — Image Generation Wiring

**Reviewed:** 2026-05-26
**Scope:** Phase 3 delta — ImageGenerationRuntime + /image slash command + ConversationService.performImageGeneration
**Focus:** concurrency safety (MainActor service), iPhone memory for PNG bytes, error-path symmetry with text runtime, slash command edge cases
**Decision:** APPROVE with one mandatory fix (HIGH) + two recommended (MEDIUM)

## Summary

Architecture is clean: protocol-first design lets a real Core ML SD
runtime drop in later without touching chat plumbing. Stub
implementation is honest (renders "[stub]" + prompt text so users
can't mistake it for a real model). One real user-facing bug:
"Wygenerovaný" is Polish, not Czech — every successful image turn
will surface a misspelled caption.

---

## Findings

### CRITICAL

None.

### HIGH

**[H1] User-facing string "Wygenerovaný" is Polish, not Czech**
`HomeHub/Services/ConversationService.swift:2477`

```swift
assistantMessage.content = "Wygenerovaný obrázek (\(seconds) s)"
```

Should be `"Vygenerovaný"` (Czech "V", not Polish "W"). The
conversation preview on line 2499 already uses the correct form
(`"🖼 Vygenerovaný obrázek"`), so the bubble caption and the
sidebar preview would disagree. Every successful image turn shows
this. The same typo also appears in the docstring on line 2495.

**Fix:** trivial s/Wygenerovaný/Vygenerovaný/g in this file.

### MEDIUM

**[M1] Watchdog timeout from text runtime applied to image runtime**
`HomeHub/Services/ConversationService.swift:981, 988-991, 2419`

`performSend` reads `settings.current.generationTimeoutSeconds`
(text-tuned, typically 60-120 s) and schedules a watchdog that
calls `cancelStream` on expiry. When the early-return branch enters
`performImageGeneration`, that watchdog is still armed.

For the current stub (~200 ms) this is fine. For a real Core ML SD
that needs 5-15 s on iPhone, it's still fine. But once we have FLUX
or a multi-step SDXL run that pushes 30-60 s, the configured timeout
might trip mid-decode and orphan the partial weights. Image
generation should either:
- get its own `imageGenerationTimeoutSeconds` setting, or
- explicitly extend the watchdog when entering the image branch.

Documenting as a known limitation in the code is enough for now.

**[M2] User's "Stop" tap only cancels via stream's internal poll**
`HomeHub/Services/ConversationService.swift:2444-2459`

`performImageGeneration` does `for try await event in stream`. If
the user taps the cancel button, `cancelStream(...)` cancels the
parent Task, which causes Swift to throw `CancellationError` on
the next suspension point. The stub respects this (it checks
`Task.isCancelled` inside its render loop). A real diffusion
runtime that doesn't poll `Task.isCancelled` between steps will
finish the full generation before the cancel takes effect.

**Fix (when real SD lands):** poll `Task.isCancelled` inside the
runtime's step loop AND have the runtime expose an explicit
`cancel()` API the service can call when the parent stream is
finished early.

### LOW

**[L1] StubImageGenerationRuntime calls UIKit from non-MainActor Task**
`HomeHub/Runtime/ImageGenerationRuntime.swift:182-211, 220-272`

The `Task { ... }` inside `AsyncThrowingStream` runs on the
cooperative pool (no inherited isolation). `renderGradient` then
calls `UIGraphicsImageRenderer`, `UIColor.white.setFill()`,
`NSString.draw(in:withAttributes:)`. Per Apple's framework docs
`UIGraphicsImageRenderer` IS thread-safe on iOS 16+, but mixing
this with the off-main `UIColor.setFill()` call is a pattern that's
sometimes flagged by static analyzers and may regress on a future
strict-concurrency tightening.

**Suggested:** wrap the render in `await MainActor.run { ... }` or
mark the protocol's `generate` to inherit the caller's actor. The
stub is non-blocking enough that running on main is fine.

**[L2] No unit tests for `parseImagePromptCommand` or stub runtime**
`HomeHub/Services/ConversationService.swift:2396-2405`,
`HomeHub/Runtime/ImageGenerationRuntime.swift`

`parseImagePromptCommand` is `static` and pure — trivial to test.
Cases worth exercising:
- `"/image cat"` → `"cat"`
- `"/img a fox"` → `"a fox"`
- `"/IMAGE cat"` → `"cat"` (already covered via `.lowercased()`)
- `"/image"` (no body) → `nil`
- `"/image   "` → `nil`
- `"image cat"` (missing slash) → `nil`
- `"/imagery"` (lookalike) → `nil` (relies on trailing space in prefix)

The lookalike case is interesting: `"/imagery"` starts with `"/image"` but not `"/image "`. The prefix check uses `"/image "` (with space), so `"/imagery"` correctly returns nil. Good — but worth a regression test.

Similarly, `StubImageGenerationRuntime.colours(for:)` is deterministic and pure; a snapshot test would catch accidental hash-algorithm changes that would invalidate prior conversations' visual identity.

---

## Concurrency / iPhone perf

✅ **Sendable**: All protocol types (`GeneratedImage`, `ImageGenerationParameters`, `ImageGenerationEvent`) are value types or enum-with-Error. Protocol conformance enforced.
✅ **Actor isolation**: `StubImageGenerationRuntime.State` correctly funnels mutations through `setLoaded(_:)`.
✅ **No retain cycles**: `performImageGeneration` doesn't capture `self` strongly in a long-lived closure; the for-await is structured.
✅ **PNG memory**: 512² PNG ≈ 50-200 KB — fits comfortably in Message persistence even with 30 artifacts per conversation.
⚠️ **L1 above** is the only concurrency note.

## Error-path symmetry with text runtime

✅ Failure populates `assistantMessage.content` with `LocalizedError.errorDescription` and sets `.status = .failed` — same shape as text-runtime failure.
✅ Cancellation surfaces as `ImageGenerationError.cancelled` from stub; user sees Czech "Generování bylo zrušeno."
✅ Background-task handle from `performSend`'s `defer` covers the image branch via the early-return-still-runs-defer Swift semantics.

## Slash command parsing edge cases

✅ Trims surrounding whitespace before AND after the prefix.
✅ Case-insensitive prefix match via `.lowercased()` (only the prefix is lowercased; body keeps original case).
✅ Empty body falls through to the LLM path (model can ask).
✅ Lookalikes like `/imagery` correctly skip (trailing space in prefix).
⚠️ `"/Image cat"` with capital I gets normalized to lowercase via `trimmed.lowercased().hasPrefix(prefix)` — note that the comparison is on the lowercased version but `dropFirst(prefix.count)` operates on the original `trimmed`, so the body keeps its original case. ✓ Correct.

## Validation

| Check | Result |
|---|---|
| Build (xcodebuild Debug iphonesimulator) | ✅ Pass |
| Type check | ✅ Pass (via build) |
| Tests | ⚠️ Not run — no tests added for this feature |

## Files Reviewed

- `HomeHub/Runtime/ImageGenerationRuntime.swift` — **Added**, 298 LOC
- `HomeHub/Services/ConversationService.swift` — Modified, +~140 LOC
- `HomeHub.xcodeproj/project.pbxproj` — Modified, +3 (file ref + build file + group)

---

## Recommended action order

1. **H1 — fix "Wygenerovaný" → "Vygenerovaný" typo** (2 sites, mandatory)
2. **M1 — add code comment about watchdog/timeout coupling** (~3 LOC)
3. **M2 — add a TODO at the for-await loop noting real runtimes need explicit cancel()** (~2 LOC)
4. **L1 — wrap StubImageGenerationRuntime render in MainActor.run** (~5 LOC, optional)
5. **L2 — add unit tests for parseImagePromptCommand** (~20 LOC, optional)

H1 is a real user-visible string bug — block on that. M1/M2 are documentation fixes that should land at the same time. L1/L2 can defer.
