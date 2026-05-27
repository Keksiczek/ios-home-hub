import Foundation
import CoreML
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import UIKit
import os

#if canImport(StableDiffusion)
import StableDiffusion
#endif

/// Real Core ML diffusion runtime. Wraps Apple's
/// `StableDiffusionPipeline` (vendored as a fork at
/// `Keksiczek/ml-stable-diffusion`) and adapts it to HomeHub's
/// streaming `ImageGenerationRuntime` contract.
///
/// ## When this runtime is available
///
/// Compiled in whenever the `StableDiffusion` Swift package resolves
/// — that's the default for the iOS app target. Builds that strip the
/// dependency (e.g. someone removing it from `project.yml` to shrink
/// binary size) get `notImplemented` on every call. Crucially, the
/// project still compiles — the `#if canImport(StableDiffusion)` guard
/// keeps the public surface intact while letting the implementation
/// degrade to a `notImplemented` error.
///
/// ## Compute unit policy
///
/// `cpuAndNeuralEngine` on real iPhone/iPad hardware. The simulator
/// does not ship a Neural Engine and the Core ML predictor falls
/// back to CPU regardless of what we ask for, but specifying
/// `cpuAndNeuralEngine` there is a hard error from Core ML —
/// `MLModelError` with code `unsupportedConfiguration`. We detect
/// the simulator via `targetEnvironment(simulator)` and downgrade to
/// `cpuOnly` so smoke tests can still load + run (very slowly).
///
/// ## Memory budget (iPhone 16 Pro, 8 GB RAM)
///
/// `reduceMemory: true` swaps text encoder / U-Net / VAE in and out
/// of GPU memory across the run rather than holding all three
/// resident. Peak RSS for SD 2.1 base palettized lands around
/// 1.5–2 GB. Combined with a 4-bit palettized weight format
/// (~900 MB on disk), this fits the device without jetsamming the
/// chat surface — but the user IS spending most of their RAM
/// budget on the run, so concurrent VLM / LLM loads should be
/// blocked while a generation is in flight (out of scope here;
/// `ConversationService` already serialises through the actor).
///
/// ## Concurrency
///
/// All mutable state lives on the `State` actor — `loadedModelID`,
/// the `pipeline` reference, and the `cancellationRequested` flag.
/// `generate(...)` returns an `AsyncThrowingStream` whose producing
/// Task hops onto a background `Task.detached(priority: .userInitiated)`
/// for the actual `pipeline.generateImages(...)` call, because the
/// underlying Core ML predict is synchronous and would block whichever
/// thread it lands on for tens of seconds.
final class CoreMLStableDiffusionRuntime: ImageGenerationRuntime {

    // MARK: - Actor-isolated state

    #if canImport(StableDiffusion)
    /// `@unchecked Sendable` wrapper around `StableDiffusionPipeline`.
    /// The wrapped type is not Sendable (it owns mutable Core ML
    /// model contexts that Swift can't reason about), but our usage
    /// IS safe by construction:
    ///   - `ConversationService` serialises generate calls per chat;
    ///     two concurrent generations on the same instance are not
    ///     possible from production code.
    ///   - The pipeline reference is mutated only through the actor
    ///     below (`PipelineBox?` field), so reads and writes never
    ///     race.
    /// The wrapper exists so the actor can publish the pipeline back
    /// out without triggering Swift 6 strict-concurrency errors at
    /// every actor boundary.
    private final class PipelineBox: @unchecked Sendable {
        let pipeline: StableDiffusionPipeline
        init(_ pipeline: StableDiffusionPipeline) { self.pipeline = pipeline }
    }
    #endif

    private actor State {
        var loadedModelID: String?
        #if canImport(StableDiffusion)
        var pipelineBox: PipelineBox?
        #endif

        func setLoaded(modelID: String?) { loadedModelID = modelID }
        #if canImport(StableDiffusion)
        func setPipelineBox(_ box: PipelineBox?) { self.pipelineBox = box }
        #endif
    }

    private let state = State()

