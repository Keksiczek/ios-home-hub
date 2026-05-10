import Foundation

/// JSON-on-disk implementation of `Store`.
///
/// v1 Simplification: each entity collection is one JSON file under
/// `~/Library/Application Support/HomeHub/`. Atomic writes, ISO-8601
/// dates. Migration to SwiftData / GRDB is a future task once entity
/// volume justifies it (likely once the user has thousands of
/// messages or memory grows beyond a few hundred facts).
actor FileStore: Store {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let fileManager = FileManager.default
        // `URL.applicationSupportDirectory` is non-failable on iOS 16+ and
        // returns the sandboxed Application Support path. We intentionally
        // do NOT consult `forUbiquityContainerIdentifier:` — the app ships
        // without an iCloud entitlement (private, offline-first by design),
        // so that call would always return nil and the dead branch was
        // pure noise. If iCloud sync is ever added, gate the bridge on the
        // entitlement and put it behind a feature flag like HOMEHUB_SWIFTDATA.
        self.rootURL = URL.applicationSupportDirectory
            .appendingPathComponent("HomeHub", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private func read<T: Decodable>(_ type: T.Type, from file: String) throws -> T? {
        let url = rootURL.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to file: String) throws {
        let url = rootURL.appendingPathComponent(file)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func remove(_ file: String) throws {
        let url = rootURL.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Profiles

    func loadUserProfile() async throws -> UserProfile? {
        try read(UserProfile.self, from: "user.json")
    }

    func save(userProfile: UserProfile) async throws {
        try write(userProfile, to: "user.json")
    }

    func loadAssistantProfile() async throws -> AssistantProfile? {
        try read(AssistantProfile.self, from: "assistant.json")
    }

    func save(assistant: AssistantProfile) async throws {
        try write(assistant, to: "assistant.json")
    }

    // MARK: - Conversations + messages

    func loadConversations() async throws -> [Conversation] {
        (try read([Conversation].self, from: "conversations.json")) ?? []
    }

    func save(conversation: Conversation) async throws {
        var all = (try read([Conversation].self, from: "conversations.json")) ?? []
        if let idx = all.firstIndex(where: { $0.id == conversation.id }) {
            all[idx] = conversation
        } else {
            all.insert(conversation, at: 0)
        }
        try write(all, to: "conversations.json")
    }

    func delete(conversationID: UUID) async throws {
        var all = (try read([Conversation].self, from: "conversations.json")) ?? []
        all.removeAll { $0.id == conversationID }
        try write(all, to: "conversations.json")
        // Drop both the new JSONL log AND any leftover legacy JSON
        // array — a conversation deleted before migration ran would
        // otherwise leave the old file behind.
        try remove(messagesFileName(conversationID: conversationID))
        try remove(legacyMessagesFileName(conversationID: conversationID))
        knownMessageIDs.removeValue(forKey: conversationID)
    }

    // ─── Messages — append-only JSONL ────────────────────────────
    //
    // Up through v1, every conversation kept its messages in
    // `messages-<convID>.json` as a JSON array. Every `save(message:)`
    // had to re-serialise and atomically rewrite the whole array,
    // which is O(n) on conversation length. For a 200-turn
    // conversation that meant the ~final 200 saves each rewrote
    // 200 messages. JSONL keeps the same on-disk schema per record
    // but lets us *append* one line for a new message — O(1) — and
    // only rewrite the file when the message already exists (edit
    // / regenerate / cancel). The in-memory `knownMessageIDs` cache
    // is what tells us which path to take without a full re-parse.
    //
    // Legacy `.json` files are migrated on first read of the
    // conversation: load the array, write JSONL, drop the old file.
    // Migration is one-shot per conversation; subsequent calls hit
    // the JSONL path directly.

    private func messagesFileName(conversationID: UUID) -> String {
        "messages-\(conversationID.uuidString).jsonl"
    }
    private func legacyMessagesFileName(conversationID: UUID) -> String {
        "messages-\(conversationID.uuidString).json"
    }

    /// `convID → set of known message IDs`, populated lazily on
    /// first read/save per conversation. Lets `save(message:)`
    /// decide append vs rewrite without parsing the whole JSONL.
    /// Cache survives across calls because `FileStore` is an actor
    /// living for the app's lifetime.
    private var knownMessageIDs: [UUID: Set<UUID>] = [:]

    func loadMessages(conversationID: UUID) async throws -> [Message] {
        let messages = try loadOrMigrateMessages(conversationID: conversationID)
        knownMessageIDs[conversationID] = Set(messages.map(\.id))
        return messages
    }

    func save(message: Message) async throws {
        let convID = message.conversationID
        // Ensure cache is primed. First save on a freshly-seen
        // conversation pays the full read cost once; subsequent
        // saves use the in-memory ID set.
        if knownMessageIDs[convID] == nil {
            let messages = try loadOrMigrateMessages(conversationID: convID)
            knownMessageIDs[convID] = Set(messages.map(\.id))
        }
        if knownMessageIDs[convID]?.contains(message.id) == true {
            // Edit / regenerate / cancel — the message already
            // exists. Rewrite the whole JSONL file with the
            // updated record. Same O(n) cost as the legacy path,
            // but only on the rare edit path.
            var all = (try? readJSONL(Message.self, from: messagesFileName(conversationID: convID))) ?? []
            if let idx = all.firstIndex(where: { $0.id == message.id }) {
                all[idx] = message
                try writeJSONL(all, to: messagesFileName(conversationID: convID))
            } else {
                // Cache lied — fall through to append + reconcile.
                try appendJSONL(message, to: messagesFileName(conversationID: convID))
                knownMessageIDs[convID]?.insert(message.id)
            }
        } else {
            // Append — the streaming case. O(1).
            try appendJSONL(message, to: messagesFileName(conversationID: convID))
            knownMessageIDs[convID]?.insert(message.id)
        }
    }

    func deleteMessage(id: UUID, conversationID: UUID) async throws {
        var all = (try? readJSONL(Message.self, from: messagesFileName(conversationID: conversationID))) ?? []
        // Fall back to legacy file if JSONL doesn't exist yet.
        if all.isEmpty {
            all = try loadOrMigrateMessages(conversationID: conversationID)
        }
        let before = all.count
        all.removeAll { $0.id == id }
        guard all.count != before else { return }
        try writeJSONL(all, to: messagesFileName(conversationID: conversationID))
        knownMessageIDs[conversationID]?.remove(id)
    }

    func clearMessages(conversationID: UUID) async throws {
        try remove(messagesFileName(conversationID: conversationID))
        try remove(legacyMessagesFileName(conversationID: conversationID))
        knownMessageIDs[conversationID] = []
    }

    /// Reads the JSONL file. Empty file → empty array. Malformed
    /// individual lines are dropped with a logged warning rather
    /// than aborting the whole load — losing one corrupt message
    /// beats blocking the user from their entire conversation.
    private func loadOrMigrateMessages(conversationID: UUID) throws -> [Message] {
        let jsonlURL = rootURL.appendingPathComponent(messagesFileName(conversationID: conversationID))
        let legacyURL = rootURL.appendingPathComponent(legacyMessagesFileName(conversationID: conversationID))
        let fm = FileManager.default

        if fm.fileExists(atPath: jsonlURL.path) {
            return try readJSONL(Message.self, from: messagesFileName(conversationID: conversationID))
        }

        if fm.fileExists(atPath: legacyURL.path) {
            // One-shot migration. Read array → write JSONL →
            // remove old file. If the write fails we leave the
            // legacy file alone so the next attempt can retry.
            let messages = (try? read([Message].self, from: legacyMessagesFileName(conversationID: conversationID))) ?? []
            try writeJSONL(messages, to: messagesFileName(conversationID: conversationID))
            try? fm.removeItem(at: legacyURL)
            return messages
        }
        return []
    }

    private func readJSONL<T: Decodable>(_ type: T.Type, from file: String) throws -> [T] {
        let url = rootURL.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        var out: [T] = []
        var lineStart = data.startIndex
        for i in data.indices {
            if data[i] == 0x0A { // '\n'
                let line = data.subdata(in: lineStart..<i)
                if !line.isEmpty {
                    if let value = try? decoder.decode(T.self, from: line) {
                        out.append(value)
                    }
                }
                lineStart = data.index(after: i)
            }
        }
        // Trailing line without newline (writer always emits a
        // trailing '\n', but be defensive against truncated files).
        if lineStart < data.endIndex {
            let line = data.subdata(in: lineStart..<data.endIndex)
            if let value = try? decoder.decode(T.self, from: line) {
                out.append(value)
            }
        }
        return out
    }

    private func writeJSONL<T: Encodable>(_ values: [T], to file: String) throws {
        let url = rootURL.appendingPathComponent(file)
        var data = Data()
        for value in values {
            let line = try jsonlLineEncoder.encode(value)
            data.append(line)
            data.append(0x0A) // '\n'
        }
        try data.write(to: url, options: .atomic)
    }

    private func appendJSONL<T: Encodable>(_ value: T, to file: String) throws {
        let url = rootURL.appendingPathComponent(file)
        let fm = FileManager.default
        let line = try jsonlLineEncoder.encode(value) + Data([0x0A])
        if fm.fileExists(atPath: url.path) {
            // Append-mode FileHandle gets us O(1) without rewriting
            // the file. Atomic against single-process callers
            // because FileStore is an actor; cross-process appends
            // aren't a concern here (chat history isn't shared with
            // the Share Extension).
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    /// Compact encoder for a single JSONL record — `.sortedKeys` and
    /// `.prettyPrinted` would inflate every line and break the
    /// "one record per line" invariant. The class-level `encoder`
    /// is pretty-printed for human-readable single-array files;
    /// we keep that for those, and use this for JSONL.
    private var jsonlLineEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys] // no .prettyPrinted
        return e
    }

    // MARK: - Memory

    func loadMemoryFacts() async throws -> [MemoryFact] {
        (try read([MemoryFact].self, from: "memory.json")) ?? []
    }

    func save(fact: MemoryFact) async throws {
        var all = (try read([MemoryFact].self, from: "memory.json")) ?? []
        if let idx = all.firstIndex(where: { $0.id == fact.id }) {
            all[idx] = fact
        } else {
            all.append(fact)
        }
        try write(all, to: "memory.json")
    }

    func deleteMemoryFact(id: UUID) async throws {
        var all = (try read([MemoryFact].self, from: "memory.json")) ?? []
        all.removeAll { $0.id == id }
        try write(all, to: "memory.json")
    }

    // MARK: - Episodes

    func loadMemoryEpisodes() async throws -> [MemoryEpisode] {
        (try read([MemoryEpisode].self, from: "episodes.json")) ?? []
    }

    func save(episode: MemoryEpisode) async throws {
        var all = (try read([MemoryEpisode].self, from: "episodes.json")) ?? []
        if let idx = all.firstIndex(where: { $0.id == episode.id }) {
            all[idx] = episode
        } else {
            all.append(episode)
        }
        try write(all, to: "episodes.json")
    }

    func deleteMemoryEpisode(id: UUID) async throws {
        var all = (try read([MemoryEpisode].self, from: "episodes.json")) ?? []
        all.removeAll { $0.id == id }
        try write(all, to: "episodes.json")
    }

    // MARK: - Settings + onboarding

    func loadAppSettings() async throws -> AppSettings? {
        try read(AppSettings.self, from: "settings.json")
    }

    func save(settings: AppSettings) async throws {
        try write(settings, to: "settings.json")
    }

    func loadOnboardingState() async throws -> OnboardingState? {
        try read(OnboardingState.self, from: "onboarding.json")
    }

    func save(onboardingState: OnboardingState) async throws {
        try write(onboardingState, to: "onboarding.json")
    }
}
