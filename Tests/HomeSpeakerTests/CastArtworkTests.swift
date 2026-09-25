import XCTest
@testable import HomeSpeaker

final class CastArtworkTests: XCTestCase {
    func testPhoneCastArtworkIsReadAndClearedAtSongBoundaries() {
        var status = CastStatus()
        status.updateMediaInfo(["contentId": "first", "metadata": [
            "title": "Phone song", "artist": "Artist",
            "images": [["url": "https://example.com/first.jpg"]]
        ]])
        XCTAssertEqual(status.title, "Phone song")
        XCTAssertEqual(status.artworkURL?.absoluteString, "https://example.com/first.jpg")
        status.updateMediaInfo(["contentId": "first", "duration": 240])
        XCTAssertNotNil(status.artworkURL, "A partial update for the same song must retain its cover")
        status.updateMediaInfo(["contentId": "second"])
        XCTAssertNil(status.artworkURL, "A new song must not show the previous song's cover")
        XCTAssertEqual(status.title, "")
        status.updateMediaInfo(["metadata": ["title": "Second song", "images": [["url": "http://speaker.local/cover.jpg"]]]])
        XCTAssertEqual(status.artworkURL?.host, "speaker.local")
        status.updateMediaInfo(["metadata": ["title": "No artwork"]])
        XCTAssertNil(status.artworkURL)
    }

    func testArtworkOnlyAcceptsNetworkImageURLs() {
        var status = CastStatus()
        status.updateMediaInfo(["metadata": ["images": [
            ["url": "file:///private/cover.jpg"], ["url": "data:image/png;base64,AAAA"],
            ["url": "https://example.com/cover.jpg"]
        ]]])
        XCTAssertEqual(status.artworkURL?.absoluteString, "https://example.com/cover.jpg")
    }
}
