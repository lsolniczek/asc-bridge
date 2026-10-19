import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(red: 0.22, green: 0.52, blue: 0.98, alpha: 1),
           ending: NSColor(red: 0.10, green: 0.26, blue: 0.74, alpha: 1))!.draw(in: background, angle: -90)
// Original geometric bridge artwork, distributed under the project's MIT license.
// App icons must not embed SF Symbols; this uses only our own drawing paths.
NSColor.white.setFill()
for x in [286.0, 680.0] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 310, width: 58, height: 400),
                 xRadius: 22, yRadius: 22).fill()
}
NSBezierPath(roundedRect: NSRect(x: 210, y: 408, width: 604, height: 56),
             xRadius: 26, yRadius: 26).fill()

let cable = NSBezierPath()
cable.move(to: NSPoint(x: 315, y: 670))
cable.curve(to: NSPoint(x: 709, y: 670),
            controlPoint1: NSPoint(x: 420, y: 450), controlPoint2: NSPoint(x: 604, y: 450))
cable.lineWidth = 26
cable.lineCapStyle = .round
NSColor.white.setStroke()
cable.stroke()

for (x, top) in [(390.0, 557.0), (512.0, 505.0), (634.0, 557.0)] {
    NSBezierPath(roundedRect: NSRect(x: x - 10, y: 450, width: 20, height: top - 450),
                 xRadius: 10, yRadius: 10).fill()
}
NSColor(red: 1, green: 0.72, blue: 0.32, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 479, y: 403, width: 66, height: 66)).fill()
image.unlockFocus()

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

