import Foundation

struct ActionCommand: Equatable {
    let skillName: String
    let input: String
    let fullTag: String // e.g. "<Action:Calculator:2+2>"
}

/// Central registry for all tools available to the Agent.
///
/// The registry is **the superset**: all skills the app knows how to run
/// live here. Which of them actually surface to the model on any given
/// turn is decided at call time by the `enabled` allow-list (sourced
/// from `AppSettings.enabledTools`). This lets the user toggle individual
/// tools in Settings without forcing the prompt assembler to know about
/// skills the manager hasn't registered yet.
actor SkillManager {
    static let shared = SkillManager()

    private var skills: [String: any Skill] = [:]

    /// Cached `renderInstructions` output, keyed by the lowercased set
    /// of enabled skill names. A different allow-list invalidates the
    /// cache but a repeated turn with the same allow-list is free.
    private var cachedInstructions: (enabled: Set<String>, text: String)?

    private init() {
        // WebSearchSkill stays out of the default registration: it needs
        // explicit user consent AND an available network, and the prompt
        // assembler's privacy rail flips based on whether it's registered.
        // Call `register(WebSearchSkill())` from onboarding / settings once
        // the user opts in.
        let defaults: [any Skill] = [
            CalculatorSkill(),
            CalendarSkill(),
            HomeKitSkill(),
            RemindersSkill(),
            DeviceInfoSkill()
        ]
        for skill in defaults {
            skills[skill.name.lowercased()] = skill
        }
    }

    func register(_ skill: any Skill) {
        skills[skill.name.lowercased()] = skill
        cachedInstructions = nil
        HHLog.tool.info("registered skill \(skill.name, privacy: .public)")
    }

    /// The names of every skill currently in the registry, in registration
    /// order-independent form. Used by `ConversationService` to compute
    /// the intersection with `AppSettings.enabledTools` for each turn.
    func registeredSkillNames() -> Set<String> {
        Set(skills.values.map(\.name))
    }

    /// Snapshot of `(name, availability)` for every registered skill.
    /// Consumed by Settings so the user sees "Needs permission — Calendar
    /// access" next to a toggle instead of a silent failure at call time.
    ///
    /// `async` because `Skill.availability` is `@MainActor` (OS auth checks).
    func availabilitySnapshot() async -> [(name: String, availability: SkillAvailability)] {
        let skillList = Array(skills.values)   // snapshot [any Skill] while on SkillManager actor
        return await MainActor.run {
            skillList
                .map { (name: $0.name, availability: $0.availability) }
                .sorted { $0.name < $1.name }
        }
    }

    /// Generates the L4 system-prompt block listing the *enabled* skills.
    ///
    /// - Parameter enabled: Allow-list of skill names (case-insensitive)
    ///   that should surface to the model. Skills outside this set are
    ///   omitted even if registered. Pass `nil` to include every
    ///   registered skill (legacy behaviour for older callers).
    func buildSystemInstructions(enabled: Set<String>? = nil) -> String {
        let allow: Set<String> = enabled.map { Set($0.map { $0.lowercased() }) }
            ?? Set(skills.keys)

        if let cached = cachedInstructions, cached.enabled == allow {
            return cached.text
        }

        let built = renderInstructions(enabled: allow)
        cachedInstructions = (allow, built)
        return built
    }

    private func renderInstructions(enabled: Set<String>) -> String {
        let visible = skills
            .filter { enabled.contains($0.key) }
            .values
            .sorted { $0.name < $1.name }

        guard !visible.isEmpty else { return "" }

        var instructions = "You have access to the following native tools/skills:\n"
        for skill in visible {
            instructions += "- \(skill.name): \(skill.description)\n"
        }

        instructions += """

        To use a tool, emit a single `<tool_call>` block containing a JSON object \
        with a `name` field (skill name) and an `input` field (argument string):

        <tool_call>{"name": "Calculator", "input": "25 * 4 + 10"}</tool_call>

        Important rules:
        1. Output ONLY the `<tool_call>` block — stop immediately after `</tool_call>`. Add nothing else.
        2. Do NOT wrap the JSON in markdown code blocks (e.g., ```json). Use raw JSON inside the tag.
        3. `input` is a plain string. Do not nest JSON, do not manually escape quotes inside `input`.
        4. The system executes the tool and returns the result in an `<Observation>` block.
        5. Use the observation to write your final user-facing response.
        6. Never fabricate an observation or guess the result. Always wait for the real `<Observation>`.
        """

        return instructions
    }

    /// Parses the first `<tool_call>` envelope in `text`.
    ///
    /// Returns `nil` if no valid envelope is present, the JSON is malformed,
    /// or the `name` field is missing. A missing `input` parses to an EMPTY
    /// input rather than nil — no-argument skills like `DeviceInfo` ignore
    /// their input entirely, so requiring the field would reject well-formed
    /// calls. Logs the drop at `debug` so agentic-loop regressions leave a
    /// trace in Console.app.
    func parseAction(from text: String) -> ActionCommand? {
        if let cmd = ToolCallEnvelope.parse(from: text)?.toActionCommand() {
            return cmd
        }
        // Only log when the text actually contained what LOOKS like a
        // tool call — otherwise every plain assistant turn generates noise.
        if text.contains(ToolCallEnvelope.openTag) {
            HHLog.tool.error("malformed <tool_call> envelope — skipping")
        }
        return nil
    }

    /// Structured execution. Dispatches to the registered skill, enforces
    /// the allow-list and per-skill availability, and wraps the outcome
    /// in a `ToolExecutionResult` the agentic loop can branch on.
    ///
    /// - Parameters:
    ///   - command: Parsed envelope from the model.
    ///   - enabled: Optional allow-list (case-insensitive). Missing → no
    ///     allow-list filtering (legacy callers).
    ///   - timeout: Per-call budget. Default is generous (10 s) because
    ///     tools like WebSearch can legitimately take a few seconds;
    ///     Calculator / DeviceInfo finish in microseconds anyway.
    /// Execute a tool call.
    ///
    /// - Parameter turnHasUntrustedContent: `true` once this turn has already
    ///   run a skill whose output is third-party text (`WebSearch`,
    ///   `FetchPage`). State-changing skills are refused while it holds.
    ///
    /// ## Why an information-flow rule rather than injection detection
    ///
    /// The agentic loop feeds a fetched page back to the model as an
    /// observation and then auto-executes whatever tool call the model emits
    /// next, with no confirmation step. That closes a real chain: a page can
    /// address the model directly, tell it to call `HomeKitSearch` with
    /// `"status"` to enumerate accessory names, and then act on one — or simply
    /// create a Reminder with attacker-chosen text, which needs no
    /// reconnaissance at all. It is reachable without the UI ever appearing,
    /// via `AskHomeHubIntent` from Siri, which deletes its conversation
    /// afterwards and leaves no trace.
    ///
    /// Trying to *detect* the injection in the page text is not reliable and
    /// never will be. Tracking where the content came from is reliable, because
    /// it is a property of our own call graph rather than of the attacker's
    /// prose. So: reading the web is always allowed, and acting on the world
    /// after reading the web is not.
    ///
    /// The rule costs almost nothing legitimate. "Add milk to my reminders"
    /// involves no web content and runs untouched; only "read this page, then
    /// change something" is refused, and the user can still do it in two turns.
    ///
    /// A full per-action confirmation UI would be strictly better and is still
    /// worth building — `Skill.isStateChanging(input:)` exists so it has a
    /// foundation. This closes the demonstrated hole in the meantime, without
    /// blocking on a UX decision.
    /// Whether the named skill's output is third-party text.
    ///
    /// Exposed so the agentic loop can raise its taint flag without reaching
    /// into the registry, and so the answer stays a property of the skill
    /// rather than a hardcoded name list at the call site.
    func producesUntrustedContent(_ skillName: String) -> Bool {
        skills[skillName.lowercased()]?.producesUntrustedContent ?? false
    }

    func run(
        _ command: ActionCommand,
        enabled: Set<String>? = nil,
        timeout: Duration = .seconds(10),
        turnHasUntrustedContent: Bool = false
    ) async -> ToolExecutionResult {
        let key = command.skillName.lowercased()
        guard let skill = skills[key] else {
            HHLog.tool.error("unknown skill '\(command.skillName, privacy: .public)'")
            return .error(
                message: "Skill '\(command.skillName)' is not recognised.",
                reason: .unknownTool
            )
        }
        if let enabled, !enabled.contains(where: { $0.lowercased() == key }) {
            HHLog.tool.info("skill '\(command.skillName, privacy: .public)' disabled — refusing")
            return .error(
                message: "Skill '\(command.skillName)' is disabled in Settings.",
                reason: .disabled
            )
        }
        // Policy before capability.
        //
        // This gate is evaluated ahead of the permission and availability
        // checks on purpose. Whether the call is *allowed* does not depend on
        // whether it would have *succeeded*, and ordering it first means the
        // user and the log get the real reason: a permission-denied message for
        // an injected HomeKit write would be actively misleading, and the
        // behaviour would silently differ between a device that had granted
        // access and one that had not.
        if turnHasUntrustedContent, skill.isStateChanging(input: command.input) {
            HHLog.tool.error(
                "BLOCKED state-changing skill '\(skill.name, privacy: .public)' — this turn already ingested third-party content, so the instruction may not have come from the user"
            )
            return .error(
                message: "Nemůžu provést akci, která mění nastavení nebo data, "
                       + "když jsem v tomto tahu četl obsah z internetu — instrukce mohla "
                       + "pocházet ze stránky, ne od tebe. Napiš mi to prosím zvlášť a udělám to.",
                reason: .blockedAfterUntrustedContent
            )
        }

        let avail = await MainActor.run { skill.availability }
        if case .permission(let prompt) = avail {
            HHLog.tool.info("skill '\(skill.name, privacy: .public)' needs permission: \(prompt, privacy: .public)")
            return .error(
                message: "This tool needs permission: \(prompt). Open Settings to grant it.",
                reason: .permissionMissing
            )
        }
        if case .unavailable(let reason) = avail {
            return .error(
                message: "\(skill.name) is unavailable: \(reason)",
                reason: .executionFailed
            )
        }

        HHLog.tool.info("executing \(skill.name, privacy: .public)")
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await skill.execute(input: command.input) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ToolTimeoutError()
                }
                guard let first = try await group.next() else {
                    throw ToolTimeoutError()
                }
                group.cancelAll()
                return first
            }
            return .success(text)
        } catch is ToolTimeoutError {
            HHLog.tool.error("skill '\(skill.name, privacy: .public)' timed out")
            return .error(
                message: "\(skill.name) took longer than \(timeout).",
                reason: .timeout
            )
        } catch {
            HHLog.tool.error("skill '\(skill.name, privacy: .public)' threw: \(error.localizedDescription, privacy: .public)")
            return .error(
                message: "\(skill.name): \(error.localizedDescription)",
                reason: .executionFailed
            )
        }
    }

    /// Legacy flat-string execute. Kept for callers (tests, widgets)
    /// that don't want to branch on `ToolExecutionResult`. Internally
    /// routes through `run(_:enabled:)` so error shaping stays in one
    /// place.
    func execute(_ command: ActionCommand, enabled: Set<String>? = nil) async -> String {
        let result = await run(command, enabled: enabled)
        switch result {
        case .success(let text):
            return text
        case .error(let message, _):
            return "Error: \(message)"
        }
    }

    private struct ToolTimeoutError: Error {}

    /// Like `execute(_:)` but rethrows the underlying skill error instead
    /// of stringifying it. Used by callers (widget action handler, App
    /// Intents) that need structured success/failure detection rather
    /// than a localised keyword scan.
    ///
    /// Throws `SkillManagerError.unknownSkill` when the skill name does
    /// not resolve; rethrows whatever the skill itself raised on error.
    func executeThrowing(_ command: ActionCommand) async throws -> String {
        guard let skill = skills[command.skillName.lowercased()] else {
            throw SkillManagerError.unknownSkill(name: command.skillName)
        }
        return try await skill.execute(input: command.input)
    }
}

enum SkillManagerError: LocalizedError, Equatable {
    case unknownSkill(name: String)

    var errorDescription: String? {
        switch self {
        case .unknownSkill(let name):
            return "Skill '\(name)' is not recognized."
        }
    }
}
