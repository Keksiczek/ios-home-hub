import Foundation
import os

/// View-layer + runtime-layer snapshot of the small subset of GGUF
/// metadata the rest of the app cares about.
///
/// This struct is the *output* of a one-shot `GGUFMetadata.read(at:)`
/// pass for a single model file, post-processed into the form callers
/// expect:
///   - empty strings collapse to `nil`
///   - context length must be > 0 to be considered "known"
///   - everything is best-effort: missing fields stay `nil` and the
///     caller falls back to the catalog defaults
///
/// **Cached, not embedded in `LocalModel`.** `LocalModel` is `Codable` /
/// `Hashable` and lives on disk under `user-models.json`; mutating it
/// every time we open a GGUF would churn equality and persistence.
/// `ModelCatalogService.ggufMetadata[modelID]` is the canonical home.
struct GGUFModelMetadata: Sendable, Equatable {

    /// Source of the chat template the runtime should use for this model.
    enum TemplateSource: String, Sendable, Equatable {
        /// `tokenizer.chat_template` was present in the GGUF header.
        case gguf
        /// No template in metadata — runtime falls back to the
        /// `ChatTemplate.render(_:family:)` per-family default.
        case builtIn
    }

    /// `general.architecture` (`"llama"`, `"qwen2"`, …) — useful for UI.
    let architecture: String?
    /// `general.name` — many GGUFs ship a better human-readable name
    /// than the file path implies. The catalog's `displayName` still wins
    /// in the UI unless this is explicitly preferred at the call site.
    let displayName:  String?
    /// Raw Jinja `tokenizer.chat_template` — when present this is what
    /// `llama_apply_chat_template` (llama.cpp opt-in path) should consume.
    /// `MLXLLM.ChatSession` reads its own copy from the tokenizer snapshot
    /// so the MLX runtime doesn't need to look at this field.
    let chatTemplate: String?
    /// Native context-length declared by the model
    /// (`<arch>.context_length`). The catalog's per-device-adjusted value
    /// still applies as the upper bound; the runtime takes
    /// `min(catalog, metadata)`.
    let contextLength: Int?

    /// What the runtime will actually use for templating.
    var templateSource: TemplateSource {
        chatTemplate != nil ? .gguf : .builtIn
    }

    // MARK: - Factory

    /// Reads the on-disk GGUF header (O(header)) and returns the
    /// post-processed snapshot. Returns `nil` for non-GGUF files,
    /// unreadable files, or files whose header is malformed.
    ///
    /// **Never throws** — this is called from background download
    /// completion and reconcile paths where a malformed file is
    /// expected (e.g. a stub left over from a failed install). The
    /// failure path is logged once and the caller proceeds with
    /// catalog defaults.
    static func read(at url: URL) -> GGUFModelMetadata? {
        let log = Logger(subsystem: "HomeHub", category: "GGUFModelMetadata")
        do {
            let raw = try GGUFMetadata.read(at: url)
            let meta = GGUFModelMetadata(
                architecture: emptyToNil(raw.architecture),
                displayName:  emptyToNil(raw.modelName),
                chatTemplate: emptyToNil(raw.chatTemplate),
                contextLength: (raw.nativeContextLength ?? 0) > 0 ? raw.nativeContextLength : nil
            )
            // One line per successful parse so the install / reconcile flow
            // surfaces *which* model authored a template and what context
            // length it declared. Helps diagnose "garbage prompt" reports.
            log.info(
                "GGUF metadata parsed for \(url.lastPathComponent, privacy: .public): arch=\(meta.architecture ?? "(none)", privacy: .public) ctx=\(meta.contextLength.map(String.init) ?? "(none)", privacy: .public) chatTemplate=\(meta.chatTemplate != nil ? "present" : "absent", privacy: .public)"
            )
            return meta
        } catch {
            log.notice("GGUF metadata read failed at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public) — falling back to catalog defaults")
            return nil
        }
    }

    private static func emptyToNil(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
