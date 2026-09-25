import AppKit
import Foundation

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconURL = project.appendingPathComponent("Resources/HomeSpeakerIconSource.png")
let outputURL = project.appendingPathComponent("Resources/HomeSpeakerLogo.png")

guard let icon = NSImage(contentsOf: iconURL),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 360,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create the logo canvas")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1600, height: 360).fill()
icon.draw(in: NSRect(x: 28, y: 24, width: 312, height: 312),
          from: .zero, operation: .sourceOver, fraction: 1)

let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 118, weight: .bold),
    .foregroundColor: NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.29, alpha: 1),
    .kern: -2.5
]
("Home Speaker" as NSString).draw(at: NSPoint(x: 376, y: 116), withAttributes: attributes)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the logo")
}
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
