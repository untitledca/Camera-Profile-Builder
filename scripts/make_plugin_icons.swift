import AppKit
import Foundation

// Render exact pixel sizes, independent of the display's Retina scale.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make_plugin_icons.swift OUTPUT_DIRECTORY\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func cameraGlyph(in rect: NSRect, color: NSColor) {
    let unit = min(rect.width, rect.height)
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: rect.minX + unit * x, y: rect.minY + unit * y, width: unit * w, height: unit * h)
    }
    color.setFill()
    NSBezierPath(roundedRect: box(0.31, 0.67, 0.28, 0.13), xRadius: unit * 0.035, yRadius: unit * 0.035).fill()
    let body = NSBezierPath(roundedRect: box(0.10, 0.20, 0.80, 0.52), xRadius: unit * 0.095, yRadius: unit * 0.095)
    body.appendOval(in: box(0.345, 0.305, 0.31, 0.31))
    body.windingRule = .evenOdd
    body.fill()
}

func dialGlyph(in rect: NSRect) {
    let unit = min(rect.width, rect.height)
    let center = NSPoint(x: rect.midX, y: rect.midY)
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - unit * 0.275, y: center.y - unit * 0.275,
                                         width: unit * 0.55, height: unit * 0.55))
    ring.lineWidth = unit * 0.09
    ring.stroke()
    let pointer = NSBezierPath()
    pointer.lineCapStyle = .round
    pointer.lineWidth = unit * 0.09
    pointer.move(to: center)
    pointer.line(to: NSPoint(x: center.x + unit * 0.12, y: center.y + unit * 0.12))
    pointer.stroke()
    for degrees: CGFloat in [0, 45, 90, 135, 180, 225, 270, 315] {
        let angle = degrees * .pi / 180
        let tick = NSBezierPath()
        tick.lineCapStyle = .round
        tick.lineWidth = unit * 0.065
        tick.move(to: NSPoint(x: center.x + cos(angle) * unit * 0.39, y: center.y + sin(angle) * unit * 0.39))
        tick.line(to: NSPoint(x: center.x + cos(angle) * unit * 0.45, y: center.y + sin(angle) * unit * 0.45))
        tick.stroke()
    }
}

func render(_ filename: String, pixels: Int, draw: (NSRect) -> Void) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CameraPluginIcons", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create a PNG rendering context."])
    }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.shouldAntialias = true
    graphics.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.setFill()
    rect.fill(using: .copy)
    draw(rect)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CameraPluginIcons", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode the PNG icon."])
    }
    try data.write(to: output.appendingPathComponent(filename), options: .atomic)
}

for (filename, size) in [("plugin.png", 256), ("plugin@2x.png", 512)] {
    try render(filename, pixels: size) { rect in
        let s = rect.width
        NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.04, dy: s * 0.04), xRadius: s * 0.20, yRadius: s * 0.20).fill()
        cameraGlyph(in: rect.insetBy(dx: s * 0.13, dy: s * 0.13),
                    color: NSColor(calibratedRed: 0.25, green: 0.88, blue: 0.76, alpha: 1))
        NSColor.white.withAlphaComponent(0.9).setFill()
        for offset: CGFloat in [0.29, 0.43, 0.57, 0.71] {
            NSBezierPath(ovalIn: NSRect(x: s * (offset - 0.018), y: s * 0.16, width: s * 0.036, height: s * 0.036)).fill()
        }
    }
}
for (filename, size) in [("category.png", 28), ("category@2x.png", 56),
                         ("button.png", 20), ("button@2x.png", 40)] {
    try render(filename, pixels: size) { rect in cameraGlyph(in: rect, color: .white) }
}
for (filename, size) in [("dial.png", 20), ("dial@2x.png", 40)] {
    try render(filename, pixels: size) { rect in dialGlyph(in: rect) }
}
print("Generated Stream Deck plugin, category and action icons in \(output.path)")
