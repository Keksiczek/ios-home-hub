import Foundation

/// Strongly-typed deep links for the host app. One enum so:
/// - Spotlight item activation, custom URL schemes, and (later)
///   App Intents all converge on the same router input.
/// - Adding a new destination is a compiler-enforced exhaustive
///   change: the parser, the string-formatter, and `AppState.
///   handle(deepLink:)` all break together.
///
/// Identifier scheme: `homehub.<type>.<UUID>` (a.k.a. the dotted
/// form). It's the persistent identifier we hand Core Spotlight,
/// AND it round-trips through a `homehub://<type>/<UUID>` URL for
/// custom-scheme launches and Shortcuts/AppIntents output.
enum DeepLink: Equatable, Hashable, Sendable {
    case document(UUID)
    case conversation(UUID)
    case memoryFact(UUID)
    /// Opens chat with the given prompt as a fresh draft. Used by
    /// the "Ask Home Hub" App Intent (Epic 1) and by Spotlight
    /// suggested actions.
    case query(String)

    // MARK: - Persistent identifier (Spotlight contract)

    /// String form persisted as `CSSearchableItem.uniqueIdentifier`.
    /// MUST be stable — the next reindex with the same value
    /// updates the existing entry instead of duplicating.
    var persistentIdentifier: String {
        switch self {
        case .document(let id):     return "homehub.document.\(id.uuidString)"
        case .conversation(let id): return "homehub.conversation.\(id.uuidString)"
        case .memoryFact(let id):   return "homehub.memory.\(id.uuidString)"
        case .query(let text):
            // `query` deep links aren't indexed in Spotlight (no
            // persistent identity); the formatter is here only so
            // App Intents output can still emit a single string.
            return "homehub.query.\(text.hashValue)"
        }
    }

    /// Inverse of `persistentIdentifier`. Returns `nil` for unknown
    /// formats — Spotlight occasionally stores legacy identifiers
    /// from previous schema versions.
    init?(persistentIdentifier id: String) {
        let parts = id.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "homehub" else { return nil }
        let payload = String(parts[2])
        switch parts[1] {
        case "document":
            guard let uuid = UUID(uuidString: payload) else { return nil }
            self = .document(uuid)
        case "conversation":
            guard let uuid = UUID(uuidString: payload) else { return nil }
            self = .conversation(uuid)
        case "memory":
            guard let uuid = UUID(uuidString: payload) else { return nil }
            self = .memoryFact(uuid)
        case "query":
            self = .query(payload)
        default:
            return nil
        }
    }

    // MARK: - URL form (custom scheme)

    /// `homehub://<type>/<value>` — the scheme that App Shortcuts
    /// and (eventually) Universal Links route through. Declare
    /// `homehub` as a `CFBundleURLSchemes` entry once we ship the
    /// "open from Shortcut" path; the scheme can be parsed without
    /// the entry being present.
    var url: URL? {
        switch self {
        case .document(let id):
            return URL(string: "homehub://document/\(id.uuidString)")
        case .conversation(let id):
            return URL(string: "homehub://conversation/\(id.uuidString)")
        case .memoryFact(let id):
            return URL(string: "homehub://memory/\(id.uuidString)")
        case .query(let text):
            var c = URLComponents()
            c.scheme = "homehub"
            c.host = "ask"
            c.queryItems = [URLQueryItem(name: "q", value: text)]
            return c.url
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "homehub" else { return nil }
        let host = url.host?.lowercased()
        // `pathComponents` returns `[String]`, and the first entry
        // is "/" for absolute URLs — drop it and pull the first
        // real path segment. No `.map(String.init)` because the
        // element is already a `String` and that triggers an
        // ambiguous-init overload error in Swift 6.
        let pathComponent = url.pathComponents.dropFirst().first
        switch host {
        case "document":
            guard let raw = pathComponent, let uuid = UUID(uuidString: raw) else { return nil }
            self = .document(uuid)
        case "conversation":
            guard let raw = pathComponent, let uuid = UUID(uuidString: raw) else { return nil }
            self = .conversation(uuid)
        case "memory":
            guard let raw = pathComponent, let uuid = UUID(uuidString: raw) else { return nil }
            self = .memoryFact(uuid)
        case "ask":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value
            self = .query(q ?? "")
        default:
            return nil
        }
    }
}
