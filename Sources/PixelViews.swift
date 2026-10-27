import AppKit

/// Shows the renderer's tiny image scaled up with hard pixel edges, plus optional LED gaps.
class PixelDisplayView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var ledGrid = true { didSet { needsDisplay = true } }
    /// Part of the image to show (0...1 on each axis), for close-ups.
    var crop: CGRect?
    /// When set, each image pixel is drawn exactly this many points wide (centered) instead of
    /// stretching to fill, so every pixel lands on whole screen pixels. Used on the Touch Bar.
    var cellSize: CGFloat? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard var image, let context = NSGraphicsContext.current?.cgContext else { return }
        if let crop {
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let rect = CGRect(x: crop.minX * width, y: crop.minY * height,
                              width: crop.width * width, height: crop.height * height).integral
            if let cropped = image.cropping(to: rect) { image = cropped }
        }

        var target = bounds
        if let cellSize {
            let size = CGSize(width: CGFloat(image.width) * cellSize, height: CGFloat(image.height) * cellSize)
            target = CGRect(x: ((bounds.width - size.width) / 2).rounded(.down),
                            y: ((bounds.height - size.height) / 2).rounded(.down),
                            width: size.width, height: size.height)
        }
        context.interpolationQuality = .none
        context.draw(image, in: target)

        if ledGrid, let grid = gridImage(columns: image.width, rows: image.height, size: target.size) {
            context.draw(grid, in: target)
        }
    }

    private var cachedGrid: (key: [Int], image: CGImage?)?

    /// LED gaps as one transparent overlay, snapped to whole screen pixels and cached per size.
    /// None when pixels are too small to show gaps cleanly.
    private func gridImage(columns: Int, rows: Int, size: CGSize) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        let key = [columns, rows, width, height]
        if let cachedGrid, cachedGrid.key == key { return cachedGrid.image }

        let cellWidth = CGFloat(width) / CGFloat(columns), cellHeight = CGFloat(height) / CGFloat(rows)
        var image: CGImage?
        if min(cellWidth, cellHeight) >= 2.5,
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let line = max(1, (min(cellWidth, cellHeight) * 0.2).rounded())
            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            for column in 1..<columns {
                let x = (CGFloat(column) * cellWidth).rounded()
                context.fill(CGRect(x: x - line, y: 0, width: line, height: CGFloat(height)))
            }
            for row in 1..<rows {
                let y = (CGFloat(row) * cellHeight).rounded()
                context.fill(CGRect(x: 0, y: y - line, width: CGFloat(width), height: line))
            }
            image = context.makeImage()
        }
        cachedGrid = (key, image)
        return image
    }
}

/// The visualizer as it sits on the Touch Bar, with touch controls:
/// swipe = next style, tap = next colors, drag = sparks.
final class TouchBarVisualizerView: PixelDisplayView {
    var onVisibilityChange: (() -> Void)?
    var onSwipe: ((Int) -> Void)?
    var onTap: (() -> Void)?
    var onDrag: ((CGPoint, Int) -> Void)?
    private var touchStart: (x: CGFloat, time: TimeInterval)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 1000, height: 30) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onVisibilityChange?()
    }

    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .began, in: self).first else { return }
        let point = touch.location(in: self)
        touchStart = (point.x, event.timestamp)
        onDrag?(fraction(point), 10)
    }

    override func touchesMoved(with event: NSEvent) {
        for touch in event.touches(matching: .moved, in: self) {
            onDrag?(fraction(touch.location(in: self)), 3)
        }
    }

    override func touchesEnded(with event: NSEvent) {
        guard let touch = event.touches(matching: .ended, in: self).first, let start = touchStart else { return }
        touchStart = nil
        let distance = touch.location(in: self).x - start.x
        let duration = event.timestamp - start.time
        if abs(distance) > 60, duration < 0.4 {
            onSwipe?(distance < 0 ? 1 : -1)
        } else if abs(distance) < 12, duration < 0.3 {
            onTap?()
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        touchStart = nil
    }

    private func fraction(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1))
    }
}
