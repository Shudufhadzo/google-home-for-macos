import Foundation

/// The advertised live window cannot grow with the length of a casting session.
struct LiveAudioPlaylist {
    struct Segment { let number: Int; let duration: Double; let data: Data }
    private(set) var segments: [Segment] = []
    private var nextNumber = 0
    var initialization: Data?
    let windowCount = 6
    let retainedCount = 20

    mutating func append(_ data: Data, duration: Double) {
        segments.append(Segment(number: nextNumber, duration: duration, data: data))
        nextNumber += 1
        if segments.count > retainedCount { segments.removeFirst(segments.count - retainedCount) }
    }

    var isReady: Bool { initialization != nil && segments.count >= 3 }

    var manifest: Data {
        let window = segments.suffix(windowCount)
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:1",
                     "#EXT-X-MEDIA-SEQUENCE:\(window.first?.number ?? 0)",
                     "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"init.mp4\""]
        // Three half-second segments behind the edge, instead of an unbounded WAV prebuffer.
        lines.append("#EXT-X-START:TIME-OFFSET=-1.5,PRECISE=YES")
        for segment in window {
            lines.append(String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), segment.duration))
            lines.append("\(segment.number).m4s")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
