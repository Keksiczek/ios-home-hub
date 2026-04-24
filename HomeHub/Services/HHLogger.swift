import Foundation
import os

/// Thin facade over `os.Logger` used across the app.
///
/// ## Why not just use `os.Logger` directly?
/// - A single `subsystem` string in one place — otherwise `Logger(
///   subsystem: "cz.keksiczek.homehub", category: …)` gets copied into
///   every file and one stray typo silently drops events off the
///   Console.app filter.
/// - Matches the project's "one central place to swap for a different
///   logger later" pattern already hinted at in `SettingsService`.
/// - Keeps log sites short: `HHLog.tool.info("called Calculator")` vs.
///   `Logger(subsystem: …, category: "Tool").info(…)` at every call site.
///
/// ## Categories
/// - `runtime`   — model load/unload, token streaming lifecycle.
/// - `chat`      — conversation send/receive, cancellation, regeneration.
/// - `tool`      — skill registration, parsing, execution, timeouts.
/// - `memory`    — fact/episode extraction and injection.
/// - `settings`  — persisted-state read/write.
/// - `ui`        — view-layer notable events (rare; prefer behavioural logs).
enum HHLog {
    private static let subsystem = "cz.keksiczek.homehub"

    static let runtime  = Logger(subsystem: subsystem, category: "runtime")
    static let chat     = Logger(subsystem: subsystem, category: "chat")
    static let tool     = Logger(subsystem: subsystem, category: "tool")
    static let memory   = Logger(subsystem: subsystem, category: "memory")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let ui       = Logger(subsystem: subsystem, category: "ui")
}
