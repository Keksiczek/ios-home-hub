import Foundation
import os

/// Picks the LLM model that should handle a given chat turn when
/// `AppSettings.routingPolicy != .manual`. Consults the user's
/// per-tier picks (`AppSettings.fastModelID`, `.balancedModelID`,
/// `.smartModelID`), falls back to the catalog's installed
/// candidates per tier, and applies attachment-driven overrides
/// (vision needed → must pick a VLM-capable model regardless of
/// tier).
///
/// ## Design
///
/// The router is **pure** — it takes a snapshot of catalog +
/// settings + the turn's input and returns a model ID. It does
/// NOT mutate runtime state or call `RuntimeManager.load(...)`;
/// that's the caller's responsibility. Tests can inject any
/// catalog snapshot without spinning up the full service graph.
///
/// ## Tier classification
///
/// The classifier is **heuristic, not LLM-backed**. We
/// deliberately don't call a tiny model to classify because:
///   1. The classification has to fire BEFORE we know which model
///      is loaded. Calling the FAST model first would itself
///      require loading it.
///   2. Even a perfect classifier saves at most a few seconds of
///      wrong-model load time per turn; the user's tier picks +
///      simple length/shape heuristics get us 80% of the way there
///      at zero cost.
///   3. A pure heuristic is unit-testable and deterministic.
///
/// ### Heuristics
///
/// - **Vision attachments present** → must pick a VLM-capable
///   model. The tier becomes "smallest VLM that fits the device".
/// - **Slash command** (`/image`, `/img`) → routed elsewhere by
///   `ConversationService.parseImageCommand` before the router
///   is consulted; we return `.fast` defensively but the value
///   is unused.
/// - **Short conversational input** (< 60 chars, no code blocks)
///   → `.fast`. Greetings, quick clarifications, short follow-ups
///   don't need a 7B model.
/// - **Code-ish input** (contains triple backticks, `def `, `func `,
///   `class `, `import `, `<script>`, `SELECT `, ...) → `.smart`.
///   Code reasoning rewards bigger models disproportionately.
/// - **Long input** (> 500 chars OR contains explicit "explain in
///   detail" / "vysvětli detailně" markers) → `.smart`.
/// - **Default** → `.balanced`.
///
/// ## Co-residency policy
///
/// On iPhone (8 GB RAM, ~5 GB available), the smart tier eats
/// almost the entire budget. The router knows this via
/// `LocalModel.recommendedFor`: when the user is on iPhone and
/// the smart pick is `recommendedFor: [.iPadMSeries]`, we
/// downgrade to balanced. The `experimental` policy's
/// "fast helps smart" mode is also gated here — we only signal
/// "co-resident OK" when the picked smart model + fast model
/// together fit in the budget.
@MainActor
final class ModelRouter {

    private let catalog: ModelCatalogService
    private let settings: SettingsService
    private let log = Logger(subsystem: "com.keksiczek.HomeHub", category: "ModelRouter")

    init(catalog: ModelCatalogService, settings: SettingsService) {
        self.catalog = catalog
        self.settings = settings
    }

    // MARK: - Public API

    /// Tier classification for a turn. Pure function of input +
    /// attachments; exposed so tests can pin the heuristic
    /// independently of catalog state.
    enum Tier: String, Sendable, Equatable {
        case fast
        case balanced
        case smart
    }

    /// Output of a routing decision. Carries the resolved
    /// `LocalModel` (not just an ID) because the router already
    /// touched the catalog to find it — handing back the full
    /// row spares the caller a second lookup. `tier` is what the
    /// classifier picked (may differ from the model's tier if a
    /// fallback was applied). `coResidentFastModelID` is set ONLY
    /// when policy is `.experimental` AND the picked smart model
    /// + a fast model fit in the device memory budget together.
    struct Decision: Sendable, Equatable {
        let model: LocalModel
        let tier: Tier
        let coResidentFastModelID: String?
        /// Human-readable reason for the pick, used in chat logs
        /// and the developer strip. Czech because it surfaces in
        /// UI when the developer-mode badge is enabled.
        let reasonCZ: String
    }

    /// Picks the model that should handle this turn. Returns
    /// `nil` when no installed model satisfies the constraints
    /// (e.g. user attached an image but no VLM is installed) —
    /// caller must surface an actionable failure to the user.
    func pick(userInput: String, hasImageAttachment: Bool) -> Decision? {
        let tier = Self.classify(userInput: userInput, hasImageAttachment: hasImageAttachment)
        return resolve(tier: tier, hasImageAttachment: hasImageAttachment)
    }

