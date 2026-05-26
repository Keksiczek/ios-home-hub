import Foundation
import CoreGraphics
import UIKit

/// Result of one image-generation call. Always carries the encoded
/// bytes (PNG or JPEG) so the artifact pipeline can persist the
/// payload verbatim — no in-memory `UIImage`/`CIImage` reference
/// types leak past this boundary, which keeps the type `Sendable`
/// and lets us cross actor isolation cheaply.
///
/// `mime` mirrors `Message.Artifact.image(data:mime:)` so the chat
/// layer can pass it straight through without re-sniffing the format.
struct GeneratedImage: Sendable, Equatable {
    let data: Data
    let mime: String
    /// Wall-clock generation time in seconds. Useful for the chat
    /// chrome's "generated in Xs" affordance and for profiling the
    /// runtime; defaults to 0 when the producer didn't measure.
    let durationSeconds: Double

    init(data: Data, mime: String = "image/png", durationSeconds: Double = 0) {
        self.data = data
        self.mime = mime
        self.durationSeconds = durationSeconds
    }
}

/// Parameters for one generation call. Mirrors the surface the rest
/// of the codebase expects from text models — `prompt` is required,
/// everything else has a sensible default so callers don't have to
/// thread settings end-to-end.
///
/// Kept deliberately small for v1. Future expansions (seed, negative
/// prompt, scheduler choice, LoRA picker) belong here so the protocol
/// surface stays single-parameter-blob and additive.
struct ImageGenerationParameters: Sendable, Equatable {
    let prompt: String
    /// Target output dimensions. Stable Diffusion 1.5 / 2.1 want
    /// multiples of 64; SDXL wants 1024×1024. The stub doesn't care
    /// about either — it just respects what the caller asks for.
    let width: Int
    let height: Int
    /// Higher = more guidance toward the prompt but less diversity.
    /// 7.5 is the canonical SD default; FLUX-dev runs lower (~3.5).
    let guidanceScale: Double
    /// Diffusion / flow-match steps. The stub ignores this entirely;
    /// real runtimes honour it as their primary latency knob.
    let steps: Int

    init(
        prompt: String,
        width: Int = 512,
        height: Int = 512,
        guidanceScale: Double = 7.5,
        steps: Int = 20
    ) {
        self.prompt = prompt
        self.width = width
        self.height = height
        self.guidanceScale = guidanceScale
        self.steps = steps
    }
}

/// One-shot streaming event emitted during generation. Mirrors the
/// shape of `RuntimeEvent` for text models so the chat plumbing can
/// be uniform across modalities.
///
/// `.progress` fires per-step (or coarser, depending on the runtime)
/// so the UI can show "Step 12/20"; `.preview` carries the in-flight
/// latent decoded to a low-res preview, useful for big SDXL runs
/// where users want to abort early.
enum ImageGenerationEvent: Sendable {
    case progress(step: Int, total: Int)
    case preview(GeneratedImage)
    case finished(GeneratedImage)
    case failed(Error)
}

/// Errors a runtime can surface. Kept user-readable because they
/// land in the chat surface verbatim — same convention the text
/// runtime follows for `RuntimeError.localizedDescription`.
enum ImageGenerationError: Error, LocalizedError, Equatable {
    case notImplemented
    case modelNotLoaded
    case promptTooLong(Int)
    case cancelled
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Generování obrázků v této verzi není dostupné."
        case .modelNotLoaded:
            return "Model pro generování obrázků není načtený."
        case .promptTooLong(let len):
            return "Popis je příliš dlouhý (\(len) znaků). Zkrať jej, prosím."
        case .cancelled:
            return "Generování bylo zrušeno."
        case .generationFailed(let detail):
            return "Generování selhalo: \(detail)"
        }
    }
}

/// Minimal runtime contract for image generation. Mirrors the text
/// runtime's split — load/unload + a single `generate` entry point
/// that returns a stream of events.
///
/// Implementations are expected to be `Sendable` so the orchestrator
/// can dispatch from any isolation context; concrete types typically
/// wrap an actor for the actual model state.
protocol ImageGenerationRuntime: Sendable {
    /// Identifier of the currently-loaded model, or `nil` when none
    /// is loaded. Stays a plain string (no `LocalModel` dependency)
    /// so this protocol can be tested without dragging the whole
    /// catalog model in.
    var loadedModelID: String? { get async }

    /// Load a model by identifier. Idempotent — calling with the
    /// same ID while loaded is a no-op.
    func load(modelID: String) async throws

    /// Drop the model and free GPU/Neural Engine state. Safe to
    /// call when nothing is loaded.
    func unload() async

    /// Run one generation. Returns a stream so consumers can render
    /// previews / progress bars; the final `.finished` event carries
    /// the full-resolution image.
    func generate(parameters: ImageGenerationParameters) -> AsyncThrowingStream<ImageGenerationEvent, Error>
}

// MARK: - Stub implementation

