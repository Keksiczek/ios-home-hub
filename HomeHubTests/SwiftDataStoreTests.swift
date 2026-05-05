import XCTest
import SwiftData
@testable import HomeHub

/// Unit tests for `SwiftDataStore` init-path hardening (task 1A).
///
/// - Happy path: store initialises without throwing.
/// - Error path: `containerFactory` failure is surfaced as
///   `SwiftDataStoreError.containerInitFailed` (not a crash).
final class SwiftDataStoreTests: XCTestCase {

    // MARK: - Happy path

    func testStoreInitializesSuccessfully() throws {
        // The default init builds a real (in-process) SwiftData container.
        // On a fresh schema with no conflicting on-disk data this must succeed.
        XCTAssertNoThrow(try SwiftDataStore())
    }

    // MARK: - Error path

    func testContainerFactoryFailureSurfacesAsSwiftDataStoreError() {
        struct FakeContainerError: Error, LocalizedError {
            var errorDescription: String? { "Simulated container failure" }
        }

        XCTAssertThrowsError(
            try SwiftDataStore(containerFactory: { throw FakeContainerError() })
        ) { error in
            guard let storeError = error as? SwiftDataStoreError,
                  case .containerInitFailed(let underlying) = storeError else {
                XCTFail("Expected SwiftDataStoreError.containerInitFailed, got \(error)")
                return
            }
            XCTAssertTrue(underlying is FakeContainerError)
        }
    }

    func testContainerInitFailedHasLocalizedDescription() {
        let underlying = NSError(domain: "SwiftDataStore.Test", code: 99,
                                 userInfo: [NSLocalizedDescriptionKey: "Schema mismatch"])
        let error = SwiftDataStoreError.containerInitFailed(underlying: underlying)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(
            error.errorDescription?.contains("Schema mismatch") == true,
            "errorDescription should include the underlying message"
        )
    }
}
