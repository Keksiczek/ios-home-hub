import Foundation
// Hub and Tokenizers are internal targets of the swift-transformers `Transformers`
// library product.  We depend on product: Transformers in project.yml / Package.swift;
// both modules are compiled into the build graph and importable here.
@preconcurrency import Hub
import Tokenizers
import MLXLMCommon

// MARK: - HubApiDownloader

/// A concrete `MLXLMCommon.Downloader` that delegates to `swift-transformers`'s
/// `HubApi.snapshot(from:matching:progressHandler:)`.
///
/// The snapshot is stored at:
/// `Documents/huggingface/models/<org>/<repo>/` — the same path that
/// `LocalModelService.mlxCacheState(for:)` checks (Phase 3 compatibility).
///
/// ## Progress
/// The `HubApi` downloader emits a `Foundation.Progress` object as it fetches
/// each file in the repo. We forward that directly to the caller's `progressHandler`
/// so the UI receives **real** fractional progress during download.
///
/// ## Cancellation
/// `HubApi.snapshot()` is a standard `async throws` function, so Swift cooperative
/// cancellation (`Task.cancel()`) propagates. Cancellation may complete the current
/// file chunk before stopping — this is expected and safe. Phase 3 detection will
/// classify any partial cache as `.partial`, not `.ready`.
struct HubApiDownloader: Downloader {
    private let hub: HubApi

    init(hub: HubApi = .shared) {
        self.hub = hub
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // NOTE: revision and useLatest are intentionally not forwarded —
        // HubApi.snapshot has no revision parameter in swift-transformers 0.1.14
        // (upstream tracks this as a TODO). Models are always fetched at HEAD.
        return try await hub.snapshot(
            from: id,
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

// MARK: - SwiftTransformersTokenizerLoader

/// A concrete `MLXLMCommon.TokenizerLoader` that delegates to
/// `swift-transformers`'s `AutoTokenizer.from(modelFolder:)`.
///
/// This bridges the `Tokenizers.Tokenizer` protocol from `swift-transformers`
/// into `MLXLMCommon.Tokenizer`, satisfying the type requirements of the
/// `loadModelContainer(from:using:configuration:progressHandler:)` API.
struct SwiftTransformersTokenizerLoader: TokenizerLoader {
    private let modelFamily: String?

    init(modelFamily: String? = nil) {
        self.modelFamily = modelFamily
    }

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        do {
            let upstream = try await AutoTokenizer.from(modelFolder: directory)
            return SwiftTransformersTokenizerBridge(upstream, modelFamily: modelFamily)
        } catch {
            // Log what is actually present in the folder for easier debugging on device
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(atPath: directory.path))?.joined(separator: ", ") ?? "unreadable"
            
            HHLog.runtime.error("""
                Tokenizer load failed at: \(directory.path)
                Found files: \(files)
                Error: \(error)
                """)
            throw error
        }
    }
}

// MARK: - SwiftTransformersTokenizerBridge

/// Bridges a `Tokenizers.Tokenizer` (from swift-transformers) to
/// `MLXLMCommon.Tokenizer`.
///
/// This is the same bridge that `MLXHuggingFace`'s `#adaptHuggingFaceTokenizer()`
/// macro would generate, written out explicitly so we don't need to add the
/// `MLXHuggingFace` product (which requires bringing in its own macro build target).
// @unchecked Sendable: Tokenizers.Tokenizer is not declared Sendable in swift-transformers.
// SwiftTransformersTokenizerBridge is safe because the underlying tokenizer is created once,
// never mutated after init, and AutoTokenizer implementations are stateless for encode/decode.
private struct SwiftTransformersTokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any Tokenizers.Tokenizer
    private let modelFamily: String?

