import Foundation

struct CastNowPlaying: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?

    static let macAudio = CastNowPlaying(id: "mac", title: "Mac audio", artist: "", album: "", artworkURL: nil)

    func streamURL(at url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = (components.queryItems ?? []).filter { $0.name != "track" }
        items.append(URLQueryItem(name: "track", value: id))
        components.queryItems = items
        return components.url!
    }

    func media(at url: URL) -> [String: Any] {
        var metadata: [String: Any] = ["metadataType": 3, "title": title, "artist": artist, "albumName": album]
        if let artworkURL { metadata["images"] = [["url": artworkURL.absoluteString]] }
        return ["contentId": streamURL(at: url).absoluteString, "contentType": "audio/wav", "streamType": "LIVE", "metadata": metadata]
    }
}
