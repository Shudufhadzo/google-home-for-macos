import XCTest
@testable import HomeSpeaker

final class MixedPlaybackTimingTests: XCTestCase {
    private func status(_ position: Double = 10, sampled: Double = 100) -> CastStatus {
        var value = CastStatus()
        value.contentID = "live"
        value.receiverAppID = "CC1AD845"
        value.mediaSessionID = 7
        value.playerState = "PLAYING"
        value.playbackRate = 1
        value.currentTime = position
        value.positionSampledAt = sampled
        return value
    }

    private func assess(_ statuses: [String: CastStatus]? = nil, now: Double = 100,
                        airPlayPosition: Double? = 11, airPlaySampledAt: Double? = 100,
                        airPlayPlaying: Bool = true, ranges: [ClosedRange<Double>] = [5...20],
                        offset: Double = 0) -> MixedPlaybackTiming.Assessment {
        MixedPlaybackTiming.assess(statuses: statuses ?? ["speaker": status()], contentID: "live", now: now,
                                   airPlayPosition: airPlayPosition, airPlaySampledAt: airPlaySampledAt,
                                   airPlayPlaying: airPlayPlaying, seekableRanges: ranges, offset: offset)
    }

    func testValidTargetUsesSlowestReceiverAndRequestedOffsetAtSameInstant() throws {
        let result = assess(["slow": status(10, sampled: 99), "fast": status(12)], now: 101,
                            airPlayPosition: 11.5, airPlaySampledAt: 100, offset: -0.25)
        XCTAssertEqual(try XCTUnwrap(result.target), 11.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.difference), 0.5, accuracy: 0.0001)
        XCTAssertEqual(assess(offset: 5).target, 15)
        XCTAssertEqual(assess(ranges: [0...20], offset: -5).target, 5)
    }

    func testEveryCastReportMustDescribeFreshCurrentStreamAtNormalSpeed() {
        let mutations: [(inout CastStatus) -> Void] = [
            { $0.contentID = "other" }, { $0.receiverAppID = "other-app" },
            { $0.mediaSessionID = nil }, { $0.positionSampledAt = nil },
            { $0.positionSampledAt = 96.9 }, { $0.positionSampledAt = 101 },
            { $0.currentTime = nil }, { $0.currentTime = .infinity },
            { $0.playerState = "PAUSED" }, { $0.playerState = "BUFFERING" },
            { $0.playbackRate = nil }, { $0.playbackRate = 0 },
            { $0.playbackRate = 0.5 }, { $0.playbackRate = .nan }
        ]
        for mutation in mutations {
            var invalid = status()
            mutation(&invalid)
            let result = assess(["good": status(), "bad": invalid])
            XCTAssertNil(result.target)
            XCTAssertNil(result.difference)
        }
        XCTAssertNil(assess([:]).target)
    }

    func testAirPlayMustHaveFiniteFreshAdvancingSample() {
        for sample in [nil, 96.9, 101, Double.nan, Double.infinity] as [Double?] {
            XCTAssertNil(assess(airPlaySampledAt: sample).target)
            XCTAssertNil(assess(airPlaySampledAt: sample).difference)
        }
        for position in [nil, Double.nan, Double.infinity, -1] as [Double?] {
            XCTAssertNil(assess(airPlayPosition: position).target)
        }
        XCTAssertNil(assess(airPlayPlaying: false).target)
        XCTAssertNil(assess(now: .infinity).target)
        XCTAssertNotNil(assess(airPlaySampledAt: 97).target, "Three seconds is the inclusive freshness limit")
    }

    func testMissingOrOutOfWindowSeekingRetainsDifferenceWithoutFabricatingTarget() {
        for ranges: [ClosedRange<Double>] in [[], [11...20], [0...9], [0...9, 11...20], [9.95...20], [0...10.05]] {
            let result = assess(ranges: ranges)
            XCTAssertNil(result.target)
            XCTAssertEqual(result.difference, 1)
        }
        XCTAssertEqual(assess(ranges: [0...2, 5...20]).target, 10)
        XCTAssertEqual(assess(ranges: [0...10.1]).target, 10)
        XCTAssertEqual(assess(ranges: [9.9...20]).target, 10)
    }

    func testInvalidOffsetsCannotProduceSeekTarget() {
        for offset in [Double.nan, Double.infinity, -Double.infinity, -5.01, 5.01] {
            XCTAssertNil(assess(offset: offset).target)
        }
    }
}
