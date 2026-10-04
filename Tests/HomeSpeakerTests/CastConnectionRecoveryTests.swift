import XCTest
@testable import HomeSpeaker

final class CastConnectionRecoveryTests: XCTestCase {
    func testOnlyOwnedActiveStreamsRecoverAndRetryBudgetIsBounded() {
        var policy = CastConnectionRecovery()
        XCTAssertNil(policy.retryDelay(at: 100, ownsActiveStream: false))
        XCTAssertEqual(policy.retryDelay(at: 100, ownsActiveStream: true), 0.5)
        XCTAssertEqual(policy.retryDelay(at: 101, ownsActiveStream: true), 1)
        XCTAssertEqual(policy.retryDelay(at: 103, ownsActiveStream: true), 2)
        XCTAssertNil(policy.retryDelay(at: 107, ownsActiveStream: true))
    }

    func testBriefSuccessfulConnectionsDoNotCreateAnInfiniteRetryLoop() {
        var policy = CastConnectionRecovery()
        for time in [100.0, 102, 104] { XCTAssertNotNil(policy.retryDelay(at: time, ownsActiveStream: true)) }
        XCTAssertNil(policy.retryDelay(at: 106, ownsActiveStream: true))
        XCTAssertEqual(policy.retryDelay(at: 137, ownsActiveStream: true), 0.5,
                       "A later independent interruption gets a fresh budget after thirty healthy seconds")
        policy.reset()
        XCTAssertEqual(policy.retryDelay(at: 138, ownsActiveStream: true), 0.5)
    }
}
