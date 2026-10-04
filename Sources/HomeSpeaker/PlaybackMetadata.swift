import AppKit
import AVFoundation
import MediaPlayer

/// Public macOS metadata APIs. AVPlayerItem.externalMetadata is not available on macOS.
struct PlaybackMetadata {
    let title: String
    let artist: String
    let album: String
    let artwork: Data?

    static let macAudio = PlaybackMetadata(title: "Mac audio", artist: "Home Manager", album: "", artwork: nil)

    var assetMetadata: [AVMetadataItem] {
        var result = [(AVMetadataIdentifier.commonIdentifierTitle, title),
                      (.commonIdentifierArtist, artist), (.commonIdentifierAlbumName, album)]
            .filter { !$0.1.isEmpty }.map { identifier, value -> AVMetadataItem in
                let item = AVMutableMetadataItem()
                item.identifier = identifier
                item.value = value as NSString
                item.extendedLanguageTag = "und"
                return item.copy() as! AVMetadataItem
            }
        if let artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.dataType = kCMMetadataBaseDataType_JPEG as String
            item.value = artwork as NSData
            result.append(item.copy() as! AVMetadataItem)
        }
        return result
    }

    var nowPlayingInfo: [String: Any] {
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist,
                                  MPMediaItemPropertyAlbumTitle: album, MPNowPlayingInfoPropertyIsLiveStream: true,
                                  MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let artwork, let image = NSImage(data: artwork) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        return info
    }
}
