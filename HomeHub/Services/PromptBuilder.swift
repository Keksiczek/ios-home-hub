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
        /// When `true`, the rail uses a shorter, less instructional form
        /// of the date block. Specifically: drops the verbatim Czech
        /// quoting hint that small models (Llama 3.2 1B Q4 observed in
        /// the field) parrot as the opening line of EVERY reply
        /// regardless of whether the user asked about the date. Also
        /// adds an explicit "do not lead with the date" instruction.
        var isWeakInstructionFollower: Bool = false

        static func live(
            settings: AppSettings,
            availableTools: Set<String>,
            isWeakInstructionFollower: Bool = false
        ) -> Context {
            Context(
                settings: settings,
                now: .now,
                locale: .current,
                timeZone: .current,
                availableTools: availableTools,
                isWeakInstructionFollower: isWeakInstructionFollower
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

    /// Stable subset of the rail. Everything here is invariant under the
    /// passage of time: location, tool-policy, style, language. Goes into
    /// `stableSystemPrompt` so the MLX KV-cache prefix stays valid across
    /// turns.
    ///
    /// **Architectural note**: previously the entire rail was emitted as
    /// volatile, meaning the date-stamp re-render alone invalidated
    /// 200–300 tokens of static boilerplate (tool policy, style hints)
    /// every single turn. On Gemma 3n at ~30 t/s prefill that's ~7-10 s
    /// of wasted time-to-first-token per turn. After the split only the
    /// genuinely-volatile date+time block invalidates the prefix.
    static func contextRailStable(_ ctx: Context) -> String {
        var chunks: [String] = []
        let loc = locationBlock(ctx)
        if !loc.isEmpty { chunks.append(loc) }
        chunks.append(languageBlock(ctx))
        chunks.append(toolPolicyBlock(ctx))
        chunks.append(styleBlock(ctx))
        return chunks.joined(separator: "\n\n")
    }

    /// Volatile subset of the rail. Only date/time + the anti-parrot
    /// guard for weak models — both genuinely time-sensitive (date) or
    /// freshness-sensitive (anti-parrot reminder, kept near the date so
    /// the model sees them as one block).
    static func contextRailVolatile(_ ctx: Context) -> String {
        dateTimeBlock(ctx)
    }

    /// Legacy combined accessor. Kept so any future caller / test that
    /// wants the whole rail in one string can still get it without
    /// reassembling the parts. Production assembly should go through
    /// the `contextRailStable` / `contextRailVolatile` pair above so
    /// the MLX KV-cache prefix can be reused turn-to-turn.
    @available(*, deprecated, message: "Use contextRailStable + contextRailVolatile so KV-cache prefix reuse stays valid")
    static func contextRailCombined(_ ctx: Context) -> String {
        var chunks: [String] = []
        chunks.append(dateTimeBlock(ctx))
        let loc = locationBlock(ctx)
        if !loc.isEmpty { chunks.append(loc) }
        chunks.append(languageBlock(ctx))
        chunks.append(toolPolicyBlock(ctx))
        chunks.append(styleBlock(ctx))
        return chunks.joined(separator: "\n\n")
    }

    // MARK: - Sub-blocks (exposed for targeted tests)

    /// Cached DateFormatters. `DateFormatter.init()` parses locale data
    /// (a noticeable chunk of work — measurable in tens of microseconds
    /// per instance, multiplied by 5 instances × every turn). The
    /// formatters are reused across calls; only their `timeZone` is
    /// reassigned per call because callers can pass a different zone
    /// (tests pin `Europe/Prague`; production reads `.current`).
    /// `DateFormatter` is documented thread-safe for `string(from:)` as
    /// long as you don't mutate its config concurrently — we serialise
    /// the timeZone assignment behind `formatterLock` to keep that
    /// guarantee.
    private static let formatterLock = NSLock()
    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let enWeekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE"
        return f
    }()
    private static let csWeekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = "EEEE"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let csDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = "d. MMMM yyyy"
        return f
    }()

    /// Volatile date / time / Czech-locale weekday hint / anti-parrot
    /// guard for weak models. The only true per-turn churn.
    static func dateTimeBlock(_ ctx: Context) -> String {
        let isCS = ctx.settings.language.resolved(locale: ctx.locale) == .cs

        // Snapshot formatted strings under the lock so the timeZone
        // mutation can't race with another thread's `string(from:)`.
        // The lock is held for the duration of formatting — measured
        // at ~30-60 µs total per call, well below the cost of
        // re-instantiating five formatters from scratch.
        let (isoDate, weekdayName, timeStr, csDay, csDate) = formatterLock.withLock { () -> (String, String, String, String, String) in
            Self.isoDateFormatter.timeZone = ctx.timeZone
            Self.enWeekdayFormatter.timeZone = ctx.timeZone
            Self.csWeekdayFormatter.timeZone = ctx.timeZone
            Self.timeFormatter.timeZone = ctx.timeZone
            Self.csDateFormatter.timeZone = ctx.timeZone

            let weekdayFormatter = isCS ? Self.csWeekdayFormatter : Self.enWeekdayFormatter
            return (
                Self.isoDateFormatter.string(from: ctx.now),
                weekdayFormatter.string(from: ctx.now),
                Self.timeFormatter.string(from: ctx.now),
                Self.csWeekdayFormatter.string(from: ctx.now).lowercased(),
                Self.csDateFormatter.string(from: ctx.now)
            )
        }

        var lines: [String] = [
            "Context:",
            "- Current date: \(isoDate) (\(weekdayName))",
            "- Local time: \(timeStr) \(ctx.timeZone.identifier)"
        ]

        if isCS {
            if ctx.isWeakInstructionFollower {
                lines.append("- Dnes: \(csDay), \(csDate)")
            } else {
                lines.append("- Když se uživatel zeptá na dnešní den nebo datum, použij přesně tuto formulaci: \"Dnes je \(csDay), \(csDate).\"")
            }
        }

        if ctx.isWeakInstructionFollower {
            lines.append("- NEPOZDRAVUJ uživatele jménem a NEZAČÍNEJ odpověď datem ani časem, pokud se uživatel přímo nezeptal. Odpovídej rovnou na otázku.")
        }
        return lines.joined(separator: "\n")
    }

    /// Stable location hint. Returns `""` when the user has cleared the
    /// `locationHint` setting — the caller filters empty blocks out.
    static func locationBlock(_ ctx: Context) -> String {
        let loc = ctx.settings.locationHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loc.isEmpty else { return "" }
        return "Location: \(loc)"
    }

    /// Combined context block (date + location + weak guards). Retained
    /// for compatibility with the `toolFollowup` assembly path that emits
    /// the rail as one chunk. Composed from the cached sub-blocks so
    /// there's only one DateFormatter cache to maintain.
    static func contextBlock(_ ctx: Context) -> String {
        var lines = dateTimeBlock(ctx).components(separatedBy: "\n")
        let loc = locationBlock(ctx)
        if !loc.isEmpty {
            // `locationBlock` returns `"Location: …"` for the stable use;
            // here we want it inline as a `"- Location: …"` bullet
            // alongside the other Context lines. Splice it in before
            // any weak-model guard line (which `dateTimeBlock` puts last
            // when `isWeakInstructionFollower`).
            let bullet = "- \(loc)"
            if let guardIdx = lines.firstIndex(where: { $0.hasPrefix("- NEPOZDRAVUJ") }) {
                lines.insert(bullet, at: guardIdx)
            } else {
                lines.append(bullet)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func languageBlock(_ ctx: Context) -> String {
        let resolved = ctx.settings.language.resolved(locale: ctx.locale)
        // Weak models need explicit "no mixing" instructions — Llama 3.2
        // 1B Q4 in the field produces "yesterday Discuss", "good music",
        // `тебе` (Cyrillic) inside Czech replies. Strong models don't
        // need this prompt overhead.
        let antiMixingGuard = ctx.isWeakInstructionFollower
        switch resolved {
        case .cs:
            if antiMixingGuard {
                return """
                Language policy:
                Odpovídej VŽDY a POUZE v češtině. Nikdy nemíchej anglická, \
                ruská, ukrajinská nebo jiná cizí slova do české věty. \
                Pokud něco nevíš česky, řekni "Nevím." — nepoužívej cizí slovo. \
                Pouze technické pojmy v kódu zůstávají v původním jazyce.
                """
            }
            return """
            Language policy:
            Respond ONLY in Czech (čeština). Even if the user writes in \
            English or another language, reply in Czech. Technical terms \
            and code stay in their original language.
            """
        case .en, .auto:
            if antiMixingGuard {
                return """
                Language policy:
                Respond ONLY in English. Do not mix words from other \
                languages (Czech, Russian, etc.) into English sentences. \
                If you don't know an English word, say so plainly. Code \
                and identifiers stay verbatim.
                """
            }
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
            rules.append("- Please use the Calculator tool for arithmetic or numeric computations.")
        } else {
            rules.append("- The Calculator tool is currently disabled.")
        }

        if lower.contains("websearch") {
            // Strong "MUST" wording for the search rail: small models
            // default to fabricating when a tool is merely permitted.
            // Training data is full of "MAY call X" prompts where
            // the model never does — flipping to imperative-with-
            // examples reliably nudges Q4 checkpoints into actually
            // calling the tool for time-sensitive questions.
            rules.append("- For current events, prices, news, weather, sports scores, " +
                         "or ANY fact that depends on the current date (anything published " +
                         "after early 2024), you MUST call the WebSearch tool. " +
                         "Reformulate the user's question into 2-6 keywords before searching " +
                         "(e.g. 'kolik stoji EUR?' → 'EUR CZK rate today'). " +
                         "Never invent facts you could only know by looking them up.")
            if lower.contains("fetchpage") {
                rules.append("- After WebSearch, if the result snippets are too short to " +
                             "fully answer the question, call FetchPage on the most relevant " +
                             "URL to read the page content before responding.")
            }
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
        // Weak models need a stronger, simpler discipline rail — the
        // nuanced "1-2 lines of supporting context" style brief gets
        // ignored by Q4 small checkpoints. The lean wording below
        // collapses each tier to two imperative sentences which
        // empirically survive the chat-template overhead.
        let isWeak = ctx.isWeakInstructionFollower
        switch ctx.settings.answerLength {
        case .concise:
            if isWeak {
                return """
                Answer style — Concise:
                První věta odpovídá na otázku přímo. Maximálně 3 věty celkem. \
                Žádný úvod, žádné "samozřejmě", žádný pozdrav, žádný podpis.
                """
            }
            return """
            Answer length — Concise:
            Reply in 1–3 sentences. No preamble ("Sure!", "Of course"), \
            no sign-off. If the question genuinely needs a list, keep it \
            to 3 bullets max.
            """
        case .balanced:
            if isWeak {
                return """
                Answer style — Balanced:
                První věta odpovídá přímo na otázku. Pak maximálně 2 věty \
                doplnění nebo příklad. Žádný úvod ani podpis. Pokud nevíš, \
                řekni "Nevím." — neopisuj otázku.
                """
            }
            return """
            Answer length — Balanced:
            Give a short direct answer, then 1–2 lines of supporting \
            context. Use bullet lists for enumerations, prose for everything \
            else. No filler.
            """
        case .detailed:
            if isWeak {
                return """
                Answer style — Detailed:
                První věta je přímá odpověď. Pak rozveď postup, příklad nebo \
                konkrétní čísla. Maximálně 6 vět. Žádné fráze typu \
                "rád ti pomůžu" ani "doufám, že to pomůže".
                """
            }
            return """
            Answer length — Detailed:
            Give a complete answer with headings, examples, and concrete \
            numbers or commands where useful. Still avoid filler phrases \
            and self-references.
            """
        }
    }
}

// MARK: - Hypothetical test case (kept inline as documentation)
//
// Given:
//   var s = AppSettings.default
//   s.language = .cs
//   s.answerLength = .concise
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
//   - rail contains "Concise" (answer-length section header)
