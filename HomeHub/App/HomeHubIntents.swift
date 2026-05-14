import AppIntents
import Foundation
import SwiftUI

// MARK: - Backend compatibility note
//
// Every intent in this file goes through `ConversationService.sendAndWait`,
// which delegates to whichever runtime is currently active (MLX, llama.cpp,
// mock). The intents themselves never touch a specific backend — adding /
// switching a backend in `RoutingRuntime` is invisible to them. The one
// caveat: an intent can only run when *some* model is loaded; the
// `.modelNotReady` branch handles the "user installed the app but never
// downloaded a model" case.

// MARK: - Helpers

/// Shared bootstrap path for every App Intent that needs the live
/// service graph. iOS may launch the extension process for an
/// intent before the app's own launch path runs, so we have to
/// drive `bootstrap()` manually if the phase is still `.launching`.
@MainActor
private func boostrappedContainer() async -> AppContainer {
    let container = AppContainer.shared
    if container.appState.phase == .launching {
        await container.bootstrap()
    }
    return container
}

// MARK: - Shared runner

/// Result envelope used by every intent helper below. Maps the
/// `sendAndWait` return values into a single `String` that the App
/// Intents framework can return verbatim. Keeps every intent's
/// `perform()` body to two or three lines: build prompt → run → return.
private enum IntentRunResult {
    case reply(String)
    case fail(String)
}

/// Runs `prompt` against an ephemeral conversation and returns the
/// assistant's reply. Backend-agnostic (delegates to the active runtime
/// via `ConversationService`).
///
/// - Parameters:
///   - title: Conversation title — visible only briefly because we
///     delete the conversation on return.
///   - prompt: Final, fully-assembled user message. Callers compose
///     style / system instructions into the prompt body because
///     `sendAndWait` doesn't expose per-call parameter overrides.
///   - emptyReply: Message to return when the model produced nothing
///     (different intents want different wording — "No summary
///     produced." vs "No matches.").
@MainActor
private func runEphemeral(
    title: String,
    prompt: String,
    emptyReply: String = "No reply."
) async -> IntentRunResult {
    let container = await boostrappedContainer()
    let conversations = container.conversationService
    let temp = await conversations.createConversation(title: title)
    defer { Task { await conversations.deleteConversation(temp.id) } }

    switch await conversations.sendAndWait(userInput: prompt, in: temp.id) {
    case .sent: break
    case .emptyInput:
        return .fail("Empty input.")
    case .modelNotReady:
        return .fail("The local model isn't loaded yet. Open Home Hub once and let it warm up.")
    case .blockedSameConversation, .blockedOtherConversation:
        return .fail("Home Hub is busy answering another request. Try again in a moment.")
    }
    let reply = conversations.messages(in: temp.id)
        .last(where: { $0.role == .assistant })?
        .content ?? ""
    return reply.isEmpty ? .fail(emptyReply) : .reply(reply)
}

private extension IntentRunResult {
    var value: String {
        switch self {
        case .reply(let s), .fail(let s): return s
        }
    }
}

// MARK: - Shared response style

/// Coarse style knob exposed by composable intents. Translated into a
/// short instruction prefix at prompt-assembly time because
/// `sendAndWait` doesn't take per-call temperature / max-tokens
/// overrides — the user's chat settings still rule the actual sampler.
/// What we control here is *prompt shape*, which is enough to get the
/// model to be brief or verbose without engine-level changes.
enum ResponseStyleAppEnum: String, AppEnum {
    case concise
    case balanced
    case detailed

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Response Style"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .concise:  "Concise",
        .balanced: "Balanced",
        .detailed: "Detailed"
    ]

    /// Returns a short instruction line to prepend to the user prompt.
    /// Empty string for `.balanced` so the default model behaviour
    /// applies — the user's chat settings already lean balanced.
    var instructionPrefix: String {
        switch self {
        case .concise:  return "Be concise (≤ 3 sentences). No preamble.\n\n"
        case .balanced: return ""
        case .detailed: return "Give a thorough answer with concrete examples. Use short paragraphs.\n\n"
        }
    }
}

// MARK: - Ask Home Hub

/// Sends a single message to the local assistant and returns the
/// reply as text. Ephemeral — the dispatched conversation is
/// deleted on completion so Siri/Shortcuts don't pollute the
/// main chat history.
struct AskHomeHubIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Home Hub"
    static let description = IntentDescription(
        "Ask the on-device assistant a single question. Returns the reply as text.",
        categoryName: "Chat"
    )

    @Parameter(
        title: "Question",
        description: "What to ask the assistant.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var question: String

    @Parameter(
        title: "Style",
        description: "How verbose the reply should be.",
        default: ResponseStyleAppEnum.balanced
    )
    var style: ResponseStyleAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Home Hub: \(\.$question)") {
            \.$style
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let prompt = style.instructionPrefix + question
        return .result(value: await runEphemeral(
            title: "Siri Ask", prompt: prompt
        ).value)
    }
}

