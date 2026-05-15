import XCTest
@testable import HomeHub

/// Sanity-contract tests for `ConversationService`'s centralised generation
/// lifecycle. The lifecycle has four observable slots that must agree at
/// every quiescent point:
///   1. `activeStreams[id]`         — the Task handle
///   2. `streamingConversationIDs`  — bool gate the chat UI reads
///   3. `generationPhase[id]`       — prefill/decoding indicator state
///   4. (`timedOutConversations`)   — set by the watchdog before cancel
///
/// These tests exercise the three private helpers
/// (`beginGenerationLifecycle`, `markDecoding`, `endGenerationLifecycle`)
/// via the `#if DEBUG` test hooks declared on `ConversationService`. They
/// don't spin up a real generation Task — that's covered by the runtime
/// integration tests. The goal here is to prove the **state machine**
/// itself never drifts, regardless of which ending path runs.
@MainActor
final class GenerationLifecycleTests: XCTestCase {

    // MARK: - Setup

    private var container: AppContainer!
    private var service: ConversationService!

    override func setUp() async throws {
        try await super.setUp()
        container = AppContainer.preview()
        service = container.conversationService
    }

    override func tearDown() async throws {
        service = nil
        container = nil
        try await super.tearDown()
    }

    /// Wraps the helper boilerplate of "give me a Task I can register".
    /// The Task is intentionally never awaited — the lifecycle contract
    /// is independent of whether the task body actually runs.
    private func makeIdleTask() -> Task<Void, Never> {
        Task { /* no-op */ }
    }

    // MARK: - beginGenerationLifecycle

    func testBeginPopulatesAllSlots() {
        let id = UUID()
        let task = makeIdleTask()
        service._test_beginLifecycle(task, for: id)

        XCTAssertTrue(service._test_hasActiveStream(for: id),
            "activeStreams should contain the task after begin")
        XCTAssertTrue(service.streamingConversationIDs.contains(id),
            "streamingConversationIDs should contain the id after begin")
        XCTAssertEqual(service.generationPhase[id], .prefill,
            "generationPhase should start in .prefill after begin")

        // Clean up so the dangling task doesn't bleed into other tests.
        service._test_endLifecycle(for: id, cancellingTask: true)
    }

    // MARK: - markDecoding

    func testMarkDecodingPromotesFromPrefill() {
        let id = UUID()
        service._test_beginLifecycle(makeIdleTask(), for: id)
        XCTAssertEqual(service.generationPhase[id], .prefill)

        service._test_markDecoding(for: id)
        XCTAssertEqual(service.generationPhase[id], .decoding,
            "First token should promote prefill → decoding")

        // Idempotent — calling again stays at .decoding.
        service._test_markDecoding(for: id)
        XCTAssertEqual(service.generationPhase[id], .decoding,
            "Repeated markDecoding calls must be idempotent")

        service._test_endLifecycle(for: id, cancellingTask: true)
    }

    func testMarkDecodingIgnoredAfterTeardown() {
        // Defensive: a late `.token` event arriving after a cancel must
        // NOT re-introduce phase state into the dictionary, otherwise
        // the chat UI would briefly show "decoding" for a dead turn.
        let id = UUID()
        service._test_beginLifecycle(makeIdleTask(), for: id)
        service._test_endLifecycle(for: id, cancellingTask: true)

        service._test_markDecoding(for: id)
        XCTAssertNil(service.generationPhase[id],
            "markDecoding after teardown must not re-introduce phase")
        XCTAssertFalse(service.streamingConversationIDs.contains(id))
    }

    // MARK: - endGenerationLifecycle

    func testEndClearsAllSlots() {
        let id = UUID()
        service._test_beginLifecycle(makeIdleTask(), for: id)

        service._test_endLifecycle(for: id, cancellingTask: true)

        XCTAssertFalse(service._test_hasActiveStream(for: id),
            "activeStreams must be cleared after end")
        XCTAssertFalse(service.streamingConversationIDs.contains(id),
            "streamingConversationIDs must be cleared after end")
        XCTAssertNil(service.generationPhase[id],
            "generationPhase must be cleared after end")
    }

