# HomeHub Implementation Roadmap

This document outlines recommended next phases for HomeHub, prioritized by impact and complexity.

---

## Current State (May 2026)

✅ **Completed**:
- Dynamic device memory profiling (iPhone SE → iPhone 16 Pro)
- Context window optimization (Jetsam OOM prevention)
- MLX GPU cache limiting (multi-turn stability)
- Sliding window history trimming (KV cache mitigation)
- Kernel entitlements (extended memory allocation)
- Native Voice Chat (SFSpeechRecognizer + AVSpeechSynthesizer)
- Image OCR (Vision framework text extraction)

❓ **Partial/Missing**:
- RAG for PDF/document analysis
- Vision-Language Model integration
- Offline embedding models

---

## Phase 6: Retrieval-Augmented Generation (RAG)

**Priority**: HIGH  
**Effort**: 2–3 weeks  
**Complexity**: Medium

### Problem Statement

Currently, if a user uploads a 50-page PDF and asks "summarize chapter 3", the app:
1. Tries to extract full text
2. Attempts to fit entire text into LLM context window
3. Either truncates content (loses information) or exceeds context limit (OOM)

### Solution Architecture

```
┌─────────────────────────────────────────────────────┐
│ User uploads document (PDF / TXT)                   │
└────────────────┬────────────────────────────────────┘
                 │
        ┌────────▼─────────┐
        │ DocumentService  │
        │ (parse + chunk)  │
        └────────┬─────────┘
                 │
              512-token chunks
                 │
        ┌────────▼──────────────┐
        │ EmbeddingService      │
        │ (nomic-embed-text)    │
        │ 384-dimensional       │
        └────────┬──────────────┘
                 │
        ┌────────▼──────────────┐
        │ Local Vector DB       │
        │ (SQLite + vectors)    │
        └──────────────────────┘
                 ▲
                 │
    User asks "What about chapter 3?"
                 │
        ┌────────▼──────────────┐
        │ Retrieve top-3 chunks │
        │ by vector similarity  │
        └────────┬──────────────┘
                 │
              ┌──▼───────────────────────┐
              │ Inject into LLM prompt   │
              │ (within n_ctx limit)     │
              └──────────────────────────┘
```

### Implementation Steps

#### 1. **Chunking Service**

```swift
// Services/DocumentChunkingService.swift
actor DocumentChunkingService {
    func chunk(text: String, size: Int = 512, overlap: Int = 100) -> [String] {
        // Split by sentences, not characters, to preserve semantics
        let sentences = text.split(separator: ".")
        var chunks: [String] = []
        var current = ""
        
        for sentence in sentences {
            if current.count + sentence.count > size {
                if !current.isEmpty {
                    chunks.append(current)
                }
                current = String(sentence)
            } else {
                current.append(contentsOf: "." + sentence)
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
```

#### 2. **Embedding Service** (Lightweight)

Recommendation: Use **nomic-embed-text** (MLX-optimized, 384-dimensional)

```swift
// Services/EmbeddingService.swift
actor EmbeddingService {
    private var embeddingModel: ModelContainer?
    
    func load() async throws {
        let config = ModelConfiguration(id: "nomic-ai/nomic-embed-text-v1")
        embeddingModel = try await loader.load(configuration: config, ...)
    }
    
    func embed(text: String) async throws -> [Float] {
        let container = try embeddingModel ?? (try await load())
        let input = [text]
        let result = try await container.perform { context in
            try await generate(input: input, context: context)
        }
        return result  // 384 floats
    }
}
```

#### 3. **Vector Database** (SQLite + Extension)

Use **sqlite-vec** for local vector similarity:

```swift
// Services/VectorDatabaseService.swift
actor VectorDatabaseService {
    private let db: Database  // sqlite-vec
    
    func store(chunks: [String], embeddings: [[Float]], documentID: UUID) async throws {
        for (chunk, embedding) in zip(chunks, embeddings) {
            try await db.insert(
                document_id: documentID,
                chunk_text: chunk,
                embedding: embedding  // stored as blob
            )
        }
    }
    
    func search(query: String, queryEmbedding: [Float], topK: Int = 3) async -> [String] {
        // SQLite-vec: find K nearest neighbors by cosine distance
        let results = try await db.execute("""
            SELECT chunk_text FROM chunks
            ORDER BY vec_distance_cosine(embedding, ?)
            LIMIT ?
        """, [queryEmbedding, topK])
        return results.map { $0.chunk_text }
    }
}
```

#### 4. **RAG Assembly in Prompt**

Integrate into `PromptAssemblyService`:

```swift
// Existing chat assembly
private func assembleChatPrompt(from package: PromptContextPackage) -> String {
    var chunks: [String] = [package.assistant.systemPromptBase]
    
    // NEW: RAG retrieval
    if let documentContext = package.documentContext {
        let embedding = try await embeddingService.embed(documentContext.query)
        let relevantChunks = await vectorDB.search(
            queryEmbedding: embedding, 
            topK: 3
        )
        let ragContext = """
        Context from document:
        \(relevantChunks.joined(separator: "\n---\n"))
        """
        chunks.append(ragContext)
    }
    
    // Continue with existing assembly...
    return chunks.joined(separator: "\n\n")
}
```

### Testing RAG

