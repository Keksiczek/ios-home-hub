import Foundation

/// Describes the current phase of an in-flight MLX model load operation.
///
/// MLX model loading has two distinct phases:
/// 1. **downloading** — Weights and metadata are fetched from Hugging Face Hub.
///    A real `fractionCompleted` is available from the Hub downloader.
/// 2. **preparing** — Files are on disk; the model weights are being loaded
///    into memory and the Metal compute pipeline is being compiled.
///    This phase is **indeterminate** — no measurable fraction is available.
///
/// We do not fake progress for the preparing phase: the UI shows a spinner
/// and the label "Preparing model…" without a progress bar.
enum MLXLoadPhase: Equatable, Sendable {
    /// Hub download in progress. `fraction` is in [0, 1].
    case downloading(fraction: Double)
    /// Download complete; weights are being loaded and Metal compiled.
    /// Duration is ~10–60 s on iPhone; no fraction available.
    case preparing
}

/// Transient progress snapshot for the current MLX load operation.
///
/// Published on `RuntimeManager.mlxLoadProgress`. Set to `nil` when the
/// load completes (success or failure) so the UI can revert to normal state.
struct MLXLoadProgress: Equatable, Sendable {
    let modelID: String
    let phase: MLXLoadPhase
}