    /// Heuristic classifier. Pure; no I/O. Exposed for tests.
    nonisolated static func classify(userInput: String, hasImageAttachment: Bool) -> Tier {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Vision attachments are special: the tier itself doesn't
        // change here (a VLM gate happens later in resolve), but
        // a vision turn typically warrants more reasoning since
        // the user usually asks a multi-step question about the
        // image. Bias upward to balanced.
        if hasImageAttachment {
            return .balanced
        }

        // Code-ish input → smart. Look for the universal markers
        // first (triple backticks always win) then language-specific
        // tokens that strongly signal "this is code".
        if trimmed.contains("```") {
            return .smart
        }
        let lower = trimmed.lowercased()
        let codeMarkers = [
            "func ", "def ", "class ", "import ",
            "fun ", "fn ", "func(",
            "<script>", "<?php",
            "select ", "update ", "insert into",
            "git ", "npm ", "swift ",
            "stacktrace", "traceback", "exception:"
        ]
        if codeMarkers.contains(where: { lower.contains($0) }) {
            return .smart
        }

        // Length-based classification. The thresholds are tuned for
        // typical Czech / English chat lengths:
        //   - Greetings, quick yes/no, follow-up clarifications
        //     hover around 5–40 chars.
        //   - "Normal" questions land in 40–500 chars.
        //   - Anything longer than 500 chars is usually a multi-
        //     paragraph dump that benefits from more reasoning.
        let charCount = trimmed.count
        if charCount < 60 {
            return .fast
        }
        if charCount > 500 {
            return .smart
        }

        // Explicit "detail / depth" markers — even a short prompt
        // with these wants the bigger model.
        let depthMarkers = [
            "vysvětli detailně", "vysvětli podrobně",
            "explain in detail", "step by step",
            "krok za krokem", "krok po kroku",
            "compare", "porovnej",
            "analyze", "analyzuj"
        ]
        if depthMarkers.contains(where: { lower.contains($0) }) {
            return .smart
        }

        return .balanced
    }

    // MARK: - Resolution

    /// Translate a tier pick into a concrete catalog model ID,
    /// applying installed-state checks, device-class downgrade,
    /// vision overrides, and the user's per-tier picks.
    private func resolve(tier: Tier, hasImageAttachment: Bool) -> Decision? {
        let current = settings.current

        // Vision override: any image attachment forces a VLM-
        // capable pick regardless of tier. We prefer the smallest
        // installed VLM (SmolVLM 256M / 500M / Qwen2-VL 2B) to
        // keep the load time down.
        if hasImageAttachment {
            if let vlm = installedVLMs().first {
                return Decision(
                    model: vlm,
                    tier: tier,
                    coResidentFastModelID: nil,
                    reasonCZ: "Připojen obrázek → vision model \(vlm.displayName)."
                )
            }
            // No VLM installed — let caller raise an actionable
            // error. The UI banner in MessageComposerView already
            // catches this at compose time.
            return nil
        }

        // Apple Intelligence is the priority pick on iOS 26+ for
        // FAST and BALANCED turns: zero load cost, instant TTFT,
        // no RAM pressure on HomeHub's budget. SMART turns still
        // go through a sized MLX model because Apple's model is
        // ~3B and not the strongest for code / multi-step reasoning.
        if (tier == .fast || tier == .balanced),
           let afm = appleIntelligence() {
            return Decision(
                model: afm,
                tier: tier,
                coResidentFastModelID: nil,
                reasonCZ: "Apple Intelligence — bez stahování, okamžitý start."
            )
        }

        // User's explicit per-tier pick takes priority if
        // installed and device-appropriate.
        let userPick: String?
        switch tier {
        case .fast:     userPick = current.fastModelID
        case .balanced: userPick = current.balancedModelID
        case .smart:    userPick = current.smartModelID
        }
        if let id = userPick, let model = catalog.model(withID: id), isUsable(model) {
            return Decision(
                model: model,
                tier: tier,
                coResidentFastModelID: coResidentFastPick(for: model, policy: current.routingPolicy),
                reasonCZ: "Uživatelská volba pro \(tierLabel(tier))."
            )
        }

        // Fallback: pick the smallest installed model in the
        // requested tier. If empty, degrade to the next tier
        // (fast → balanced → smart, smart → balanced → fast).
        let preferredOrder: [Tier] = {
            switch tier {
            case .fast:     return [.fast, .balanced, .smart]
            case .balanced: return [.balanced, .fast, .smart]
            case .smart:    return [.smart, .balanced, .fast]
            }
        }()
        for fallbackTier in preferredOrder {
            if let pick = catalogPick(for: fallbackTier) {
                let downgraded = fallbackTier != tier
                return Decision(
                    model: pick,
                    tier: fallbackTier,
                    coResidentFastModelID: coResidentFastPick(for: pick, policy: current.routingPolicy),
                    reasonCZ: downgraded
                        ? "Žádný \(tierLabel(tier)) model není nainstalovaný → \(tierLabel(fallbackTier)) náhrada."
                        : "Auto-pick: \(pick.displayName)."
                )
            }
        }

        log.warning("ModelRouter: no installed model satisfies tier=\(tier.rawValue, privacy: .public)")
        return nil
    }

    // MARK: - Catalog helpers

