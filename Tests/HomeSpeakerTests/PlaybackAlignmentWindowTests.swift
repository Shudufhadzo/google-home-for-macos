import XCTest
@testable import HomeSpeaker

final class PlaybackAlignmentWindowTests: XCTestCase {
    func testSongTailMustReachEveryOutputBeforeAnyCorrection() {
        var window = PlaybackAlignmentWindow()
        window.begin(at: 100, drainingThrough: 50)
        XCTAssertFalse(window.observe(positions: ["cast": 51, "tv": 48], sampleTimes: ["cast": 100, "tv": 100], expectedCount: 2, spread: 3, now: 100))
        XCTAssertFalse(window.canCorrect(at: 100), "Music finishing at the source does not mean the buffered TV song has finished")
        XCTAssertFalse(window.observe(positions: ["cast": 55, "tv": 51], sampleTimes: ["cast": 104, "tv": 104], expectedCount: 2, spread: 4, now: 104))
        XCTAssertTrue(window.canCorrect(at: 104))
    }

    func testTwoCorrectionsFinishTheGapAndCannotReopenDuringTheSong() {
        var window = PlaybackAlignmentWindow()
        window.begin(at: 100)
        window.corrected(at: 100)
        XCTAssertFalse(window.canCorrect(at: 103))
        window.corrected(at: 104)
        XCTAssertFalse(window.canCorrect(at: 108))
        XCTAssertTrue(window.observe(positions: ["cast": 30, "tv": 31], sampleTimes: ["cast": 108, "tv": 108], expectedCount: 2, spread: 1, now: 108))
        for second in 109..<400 { XCTAssertFalse(window.canCorrect(at: Double(second))) }
        window.begin(at: 400, drainingThrough: 300)
        XCTAssertFalse(window.canCorrect(at: 400))
    }

    func testStableDistinctTimingCanFinishWithoutSeekingAndMissingTimingIsBounded() {
        var window = PlaybackAlignmentWindow()
        window.begin(at: 100)
        for _ in 0..<20 { XCTAssertFalse(window.observe(positions: ["cast": 10, "tv": 10.05], sampleTimes: ["cast": 100, "tv": 100], expectedCount: 2, spread: 0.05, now: 100)) }
        XCTAssertFalse(window.observe(positions: ["cast": 11, "tv": 11.05], sampleTimes: ["cast": 101, "tv": 101], expectedCount: 2, spread: 0.05, now: 101))
        XCTAssertTrue(window.observe(positions: ["cast": 12, "tv": 12.05], sampleTimes: ["cast": 102, "tv": 102], expectedCount: 2, spread: 0.05, now: 102))
        window.begin(at: 200, drainingThrough: 100)
        XCTAssertFalse(window.observe(positions: ["cast": 105], sampleTimes: ["cast": 200], expectedCount: 2, spread: 0, now: 200))
        XCTAssertFalse(window.canCorrect(at: 244))
        XCTAssertTrue(window.observe(positions: [:], sampleTimes: [:], expectedCount: 2, spread: nil, now: 245))
        XCTAssertFalse(window.canCorrect(at: 245), "A stalled receiver must not turn a song-gap timeout into a mid-song seek")
    }

    func testStaleOrFutureTimingCannotSkipTheBufferedSongTail() {
        var window = PlaybackAlignmentWindow()
        window.begin(at: 100, drainingThrough: 50)
        XCTAssertFalse(window.observe(positions: ["cast": 60, "tv": 60], sampleTimes: ["cast": 96, "tv": 100], expectedCount: 2, spread: 0, now: 100))
        XCTAssertFalse(window.canCorrect(at: 100))
        XCTAssertFalse(window.observe(positions: ["cast": 60, "tv": 60], sampleTimes: ["cast": 101, "tv": 100], expectedCount: 2, spread: 0, now: 100))
        XCTAssertFalse(window.canCorrect(at: 100))
        XCTAssertFalse(window.observe(positions: ["cast": .nan, "tv": 60], sampleTimes: ["cast": 100, "tv": 100], expectedCount: 2, spread: 0, now: 100))
        XCTAssertFalse(window.canCorrect(at: 100))
    }
}
