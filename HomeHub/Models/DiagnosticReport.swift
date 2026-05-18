import Foundation
import UIKit

/// Snapshot of runtime, generation, settings, and recent telemetry data
/// suitable for sharing as a single JSON blob in a bug report.
///
/// Built on demand by `DeveloperDiagnosticsView`'s "Copy diagnostics" /
/// share-sheet actions. The fields mirror what the user already sees in
/// the diagnostics screen, so a copied report is interpretable by anyone
/// looking at the same UI — no internal state leaks in.
///
/// ## Privacy
/// We deliberately never include conversation contents, memory facts,
/// the user profile, or attachment metadata. The report is a runtime
/// health snapshot, not a session export.
struct DiagnosticReport: Codable, Equatable {

    let generatedAt: Date
    let appVersion: String
    let device: Device
    let build: Build
    let runtime: Runtime
    let activeModel: ActiveModel?
    let lastGeneration: LastGeneration
    let memory: MemoryStats
    let settings: Settings
    let catalog: CatalogStats
    let lastBudget: Budget?
    let recentTelemetry: [String]
    /// Snapshot of the active guardrails configuration. Included so bug
    /// reports make it immediately clear whether hard rules / privacy
    /// guardrails are enabled and which context layers are active — without
    /// that, "model behaves unexpectedly" reports are very hard to reproduce.
    let guardrails: GuardrailsSnapshot
    /// Hugging Face token state at report time. Always present so the
    /// JSON shape is stable; the *token itself* is never included —
    /// only "is one configured?" and "when was it last validated?".
    /// Defaulted to `.none` for tests / preview reports that don't
    /// populate it explicitly. Critical for triage: "user filed a 401
    /// bug — did they actually have a token in the first place?".
    var huggingFace: HuggingFaceSnapshot = .none

    struct HuggingFaceSnapshot: Codable, Equatable {
        /// `true` when `HFTokenStore.hasToken` returned true at report
        /// time. The actual token bytes are NEVER serialized.
        let hasToken: Bool
        /// Unix seconds of the most recent successful `whoami-v2`
        /// validation, or `nil` if never validated. Lets the recipient
        /// compute "X days since validation" without needing the
        /// current clock.
        let lastVerifiedAtUnix: Double?
        /// Coarse status label matching `AppContainer.HFTokenStatus`:
        /// `"valid" | "invalid" | "networkError" | "stale"`. `"stale"`
        /// means a token exists but the last validation is older than
        /// the foreground re-probe threshold.
        let status: String

        static let none = HuggingFaceSnapshot(
            hasToken: false,
            lastVerifiedAtUnix: nil,
            status: "absent"
        )
    }

    struct Device: Codable, Equatable {
        let modelName: String
        let systemVersion: String
        let isPhone: Bool
        let isSimulator: Bool
    }

    struct Build: Codable, Equatable {
        /// Stays in the report for backward-compat with bug reports filed
        /// before MLX became the primary backend. Contains the same string
        /// the diagnostics screen shows next to "Available backends".
        let cppBridge: String
        let downloadMode: String
        /// True when this build was compiled with `HOMEHUB_LLAMA_RUNTIME=1`.
        /// Field name kept for compat with the diagnostic-export schema.
        let realRuntimeFlag: Bool
        /// Always "mlx" — the primary backend. Captured explicitly so report
        /// readers don't have to infer it from the cppBridge label.
        let primaryBackend: String
    }

    struct Runtime: Codable, Equatable {
        let identifier: String
        let state: String
        let failureReason: String?
    }

    struct ActiveModel: Codable, Equatable {
        let id: String
        let displayName: String
        let family: String
        let parameterCount: String
        let quantization: String
        let sizeBytes: Int64
        let contextLength: Int
    }

    struct LastGeneration: Codable, Equatable {
        let ttftMs: Int?
        let tokensPerSecond: Double?
        let totalDurationMs: Int?
    }

