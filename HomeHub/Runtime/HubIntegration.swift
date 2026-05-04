import Foundation
// Hub and Tokenizers are internal targets of the swift-transformers `Transformers`
// library product.  We depend on product: Transformers in project.yml / Package.swift;
// both modules are compiled into the build graph and importable here.
import Hub
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
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return SwiftTransformersTokenizerBridge(upstream)
    }
}

// MARK: - SwiftTransformersTokenizerBridge

/// Bridges a `Tokenizers.Tokenizer` (from swift-transformers) to
/// `MLXLMCommon.Tokenizer`.
///
/// This is the same bridge that `MLXHuggingFace`'s `#adaptHuggingFaceTokenizer()`
/// macro would generate, written out explicitly so we don't need to add the
/// `MLXHuggingFace` product (which requires bringing in its own macro build target).
private struct SwiftTransformersTokenizerBridge: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        // swift-transformers uses `decode(tokens:)` — note the parameter label difference.
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
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
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