// MARK: - Continue last chat

/// Opens the most recent conversation in the chat tab. Routes
/// through the same `DeepLink` machinery Spotlight uses so the
/// behaviour is identical regardless of entry point.
struct ContinueLastChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Last Home Hub Chat"
    static let description = IntentDescription(
        "Open Home Hub on your most recent conversation.",
        categoryName: "Chat"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = await boostrappedContainer()
        if let last = container.conversationService.conversations
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first {
            container.appState.handle(deepLink: .conversation(last.id))
        } else {
            // No conversations exist yet — fall back to the
            // standard "open chat tab" affordance instead of
            // failing the intent.
            container.appState.selectedTab = .chat
        }
        return .result()
    }
}

// MARK: - Summarize text

/// Asks the on-device model to produce a short summary of the
/// supplied text. Uses an ephemeral conversation; the system
/// prompt nudges the model into "concise summary" mode.
struct SummarizeTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize with Home Hub"
    static let description = IntentDescription(
        "Produce a short summary of the given text using the local model.",
        categoryName: "Productivity"
    )

    @Parameter(
        title: "Text",
        description: "The text to summarise.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var text: String

    @Parameter(
        title: "Bullet points",
        description: "If on, ask the model for a bulleted summary.",
        default: false
    )
    var bulletPoints: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Summarise \(\.$text) with Home Hub") {
            \.$bulletPoints
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let style = bulletPoints
            ? "Reply with a concise bulleted summary (≤ 5 bullets). No preamble."
            : "Reply with a concise paragraph summary (≤ 4 sentences). No preamble."
        let prompt = """
        \(style)

        TEXT:
        \(text)
        """
        return .result(value: await runEphemeral(
            title: "Siri Summarise",
            prompt: prompt,
            emptyReply: "No summary produced."
        ).value)
    }
}

// MARK: - Save to memory

/// Adds a user-authored fact to long-term memory. Bypasses the
/// extraction pipeline (no LLM round-trip) — this is for the user
/// explicitly telling the assistant "remember this".
struct SaveToMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Save to Home Hub Memory"
    static let description = IntentDescription(
        "Save a fact to Home Hub's long-term memory.",
        categoryName: "Memory"
    )

    @Parameter(
        title: "Fact",
        description: "A piece of information to remember.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var fact: String

    @Parameter(
        title: "Category",
        description: "Memory category.",
        default: MemoryCategoryAppEnum.other
    )
    var category: MemoryCategoryAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Remember \(\.$fact) as \(\.$category)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(value: "Empty fact.") }

        let container = await boostrappedContainer()
        let model = MemoryFact(
            id: UUID(),
            content: trimmed,
            category: category.toCategory(),
            source: .userManual,
            confidence: 1.0,
            createdAt: .now,
            lastUsedAt: nil,
            pinned: false,
            disabled: false,
            sourceConversationID: nil,
            sourceMessageID: nil,
            extractionMethod: nil
        )
        await container.memoryService.add(model)
        return .result(value: "Saved.")
    }
}

/// App-Intents-friendly mirror of `MemoryFact.Category`.
/// `AppEnum` requires a separate type so the framework can
/// generate localisation tables and the iOS picker UI.
enum MemoryCategoryAppEnum: String, AppEnum {
    case personal
    case work
    case preferences
    case relationships
    case projects
    case other

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Memory Category"
    // `let` (not `var`) so Swift 6 strict concurrency accepts it as
    // a non-mutable global. The `AppEnum` protocol declares this
    // requirement as a `var` for historical reasons; conforming
    // with `let` is allowed and concurrency-safe.
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .personal:      "Personal",
        .work:          "Work",
        .preferences:   "Preferences",
        .relationships: "Relationships",
        .projects:      "Projects",
        .other:         "Other"
    ]

    func toCategory() -> MemoryFact.Category {
        switch self {
        case .personal:      return .personal
        case .work:          return .work
        case .preferences:   return .preferences
        case .relationships: return .relationships
        case .projects:      return .projects
        case .other:         return .other
        }
    }
}

// MARK: - Query workspace (full Knowledge Base RAG retrieval)

