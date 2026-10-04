import AVFoundation
import MediaPlayer
import XCTest
@testable import HomeSpeaker

final class PlaybackMetadataTests: XCTestCase {
    func testAirPlayMetadataContainsTitleArtistAlbumAndIndependentArtwork() throws {
        let subject = PlaybackMetadata(title: "Song", artist: "Artist", album: "Album", artwork: Data([1, 2, 3]))
        let values = Dictionary(uniqueKeysWithValues: subject.assetMetadata.map { ($0.identifier!, $0) })
        XCTAssertEqual(values[.commonIdentifierTitle]?.stringValue, "Song")
        XCTAssertEqual(values[.commonIdentifierArtist]?.stringValue, "Artist")
        XCTAssertEqual(values[.commonIdentifierAlbumName]?.stringValue, "Album")
        XCTAssertEqual(values[.commonIdentifierArtwork]?.dataValue, Data([1, 2, 3]))
        XCTAssertEqual(subject.nowPlayingInfo[MPMediaItemPropertyTitle] as? String, "Song")
        let next = PlaybackMetadata.macAudio
        XCTAssertNil(next.nowPlayingInfo[MPMediaItemPropertyArtwork], "Track changes must not retain a previous song's cover")
        XCTAssertFalse(next.assetMetadata.contains { $0.identifier == .commonIdentifierArtwork })
    }
}
