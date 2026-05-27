import SwiftUI

/// Per-tool icon + label mapping used by both the inline "Calling …"
/// chip on the streaming assistant bubble and the post-run
/// `ToolResultChip`.
///
/// Centralised here so the visual identity of a tool stays consistent
/// across the chat — the same magnifying glass that previewed
/// "🔍 Hledám…" should reappear on the result card. Without this both
/// surfaces would drift their icon choices independently.
///
/// The lookup is case-insensitive on the tool name because:
///   * `ToolCallEnvelope.parse` may surface either canonical
///     (`WebSearch`) or model-emitted (`websearch`, `web_search`)
///     forms depending on how the agentic loop normalised it.
///   * Persisted messages from earlier app versions can carry an
///     all-lowercase tool name in the saved envelope.
///
/// Unknown tools fall back to a generic wrench so a future skill
/// added without a presentation entry still renders something
/// sensible.
enum ToolPresenter {

    /// What to render for a tool. Three fields:
    ///   * `systemImage`: SF Symbol name. Picked for instant readability
    ///     at chip size (≤ 14 pt); avoid icons whose meaning needs
    ///     surrounding context.
    ///   * `runningLabel`: imperative present continuous, shown while
    ///     the model is mid-call.
    ///   * `completedLabel`: past-tense, shown on the persisted bubble
    ///     after the turn finished so an exported transcript still
    ///     reads naturally.
    struct Style: Sendable {
        let systemImage: String
        let runningLabel: String
        let completedLabel: String
        /// Optional multi-stage cycle for tools whose work happens in
        /// distinguishable phases (e.g. WebSearch: fetch SERP → read
        /// pages → summarise). When non-nil, `MessageBubbleView`
        /// rotates through these strings every ~1.6 s while
        /// `status == .streaming`, then falls back to
        /// `completedLabel` once the turn lands.
        ///
        /// This is purely UX cosmetic — the tool isn't required to
        /// report progress; the cycle just gives the user a sense of
        /// active work for long-running tools (3–8 s on a public
        /// SearXNG instance) where a static "Hledám na webu…" would
        /// otherwise read as stuck. Phases are localised Czech to
        /// match the rest of the chat surface.
        ///
        /// `nil` for tools where a single-stage label is honest
        /// (Calculator finishes in tens of ms; phases would feel
        /// fake).
        let streamingPhases: [String]?
    }

    static func style(for toolName: String) -> Style {
        switch normalised(toolName) {
        case "websearch", "web_search":
            return Style(
                systemImage: "magnifyingglass",
                runningLabel: "Hledám na webu…",
                completedLabel: "Web search",
                streamingPhases: [
                    "Hledám na webu…",
                    "Čtu výsledky…",
                    "Shrnuju…"
                ]
            )
        case "fetchpage", "fetch_page":
            return Style(
                systemImage: "doc.text.viewfinder",
                runningLabel: "Načítám stránku…",
                completedLabel: "Načtená stránka",
                streamingPhases: [
                    "Stahuju HTML…",
                    "Čistím obsah…",
                    "Extrahuju text…"
                ]
            )
        case "calculator":
            return Style(
                systemImage: "function",
                runningLabel: "Počítám…",
                completedLabel: "Výpočet",
                streamingPhases: nil
            )
        case "calendar":
            return Style(
                systemImage: "calendar",
                runningLabel: "Čtu kalendář…",
                completedLabel: "Kalendář",
                streamingPhases: nil
            )
        case "reminders":
            return Style(
                systemImage: "checklist",
                runningLabel: "Čtu připomínky…",
                completedLabel: "Připomínky",
                streamingPhases: nil
            )
        case "homekit":
            return Style(
                systemImage: "house.fill",
                runningLabel: "Ovládám zařízení…",
                completedLabel: "HomeKit",
                streamingPhases: nil
            )
        case "deviceinfo", "device_info":
            return Style(
                systemImage: "iphone",
                runningLabel: "Čtu stav zařízení…",
                completedLabel: "Stav zařízení",
                streamingPhases: nil
            )
        default:
            return Style(
                systemImage: "wrench.and.screwdriver.fill",
                runningLabel: "Volá \(toolName)…",
                completedLabel: toolName,
                streamingPhases: nil
            )
        }
    }

    /// Lower-case + strip non-alphanumeric so `WebSearch`, `websearch`,
    /// and `web_search` all map to the same lookup key.
    private static func normalised(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
