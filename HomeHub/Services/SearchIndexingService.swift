import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Wraps `CSSearchableIndex.default()` for the host app. Every
/// piece of user-facing content that should be discoverable via
/// system Spotlight (workspace search, system search, lock-screen
/// search) lands in this service.
///
/// ## Domains
/// One Spotlight domain per record type. `domainIdentifier` lets us
/// wholesale `deleteSearchableItems(withDomainIdentifiers:)` when
/// we need to rebuild a category from scratch — e.g. on schema
/// version bump or "wipe Knowledge Base" debug action — without
/// touching the others.
///
/// - `homehub.documents`     — `DocumentRecord`
/// - `homehub.conversations` — `Conversation`
/// - `homehub.memory`        — `MemoryFact`
///
/// ## Identifier convention
/// `CSSearchableItem.uniqueIdentifier` == `DeepLink.persistent
/// Identifier` (e.g. `homehub.document.<UUID>`). When iOS hands
/// the activity back via `NSUserActivity`, that identifier is
/// what we parse straight back into a `DeepLink` to route.
///
/// ## Concurrency
/// `actor` so concurrent callers (e.g. KB refresh + chat save
/// happening at the same time) don't trample each other's index
/// batches. `CSSearchableIndex` itself is documented thread-safe,
/// but the actor also serialises *which* batch the user sees
/// first, which matters when one path is incremental and another
/// is wholesale.
///
/// ## Rate limit & change detection
/// All indexing methods are best-effort — failures are logged,
/// not surfaced to the user. The expensive operation isn't
/// indexing itself but *building* the searchable items, so
/// callers SHOULD pre-filter to only changed records before
/// invoking these. `KnowledgeBaseService.refresh()` is the
/// canonical example of pre-filtering.
actor SearchIndexingService {

    // MARK: - Domains

    private enum Domain {
        static let documents     = "homehub.documents"
        static let conversations = "homehub.conversations"
        static let memory        = "homehub.memory"
    }

    private let index: CSSearchableIndex

    /// One-shot bootstrap flag: a fresh install (or a wipe-then-
    /// reinstall) should do a full reindex, but launches after
    /// the first should rely on incremental updates from the
    /// service hooks. Persisted in `UserDefaults` because the
    /// flag itself is a couple of bytes and outliving the actor
    /// is exactly the lifecycle we want.
    private static let bootstrapKey = "homehub.spotlight.bootstrapDoneV1"

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    // MARK: - Documents

    func index(documents: [DocumentRecord]) async {
        let items = documents.map(makeItem(for:))
        await put(items)
    }

    func remove(documentIDs: [UUID]) async {
        let identifiers = documentIDs.map { DeepLink.document($0).persistentIdentifier }
        await delete(identifiers: identifiers)
    }

    private func makeItem(for doc: DocumentRecord) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: contentType(for: doc.mimeType))
        attrs.title = doc.title
        attrs.contentDescription = "\(doc.chunkCount) chunků · \(doc.mimeType)"
        attrs.contentCreationDate = doc.createdAt
        attrs.contentModificationDate = doc.lastIndexedAt ?? doc.createdAt
        attrs.identifier = doc.id.uuidString
        if let workspace = doc.workspaceID {
            attrs.namedLocation = workspace
        }
        // `keywords` lets Spotlight match on synonyms even when the
        // title doesn't contain the query. Filename + MIME type
        // gives a useful surface for "find that PDF I shared".
        attrs.keywords = [doc.title, doc.mimeType]
        return CSSearchableItem(
            uniqueIdentifier: DeepLink.document(doc.id).persistentIdentifier,
            domainIdentifier: Domain.documents,
            attributeSet: attrs
        )
    }

    private func contentType(for mime: String) -> UTType {
        if mime == "application/pdf" { return .pdf }
        if mime.hasPrefix("text/") { return .plainText }
        return .data
    }

    // MARK: - Conversations

    /// Conversations are indexed by their *display* title only —
    /// indexing every message body would explode the index size
    /// and conflict with the user's memory/privacy expectations
    /// ("my chat about my therapist appears in Spotlight").
    /// The chunk-level RAG index already covers content search
    /// inside Knowledge Base.
    func index(conversations: [Conversation]) async {
        let items = conversations.map(makeItem(for:))
        await put(items)
    }

    func remove(conversationIDs: [UUID]) async {
        let identifiers = conversationIDs.map { DeepLink.conversation($0).persistentIdentifier }
        await delete(identifiers: identifiers)
    }

    private func makeItem(for conv: Conversation) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = conv.title.isEmpty ? "Untitled chat" : conv.title
        attrs.contentDescription = nil
        attrs.contentCreationDate = conv.createdAt
        attrs.contentModificationDate = conv.updatedAt
        attrs.identifier = conv.id.uuidString
        attrs.keywords = ["chat", "homehub"]
        return CSSearchableItem(
            uniqueIdentifier: DeepLink.conversation(conv.id).persistentIdentifier,
            domainIdentifier: Domain.conversations,
            attributeSet: attrs
        )
    }

    // MARK: - Memory facts

    func index(memoryFacts: [MemoryFact]) async {
        let items = memoryFacts
            // Disabled facts are explicitly muted by the user;
            // exposing them via Spotlight would surprise them.
            .filter { !$0.disabled }
            .map(makeItem(for:))
        await put(items)
    }

    func remove(memoryFactIDs: [UUID]) async {
        let identifiers = memoryFactIDs.map { DeepLink.memoryFact($0).persistentIdentifier }
        await delete(identifiers: identifiers)
    }

    private func makeItem(for fact: MemoryFact) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = fact.content
        attrs.contentDescription = fact.category.label
        attrs.contentCreationDate = fact.createdAt
        attrs.contentModificationDate = fact.lastUsedAt ?? fact.createdAt
        attrs.identifier = fact.id.uuidString
        attrs.keywords = [fact.category.rawValue, "memory"]
        return CSSearchableItem(
            uniqueIdentifier: DeepLink.memoryFact(fact.id).persistentIdentifier,
            domainIdentifier: Domain.memory,
            attributeSet: attrs
        )
    }

    // MARK: - Bulk operations

    /// Drops every record this app has indexed. Used by the
    /// debug "Reindex" action and by privacy-sensitive flows
    /// (sign-out / wipe).
    func wipeAll() async {
        await deleteAllInDomains([Domain.documents, Domain.conversations, Domain.memory])
        UserDefaults.standard.removeObject(forKey: Self.bootstrapKey)
    }

    /// First-launch bootstrap path. Indexes everything wholesale
    /// once per install/version bump. The flag prevents repeated
    /// full-corpus indexing on every cold launch, which would be
    /// wasteful given the incremental hooks elsewhere already
    /// keep the index in sync.
    func bootstrap(
        documents: [DocumentRecord],
        conversations: [Conversation],
        memoryFacts: [MemoryFact]
    ) async {
        let done = UserDefaults.standard.bool(forKey: Self.bootstrapKey)
        guard !done else { return }
        await index(documents: documents)
        await index(conversations: conversations)
        await index(memoryFacts: memoryFacts)
        UserDefaults.standard.set(true, forKey: Self.bootstrapKey)
    }

    // MARK: - Private IO

    private func put(_ items: [CSSearchableItem]) async {
        guard !items.isEmpty else { return }
        do {
            try await index.indexSearchableItems(items)
        } catch {
            HHLog.ui.error(
                "spotlight: indexSearchableItems failed (\(items.count, privacy: .public) items): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func delete(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        do {
            try await index.deleteSearchableItems(withIdentifiers: identifiers)
        } catch {
            HHLog.ui.error(
                "spotlight: deleteSearchableItems failed (\(identifiers.count, privacy: .public) ids): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func deleteAllInDomains(_ domains: [String]) async {
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: domains)
        } catch {
            HHLog.ui.error("spotlight: deleteAll failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
