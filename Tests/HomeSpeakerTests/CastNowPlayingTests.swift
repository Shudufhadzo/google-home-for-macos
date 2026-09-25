import XCTest
@testable import HomeSpeaker

final class CastNowPlayingTests: XCTestCase {
    func testSongMetadataKeepsTheLiveAudioURLAndUsesMusicFields() throws {
        let stream = URL(string: "http://192.0.2.1:8000/session.wav")!
        let artwork = stream.appendingPathExtension("jpg")
        let song = CastNowPlaying(id: "track-one", title: "Song", artist: "Artist", album: "Album", artworkURL: artwork)
        let media = song.media(at: stream)
        XCTAssertEqual(media["contentId"] as? String, song.streamURL(at: stream).absoluteString)
        XCTAssertEqual(media["streamType"] as? String, "LIVE")
        let metadata = try XCTUnwrap(media["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["metadataType"] as? Int, 3)
        XCTAssertEqual(metadata["title"] as? String, "Song")
        XCTAssertEqual(metadata["artist"] as? String, "Artist")
        XCTAssertEqual(metadata["albumName"] as? String, "Album")
        XCTAssertEqual((metadata["images"] as? [[String: String]])?.first?["url"], artwork.absoluteString)
        let nextSong = CastNowPlaying(id: "track-two", title: "Next", artist: "Artist", album: "Album", artworkURL: nil)
        XCTAssertNotEqual(nextSong.media(at: stream)["contentId"] as? String, song.media(at: stream)["contentId"] as? String,
                          "Each song has a distinct receiver identity")
    }
}