/// Runs a Knowledge Base retrieval over the user's full corpus and
/// returns the top hits as a single string. Useful for "find that
/// thing I imported" without going through chat.
struct QueryWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Home Hub Knowledge Base"
    static let description = IntentDescription(
        "Search across all imported documents and return the top matching passages.",
        categoryName: "Knowledge Base"
    )

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Maximum results", default: 5)
    var maxResults: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search Home Hub for \(\.$query)") {
            \.$maxResults
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let container = await boostrappedContainer()
        guard let retrieval = container.knowledgeBaseService.retrievalAPI else {
            return .result(value: "Knowledge Base unavailable.")
        }
        let q = RetrievalQuery(
            queryText: query,
            workspaceID: nil,
            documentIDs: nil,
            maxChunks: max(1, min(maxResults, 20)),
            minRelevance: 0.2
        )
        let hits = (try? await retrieval.retrieve(for: q)) ?? []
        guard !hits.isEmpty else {
            return .result(value: "No matches.")
        }
        let formatted = hits.enumerated().map { i, hit in
            let page = hit.chunk.pageNumber.map { " · p. \($0)" } ?? ""
            return "[\(i + 1)] \(hit.document.title)\(page)\n\(hit.chunk.text.prefix(280))…"
        }.joined(separator: "\n\n")
        return .result(value: formatted)
    }
}

// MARK: - Document AppEntity

/// Exposes ingested documents as picker-friendly entities so the
/// "Ask over imported document" intent can render a Shortcuts
/// picker with recent docs by title.
struct HomeHubDocumentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Home Hub Document"

    let id: UUID
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title))
    }

    static let defaultQuery = HomeHubDocumentQuery()
}

struct HomeHubDocumentQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [HomeHubDocumentEntity.ID]) async throws -> [HomeHubDocumentEntity] {
        let container = await boostrappedContainer()
        return container.knowledgeBaseService.documents
            .filter { identifiers.contains($0.id) }
            .map { HomeHubDocumentEntity(id: $0.id, title: $0.title) }
    }

    @MainActor
    func suggestedEntities() async throws -> [HomeHubDocumentEntity] {
        let container = await boostrappedContainer()
        // Most-recent-first, capped — Shortcuts pickers don't need
        // every doc the user ever imported, just the convenient set.
        return container.knowledgeBaseService.documents
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(20)
            .map { HomeHubDocumentEntity(id: $0.id, title: $0.title) }
    }
}

/// Restricts the Knowledge Base RAG to a specific document and
/// asks the model for an answer grounded in its chunks.
struct AskOverImportedDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Home Hub About a Document"
    static let description = IntentDescription(
        "Ask a question scoped to a single imported document.",
        categoryName: "Knowledge Base"
    )

    @Parameter(title: "Document")
    var document: HomeHubDocumentEntity

    @Parameter(
        title: "Question",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Home Hub about \(\.$document): \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let container = await boostrappedContainer()
        guard let retrieval = container.knowledgeBaseService.retrievalAPI else {
            return .result(value: "Knowledge Base unavailable.")
        }

        // 1. Retrieve top chunks scoped to the chosen document.
        let q = RetrievalQuery(
            queryText: question,
            workspaceID: nil,
            documentIDs: [document.id],
            maxChunks: 6,
            minRelevance: 0.2
        )
        let hits = (try? await retrieval.retrieve(for: q)) ?? []
        let context = hits
            .map { "PAGE \($0.chunk.pageNumber.map(String.init) ?? "?"): \($0.chunk.text)" }
            .joined(separator: "\n\n")

        // 2. Compose a grounded prompt and run it through the
        // standard chat pipeline. Document title is interpolated
        // into the user prompt so the model can echo a citation
        // even without retrieved chunks (cold-cache fallback).
        let prompt: String
        if context.isEmpty {
            prompt = "I imported a document called \"\(document.title)\". Question: \(question)"
        } else {
            prompt = """
            Use ONLY the passages below from "\(document.title)" to answer.
            If the answer isn't in them, reply with "Not in this document.".

            \(context)

            Question: \(question)
            """
        }

        let conversations = container.conversationService
        let temp = await conversations.createConversation(title: "Siri Ask Doc")
        defer { Task { await conversations.deleteConversation(temp.id) } }

        switch await conversations.sendAndWait(userInput: prompt, in: temp.id) {
        case .sent: break
        case .emptyInput:
            return .result(value: "Empty question.")
        case .modelNotReady:
            return .result(value: "Local model isn't loaded yet.")
        case .blockedSameConversation, .blockedOtherConversation:
            return .result(value: "Home Hub is busy. Try again in a moment.")
        }
        let reply = conversations.messages(in: temp.id)
            .last(where: { $0.role == .assistant })?
            .content ?? ""
        return .result(value: reply.isEmpty ? "No reply." : reply)
    }
}

// MARK: - Extract structured data

