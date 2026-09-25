import XCTest
@testable import HomeSpeaker

final class AudioCaptureCancellationTests: XCTestCase {
    func testCancelledSessionCannotPrepareOrStartCapture() async {
        let tap = SystemAudioTap()
        let stopped = expectation(description: "Asynchronous teardown completes")
        tap.stop { stopped.fulfill() }
        do {
            _ = try await tap.prepare(source: .system)
            XCTFail("Cancelled capture must not open an audio device")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            try await tap.startCapture { _ in XCTFail("Cancelled capture must not deliver audio") }
            XCTFail("Cancelled capture must not start")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
    }
}
