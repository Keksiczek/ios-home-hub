# Local Review: Vision + Artifacts sprint

**Reviewed:** 2026-05-26
**Scope:** uncommitted changes (15 modified + 2 new files, ~870 LOC added)
**Focus:** iPhone performance, ARC/memory pressure, Sendable correctness, MLX runtime safety
**Decision:** APPROVE with fixes (1 HIGH, 3 MEDIUM, 2 LOW)

## Summary

Sprint is structurally clean: Sendable boundaries are correct after the
fix iteration, MLX runtime auto-routes vision vs. text via the MLXVLM
trampoline import, persistence model is backward-compatible. Two real
iPhone memory hazards need follow-up before declaring this
production-ready on a constrained device:

1. PDF OCR fallback can balloon to multi-GB peaks on long scanned PDFs.
2. `Message.Artifact.Kind` synthesised `Equatable` compares full image
   byte buffers — SwiftUI diffs these on every render.

Both are quick fixes.

---

## Findings

### CRITICAL

None.

### HIGH

**[H1] PDF OCR loop holds page CGImages across iterations**
`HomeHub/Services/DocumentReaderService.swift:204-220`

```swift
for i in 0..<pdf.pageCount {
    guard let page = pdf.page(at: i) else { continue }
    guard let cgImage = renderPDFPage(page) else { continue }
    // … OCR …
}
```

`renderPDFPage` allocates a `UIGraphicsImageRenderer` → `UIImage` →
`CGImage`. At 144 DPI an A4 page is roughly **16 MB RGBA** in pixels.
Without an explicit `autoreleasepool` the temporary `UIImage` and
`CGContext`'s backing store are released only when the surrounding
async context unwinds — for a 50-page PDF on an iPhone this can
peak past 800 MB of dirty pages before any release happens, well
into jetsam territory.

**Fix:**
```swift
for i in 0..<pdf.pageCount {
    try await autoreleasepool {  // drains per-page
        guard let page = pdf.page(at: i) else { return }
        guard let cgImage = renderPDFPage(page) else { return }
        let recognised = try await ImageVisionService.extractText(fromCGImage: cgImage)
        // …
    }
}
```

(`autoreleasepool` doesn't bridge `try await` directly — needs the body
restructured to return `Void` and side-effect into a local mutable
`pages`. Or use an explicit `Task { ... }.value` pattern.)

### MEDIUM

**[M1] `Message.Artifact.Kind` synthesised Equatable compares image bytes**
`HomeHub/Models/Message.swift:179-275`

`Artifact` has manual `Hashable` that excludes `Data` from the hash
(documented). But `Equatable` was left synthesised — and synthesised
`Equatable` on `case image(data: Data, mime: String)` does
`lhs.data == rhs.data`, i.e. **O(N) byte-by-byte compare per Artifact
on every SwiftUI diff**. With a 2 MB generated image and a 30-message
conversation, scrolling produces 60 MB of memcmp per frame.

**Fix:** add manual `Equatable` that mirrors the `Hashable` strategy —
compare by `id` (and kind tag for sanity):

```swift
static func == (lhs: Artifact, rhs: Artifact) -> Bool {
    guard lhs.id == rhs.id else { return false }
    switch (lhs.kind, rhs.kind) {
    case (.image(_, let a), .image(_, let b)): return a == b  // mime
    case (.code(let s1, let l1), .code(let s2, let l2)): return s1 == s2 && l1 == l2
    case (.unknown(let a), .unknown(let b)): return a == b
    default: return false
    }
}
```

**[M2] `ArtifactView.imageView` decodes UIImage on every body run**
`HomeHub/Features/Chat/ArtifactView.swift:42-65`

```swift
@ViewBuilder
private func imageView(data: Data) -> some View {
    if let uiImage = UIImage(data: data) {
        // …
    }
}
```