    struct MemoryStats: Codable, Equatable {
        let memoryWarningCount: Int
        let lastUnloadNotification: String?
        /// Tally of how the two-tier pressure policy handled recent L1
        /// warnings. Snapshotted from `AppContainer.pressureHistory` at
        /// report time so the user can attach an honest "what the
        /// policy did" record to bug reports without us asking them to
        /// type out each line. All three values default to 0 when the
        /// history is empty, keeping the JSON shape stable for
        /// downstream parsers (e.g. existing bug-report tooling).
        var pressureTierCounts: PressureTierCounts = .init(soft: 0, hard: 0, deferred: 0)
        /// Bounded list of recent pressure events, newest-first.
        /// Structured rather than human-readable so external tools
        /// (Grafana dashboards, log replay scripts, the planned
        /// pressure-trend analyser) can ingest the JSON without parsing
        /// localized Czech strings. Cap matches
        /// `AppContainer.pressureHistoryCap` so report and live UI
        /// agree on what "recent" means.
        var pressureHistory: [PressureEvent] = []
    }

    struct PressureTierCounts: Codable, Equatable {
        let soft: Int
        let hard: Int
        let deferred: Int
    }

    /// Wire-format snapshot of a single L1 pressure decision. Mirrors
    /// `AppContainer.PressureEventSnapshot` field-for-field but Codable
    /// — the live type is `Equatable` only because it doesn't need to
    /// cross process boundaries until report-export time, and adding
    /// Codable to it would force every consumer of the live channel
    /// to deal with the synthesis. Two types, one mapping, no
    /// surprises.
    struct PressureEvent: Codable, Equatable {
        /// Unix seconds. Use `Date(timeIntervalSince1970:)` to rehydrate.
        let occurredAtUnix: Double
        /// `nil` when the sysctl returned 0 (e.g. simulator).
        let availableBytes: Int64?
        /// `0` when no model was loaded.
        let weightsBytes: Int64
        let inDebounceWindow: Bool
        let belowHardFloor: Bool
        let wasGenerating: Bool
        /// Coarse tier label so downstream tooling can group without
        /// re-deriving the policy. Values: `"soft" | "hard" | "deferred"`.
        let tier: String
    }

    /// Sampling parameters at snapshot time. Critical for "why is the
    /// model rambling?" reports — temperature 1.4 produces very different
    /// behaviour than 0.7, and the report should make that obvious.
    struct Settings: Codable, Equatable {
        let temperature: Double
        let topP: Double
        let topK: Int
        let minP: Double
        let repeatPenalty: Double
        let repeatPenaltyLastN: Int
        let maxResponseTokens: Int
        let answerLength: String
        let language: String
    }

    struct CatalogStats: Codable, Equatable {
        let total: Int
        let installed: Int
        let downloading: Int
        let failed: Int
        let userAdded: Int
        /// Total catalog entries with `backend == .mlx`.
        let mlxModels: Int
        /// Total catalog entries with `backend == .llamaCpp`.
        let ggufModels: Int
        /// How many entries the current build can actually load. On
        /// MLX-only builds this equals `mlxModels`; on opt-in builds it's
        /// `mlxModels + ggufModels`. Lets bug-report readers see at a
        /// glance whether the user is in a degraded catalog state.
        let usableInThisBuild: Int
    }

    struct Budget: Codable, Equatable {
        let family: String
        let mode: String
        let totalPromptTokens: Int
        let historyKept: Int
        let historyDropped: Int
    }

    /// Snapshot of the active guardrails configuration, populated from
    /// `AppSettings.guardrailsConfig` at export time.
    struct GuardrailsSnapshot: Codable, Equatable {
        let hardRulesEnabled: Bool
        let privacyGuardrailEnabled: Bool
        /// Enabled context layers ordered by name (e.g. ["episodes", "facts"]).
        let enabledContextLayers: [String]
        /// Canonical preset label: "default", "unrestricted", or "custom".
        let activePreset: String
    }

    /// Renders the report as pretty-printed JSON the user can paste into
    /// an issue tracker. Falls back to a single-line summary if encoding
    /// somehow fails (which shouldn't happen — every field is plain
    /// Codable).
    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "Could not encode diagnostic report."
        }
        return str
    }
}