    func testEndIsIdempotent() {
        let id = UUID()
        service._test_beginLifecycle(makeIdleTask(), for: id)

        service._test_endLifecycle(for: id, cancellingTask: true)
        // Calling end again on an already-clean id is a no-op — the
        // defer path inside `performSend` relies on this when the
        // user has already cancelled the stream from the UI.
        service._test_endLifecycle(for: id, cancellingTask: false)

        XCTAssertFalse(service._test_hasActiveStream(for: id))
        XCTAssertFalse(service.streamingConversationIDs.contains(id))
        XCTAssertNil(service.generationPhase[id])
    }

    func testEndOnUnknownIdIsNoOp() {
        // Should never crash or pollute neighbouring conversations.
        let id = UUID()
        service._test_endLifecycle(for: id, cancellingTask: true)
        XCTAssertFalse(service._test_hasActiveStream(for: id))
        XCTAssertFalse(service.streamingConversationIDs.contains(id))
        XCTAssertNil(service.generationPhase[id])
    }

    // MARK: - Public surface

    func testCancelStreamClearsAllSlots() {
        let id = UUID()
        service._test_beginLifecycle(makeIdleTask(), for: id)

        service.cancelStream(in: id)

        XCTAssertFalse(service._test_hasActiveStream(for: id),
            "cancelStream must clear activeStreams")
        XCTAssertFalse(service.streamingConversationIDs.contains(id),
            "cancelStream must clear streamingConversationIDs")
        XCTAssertNil(service.generationPhase[id],
            "cancelStream must clear generationPhase")
    }

    func testDeleteConversationClearsLifecycleSlots() async {
        let convo = await service.createConversation(title: "Lifecycle test")
        service._test_beginLifecycle(makeIdleTask(), for: convo.id)

        await service.deleteConversation(convo.id)

        XCTAssertFalse(service._test_hasActiveStream(for: convo.id),
            "deleteConversation must clear activeStreams")
        XCTAssertFalse(service.streamingConversationIDs.contains(convo.id),
            "deleteConversation must clear streamingConversationIDs")
        XCTAssertNil(service.generationPhase[convo.id],
            "deleteConversation must clear generationPhase")
        XCTAssertFalse(service.conversations.contains(where: { $0.id == convo.id }),
            "conversation should be gone from the published list")
    }

    func testTrimMessagesNoOpWhileStreaming() async {
        let convo = await service.createConversation(title: "Trim guard")
        service._test_beginLifecycle(makeIdleTask(), for: convo.id)
        XCTAssertTrue(service.streamingConversationIDs.contains(convo.id))

        // Pre-seed enough messages that a real trim would remove some.
        // Pull current messages first; createConversation may seed none,
        // so we directly verify the no-op contract: trimMessages must
        // not touch the streaming-state slots.
        let phaseBefore = service.generationPhase[convo.id]
        let activeBefore = service._test_hasActiveStream(for: convo.id)
        let streamingBefore = service.streamingConversationIDs.contains(convo.id)

        await service.trimMessages(in: convo.id, keepLast: 1)

        XCTAssertEqual(service.generationPhase[convo.id], phaseBefore,
            "trimMessages must not change phase while streaming")
        XCTAssertEqual(service._test_hasActiveStream(for: convo.id), activeBefore,
            "trimMessages must not touch activeStreams while streaming")
        XCTAssertEqual(service.streamingConversationIDs.contains(convo.id), streamingBefore,
            "trimMessages must not touch streamingConversationIDs while streaming")

        // Clean up.
        service._test_endLifecycle(for: convo.id, cancellingTask: true)
    }
}

/// Pure-function tests for `RuntimeManager.LoadFeasibility` — verifies
/// the tri-state oracle classifies the three buckets correctly given
/// hand-crafted (model, profile, available) inputs.
final class LoadFeasibilityOracleTests: XCTestCase {

