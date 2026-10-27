// Draws the BeatBar icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // Body.
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    color(0x0C0A1E).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x241A4F), color(0x0E0B24), color(0x05040F)])!.draw(in: body, angle: -90)

    // Mirrored pixel equalizer: tall in the middle, short at the edges.
    let heights = [3, 5, 8, 6, 11, 9, 13, 9, 11, 6, 8, 5, 3]
    let pixel: CGFloat = 34, gap: CGFloat = 8, step = pixel + gap
    let totalWidth = CGFloat(heights.count) * step - gap
    let left = (1024 - totalWidth) / 2, baseline: CGFloat = 512 - 6.5 * step
    let neon = NSGradient(colors: [color(0x00D9FF), color(0xF233F2), color(0xFFD9F2)])!

    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xC53CFF, 0.85)
    glow.shadowBlurRadius = 36 * s
    glow.set()
    for (column, height) in heights.enumerated() {
        for row in 0..<height {
            let t = CGFloat(row) / 12
            neon.interpolatedColor(atLocation: t).setFill()
            let x = left + CGFloat(column) * step, y = baseline + CGFloat(row) * step
            NSBezierPath(roundedRect: r(x, y, pixel, pixel), xRadius: 6 * s, yRadius: 6 * s).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    // Thin Touch Bar outline across the bottom.
    let strip = NSBezierPath(roundedRect: r(170, 168, 684, 40), xRadius: 14 * s, yRadius: 14 * s)
    color(0xFFFFFF, 0.08).setFill()
    strip.fill()
    color(0xFFFFFF, 0.25).setStroke()
    strip.lineWidth = 3 * s
    strip.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("BeatBarIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let png = drawIcon(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
