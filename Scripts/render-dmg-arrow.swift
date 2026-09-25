import AppKit
import Foundation

let width = 220
let height = 160
guard let image = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: image) else {
    fatalError("Could not create the DMG arrow")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: 2, y: 2)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let blue = NSColor(deviceRed: 0.15, green: 0.40, blue: 0.88, alpha: 1)
let text = NSAttributedString(string: "DRAG", attributes: [
    .font: NSFont.systemFont(ofSize: 22, weight: .bold),
    .foregroundColor: NSColor(deviceRed: 0.17, green: 0.32, blue: 0.58, alpha: 1)
])
text.draw(at: NSPoint(x: (CGFloat(width) - text.size().width) / 2, y: 108))

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 30, y: 72))
shaft.line(to: NSPoint(x: 173, y: 72))
blue.setStroke()
shaft.lineWidth = 11
shaft.lineCapStyle = .round
shaft.stroke()

let tip = NSBezierPath()
tip.move(to: NSPoint(x: 153, y: 46))
tip.line(to: NSPoint(x: 188, y: 72))
tip.line(to: NSPoint(x: 153, y: 98))
tip.lineWidth = 11
tip.lineCapStyle = .round
tip.lineJoinStyle = .round
tip.stroke()
NSGraphicsContext.restoreGraphicsState()

guard let png = image.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the DMG arrow")
}
let destination = CommandLine.arguments.dropFirst().first ?? "Resources/DMGDragArrow.png"
try png.write(to: URL(fileURLWithPath: destination))
