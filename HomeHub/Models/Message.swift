import Foundation

struct Message: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let conversationID: UUID
    var role: Role
    var content: String
    var createdAt: Date
    var status: Status
    var tokenCount: Int?
    var attachments: [Attachment]?
    /// Assistant-produced side outputs that aren't plain chat text:
    /// generated images, runnable code, structured tables, etc. Kept
    /// separate from `content` so the UI can render each artifact in
    /// its own affordance (image preview, code block with copy/run,
    /// table viewer) instead of cramming everything into the text
    /// bubble.
    ///
    /// Optional + decoded permissively so older messages without
    /// artifacts continue to decode after a schema bump. `nil` for
    /// user/system messages and for assistant turns that didn't
    /// produce any artifact.
    var artifacts: [Artifact]?
    /// User-set bookmark flag. Optional (with implicit-false read via
    /// `isBookmarked`) so older persisted messages decode without
    /// requiring a migration — Swift's synthesized `Codable` treats a
    /// missing key as `nil` for optionals, but would throw on a
    /// missing non-optional `Bool`.
    var bookmarked: Bool?

    /// Why the runtime stopped generating this message. Stored as a
    /// raw string (not the runtime's enum) so the chat layer doesn't
    /// pull in `MLXLLM` types and so older persisted messages decode
    /// without a migration. Values mirror `RuntimeEvent.FinishReason`:
    /// `"stop"` (model emitted EOT), `"length"` (max tokens budget),
    /// `"cancelled"` (user-initiated stop). `nil` on `.user` /
    /// `.system` messages and on assistant messages persisted before
    /// this field existed.
    ///
    /// Drives the "Pokračovat" affordance: when the value is
    /// `"length"` AND this is the most recent assistant message, the
    /// bubble surfaces a button that asks the model to continue from
    /// where it stopped instead of re-rolling the whole answer.
    var finishReason: String?

    /// IDs of `MemoryFact` rows that were injected into the prompt
    /// for THIS turn. Set by `ConversationService` right before the
    /// runtime call; surfaced in `MessageBubbleView` as a tappable
    /// "🧠 Použito X fakt" chip so users see what the model
    /// "remembered" about them.
    ///
    /// Optional so older persisted messages decode without a
    /// migration (synthesised `Codable` treats missing keys as `nil`
    /// for optionals). `nil` on user/system messages and on assistant
    /// turns that didn't pull memory (memory disabled, no facts
    /// matched). Empty array also OK — means "memory was checked, no
    /// facts applied" and we don't render the chip.
    ///
    /// Resolved back to live `MemoryFact` objects at render time by
    /// looking each ID up in `MemoryService.facts`. Facts the user
    /// has deleted since the turn just don't render — graceful
    /// degradation.
    var appliedMemoryFactIDs: [UUID]?

    /// Generation throughput snapshot captured from
    /// `RuntimeEvent.finished` for assistant messages. Surfaced as a
    /// small "12 tok · 9.4 t/s" footer on completed bubbles so users
    /// can build intuition for which model / quant is actually fast
    /// on their device without leaving the chat for a diagnostics
    /// screen.
    ///
    /// Optional + `decodeIfPresent`-safe via the synthesised Codable
    /// for forward compat. `nil` on user/system messages and on
    /// assistant messages persisted before this field existed.
    var generationStats: GenerationStats?

    /// Snapshot of one generation's throughput numbers. Plain value
    /// type — mirrors `RuntimeStats` from the runtime layer but
    /// lives in the model layer so the chat surface doesn't need
    /// to import MLX types.
    struct GenerationStats: Codable, Equatable, Hashable, Sendable {
        let tokensGenerated: Int
        let tokensPerSecond: Double
        let totalDurationMs: Int
    }

    /// Convenience for "is this message bookmarked?" so the UI doesn't
    /// have to repeat the `?? false` defaulting at every call site.
    var isBookmarked: Bool { bookmarked == true }

    /// `true` when the runtime stopped because the max-tokens budget
    /// was reached — i.e. the reply is likely mid-thought. UI uses
    /// this to render the Continue button.
    var wasTruncatedByLength: Bool { finishReason == FinishReasonKey.length }

    struct Attachment: Codable, Equatable, Hashable, Identifiable {
        let id: UUID
        let filename: String
        let extractedText: String
        /// Raw image bytes preserved alongside the OCR text so the
        /// future Vision-Language-Model path can feed actual pixels
        /// to a multimodal model instead of only the recognised text.
        ///
        /// Optional + decoded permissively so older persisted messages
        /// (pre-VLM) decode without a migration. Today only the photo
        /// attachment path populates this; document attachments leave
        /// it `nil`. Encoded as base64 in JSON via the synthesised
        /// `Data` codec — small (<5 MB downscaled) so this is fine for
        /// SwiftData blobs / JSON FileStore.
        ///
        /// Hashing intentionally ignores the byte buffer to keep
        /// `Hashable` cheap on long conversations; identity comes from
        /// `id`. `Equatable` does compare the bytes so the
        /// "is this the same attachment?" semantics stay sound.
        var imageData: Data?
        /// MIME type matching `imageData`. `"image/jpeg"` /
        /// `"image/png"` today; ignored when `imageData == nil`.
        var imageMimeType: String?

        // MARK: - Hashable

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(filename)
            hasher.combine(extractedText)
            // Deliberately omitting imageData — see doc comment.
        }

        // MARK: - Codable (migration-safe)

        private enum CodingKeys: String, CodingKey {
            case id, filename, extractedText, imageData, imageMimeType
        }

        init(
            id: UUID,
            filename: String,
            extractedText: String,
            imageData: Data? = nil,
            imageMimeType: String? = nil
        ) {
            self.id = id
            self.filename = filename
            self.extractedText = extractedText
            self.imageData = imageData
            self.imageMimeType = imageMimeType
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            self.filename = try c.decode(String.self, forKey: .filename)
            self.extractedText = try c.decode(String.self, forKey: .extractedText)
            self.imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
            self.imageMimeType = try c.decodeIfPresent(String.self, forKey: .imageMimeType)
        }
    }

    enum Role: String, Codable, Hashable {
        case system
        case user
        case assistant
    }

    enum Status: String, Codable, Hashable {
        case pending
        case streaming
        case complete
        case failed
        case cancelled
    }

    static func user(_ text: String, in conversationID: UUID, attachments: [Attachment]? = nil) -> Message {
        Message(
            id: UUID(),
            conversationID: conversationID,
            role: .user,
            content: text,
            createdAt: .now,
            status: .complete,
            tokenCount: nil,
            attachments: attachments
        )
    }

    static func assistantPlaceholder(in conversationID: UUID) -> Message {
        Message(
            id: UUID(),
            conversationID: conversationID,
            role: .assistant,
            content: "",
            createdAt: .now,
            status: .streaming,
            tokenCount: nil,
            attachments: nil
        )
    }

    /// String constants that mirror `RuntimeEvent.FinishReason` cases.
    /// Centralising them here keeps the stringly-typed `finishReason`
    /// comparison sites in sync — a typo would otherwise silently
    /// break `wasTruncatedByLength` without a compiler warning.
    enum FinishReasonKey {
        static let stop      = "stop"
        static let length    = "length"
        static let cancelled = "cancelled"
        static let error     = "error"
    }

    /// Side outputs attached to a chat turn. Encoded as a tagged
    /// union via `kind` so the JSON stays human-readable AND so
    /// future kinds (audio, table, etc.) can be added without
    /// breaking existing persisted data — unknown `kind` values
    /// decode to `.unknown(raw:)` instead of throwing.
    ///
    /// The wire format is intentionally close to OpenAI / Anthropic
    /// "content blocks" so that if/when this app's chat history
    /// becomes interchangeable with a remote API, the artifact
    /// blocks line up.
    struct Artifact: Codable, Equatable, Hashable, Identifiable {
        let id: UUID
        let kind: Kind

        enum Kind: Equatable, Hashable {
            /// A bitmap image produced by an image-generation model
            /// (Stable Diffusion / FLUX) or returned by a tool.
            /// `data` is the raw image bytes (PNG/JPEG), `mime` the
            /// media type. Kept inline (not as a file reference) so
            /// the artifact persists with the message body, mirroring
            /// how `Attachment.imageData` works.
            case image(data: Data, mime: String)
            /// A code block produced by the model. `language` is
            /// the syntax hint (e.g. `"swift"`, `"python"`); empty
            /// string when the model didn't tag the block.
            case code(source: String, language: String)
            /// Unknown artifact kind from a future schema version.
            /// Stored as the raw JSON-decoded payload so a downgrade
            /// can still roundtrip the data unchanged.
            case unknown(rawKind: String)
        }

        // MARK: Codable

        private enum CodingKeys: String, CodingKey {
            case id, kind, data, mime, source, language, rawKind
        }

        init(id: UUID = UUID(), kind: Kind) {
            self.id = id
            self.kind = kind
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            let tag = try c.decode(String.self, forKey: .kind)
            switch tag {
            case "image":
                let data = try c.decode(Data.self, forKey: .data)
                let mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? "image/png"
                kind = .image(data: data, mime: mime)
            case "code":
                let source = try c.decode(String.self, forKey: .source)
                let lang = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
                kind = .code(source: source, language: lang)
            default:
                // Unknown future kind — preserve the tag so a later
                // build (that DOES know this kind) can still see it.
                kind = .unknown(rawKind: tag)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            switch kind {
            case .image(let data, let mime):
                try c.encode("image", forKey: .kind)
                try c.encode(data, forKey: .data)
                try c.encode(mime, forKey: .mime)
            case .code(let source, let lang):
                try c.encode("code", forKey: .kind)
                try c.encode(source, forKey: .source)
                try c.encode(lang, forKey: .language)
            case .unknown(let rawKind):
                // Preserve the original tag verbatim so a roundtrip
                // doesn't lose information; payload is gone (we never
                // captured it), but the kind survives.
                try c.encode(rawKind, forKey: .kind)
            }
        }

        // MARK: Equatable
        //
        // Manual `Equatable` mirrors the manual `Hashable`: the
        // synthesised version would compare the `Data` byte buffer on
        // `.image` cases, which is `O(N·imageSize)` per check. SwiftUI
        // diffs Equatable on every body re-run, so a 30-message thread
        // with 2 MB image artifacts would memcmp ~60 MB per frame just
        // to decide nothing changed.
        //
        // Identity comes from `id`; the kind tag + cheap fields
        // (mime / language) gate the obvious "kind switched"
        // comparison. The byte buffer is intentionally excluded —
        // if `id` matches we treat the artifact as the same value.
        static func == (lhs: Artifact, rhs: Artifact) -> Bool {
            guard lhs.id == rhs.id else { return false }
            switch (lhs.kind, rhs.kind) {
            case (.image(_, let lMime), .image(_, let rMime)):
                return lMime == rMime
            case (.code(let lSrc, let lLang), .code(let rSrc, let rLang)):
                return lSrc == rSrc && lLang == rLang
            case (.unknown(let l), .unknown(let r)):
                return l == r
            default:
                return false
            }
        }

        // MARK: Hashable
        //
        // Manual Hashable mirrors the manual Codable: synthesized
        // Hashable would refuse to compile on the associated-value
        // enum without `Data` being Hashable (it is, but we want to
        // exclude the byte buffer from the hash for the same reason
        // `Attachment` does — long conversations with image artifacts
        // would pay an O(N·imageSize) hash on every diff).
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            switch kind {
            case .image(_, let mime):
                hasher.combine("image")
                hasher.combine(mime)
            case .code(let source, let lang):
                hasher.combine("code")
                hasher.combine(source)
                hasher.combine(lang)
            case .unknown(let raw):
                hasher.combine("unknown")
                hasher.combine(raw)
            }
        }
    }
}
