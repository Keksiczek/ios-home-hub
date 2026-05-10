# Knowledge Base — persistent document memory + background ingest

This module persists user-supplied documents (PDF, text, markdown,
web text snippets) and indexes them so chat / agents can retrieve
relevant chunks at query time. Storage lives inside the App Group
container so the future Share Extension can drop files into the
inbox and queue ingest jobs without IPC.

## Components

| File | Role |
|---|---|
| `Models/KnowledgeBase.swift` | `DocumentRecord`, `ChunkRecord`, `IngestJob`, status enums, `RetrievalQuery`/`RetrievedChunk`, `KBVersions` constants. |
| `SharedStorage.swift` | App Group container layout + path helpers + SHA-256. |
| `KnowledgeBaseStore.swift` | Persistence for documents/chunks/vectors. JSON for metadata, binary blob for vectors. |
| `IngestJobStore.swift` | Persistent FIFO of ingest jobs. |
| `DocumentChunker.swift` | Deterministic char-based chunker with overlap. Same input → same chunk IDs every time. |
| `DocumentEmbedder.swift` | Protocol + `EmbeddingService` adapter. |
| `IngestPipeline.swift` | Orchestrator. Restartable state machine per `IngestJob`. Yields between batches so it fits inside a `BGProcessingTask` budget. |
| `KnowledgeBaseRetrieval.swift` | Top-k cosine retrieval. |
| `IngestScheduler.swift` | Bridges the pipeline to `BGTaskScheduler` and the SwiftUI `scenePhase`. |
| `KnowledgeBaseService.swift` | `@MainActor` façade injected via `EnvironmentObject`. |
| `Features/KnowledgeBase/KnowledgeBaseDebugView.swift` | Debug list + import button. Surfaced under Settings → Developer. |

## On-disk layout (under the App Group container)

```
inbox/                          # Drop zone for the Share Extension
kb/files/                       # Canonical copies of ingested files
kb/index/
  documents.json                # [DocumentRecord]
  chunks-<docID>.json           # [ChunkRecord]   (text + offsets, no vectors)
  vectors-<docID>.bin           # Float32 vector matrix (header + payload)
  jobs.json                     # [IngestJob]
```

The vector blob has a 16-byte header (`"HHKB"`, version, count, dim)
followed by `count * dim` Float32s — Float32 instead of Double halves
disk size with no measurable cosine quality loss for the averaged
NLContextualEmbedding output.

## Ingest pipeline state machine

```
queued → parsing → chunking → embedding → indexing → indexed
                                   │
                                   └─ (any failure / time budget) ─→ failed
```

Each state transition is persisted on `DocumentRecord` before the
next step starts. `IngestPipeline.runIngest` is therefore safe to
re-enter after process death — `IngestJobStore.fetchPending` returns
`processing` jobs first so an interrupted ingest is resumed before
new work is picked up.

`embeddingBatchSize = 32` per inner-loop iteration; the
`shouldContinue` callback (set by the BG handler) flips false when
the `expirationHandler` fires, the loop exits cleanly between
batches, and the rest is left for the next foreground / BG drain.

## Background scheduling

Registration happens **synchronously** in
`AppDelegate.application(_:didFinishLaunchingWithOptions:)` via
`MainActor.assumeIsolated`. iOS terminates the app if
`BGTaskScheduler.register(forTaskWithIdentifier:)` is called any
later.

Identifier: `cz.keksiczek.homehub.ingest` — declared in
`project.yml` as `INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers`.

Submission strategy:
- on `scenePhase == .background`, if there are pending jobs, submit
  a `BGProcessingTaskRequest` with a 30 s `earliestBeginDate`.
- when the system wakes us, drain in batches and re-submit if work
  remains.
- on `scenePhase == .active`, drain any leftover queue right away —
  this is the *guaranteed* path; BG scheduling is opportunistic.

## Retrieval

```swift
let query = RetrievalQuery(
    queryText: input,
    workspaceID: nil,
    documentIDs: nil,           // nil = full KB
    maxChunks: 6,
    minRelevance: 0.25
)
let hits = try await container.knowledgeBaseService.retrievalAPI?
    .retrieve(for: query) ?? []
```

`hits` carries the full `DocumentRecord` plus the `ChunkRecord`
(with `pageNumber`, `sectionPath`, `startOffset`/`endOffset`) so the
chat UI can render citations without further look-ups. v1 does a
linear cosine pass — fine up to a few thousand chunks; switch to an
HNSW index when corpus growth makes it worthwhile.

## Adding a custom embedder

Conform to `DocumentEmbedder` and pass the new instance into
`KnowledgeBaseService(embedding:)` (the convenience init wraps the
shared `EmbeddingService`; for a custom path, build the pipeline
manually with `IngestPipeline(... embedder: yourEmbedder)`).
