import AppKit

@MainActor
enum IconRenderer {
    static func write(to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "ClipDune.Icon", code: 1)
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.035, green: 0.19, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 216, yRadius: 216).fill()
        NSColor(calibratedRed: 0.1, green: 0.43, blue: 0.43, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 215, y: 315, width: 556, height: 490), xRadius: 70, yRadius: 70).fill()
        NSColor(calibratedRed: 0.32, green: 0.66, blue: 0.61, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 170, y: 240, width: 595, height: 490), xRadius: 70, yRadius: 70).fill()
        NSColor(calibratedRed: 0.99, green: 0.94, blue: 0.81, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 245, y: 155, width: 590, height: 495), xRadius: 70, yRadius: 70).fill()
        NSColor(calibratedRed: 0.04, green: 0.34, blue: 0.35, alpha: 1).setFill()
        for (offset, width) in [(0, 330), (85, 245), (170, 300)] {
            NSBezierPath(roundedRect: NSRect(x: 335, y: 490 - offset, width: width, height: 30), xRadius: 15, yRadius: 15).fill()
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClipDune.Icon", code: 2)
        }
        try data.write(to: url)
    }
}