/// Asks the model to extract a fixed set of fields from arbitrary text
/// and return them as JSON. Useful for "share this email to Home Hub →
/// pull out the meeting time / location / participants" workflows.
///
/// Backend-agnostic: runs through `ConversationService` like every other
/// intent. The reply is whatever the model produced — we ask for JSON in
/// the prompt and trim Markdown code fences if the model wrapped its
/// output, but we don't strictly validate / re-parse it here. The
/// caller (Shortcuts) decides whether to feed it to a JSON action.
struct ExtractStructuredDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Structured Data"
    static let description = IntentDescription(
        "Extract a set of fields (comma-separated) from text and return JSON.",
        categoryName: "Productivity"
    )

    @Parameter(
        title: "Text",
        description: "The text to extract from.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var text: String

    @Parameter(
        title: "Fields",
        description: "Comma-separated field names, e.g. \"name, email, phone\".",
        default: "name, email, phone"
    )
    var fields: String

    static var parameterSummary: some ParameterSummary {
        Summary("Extract \(\.$fields) from \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let cleanFields = fields
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleanFields.isEmpty else { return .result(value: "{}") }

        // The prompt is intentionally rigid: it pins the output to a
        // single JSON object, names every key, and tells the model to
        // emit `null` for unknown values. Without the "null" rule the
        // model tends to invent plausible-looking placeholders.
        let keysList = cleanFields.map { "\"\($0)\"" }.joined(separator: ", ")
        let prompt = """
        Extract the following fields from the text below. Reply with a single \
        JSON object whose keys are exactly: \(keysList). Use null for any field \
        you cannot find. No prose, no Markdown fences — JSON only.

        TEXT:
        \(text)
        """

        let raw = (await runEphemeral(
            title: "Siri Extract",
            prompt: prompt,
            emptyReply: "{}"
        )).value
        // Strip ``` and ```json fences that some models add despite
        // being told not to. We don't validate the JSON itself —
        // downstream Shortcuts actions decide what to do with garbage.
        return .result(value: stripCodeFences(raw))
    }
}

/// Drops a leading ``` / ```json fence and a trailing ``` if present.
/// Idempotent on already-clean strings. Defensive against models that
/// inject Markdown despite "JSON only" prompts.
private func stripCodeFences(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("```json") { t.removeFirst("```json".count) }
    else if t.hasPrefix("```") { t.removeFirst("```".count) }
    if t.hasSuffix("```") { t.removeLast("```".count) }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Explain code

/// Specialised prompt for "explain what this code does" workflows.
/// Composable with Shortcuts that copy a selection to the clipboard and
/// pipe it here. Backend-agnostic.
struct ExplainCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Explain Code Snippet"
    static let description = IntentDescription(
        "Explain a code snippet step-by-step. Optionally hint at the language.",
        categoryName: "Productivity"
    )

    @Parameter(
        title: "Code",
        description: "The snippet to explain.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var code: String

    @Parameter(
        title: "Language",
        description: "Optional language hint (e.g. Swift, Python). Leave blank to auto-detect.",
        default: ""
    )
    var language: String

    @Parameter(
        title: "Style",
        default: ResponseStyleAppEnum.balanced
    )
    var style: ResponseStyleAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Explain \(\.$code)") {
            \.$language
            \.$style
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let langHint = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = langHint.isEmpty
            ? "Explain the following code. Identify the language first, then walk through what it does."
            : "Explain the following \(langHint) code step by step."
        let prompt = """
        \(style.instructionPrefix)\(header)

        CODE:
        ```
        \(code)
        ```
        """
        return .result(value: await runEphemeral(
            title: "Siri Explain Code",
            prompt: prompt,
            emptyReply: "No explanation produced."
        ).value)
    }
}

// MARK: - Legacy AskAssistantIntent (Czech)

/// Older Czech-titled intent. Kept for backwards compatibility so
/// users who already wired Shortcuts or Siri phrases against the
/// previous title don't lose them. Functionally equivalent to
/// `AskHomeHubIntent`; new builds prefer the English-titled one.
struct AskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Zeptat se asistenta"
    static let description = IntentDescription("Položí otázku lokálnímu LLM asistentovi a vrátí odpověď.")

    @Parameter(title: "Zpráva", description: "Zpráva nebo úkol pro asistenta")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let container = await boostrappedContainer()
        let conversationService = container.conversationService
        let tempConversation = await conversationService.createConversation(title: "Siri Dotaz")
        defer {
            Task { await conversationService.deleteConversation(tempConversation.id) }
        }
        let result = await conversationService.sendAndWait(userInput: message, in: tempConversation.id)
        switch result {
        case .sent: break
        case .emptyInput:
            return .result(value: "Zpráva je prázdná.")
        case .modelNotReady:
            return .result(value: "Lokální model ještě není načten. Otevři aplikaci a počkej, až bude připraven.")
        case .blockedSameConversation, .blockedOtherConversation:
            return .result(value: "Asistent zrovna odpovídá na předchozí dotaz. Zkus to prosím za chvíli.")
        }
        let messages = conversationService.messages(in: tempConversation.id)
        guard let last = messages.last(where: { $0.role == .assistant }),
              !last.content.isEmpty else {
            return .result(value: "Promiň, asistent nedokázal vygenerovat odpověď.")
        }
        return .result(value: last.content)
    }
}
