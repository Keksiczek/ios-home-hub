import Foundation

/// Builds the *context rail* injected at the top of every chat prompt.
///
/// The rail is the one place that:
///   * pins the current date/time (so the model can't hallucinate a stale
///     year),
///   * pins the user location hint (Nymburk, CZ by default),
///   * enforces the output language (CZ / EN / auto → resolved),
///   * forbids the model from doing arithmetic "in its head" — math must
///     be routed through the `Calculator` / `math.eval` skill,
///   * constrains web lookups to the registered `WebSearch` tool,
///   * selects between Lean/CI and casual response style.
///
/// Kept as a pure value type with static builders so the assembly service
/// can compose rails without taking an ownership dependency, and unit
/// tests can verify the exact rendered string for a given `AppSettings`.
enum PromptBuilder {

    /// Everything the rail needs to render. Grouped so tests can pin the
    /// "now" and locale without monkey-patching singletons.
    struct Context {
        var settings: AppSettings
        var now: Date
        var locale: Locale
        var timeZone: TimeZone
        /// Names (case-insensitive) of skills currently registered AND
        /// enabled in settings. Controls the tool-availability rail.
        var availableTools: Set<String>

        static func live(
            settings: AppSettings,
            availableTools: Set<String>
        ) -> Context {
            Context(
                settings: settings,
                now: .now,
                locale: .current,
                timeZone: .current,
                availableTools: availableTools
            )
        }
    }

    /// Renders the full context rail. Returns a multi-line string suitable
    /// for direct inclusion as a system-prompt chunk.
    ///
    /// # Example
    /// ```
    /// let rail = PromptBuilder.contextRail(.live(settings: s, availableTools: tools))
    /// // ==>
    /// // Context:
    /// // - Current date: 2026-04-24 (Friday)
    /// // - Local time: 11:42 Europe/Prague
    /// // - Location: Nymburk, CZ
    /// //
    /// // Language policy:
    /// // Respond only in Czech, even if the user writes in another language.
    /// //
    /// // Tool policy:
    /// // - For any arithmetic or numeric computation, you MUST call the
    /// //   Calculator tool. Never compute in your head.
    /// // - For current events / real-time information, you MAY call WebSearch.
    /// //   Never invent facts you could only know by looking them up.
    /// //
    /// // Style: Lean / CI — begin with a VERDICT: line (1–2 sentences), then
    /// //   structured answer with headings / tables. No filler, no apologies.
    /// ```
    static func contextRail(_ ctx: Context) -> String {
        var chunks: [String] = []
        chunks.append(contextBlock(ctx))
        chunks.append(languageBlock(ctx))
        chunks.append(toolPolicyBlock(ctx))
        chunks.append(styleBlock(ctx))
        return chunks.joined(separator: "\n\n")
    }

    // MARK: - Sub-blocks (exposed for targeted tests)

    static func contextBlock(_ ctx: Context) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = ctx.timeZone
        df.dateFormat = "yyyy-MM-dd"

        let weekday = DateFormatter()
        weekday.locale = ctx.settings.language.resolved(locale: ctx.locale) == .cs
            ? Locale(identifier: "cs_CZ")
            : Locale(identifier: "en_US")
        weekday.timeZone = ctx.timeZone
        weekday.dateFormat = "EEEE"

        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.timeZone = ctx.timeZone
        tf.dateFormat = "HH:mm"

        var lines: [String] = [
            "Context:",
            "- Current date: \(df.string(from: ctx.now)) (\(weekday.string(from: ctx.now)))",
            "- Local time: \(tf.string(from: ctx.now)) \(ctx.timeZone.identifier)"
        ]
        let loc = ctx.settings.locationHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loc.isEmpty {
            lines.append("- Location: \(loc)")
        }
        return lines.joined(separator: "\n")
    }

    static func languageBlock(_ ctx: Context) -> String {
        let resolved = ctx.settings.language.resolved(locale: ctx.locale)
        switch resolved {
        case .cs:
            return """
            Language policy:
            Respond ONLY in Czech (čeština). Even if the user writes in \
            English or another language, reply in Czech. Technical terms \
            and code stay in their original language.
            """
        case .en, .auto:
            return """
            Language policy:
            Respond ONLY in English. Even if the user writes in another \
            language, reply in English. Keep code and identifiers verbatim.
            """
        }
    }

    static func toolPolicyBlock(_ ctx: Context) -> String {
        let lower = Set(ctx.availableTools.map { $0.lowercased() })
        var rules: [String] = []

        // Math rail is unconditional: even if Calculator is disabled we
        // still forbid in-head computation. Without a calculator the model
        // should say "I can't compute this reliably without the Calculator
        // tool" rather than guess.
        if lower.contains("calculator") {
            rules.append("- For ANY arithmetic, numeric, unit, or percentage " +
                         "computation you MUST call the Calculator tool. " +
                         "Do not compute in your head, do not guess.")
        } else {
            rules.append("- The Calculator tool is currently disabled. If the " +
                         "user asks for a numeric computation, say so and ask " +
                         "them to enable it — do not compute in your head.")
        }

        if lower.contains("websearch") {
            rules.append("- For current events, prices, news, or any fact that " +
                         "requires fresh data, you MAY call the WebSearch tool. " +
                         "Never invent facts you could only know by looking them up.")
        } else {
            rules.append("- You have no web access. Do NOT pretend to look " +
                         "anything up on the internet. If a question requires " +
                         "fresh data, say you cannot access the web.")
        }

        if lower.contains("calendar") {
            rules.append("- For questions about today's or tomorrow's events, " +
                         "call the Calendar tool — don't fabricate event lists.")
        }
        if lower.contains("deviceinfo") {
            rules.append("- For questions about this device's battery, storage, " +
                         "or OS version, call the DeviceInfo tool.")
        }

        return "Tool policy:\n" + rules.joined(separator: "\n")
    }

    static func styleBlock(_ ctx: Context) -> String {
        switch ctx.settings.responseStyle {
        case .leanCI:
            return """
            Style — Lean / CI:
            - Start with a single line "VERDIKT: …" (CZ) or "VERDICT: …" (EN): \
            1–2 sentences, the bottom-line answer.
            - Then a structured body with headings, bullet lists, and tables \
            where useful. No filler, no apologies, no "As an AI…".
            - Prefer concrete numbers, file paths, commands.
            """
        case .casual:
            return """
            Style — Conversational:
            Be friendly, natural, and concise. Use paragraphs for prose; \
            fall back to bullet lists only when the answer is genuinely \
            enumerable.
            """
        }
    }
}

// MARK: - Hypothetical test case (kept inline as documentation)
//
// Given:
//   var s = AppSettings.default
//   s.language = .cs
//   s.responseStyle = .leanCI
//   s.locationHint = "Nymburk, CZ"
//   let ctx = PromptBuilder.Context(
//     settings: s,
//     now: Date(timeIntervalSince1970: 1_777_622_400), // 2026-04-30 12:00 UTC
//     locale: Locale(identifier: "cs_CZ"),
//     timeZone: TimeZone(identifier: "Europe/Prague")!,
//     availableTools: ["Calculator", "Calendar"]
//   )
//   let rail = PromptBuilder.contextRail(ctx)
//
// Expectations:
//   - rail contains "Current date: 2026-04-30"
//   - rail contains "Location: Nymburk, CZ"
//   - rail contains "Respond ONLY in Czech"
//   - rail contains "call the Calculator tool"
//   - rail contains "no web access" (WebSearch is not registered)
//   - rail contains "VERDIKT:" (Lean/CI style)
