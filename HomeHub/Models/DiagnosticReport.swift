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
    }

    struct Budget: Codable, Equatable {
        let family: String
        let mode: String
        let totalPromptTokens: Int
        let historyKept: Int
        let historyDropped: Int
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
