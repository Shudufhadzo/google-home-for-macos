import XCTest
@testable import HomeSpeaker

final class LowLatencyStreamTests: XCTestCase {
    func testCastSelectsSegmentedLiveAudioInsteadOfContinuousWave() {
        let url = URL(string: "http://192.0.2.1:8000/session/live.m3u8")!
        let media = CastNowPlaying.macAudio.media(at: url)
        XCTAssertEqual(media["contentType"] as? String, "application/x-mpegURL")
        XCTAssertEqual(media["hlsSegmentFormat"] as? String, "fmp4")
    }
}