/// Placeholder runtime that produces a deterministic, prompt-derived
/// gradient image instead of actually running diffusion. Two reasons
/// this exists:
///
/// 1. The chat / artifact pipeline can be wired end-to-end and
///    exercised on-device before any heavyweight Core ML / MLX model
///    integration lands. Bugs in the persistence + render path
///    surface against a fast, deterministic producer.
/// 2. Smoke / E2E tests can use this without downloading a multi-GB
///    diffusion model — `generate()` returns in milliseconds and the
///    output bytes are reproducible from the prompt seed.
///
/// The visual output is intentionally NOT photorealistic — it's a
/// vertical gradient between two colours derived from the prompt's
/// hash, overlaid with the prompt text. Users who see this know
/// they're looking at the stub, not a "bad" diffusion run.
final class StubImageGenerationRuntime: ImageGenerationRuntime {
    private actor State {
        var loadedModelID: String?

        /// Setter on the actor so the public surface stays free of
        /// cross-isolation property writes (which strict concurrency
        /// rejects). Keeps `loadedModelID` reads as a simple property
        /// access but funnels mutations through one entry point.
        func setLoaded(_ id: String?) {
            loadedModelID = id
        }
    }
    private let state = State()

    var loadedModelID: String? {
        get async { await state.loadedModelID }
    }

    func load(modelID: String) async throws {
        // The stub doesn't actually load anything — just records
        // the ID so `loadedModelID` reflects the call site's intent.
        // Throws never; declared `throws` to match the protocol so
        // production runtimes can throw on missing weights / OOM.
        await state.setLoaded(modelID)
    }

    func unload() async {
        await state.setLoaded(nil)
    }

    func generate(parameters: ImageGenerationParameters) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let start = Date()
                let totalSteps = max(parameters.steps, 1)
                // Yield a handful of progress events so consumers
                // can verify their UI plumbing. Spaced via short
                // sleeps to imitate the cadence a real model would
                // produce — total ≈ 200 ms so smoke tests stay
                // fast but the stream isn't instantaneous.
                let progressTicks = min(totalSteps, 4)
                for tick in 1...progressTicks {
                    try? await Task.sleep(nanoseconds: 40_000_000)  // 40 ms
                    if Task.isCancelled {
                        continuation.finish(throwing: ImageGenerationError.cancelled)
                        return
                    }
                    let step = (tick * totalSteps) / progressTicks
                    continuation.yield(.progress(step: step, total: totalSteps))
                }
                guard let result = Self.renderGradient(parameters: parameters) else {
                    continuation.finish(throwing: ImageGenerationError.generationFailed("UIGraphicsImageRenderer returned nil"))
                    return
                }
                let elapsed = Date().timeIntervalSince(start)
                let image = GeneratedImage(data: result, mime: "image/png", durationSeconds: elapsed)
                continuation.yield(.finished(image))
                continuation.finish()
            }
        }
    }

    // MARK: - Stub rendering

    /// Deterministic gradient + prompt text. Derives two colours
    /// from the prompt's UTF-8 hash so identical prompts produce
    /// identical images — useful for snapshot tests later. Output
    /// is PNG (lossless small file for 512×512 gradients).
    private static func renderGradient(parameters: ImageGenerationParameters) -> Data? {
        let size = CGSize(width: parameters.width, height: parameters.height)
        let (top, bottom) = colours(for: parameters.prompt)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()
            // Note: CGGradient takes a flat array of CGFloat components.
            // Each colour is 4 components (R, G, B, A) here.
            let components: [CGFloat] = [
                top.r, top.g, top.b, 1.0,
                bottom.r, bottom.g, bottom.b, 1.0
            ]
            let locations: [CGFloat] = [0.0, 1.0]
            guard let gradient = CGGradient(
                colorSpace: cs,
                colorComponents: components,
                locations: locations,
                count: 2
            ) else { return }
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )

            // Overlay text — wrapped, centered, mid-grey on light
            // gradient / white on dark. The runtime is "honest":
            // the user sees their prompt rendered so they know
            // this is a placeholder, not a real model output.
            let text = "[stub]\n\(parameters.prompt)"
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .paragraphStyle: style
            ]
            let bounds = CGRect(
                x: 24,
                y: size.height / 2 - 80,
                width: size.width - 48,
                height: 160
            )
            (text as NSString).draw(in: bounds, withAttributes: attrs)
        }
        return image.pngData()
    }

    private struct RGB { let r: CGFloat; let g: CGFloat; let b: CGFloat }

    /// Derive two gradient colours from the prompt's bytes. Cheap
    /// FNV-like fold; collisions are fine because we just want
    /// visual variety, not crypto-grade uniqueness.
    private static func colours(for prompt: String) -> (RGB, RGB) {
        var h: UInt64 = 1469598103934665603  // FNV offset basis
        for byte in prompt.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211  // FNV prime
        }
        // Split the 64-bit hash into two 24-bit RGB triples.
        let topRaw = h & 0xFFFFFF
        let botRaw = (h >> 24) & 0xFFFFFF
        return (rgb(from: topRaw), rgb(from: botRaw))
    }

    private static func rgb(from raw: UInt64) -> RGB {
        let r = CGFloat((raw >> 16) & 0xFF) / 255.0
        let g = CGFloat((raw >> 8) & 0xFF) / 255.0
        let b = CGFloat(raw & 0xFF) / 255.0
        return RGB(r: r, g: g, b: b)
    }
}