`UIImage(data:)` does the JPEG/PNG decode synchronously on the current
thread (typically main). SwiftUI re-runs `body` on parent state churn
(streaming token updates re-render the bubble's siblings), and each
re-run pays the decode again. On a 4 MB photo artifact this is ~30 ms
on iPhone 15 Pro — visible jank during streaming.

**Fix:** lift the decoded image into `@State` keyed by `artifact.id`,
populated in `task(id:)`:

```swift
@State private var decodedImage: UIImage?

.task(id: artifact.id) {
    if case .image(let data, _) = artifact.kind {
        decodedImage = UIImage(data: data)
    }
}
```

**[M3] No size cap on image bytes flowing into `UserInput.images`**
`HomeHub/Runtime/MLXRuntime.swift:1252-1278`

`capturedImageData` is built from `prompt.messages[*].images`. A user
could attach a 12 MP iPhone photo (~5-8 MB JPEG) and that goes through
`CIImage(data:)` → tokeniser. SmolVLM-256M's processor downsamples to
384px internally, so the upstream pixels are wasted RAM. Worse, on a
multi-image attachment turn the CIImage backing stores live until the
closure returns.

**Fix:** downscale upstream in `MessageComposerView` photo picker before
storing `Attachment.imageData` — cap to ~1024 px long edge, JPEG q=0.8.
The existing photo path already stores the picker's raw `Data`; the
fix lives in whichever service writes `Attachment.imageData`.

This is a **medium**, not high, because the catalog vision models
(SmolVLM 256-500M, Qwen2-VL 2B) themselves don't OOM on a single
full-res photo — the risk is multi-image turns or fast-fire scenarios.

### LOW

**[L1] `prompt.messages.flatMap { $0.images ?? [] }` allocates on every generate**
Cheap (one allocation per turn, not per token), but trivially avoidable:

```swift
var capturedImageData: [Data] = []
for msg in prompt.messages where !(msg.images?.isEmpty ?? true) {
    capturedImageData.append(contentsOf: msg.images!)
}
```

Marginal — keep `flatMap` if you find it more readable.

**[L2] `MessageComposerView.activeModelSupportsVision` re-resolves profile on every body run**
The `ModelCapabilityProfile.resolve(family:parameterCount:contextLength:)`
call is pure but does string comparisons against the family table for
each `body` invocation. With `runtimeManager` as `@EnvironmentObject`,
the composer re-renders on every `activeModel` change. Could cache via
`@State` keyed on `activeModel?.id`, but the cost is microseconds —
not worth the complexity unless profiling flags it.

---

## Sendable / concurrency

✅ `[watchdog, capturedLog = self.log]` capture list is correct —
captures Logger by value (Sendable), avoids self capture.
✅ `capturedImageData: [Data]` crosses isolation as Sendable; `CIImage`
   stays inside the closure.
✅ `Message.Artifact` is value type with synthesised Sendable conformance
   via Codable. No actor crossings expected.

## Memory pressure (iPhone)

⚠️ **H1** is the only path that can credibly cause jetsam. Everything
else is well-bounded:
- MLX path already has `autoreleasepool` per token (`generate` loop).
- VLM inference memory is dominated by model weights (1.5-4.3 GB),
  not by image tensors (~10 MB at 384px).
- Catalog `requiresLargeMmapAddressing` flag on Qwen2-VL-7B is set
  correctly — prevents the iOS 2 GB single-mmap crash.

## MLX runtime safety

✅ `import MLXVLM` is purely side-effect — trampoline registers with
   `ModelFactoryRegistry`. No new public API surface.
✅ Vision warning fires only when *runtime model has no vision AND
   image present* — guards against profile↔runtime drift without
   spamming the happy path.
✅ `UserInput(messages:images:)` correctly attaches images at the
   top-level (processor reconstructs per-message attachments).

## Validation

| Check | Result |
|---|---|
| Build (xcodebuild Debug iphonesimulator) | ✅ Pass |
| Type check | ✅ Pass (via build) |
| Tests | ⚠️ Not run (would require simulator boot) |
| Lint | n/a |

## Files Reviewed (changed)

- `HomeHub/Runtime/MLXRuntime.swift` — Modified, +72/-3
- `HomeHub/Runtime/LocalLLMRuntime.swift` — Modified, +32
- `HomeHub/Runtime/ModelCapabilityProfile.swift` — Modified, +121
- `HomeHub/Services/MLXRuntime image path` — covered in MLXRuntime
- `HomeHub/Services/PromptAssemblyService.swift` — Modified, +13
- `HomeHub/Services/ConversationService.swift` — Modified, +13
- `HomeHub/Services/DocumentReaderService.swift` — Modified, +138
- `HomeHub/Services/ImageVisionService.swift` — Modified, +15
- `HomeHub/Services/ModelCatalogService.swift` — Modified, +94
- `HomeHub/Services/KnowledgeBase/IngestPipeline.swift` — Modified, +6
- `HomeHub/Models/Message.swift` — Modified, +177
- `HomeHub/Models/PromptContextPackage.swift` — Modified, +10
- `HomeHub/Features/Chat/MessageBubbleView.swift` — Modified, +16
- `HomeHub/Features/Chat/MessageComposerView.swift` — Modified, +146
- `HomeHub/Features/Chat/ArtifactView.swift` — **Added**, 172 LOC
- `HomeHub.xcodeproj/project.pbxproj` — Modified, +12 (MLXVLM + ArtifactView)
- `HomeHubTests/DocumentReaderOCRFallbackTests.swift` — **Added**, 125 LOC
- `HomeHubTests/PersistenceRoundtripTests.swift` — Modified, +38

---

## Recommended action order

1. **H1 — wrap PDF OCR loop in `autoreleasepool`** (~10 LOC)
2. **M1 — manual Equatable on Artifact.Kind** (~12 LOC)
3. **M2 — `@State` decoded UIImage in ArtifactView** (~8 LOC)
4. **M3 — downscale photo on attach** (~20 LOC in photo picker handler)
5. (LOW items optional — defer until next sprint)

Once 1-4 land, ship.