    /// Returns Apple Intelligence catalog entry IFF available on
    /// this build + device. The catalog includes the entry
    /// unconditionally but `RuntimeBackendAvailability` does the
    /// real gate.
    private func appleIntelligence() -> LocalModel? {
        guard RuntimeBackendAvailability.appleFoundationModelsAvailable else { return nil }
        return catalog.models.first { $0.backend == .appleFoundationModels }
    }

    /// Installed VLM models, ordered by size (smallest first).
    /// Used by the vision-override path.
    private func installedVLMs() -> [LocalModel] {
        catalog.models
            .filter { model in
                guard model.backend == .mlx, isUsable(model) else { return false }
                return ModelCapabilityProfile.resolve(
                    family: model.family,
                    parameterCount: model.parameterCount,
                    contextLength: model.contextLength
                ).supportsVision
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }
    }

    /// Pick the catalog's preferred model for a tier, given install
    /// state and device class. Smallest-fit-first within the tier.
    private func catalogPick(for tier: Tier) -> LocalModel? {
        let candidates = catalog.models.filter { model in
            guard model.backend == .mlx, isUsable(model) else { return false }
            return Self.tierFor(model: model) == tier
        }
        // Smallest first inside the tier — we want the cheapest
        // load that satisfies the tier classification.
        return candidates.min(by: { $0.sizeBytes < $1.sizeBytes })
    }

    /// Reverse classification — given a catalog entry, what tier
    /// does its size place it in? Mirrors the sort that
    /// `code-explorer` produced during the audit.
    ///
    /// Made `nonisolated static` so `ConversationService` can call
    /// it in the auto-route block to apply hysteresis (skip a swap
    /// when the currently-loaded model already lives in the
    /// classifier's picked tier). Static because the answer is a
    /// pure function of `LocalModel.sizeBytes` + `.backend` — no
    /// catalog/settings state is consulted.
    nonisolated static func tierFor(model: LocalModel) -> Tier {
        // Apple Intelligence is its own thing; treat as fast for
        // the rare case it shows up here (the priority pick path
        // already short-circuits to it for fast/balanced).
        if model.backend == .appleFoundationModels { return .fast }
        // Size thresholds (bytes):
        //   < 1.2 GB → fast (covers 360M, 1B, 1.7B, VLM 256/500M)
        //   < 3.5 GB → balanced (covers 2-3B, Phi 3.5, Qwen2-VL 2B,
        //                        Gemma 3n E2B)
        //   ≥ 3.5 GB → smart (Mistral 7B, Llama 3.1 8B, Gemma 3n E4B)
        if model.sizeBytes < 1_200_000_000 { return .fast }
        if model.sizeBytes < 3_500_000_000 { return .balanced }
        return .smart
    }

    /// Is this model installed AND runnable on the current device?
    /// `recommendedFor` is the device-class gate; install state
    /// is the on-disk gate.
    private func isUsable(_ model: LocalModel) -> Bool {
        guard case .installed = model.installState else { return false }
        // Honour recommendedFor as a soft gate. On iPhone we skip
        // models marked iPad-only — they typically need extended
        // virtual addressing or > 4 GB of free RAM.
        #if targetEnvironment(simulator)
        // Simulators report as iPhone but have desktop-class RAM
        // and no NE. Be permissive — let everything through.
        return true
        #else
        let deviceClass: DeviceClass = UIDevice.current.userInterfaceIdiom == .pad ? .iPadMSeries : .iPhone
        return model.recommendedFor.contains(deviceClass)
        #endif
    }

    /// For SMART tier picks under `.experimental` policy, return a
    /// FAST model ID that can be co-resident. The combined
    /// resident-budget estimate uses `sizeBytes * 1.5` as a
    /// conservative resident factor (MLX usually lands ~1.2-1.5×
    /// disk size at resident).
    private func coResidentFastPick(for smartModel: LocalModel, policy: RoutingPolicy) -> String? {
        guard policy == .experimental, Self.tierFor(model: smartModel) == .smart else { return nil }
        let smartResident = Int64(Double(smartModel.sizeBytes) * 1.5)
        let budget: Int64 = 5_000_000_000  // ~5 GB safe ceiling on iPhone 16 Pro
        let headroom = budget - smartResident
        // Pick the smallest installed fast model that fits in the
        // remaining headroom. Apple Intelligence doesn't count
        // toward the resident budget so we'd prefer it, but it
        // can't be loaded "as fast tier alongside MLX smart" —
        // they live on different runtime instances. Stick with
        // MLX fast model for the co-resident slot.
        guard headroom > 800_000_000 else { return nil }  // need ≥ 800 MB free
        return catalog.models
            .filter { $0.backend == .mlx && isUsable($0) && Self.tierFor(model: $0) == .fast }
            .filter { Int64(Double($0.sizeBytes) * 1.5) < headroom }
            .min(by: { $0.sizeBytes < $1.sizeBytes })?
            .id
    }

    private func tierLabel(_ tier: Tier) -> String {
        switch tier {
        case .fast:     return "rychlý"
        case .balanced: return "vyvážený"
        case .smart:    return "chytrý"
        }
    }
}
