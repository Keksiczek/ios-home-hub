import XCTest
@testable import HomeHub

/// Coverage for the `finishReason` field + its `wasTruncatedByLength`
/// derived flag. The field is stringly-typed (deliberate, see Message
/// doc-comment) so the only thing protecting the Continue button is
/// the `FinishReasonKey` constants — these tests pin the contract.
final class MessageFinishReasonTests: XCTestCase {

    private func make(finishReason: String?) -> Message {
        Message(
            id: UUID(),
            conversationID: UUID(),
            role: .assistant,
            content: "Hello",
            createdAt: .now,
            status: .complete,
            tokenCount: nil,
            attachments: nil,
            bookmarked: nil,
            finishReason: finishReason
        )
    }

    func testWasTruncatedByLengthTrueForLengthReason() {
        let msg = make(finishReason: Message.FinishReasonKey.length)
        XCTAssertTrue(msg.wasTruncatedByLength)
    }

    func testWasTruncatedByLengthFalseForStopReason() {
        let msg = make(finishReason: Message.FinishReasonKey.stop)
        XCTAssertFalse(msg.wasTruncatedByLength)
    }

    func testWasTruncatedByLengthFalseForCancelled() {
        let msg = make(finishReason: Message.FinishReasonKey.cancelled)
        XCTAssertFalse(msg.wasTruncatedByLength)
    }

    func testWasTruncatedByLengthFalseForError() {
        let msg = make(finishReason: Message.FinishReasonKey.error)
        XCTAssertFalse(msg.wasTruncatedByLength)
    }

    func testWasTruncatedByLengthFalseForNil() {
        // Older persisted messages have nil. Must not trigger the
        // Continue button.
        let msg = make(finishReason: nil)
        XCTAssertFalse(msg.wasTruncatedByLength)
    }

    func testWasTruncatedByLengthFalseForUnknownString() {
        // Defensive: if a future enum case lands without a constant
        // mapping, wasTruncatedByLength must NOT default to true.
        let msg = make(finishReason: "future_reason_we_dont_know_yet")
        XCTAssertFalse(msg.wasTruncatedByLength)
    }

    func testFinishReasonRoundTripsThroughCodable() throws {
        let original = make(finishReason: Message.FinishReasonKey.length)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded.finishReason, Message.FinishReasonKey.length)
        XCTAssertTrue(decoded.wasTruncatedByLength)
    }

    func testOlderMessagesWithoutFinishReasonDecodeCleanly() throws {
        // Mimic a payload from before the field existed — no
        // `finishReason` key in the JSON. Decode must not throw.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "conversationID": "\(UUID().uuidString)",
          "role": "assistant",
          "content": "old message",
          "createdAt": 0,
          "status": "complete"
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let msg = try decoder.decode(Message.self, from: data)
        XCTAssertNil(msg.finishReason)
        XCTAssertFalse(msg.wasTruncatedByLength)
    }

    // MARK: - FinishReasonKey constants

    func testFinishReasonKeyConstantsMatchRuntimeEnum() {
        // The strings are dictated by the `case` labels in
        // `RuntimeEvent.FinishReason`. If those ever rename, the
        // ConversationService → Message mapping in the switch
        // *and* these constants must update in lockstep.
        XCTAssertEqual(Message.FinishReasonKey.stop,      "stop")
        XCTAssertEqual(Message.FinishReasonKey.length,    "length")
        XCTAssertEqual(Message.FinishReasonKey.cancelled, "cancelled")
        XCTAssertEqual(Message.FinishReasonKey.error,     "error")
    }
}
