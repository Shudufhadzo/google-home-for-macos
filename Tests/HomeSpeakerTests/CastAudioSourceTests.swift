import CoreAudio
import XCTest
@testable import HomeSpeaker

final class CastAudioSourceTests: XCTestCase {
    func testSystemCaptureExcludesTheAppsOwnPlaybackToPreventAirPlayFeedback() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Bundle-based tap exclusions require macOS 26") }
        let tap = try CastAudioSource.system.tapDescription()
        XCTAssertTrue(tap.isExclusive)
        XCTAssertTrue(tap.bundleIDs.contains(Bundle.main.bundleIdentifier ?? "za.shudu.homespeaker"))
        XCTAssertTrue(tap.isProcessRestoreEnabled)
        XCTAssertEqual(tap.muteBehavior, .mutedWhenTapped)
    }

    func testMusicCaptureRemainsRestrictedToTheSourceApp() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Bundle-based tap selection requires macOS 26") }
        let tap = try CastAudioSource.appleMusic.tapDescription()
        XCTAssertFalse(tap.isExclusive)
        XCTAssertEqual(tap.bundleIDs, ["com.apple.Music"])
        XCTAssertEqual(tap.muteBehavior, .mutedWhenTapped)
    }
}