    init(_ upstream: any Tokenizers.Tokenizer, modelFamily: String? = nil) {
        self.upstream = upstream
        self.modelFamily = modelFamily
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        // swift-transformers `decode(tokens:)` has no skipSpecialTokens parameter,
        // so the flag is intentionally ignored. Special tokens may appear in output
        // if the model doesn't strip them via its chat template.
        upstream.decode(tokens: tokenIds)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        // SAFETY: "\($0)" is standard Swift string interpolation of the value —
        // NOT a literal backslash sequence. This correctly calls description/CustomStringConvertible.
        let stringMessages = messages.map { dict in
            dict.compactMapValues { "\($0)" }
        }

        do {
            return try upstream.applyChatTemplate(messages: stringMessages)
        } catch let error as Tokenizers.TokenizerError {
            switch error {

            case .missingChatTemplate:
                // FALLBACK ACTIVATED: no chat_template key in tokenizer_config.json
                HHLog.runtime.warning("""
                    MLX [applyChatTemplate]: upstream threw TokenizerError.missingChatTemplate \
                    — tokenizer config contains no Jinja template. \
                    Activating conservative fallback render \
                    (family: \(self.modelFamily ?? "default/ChatML", privacy: .public)).
                    """)

            case .chatTemplate(let templateMsg):
                // FALLBACK ACTIVATED: template present but Jinja execution failed
                HHLog.runtime.warning("""
                    MLX [applyChatTemplate]: upstream threw TokenizerError.chatTemplate \
                    (\(templateMsg, privacy: .public)) \
                    — Jinja template execution error. \
                    Activating conservative fallback render \
                    (family: \(self.modelFamily ?? "default/ChatML", privacy: .public)).
                    """)

            default:
                // Non-template tokenizer errors: propagate normally, do NOT use fallback.
                throw error
            }

            // ⚠️ EXPLICIT LIMITATION: tools and additionalContext require Jinja template
            // execution and are NOT supported in the conservative fallback render path.
            // If provided, they are ignored and a warning is emitted so the caller is aware.
            if tools != nil || additionalContext != nil {
                HHLog.runtime.warning("""
                    MLX [applyChatTemplate fallback]: tools and/or additionalContext were provided \
                    but are NOT supported in the fallback render path — they will be ignored.
                    """)
            }

            let runtimePrompt = reconstructRuntimePrompt(from: stringMessages)
            let rendered = ChatTemplate.render(runtimePrompt, family: modelFamily ?? "")

            // addSpecialTokens: false — safety choice for fallback path:
            //   PRO: Prevents double-BOS tokens. ChatTemplate.render() already 
            //        includes BOS/header tokens for Llama3, Gemma2, and Gemma3. 
            //        Using false ensures AutoTokenizer doesn't prepend a 
            //        second BOS at the byte level.
            return upstream.encode(text: rendered, addSpecialTokens: false)

        } catch {
            throw error
        }
    }

    /// Converts a flat `[[String: String]]` message array into a `RuntimePrompt`
    /// for the conservative fallback renderer.
    ///
    /// **Multiple system messages**: the *first* system message becomes
    /// `RuntimePrompt.systemPrompt`. Each additional system message is kept
    /// in-band as a `.system` role `RuntimeMessage`. Renderer behaviour:
    /// - ChatML / Llama3 / Gemma3 — render them as inline system turns. ✅
    /// - Gemma2 — silently drops inline `.system` turns by design
    ///   (`ChatTemplate.renderGemma2`). A warning is logged here so this is
    ///   explicit rather than truly silent.
    private func reconstructRuntimePrompt(from messages: [[String: String]]) -> RuntimePrompt {
        var systemPrompt = ""
        var runtimeMessages: [RuntimeMessage] = []
        var extraSystemCount = 0

        for msg in messages {
            let role = msg["role"] ?? "user"
            let content = msg["content"] ?? ""

            if role == "system" {
                if systemPrompt.isEmpty {
                    systemPrompt = content
                } else {
                    // Additional system messages: kept in-band as .system turns.
                    extraSystemCount += 1
                    runtimeMessages.append(RuntimeMessage(role: .system, content: content))
                }
            } else {
                let runtimeRole: RuntimeMessage.Role = switch role {
                case "assistant": .assistant
                default:          .user
                }
                runtimeMessages.append(RuntimeMessage(role: runtimeRole, content: content))
            }
        }

        if extraSystemCount > 0 {
            HHLog.runtime.warning("""
                MLX [applyChatTemplate fallback]: \(extraSystemCount, privacy: .public) extra \
                system message(s) found after the first. Rendered inline as .system turns. \
                Gemma2 will silently drop them — this is documented behaviour in \
                ChatTemplate.renderGemma2.
                """)
        }

        return RuntimePrompt(systemPrompt: systemPrompt, messages: runtimeMessages)
    }
}

