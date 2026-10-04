import XCTest
import AVFoundation
@testable import HomeSpeaker

final class AirPlayAudioPlayerTests: XCTestCase {
    @MainActor
    func testTrackTransitionRetainsPausedItemButFinalStopReleasesIt() {
        let subject = AirPlayAudioPlayer()
        let item = AVPlayerItem(asset: AVMutableComposition())
        subject.player.replaceCurrentItem(with: item)
        subject.suspendForReplacement()
        XCTAssertTrue(subject.player.currentItem === item)
        XCTAssertEqual(subject.player.rate, 0)
        XCTAssertEqual(subject.state, .preparing)
        XCTAssertFalse(subject.isReady)
        XCTAssertNil(subject.currentURL)
        XCTAssertNil(subject.currentTime)
        subject.stop()
        XCTAssertNil(subject.player.currentItem)
        XCTAssertEqual(subject.state, .idle)
    }

    @MainActor
    func testPreparingReplacementDoesNotDetachCurrentItemFirst() {
        let subject = AirPlayAudioPlayer()
        subject.player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        var detachedItem = false
        let observation = subject.player.observe(\.currentItem, options: [.new]) { player, _ in
            if player.currentItem == nil { detachedItem = true }
        }
        // This deliberately missing local file cannot issue a network request or play audio.
        let url = URL(fileURLWithPath: "/private/tmp/home-manager-missing-audio-\(UUID().uuidString).m3u8")
        subject.prepare(url: url)
        XCTAssertFalse(detachedItem)
        XCTAssertNotNil(subject.player.currentItem)
        XCTAssertEqual(subject.currentURL, url)
        observation.invalidate()
        subject.stop()
    }

    @MainActor
    func testSeekKeepsValidPositionAndClampsToAvailableLiveWindow() throws {
        XCTAssertEqual(AirPlayAudioPlayer.clampedPosition(12, in: [10...20]), 12)
        XCTAssertEqual(AirPlayAudioPlayer.clampedPosition(0, in: [10...20]), 10)
        XCTAssertEqual(try XCTUnwrap(AirPlayAudioPlayer.clampedPosition(30, in: [10...20])), 19.95, accuracy: 0.0001)
    }

    @MainActor
    func testSeekChoosesAnActualRangeInsteadOfSeekingIntoDiscontinuityGap() throws {
        XCTAssertEqual(AirPlayAudioPlayer.clampedPosition(10, in: [0...8, 12...20]), 12)
        XCTAssertEqual(try XCTUnwrap(AirPlayAudioPlayer.clampedPosition(9, in: [0...8, 12...20])), 7.95, accuracy: 0.0001)
        XCTAssertEqual(AirPlayAudioPlayer.clampedPosition(15, in: [0...8, 12...20]), 15)
    }

    @MainActor
    func testSeekRejectsMissingUnusableOrNonfiniteWindowsAndTargets() {
        XCTAssertNil(AirPlayAudioPlayer.clampedPosition(10, in: []))
        XCTAssertNil(AirPlayAudioPlayer.clampedPosition(10, in: [5...5, 5...5.05]))
        XCTAssertNil(AirPlayAudioPlayer.clampedPosition(10, in: [-Double.infinity...20, 0...Double.infinity]))
        XCTAssertNil(AirPlayAudioPlayer.clampedPosition(10, in: [-5...20]))
        for target in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(AirPlayAudioPlayer.clampedPosition(target, in: [0...20]))
        }
        XCTAssertEqual(AirPlayAudioPlayer.clampedPosition(10, in: [-5...20, 8...15]), 10)
    }
}