```swift
// Example flow
let doc = DocumentRecord(
    id: UUID(),
    title: "iOS LLM Guide.pdf",
    text: "... 50 pages of content ..."
)

// 1. Chunk
let chunks = chunkingService.chunk(doc.text)

// 2. Embed
let embeddings = try await embeddingService.embed(chunks)

// 3. Store
try await vectorDB.store(chunks: chunks, embeddings: embeddings, documentID: doc.id)

// 4. Later: User asks a question
let userQuery = "How do I optimize memory on iPhone SE?"
let queryEmbed = try await embeddingService.embed(userQuery)
let relevant = await vectorDB.search(queryEmbedding: queryEmbed, topK: 3)
// relevant = [
//    "Memory constraints on iPhone SE are...",
//    "Context windows should be limited to...",
//    "Jetsam OOM is triggered when..."
// ]
```

### Dependencies to Add

```swift
// Package.swift
.package(url: "https://github.com/asg017/sqlite-vec.git", from: "0.1.0"),
```

---

## Phase 7: Vision-Language Model (VLM) Support

**Priority**: MEDIUM  
**Effort**: 1–2 weeks  
**Complexity**: Medium

### Current Gap

- ✅ Image OCR (text extraction via Vision framework)
- ❌ Image understanding (LLM vision capabilities)

### Solution

Add multimodal model to catalog:

```swift
// ModelCatalogService
LocalModel(
    id: "mlx-qwen-vl-7b",
    displayName: "Qwen VL 7B (Vision)",
    family: "Qwen",
    parameterCount: "7B",
    quantization: "4-bit",
    sizeBytes: 4_500_000_000,
    contextLength: 2048,           // Conservative for image + text
    imageTokenBudget: 70,          // NEW: limit image token overhead
    downloadURL: URL(static: "..."),
    recommendedFor: [.iPadMSeries], // iPad only (too large for iPhone)
    backend: .mlx,
    format: .mlx
)
```

### Implementation

Update `ModelCapabilityProfile`:

```swift
struct ModelCapabilityProfile {
    // ... existing fields ...
    let supportsVision: Bool
    let imageTokenBudget: Int  // NEW
}

// In profile resolution:
extension ModelCapabilityProfile {
    static let qwen_vl = ModelCapabilityProfile(
        family: "qwen",
        supportsVision: true,
        imageTokenBudget: 70,      // Aggressively limit image compression
        // ... rest
    )
}
```

Update prompt assembly to handle images:

```swift
// PromptAssemblyService
if let image = package.userMessage.image {
    let imageData = try ImageEncoder.encode(image)  // → tensor
    
    // Respect budget
    let budgetedTokens = min(imageData.shape[0], profile.imageTokenBudget)
    
    // Inject into prompt
    let imagePrompt = """
    User provided an image:
    <image_tokens: \(budgetedTokens)>
    """
    runtimeMessages.append(RuntimeMessage(role: .user, content: imagePrompt))
}
```

### Testing

```swift
let image = UIImage(named: "screenshot.png")!
let response = await runtime.generate(
    prompt: RuntimePrompt(
        systemPrompt: "You are an image analyst",
        messages: [
            RuntimeMessage(role: .user, content: "What's in this image?", image: image)
        ]
    )
)
// Model should describe the image content
```

---

## Phase 8: Offline Embedding Model (Optional)

**Priority**: LOW (if deploying RAG on all devices)  
**Effort**: 1 week  
**Complexity**: Low

Currently RAG requires downloading embedding model (~500 MB).

### Alternative: Smaller Embedding Model

For extremely constrained devices (iPhone SE with limited storage):

- **all-MiniLM-L6-v2** (50 MB, 384-dim, ~90% quality of nomic-embed)
- Use ONNX Runtime instead of MLX for faster inference

```swift
// Services/LightweightEmbeddingService.swift
actor LightweightEmbeddingService {
    private let onnxSession: ONNXSession  // Much lighter than MLX
    
    func embed(text: String) async -> [Float] {
        let tokenized = tokenizer.encode(text)
        let output = onnxSession.run(input: tokenized)
        return Array(output.squeezed())
    }
}
```

---

## Priority Order

1. **Phase 6: RAG** (highest impact, enables document understanding)
2. **Phase 7: VLM** (medium impact, nice-to-have for iPad Pro users)
3. **Phase 8: Lightweight Embedding** (low impact, optimization only)

---

## Estimated Timeline

| Phase | Effort | Start | Complete |
|-------|--------|-------|----------|
| 6 (RAG) | 2–3w | Week 1 | Week 3–4 |
| 7 (VLM) | 1–2w | Week 4 | Week 5–6 |
| 8 (Lightweight) | 1w | Week 7 | Week 8 |

**Total**: 4–8 weeks to production-ready state.

---

## Success Criteria

### RAG
- [ ] Upload 50-page PDF → extract into 100+ chunks
- [ ] Query PDF → retrieve relevant chunks in <200 ms
- [ ] LLM answer incorporates document information correctly
- [ ] No OOM crashes on iPhone 13+ with documents

### VLM
- [ ] Share image from Photos → LLM analyzes it
- [ ] Image understanding works without crashes on iPad Pro
- [ ] Quality comparable to Qwen VL online demo

### Lightweight Embedding
- [ ] Embedding model loads in <2 seconds
- [ ] Vector search latency <100 ms for 1000 chunks
- [ ] No increase in app binary size (download-on-demand model)

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| RAG vector DB grows unbounded | Implement cleanup policy: delete old chunks after 90 days |
| Image processing (VLM) OOMs on iPhone | Never add VLM to iPhone recommendations; iPad Pro only |
| Embedding model download fails | Graceful fallback to keyword-based search (no embeddings) |
| Vector similarity search is slow | Profile with realistic data; consider indexing if >10K chunks |

