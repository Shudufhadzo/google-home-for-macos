import XCTest
@testable import HomeSpeaker

final class PCMStreamRelayTests: XCTestCase {
    func testTrackCutoverCannotCarryOldSamplesIntoNewReceiver() {
        let relay = PCMStreamRelay()
        var oldSamples = Data()
        var newSamples = Data()
        relay.route { oldSamples.append($0) }
        relay.append(Data([1, 1, 1, 1]))
        relay.route(to: nil)
        relay.append(Data([2, 2, 2, 2]))
        relay.route { newSamples.append($0) }
        relay.append(Data([3, 3, 3, 3]))
        XCTAssertEqual(oldSamples, Data([1, 1, 1, 1]))
        XCTAssertEqual(newSamples, Data([3, 3, 3, 3]))
    }
}