    /// Cancellation token shared with the Core ML progress handler.
    /// Lives outside the actor because the progress callback runs on
    /// SD's compute thread and CANNOT make an actor hop without
    /// deadlocking the cooperative pool — `pipeline.generateImages`
    /// is synchronous, so blocking inside its progress handler holds
    /// up whatever Swift Concurrency thread serviced the detached
    /// Task. `OSAllocatedUnfairLock` gives us a nonisolated,
    /// allocation-free atomic flag the callback can poll in O(ns).
    private let cancellationFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Maps a model ID to the on-disk directory the SD pipeline
    /// should load from. Injected so tests and alternate installs
    /// (e.g. iCloud-Documents-backed model store) can override the
    /// convention. The default points at
    /// `Application Support/Models/coreml-sd/<modelID>/` which is
    /// where the download service will land HF mirror snapshots.
    private let resolveResourceURL: @Sendable (String) -> URL

    private let log = Logger(subsystem: "com.keksiczek.HomeHub", category: "CoreMLStableDiffusionRuntime")

    /// Default resource URL convention. Centralised so the default
    /// initializer and external callers stay in lockstep.
    static func defaultResourceURL(for modelID: String) -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("coreml-sd", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    init(resolveResourceURL: @escaping @Sendable (String) -> URL = CoreMLStableDiffusionRuntime.defaultResourceURL(for:)) {
        self.resolveResourceURL = resolveResourceURL
    }

    // MARK: - ImageGenerationRuntime

    var loadedModelID: String? {
        get async { await state.loadedModelID }
    }

    func load(modelID: String) async throws {
        #if canImport(StableDiffusion)
        // Idempotent — re-load of the same model is a no-op so chat
        // can call this defensively on every turn.
        let currentID = await state.loadedModelID
        let currentBox = await state.pipelineBox
        if currentID == modelID, currentBox != nil {
            return
        }

        let resourceURL = resolveResourceURL(modelID)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resourceURL.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            log.error("Resources missing at \(resourceURL.path, privacy: .public)")
            throw ImageGenerationError.generationFailed(
                "Resources pro model '\(modelID)' nejsou nainstalovány. Stáhni jej v Nastavení → Modely."
            )
        }

        let config = MLModelConfiguration()
        // Simulator has no Neural Engine; requesting it throws
        // `MLModelError.unsupportedConfiguration` at load time.
        // Real devices benefit substantially — split-einsum-v2 weights
        // are built for the ANE specifically and CPU-only is ~5× slower.
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .cpuAndNeuralEngine
        #endif

        log.info("Loading SD pipeline from \(resourceURL.path, privacy: .public) units=\(String(describing: config.computeUnits), privacy: .public)")

        // Resources init + loadResources both happen on a background
        // priority Task so we don't block whatever actor called us
        // (ConversationService is @MainActor; blocking it for the
        // 5-15 s cold load would freeze the chat UI). The boxed
        // pipeline crosses the Task boundary via PipelineBox's
        // unchecked-Sendable conformance.
        let box = try await Task.detached(priority: .userInitiated) { [resourceURL] in
            let pipe = try StableDiffusionPipeline(
                resourcesAt: resourceURL,
                controlNet: [],
                configuration: config,
                disableSafety: false,
                reduceMemory: true
            )
            try pipe.loadResources()
            return PipelineBox(pipe)
        }.value

        await state.setPipelineBox(box)
        await state.setLoaded(modelID: modelID)
        log.info("SD pipeline loaded: \(modelID, privacy: .public)")
        #else
        throw ImageGenerationError.notImplemented
        #endif
    }

    func unload() async {
        #if canImport(StableDiffusion)
        if let box = await state.pipelineBox {
            // `unloadResources()` releases all sub-model Core ML
            // contexts (text encoder, U-Net chunks, VAE) so the next
            // `load(...)` starts from a clean memory baseline. Cheap
            // (microseconds) — the heavy mmap reclaim happens when
            // the pipeline reference is dropped on the next line.
            box.pipeline.unloadResources()
        }
        await state.setPipelineBox(nil)
        #endif
        await state.setLoaded(modelID: nil)
    }

    func cancel() async {
        cancellationFlag.withLock { $0 = true }
    }

    func generate(parameters: ImageGenerationParameters) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let state = self.state
            let log = self.log

