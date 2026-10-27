import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `BeatBar --demo <folder>` renders each style (with simulated music) to GIFs and an overview PNG.
enum Demo {
    private struct Scene {
        let file: String
        let title: String
        let configure: (Settings) -> Void
    }

    private static let scenes: [Scene] = [
        Scene(file: "bars", title: "Bars · Neon") { $0.style = .bars; $0.themeID = "neon" },
        Scene(file: "wave", title: "Wave · Candy") { $0.style = .wave; $0.themeID = "candy"; $0.afterglow = 0.55 },
        Scene(file: "wave-mirrored", title: "Wave, mirrored · Ocean") {
            $0.style = .wave; $0.waveShape = .mirrored; $0.themeID = "ocean"
        },
        Scene(file: "fire", title: "Fire · Lava") { $0.style = .fire; $0.themeID = "lava" },
        Scene(file: "stars", title: "Stars · Neon") { $0.style = .stars; $0.themeID = "neon"; $0.afterglow = 0.45 },
        Scene(file: "plasma", title: "Plasma · Rainbow") { $0.style = .plasma; $0.themeID = "rainbow" },
        Scene(file: "bars-huge", title: "Bars · Matrix · Huge pixels") {
            $0.style = .bars; $0.themeID = "matrix"; $0.pixelSize = 5; $0.mirror = false
        },
    ]

    static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var stills: [(String, CGImage)] = []

        for scene in scenes {
            let suite = "dev.beatbar.demo"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let settings = Settings(defaults: defaults)
            scene.configure(settings)

            let renderer = PixelRenderer(settings: settings)
            let ambient = AmbientGenerator()
            let view = PixelDisplayView(frame: NSRect(x: 0, y: 0, width: 1000, height: 30))
            view.ledGrid = settings.ledGrid
            view.cellSize = CGFloat(settings.pixelSize)

            var frames: [CGImage] = []
            for tick in 0..<240 {
                if scene.file == "bars", tick > 140, tick % 12 == 0 {
                    renderer.spawnSparks(at: CGPoint(x: 0.15 + Double(tick - 140) / 180, y: 0.6), count: 8)
                }
                renderer.advance(ambient.frame(speed: Float(settings.speed)))
                if tick >= 120, tick % 2 == 0 {
                    view.image = renderer.image
                    frames.append(snapshot(view))
                }
            }
            writeGIF(frames, to: outputDirectory.appendingPathComponent("\(scene.file).gif"))
            stills.append((scene.title, frames[frames.count * 2 / 3]))
            defaults.removePersistentDomain(forName: suite)
            print("Rendered \(scene.file).gif")
        }
        writeOverview(stills, to: outputDirectory.appendingPathComponent("overview.png"))
        print("Rendered overview.png")
    }

    private static func snapshot(_ view: NSView) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 60, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage!
    }

    private static func writeGIF(_ frames: [CGImage], to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                                frames.count, nil) else { return }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary
        CGImageDestinationSetProperties(destination, loop)
        for frame in frames { CGImageDestinationAddImage(destination, frame, delay) }
        CGImageDestinationFinalize(destination)
    }

    private static func writeOverview(_ stills: [(String, CGImage)], to url: URL) {
        let width = 2080, rowHeight = 130
        let height = stills.count * rowHeight + 30
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.07, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ]
        for (index, still) in stills.enumerated() {
            let top = CGFloat(height - 30 - index * rowHeight)
            NSAttributedString(string: still.0, attributes: attributes).draw(at: NSPoint(x: 40, y: top - 34))
            let strip = NSRect(x: 40, y: top - 108, width: 2000, height: 60)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: strip, xRadius: 10, yRadius: 10).addClip()
            NSGraphicsContext.current?.cgContext.draw(still.1, in: strip)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