    private func makeModel(sizeBytes: Int64) -> LocalModel {
        LocalModel(
            id: "oracle-test",
            displayName: "Oracle Test",
            family: "Test",
            parameterCount: "?",
            quantization: "?",
            sizeBytes: sizeBytes,
            contextLength: 2048,
            downloadURL: URL(static: "https://example.invalid/x"),
            sha256: nil,
            installState: .notInstalled,
            recommendedFor: [.iPhone],
            license: "n/a",
            backend: .mlx,
            format: .mlx
        )
    }

    func testSafeWhenAvailableExceedsSafetyFactor() {
        let model = makeModel(sizeBytes: 1_000_000_000) // 1 GB
        // Balanced factor = 1.5 → safe threshold = 1.5 GB; available 2 GB.
        let verdict = RuntimeManager.evaluateFeasibility(
            for: model,
            profile: .balanced,
            available: 2_000_000_000
        )
        guard case .safe(let headroom) = verdict else {
            return XCTFail("Expected .safe, got \(String(describing: verdict))")
        }
        XCTAssertEqual(headroom, 2_000_000_000 - 1_500_000_000)
    }

    func testRiskyWhenFitsRawButNotSafetyMargin() {
        let model = makeModel(sizeBytes: 1_000_000_000) // 1 GB raw
        // Balanced factor = 1.5 → safe = 1.5 GB. Available 1.2 GB:
        // covers raw weights but not the safety margin → risky.
        let verdict = RuntimeManager.evaluateFeasibility(
            for: model,
            profile: .balanced,
            available: 1_200_000_000
        )
        guard case .risky(let required, let avail) = verdict else {
            return XCTFail("Expected .risky, got \(String(describing: verdict))")
        }
        XCTAssertEqual(required, 1_500_000_000)
        XCTAssertEqual(avail, 1_200_000_000)
        XCTAssertTrue(verdict?.permitsLoad ?? false,
            ".risky must still permit the load attempt")
    }

    func testCannotLoadWhenBelowRawSize() {
        let model = makeModel(sizeBytes: 2_000_000_000) // 2 GB raw
        let verdict = RuntimeManager.evaluateFeasibility(
            for: model,
            profile: .conservative,
            available: 1_000_000_000 // 1 GB — less than raw
        )
        guard case .cannotLoad(let required, let avail) = verdict else {
            return XCTFail("Expected .cannotLoad, got \(String(describing: verdict))")
        }
        XCTAssertEqual(required, 2_000_000_000)
        XCTAssertEqual(avail, 1_000_000_000)
        XCTAssertFalse(verdict?.permitsLoad ?? true,
            ".cannotLoad must veto the load")
    }

    func testNilForUnknownSize() {
        let model = makeModel(sizeBytes: 0)
        let verdict = RuntimeManager.evaluateFeasibility(
            for: model,
            profile: .balanced,
            available: 4_000_000_000
        )
        XCTAssertNil(verdict, "Oracle must abstain when model size is unknown")
    }

    func testConservativeProfileIsStricter() {
        // Same model + same available memory, different profiles can
        // flip the verdict from .safe to .risky.
        let model = makeModel(sizeBytes: 1_000_000_000) // 1 GB
        // Aggressive factor = 1.3 → safe = 1.3 GB. Available 1.4 GB → SAFE.
        let aggressive = RuntimeManager.evaluateFeasibility(
            for: model, profile: .aggressive, available: 1_400_000_000
        )
        if case .safe = aggressive {} else {
            XCTFail("Aggressive should classify 1.4 GB available / 1 GB raw as .safe")
        }
        // Conservative factor = 1.8 → safe = 1.8 GB. Same 1.4 GB → RISKY.
        let conservative = RuntimeManager.evaluateFeasibility(
            for: model, profile: .conservative, available: 1_400_000_000
        )
        if case .risky = conservative {} else {
            XCTFail("Conservative should downgrade 1.4 GB available / 1 GB raw to .risky")
        }
    }
}
