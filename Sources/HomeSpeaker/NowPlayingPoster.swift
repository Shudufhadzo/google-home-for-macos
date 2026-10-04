import AppKit
import CoreVideo

/// A real video frame lets audio-only AirPlay TVs show covers even when they
/// ignore Now Playing metadata. It is carried only by the TV rendition.
enum NowPlayingPoster {
    static let width = 1280, height = 720

    static func make(metadata: PlaybackMetadata) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw failure("Cannot allocate TV artwork frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw failure("Cannot draw TV artwork frame")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.075, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        let cover = CGRect(x: 80, y: 160, width: 400, height: 400)
        NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: cover, xRadius: 18, yRadius: 18).fill()
        if let data = metadata.artwork, let image = NSImage(data: data) {
            image.draw(in: cover, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            draw("♫", in: CGRect(x: 170, y: 255, width: 220, height: 200), size: 160, weight: .regular, color: .white)
        }
        draw("HOME MANAGER", in: CGRect(x: 540, y: 590, width: 650, height: 42), size: 22, weight: .semibold, color: .lightGray)
        draw(metadata.title, in: CGRect(x: 540, y: 380, width: 660, height: 175), size: 50, weight: .bold, color: .white)
        draw(metadata.artist, in: CGRect(x: 540, y: 265, width: 660, height: 95), size: 29, weight: .medium, color: .white)
        draw(metadata.album, in: CGRect(x: 540, y: 160, width: 660, height: 80), size: 25, weight: .regular, color: .lightGray)
        return buffer
    }

    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "HomeSpeaker.TVArtwork", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
