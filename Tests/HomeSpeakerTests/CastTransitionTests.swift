import XCTest
@testable import HomeSpeaker

final class CastTransitionTests: XCTestCase {
    func testSongIdentityIsStableWhenAppliedTwice() {
        let metadata = CastNowPlaying(id: "artist/song & live", title: "Song", artist: "Artist", album: "Album", artworkURL: nil)
        let base = URL(string: "http://192.0.2.1:8000/session.wav")!
        let first = metadata.streamURL(at: base)
        XCTAssertEqual(metadata.streamURL(at: first), first)
        XCTAssertEqual(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, metadata.id)
    }

    func testNewSongHasNewReceiverContentIdentity() throws {
        let stream = URL(string: "http://192.0.2.1:8000/session.wav")!
        let first = CastNowPlaying(id: "one", title: "First", artist: "Artist", album: "Album", artworkURL: nil)
        let next = CastNowPlaying(id: "two", title: "Next", artist: "Artist", album: "Album", artworkURL: nil)
        XCTAssertNotEqual(first.media(at: stream)["contentId"] as? String,
                          next.media(at: stream)["contentId"] as? String,
                          "Google Home must receive a new media identity at a track boundary, not retain the first loaded title")
    }
}