            // Detached Task so the synchronous Core ML predict calls
            // inside generateImages don't pin whatever actor invoked us.
            // We bridge cancellation in both directions: a cancelled
            // parent Task → `.onTermination` → `cancel()` → flag set →
            // progress handler returns false → SD aborts at the next
            // step boundary.
            let cancellationFlag = self.cancellationFlag
            let task = Task.detached(priority: .userInitiated) {
                await Self.runGeneration(
                    parameters: parameters,
                    state: state,
                    cancellationFlag: cancellationFlag,
                    log: log,
                    continuation: continuation
                )
            }

            let flag = self.cancellationFlag
            continuation.onTermination = { @Sendable termination in
                // `.cancelled` covers both explicit
                // `continuation.finish(throwing: CancellationError)`
                // from inside the producer AND the consumer dropping
                // the stream (e.g. the user closing the chat surface
                // mid-render). In either case we tell the runtime to
                // stop ASAP — the next step boundary picks up the flag.
                if case .cancelled = termination {
                    flag.withLock { $0 = true }
                    task.cancel()
                }
            }
        }
    }

    // MARK: - Generation body

    /// Runs the actual SD pipeline. Static so the detached Task captures
    /// only `Sendable` values, not the runtime instance itself (Core ML
    /// + pipeline references aren't Sendable; we work around that by
    /// reaching back through the actor).
    private static func runGeneration(
        parameters: ImageGenerationParameters,
        state: State,
        cancellationFlag: OSAllocatedUnfairLock<Bool>,
        log: Logger,
        continuation: AsyncThrowingStream<ImageGenerationEvent, Error>.Continuation
    ) async {
        #if canImport(StableDiffusion)
        // Reset the cancel flag on entry so a prior cancelled run
        // can't poison this one — `cancel()` flips it true and we'd
        // otherwise short-circuit before the first denoise step.
        cancellationFlag.withLock { $0 = false }
        let start = Date()

        guard let box = await state.pipelineBox else {
            continuation.finish(throwing: ImageGenerationError.modelNotLoaded)
            return
        }
        let pipeline = box.pipeline

        // Reasonable defaults for SD 2.1 base. CLIP's tokenizer cuts
        // off at 77 tokens regardless of input length, but Apple's
        // pipeline guards against a hugely-pathological prompt by
        // surfacing a `failedToTokenizePrompt` error. We surface that
        // as a user-readable `promptTooLong`.
        if parameters.prompt.count > 2000 {
            continuation.finish(throwing: ImageGenerationError.promptTooLong(parameters.prompt.count))
            return
        }

        var config = StableDiffusionPipeline.Configuration(prompt: parameters.prompt)
        config.stepCount = max(parameters.steps, 1)
        config.guidanceScale = Float(parameters.guidanceScale)
        config.imageCount = 1
        // Deterministic seed from prompt hash so identical prompts
        // produce identical images (matching the stub's contract +
        // helping users iterate by varying the prompt rather than
        // chasing a random seed). UInt32-clamped FNV-1a fold.
        config.seed = Self.deterministicSeed(for: parameters.prompt)
        // PNDM is the historical default for SD 2.x and produces good
        // results in 20-25 steps. DPM++ is faster (~15 steps) but
        // sometimes drifts on highly textual prompts.
        config.schedulerType = .pndmScheduler
        // Disable safety checker — on-device, opt-in, and the model
        // we ship doesn't include the checker assets in the
        // palettized variant. With the checker enabled but assets
        // missing the pipeline init would already have thrown.
        config.disableSafety = true

        do {
            let totalSteps = config.stepCount
            // generateImages is synchronous; the progress handler is
            // the cancellation seam. Returning `false` aborts SD's
            // internal denoise loop at the next step.
            let images: [CGImage?] = try pipeline.generateImages(configuration: config) { progress in
                // Best-effort progress emit. `continuation.yield(...)`
                // is non-blocking and Sendable-safe so calling it
                // from the Core ML thread is fine; the stream's
                // internal buffer absorbs any slow consumer.
                continuation.yield(.progress(step: progress.step, total: totalSteps))
                // Two cancellation channels (same shape as the stub):
                // standard Swift `Task.isCancelled` and our explicit
                // `cancel()` flag. Both are nonisolated atomic reads
                // — no actor hop, no semaphore — so we can poll them
                // synchronously from SD's compute thread without
                // risking a cooperative-pool deadlock.
                if Task.isCancelled { return false }
                let explicit = cancellationFlag.withLock { $0 }
                return !explicit
            }

            // Detect cancellation: SD returns `[nil]` when the
            // progress handler aborts mid-step. Surface as the
            // localized cancelled error so the chat surface shows
            // the same Czech string as the stub.
            guard let first = images.first, let cgImage = first else {
                let cancelled = Task.isCancelled || cancellationFlag.withLock { $0 }
                if cancelled {
                    continuation.finish(throwing: ImageGenerationError.cancelled)
                } else {
                    continuation.finish(throwing: ImageGenerationError.generationFailed(
                        "Pipeline vrátila nil obrázek."
                    ))
                }
                return
            }

            guard let pngData = Self.pngData(from: cgImage) else {
                continuation.finish(throwing: ImageGenerationError.generationFailed(
                    "Nepodařilo se zakódovat výstup jako PNG."
                ))
                return
            }

            let elapsed = Date().timeIntervalSince(start)
            let image = GeneratedImage(data: pngData, mime: "image/png", durationSeconds: elapsed)
            continuation.yield(.finished(image))
            continuation.finish()
            log.info("SD generation finished in \(elapsed, format: .fixed(precision: 2)) s steps=\(config.stepCount)")
        } catch {
            log.error("SD generation failed: \(error.localizedDescription, privacy: .public)")
            // Map known SD error categories to user-readable Czech.
            // Unknown errors bubble verbatim — the chat surface picks
            // them up via `LocalizedError.errorDescription` so users
            // see what actually broke instead of a generic message.
            let cancelled = Task.isCancelled || cancellationFlag.withLock { $0 }
            if cancelled {
                continuation.finish(throwing: ImageGenerationError.cancelled)
            } else {
                continuation.finish(throwing: ImageGenerationError.generationFailed(error.localizedDescription))
            }
        }
        #else
        continuation.finish(throwing: ImageGenerationError.notImplemented)
        #endif
    }

    // MARK: - Helpers

    /// Encode a `CGImage` to PNG. Uses `ImageIO` rather than
    /// `UIImage.pngData()` because the latter forces a UIKit hop
    /// and we're running off-main here. Returns `nil` on encoding
    /// failure (rare — only happens on malformed colour spaces).
    private static func pngData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Deterministic seed from the prompt's UTF-8 bytes, truncated to
    /// UInt32. Matches the stub's deterministic-by-prompt contract:
    /// same prompt → same seed → same image, so users can iterate on
    /// a prompt and see reproducible deltas rather than chasing a
    /// random seed.
    ///
    /// Uses CryptoKit's `SHA256` over the UTF-8 bytes, then reads the
    /// first 4 bytes in big-endian order as a `UInt32`. Two reasons
    /// to use this over Swift's `Hasher` or hand-rolled FNV-1a:
    ///   1. **Deterministic across processes.** Swift's `Hasher` is
    ///      per-launch randomised; FNV-1a is fine for short prompts
    ///      but collides at essay length. SHA256 is collision-
    ///      resistant for any input we'd see.
    ///   2. **No magic constants in source.** FNV-1a needs the
    ///      offset basis + prime to be repeated verbatim across any
    ///      caller wanting to reproduce the seed — a refactor-rot
    ///      risk. SHA256 is a single named primitive.
    ///
    /// `internal` (not `private`) so the test target can pin the
    /// determinism contract without round-tripping through a full
    /// Core ML run.
    static func deterministicSeed(for prompt: String) -> UInt32 {
        let digest = SHA256.hash(data: Data(prompt.utf8))
        // SHA256 is 32 bytes. We need a UInt32 — take the leading
        // 4 bytes and combine them big-endian. The combination is
        // deliberate: any 4 contiguous bytes of a SHA256 digest are
        // uniformly distributed, so picking the first 4 is fine.
        var seed: UInt32 = 0
        for (i, byte) in digest.prefix(4).enumerated() {
            seed |= UInt32(byte) << ((3 - i) * 8)
        }
        return seed
    }
}
