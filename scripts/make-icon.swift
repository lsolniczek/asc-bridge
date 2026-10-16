import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(red: 0.22, green: 0.52, blue: 0.98, alpha: 1),
           ending: NSColor(red: 0.10, green: 0.26, blue: 0.74, alpha: 1))!.draw(in: background, angle: -90)
let symbol = NSImage(systemSymbolName: "link", accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: 500, weight: .medium))!
let whiteSymbol = NSImage(size: symbol.size)
whiteSymbol.lockFocus()
symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.setFill()
NSRect(origin: .zero, size: symbol.size).fill(using: .sourceIn)
whiteSymbol.unlockFocus()
whiteSymbol.draw(in: NSRect(x: 252, y: 272, width: 520, height: 480))
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

