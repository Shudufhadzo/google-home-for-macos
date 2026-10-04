import XCTest
@testable import HomeSpeaker

final class CastSyncPlannerTests: XCTestCase {
    private func status(_ time: Double, sampled: Double = 100) -> CastStatus {
        var status = CastStatus()
        status.contentID = "live"; status.receiverAppID = "CC1AD845"; status.mediaSessionID = 7
        status.playerState = "PLAYING"; status.playbackRate = 1; status.currentTime = time; status.positionSampledAt = sampled
        status.supportsSeek = true; status.liveSeekableRange = 5...15
        return status
    }

    func testDifferentSampleTimesAreComparedAtTheSameInstant() throws {
        let result = CastSyncPlanner.assess(statuses: ["speaker": status(10, sampled: 99), "tv": status(11.8)], contentID: "live", at: 101)
        XCTAssertEqual(try XCTUnwrap(result.spread), 0.8, accuracy: 0.0001)
        XCTAssertEqual(result.corrections, ["tv": 12])
        XCTAssertEqual(CastSyncPlanner.commonLiveAnchor(statuses: ["speaker": status(10), "tv": status(11)], contentID: "live", at: 100), 13.5)
    }

    func testUnrelatedStalePausedAndNonNormalMediaCannotBeCorrected() {
        for mutation in [0, 1, 2, 3] {
            var bad = status(11)
            switch mutation {
            case 0: bad.contentID = "phone-media"
            case 1: bad.positionSampledAt = 90
            case 2: bad.playerState = "BUFFERING"
            default: bad.playbackRate = 1.5
            }
            let result = CastSyncPlanner.assess(statuses: ["speaker": status(10), "tv": bad], contentID: "live", at: 100)
            XCTAssertNil(result.spread); XCTAssertTrue(result.corrections.isEmpty)
        }
    }

    func testNonSeekableAndNonOverlappingLiveWindowsOnlyReportDrift() {
        var tv = status(11); tv.supportsSeek = false
        var result = CastSyncPlanner.assess(statuses: ["speaker": status(10), "tv": tv], contentID: "live", at: 100)
        XCTAssertEqual(result.spread, 1); XCTAssertTrue(result.corrections.isEmpty)
        tv.supportsSeek = true; tv.liveSeekableRange = 16...20
        result = CastSyncPlanner.assess(statuses: ["speaker": status(10), "tv": tv], contentID: "live", at: 100)
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertNil(CastSyncPlanner.commonLiveAnchor(statuses: ["speaker": status(10), "tv": tv], contentID: "live", at: 100))
    }

    func testRealJSONTimingParsingAndPartialUpdatesDoNotRestartTheClock() throws {
        let json = Data(#"{"playerState":"PLAYING","currentTime":10,"playbackRate":1,"supportedMediaCommands":3,"liveSeekableRange":{"start":5,"end":15}}"#.utf8)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        var sample = CastStatus()
        sample.updateTiming(body, at: 100)
        XCTAssertTrue(sample.supportsSeek); XCTAssertTrue(sample.supportsPause)
        XCTAssertEqual(sample.liveSeekableRange, 5...15)
        sample.updateTiming(["supportedMediaCommands": 3], at: 102)
        XCTAssertEqual(sample.estimatedPosition(at: 102), 12)
        XCTAssertNil(sample.estimatedPosition(at: 104), "Unchanged status messages cannot refresh old timing samples")
        sample.updateTiming(["currentTime": 15.0, "playerState": "PAUSED"], at: 105)
        XCTAssertEqual(sample.estimatedPosition(at: 106), 15)
        sample.updateMediaInfo(["contentId": "new-song"])
        XCTAssertNil(sample.currentTime); XCTAssertNil(sample.liveSeekableRange)
    }

    func testPlaybackRateChangesPreserveElapsedTimeAndRemovedLiveRangeDisablesSeeking() {
        var sample = status(10)
        sample.updateTiming(["playbackRate": 0.5], at: 102)
        XCTAssertEqual(sample.estimatedPosition(at: 103), 12.5)
        sample.updateTiming(["liveSeekableRange": NSNull()], at: 103)
        XCTAssertNil(sample.liveSeekableRange)
        sample.updateTiming(["liveSeekableRange": ["start": 5.0, "end": 15.0, "isLiveDone": true]], at: 103)
        XCTAssertNil(sample.liveSeekableRange)
    }
}
