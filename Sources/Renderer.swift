import AppKit

/// Draws one visualizer frame into a small pixel grid (e.g. 666 × 20) that views scale up crisply.
/// The Touch Bar and the settings preview show the same image, so the preview is exact.
final class PixelRenderer {
    var logicalSize = NSSize(width: 1000, height: 30)
    private(set) var image: CGImage?

    private let settings: Settings
    private var cols = 0, rows = 0
    private var canvas: [RGB] = []
    private var heat: [Float] = []
    private var peaks: [Float] = []
    private var stars: [Star] = []
    private var sparks: [Spark] = []
    private var flash: Float = 0
    private var time: Float = 0
    private var lastStyle: VisualStyle?

    private struct Star { var x, y, direction, speed, hue: Float }
    private struct Spark { var x, y, vx, vy, life, hue: Float }

    init(settings: Settings) {
        self.settings = settings
    }

    func advance(_ frame: AudioFrame) {
        let cell = CGFloat(settings.pixelSize)
        let newCols = max(8, Int(logicalSize.width / cell))
        let newRows = max(3, Int((logicalSize.height / cell).rounded()))
        if newCols != cols || newRows != rows || lastStyle != settings.style {
            reset(cols: newCols, rows: newRows)
        }

        time += Float(settings.speed) / 60
        if frame.beat { flash = 1 }
        fade(Float(settings.afterglow))

        let theme = settings.theme
        switch settings.style {
        case .bars: drawBars(frame, theme)
        case .wave: drawWave(frame, theme)
        case .fire: drawFire(frame, theme)
        case .stars: drawStars(frame, theme)
        case .plasma: drawPlasma(frame, theme)
        }
        drawSparks(theme)
        flash *= 0.86
        image = makeImage(brightness: Float(settings.brightness))
    }

    /// `point` is in 0...1 on both axes, origin bottom-left.
    func spawnSparks(at point: CGPoint, count: Int) {
        let x = Float(point.x) * Float(cols), y = Float(point.y) * Float(rows)
        for _ in 0..<count {
            sparks.append(Spark(x: x, y: y, vx: .random(in: -1.6...1.6), vy: .random(in: -0.3...0.9),
                                life: 1, hue: .random(in: 0...1)))
        }
        if sparks.count > 400 { sparks.removeFirst(sparks.count - 400) }
    }

    // MARK: Styles

    private func drawBars(_ frame: AudioFrame, _ theme: Theme) {
        let step = max(2, cols / 160)
        let barWidth = step - 1
        let count = cols / step
        if peaks.count != count { peaks = [Float](repeating: 0, count: count) }
        if flash > 0.05 { fillAll(theme.color(0) * (flash * 0.12)) }

        let offset = (cols - count * step + 1) / 2
        for i in 0..<count {
            let height = sample(frame.bands, at: position(i, of: count)) * Float(rows)
            peaks[i] = max(height, peaks[i] - 0.12)
            let x0 = offset + i * step
            for y in 0..<rows {
                let lit = min(max(height - Float(y), 0), 1)
                guard lit > 0 else { break }
                let color = theme.color(Float(y) / Float(rows - 1)) * lit
                for dx in 0..<barWidth { put(x0 + dx, y, color) }
            }
            if settings.peaks, peaks[i] >= 1 {
                let y = min(Int(peaks[i]), rows - 1)
                for dx in 0..<barWidth { put(x0 + dx, y, RGB(repeating: 0.9)) }
            }
        }
    }

    private func drawWave(_ frame: AudioFrame, _ theme: Theme) {
        let center = Float(rows - 1) / 2
        let amplitude = Float(rows) / 2 - 0.5
        let chunk = max(1, frame.wave.count / cols)
        var previous: Int?

        for x in 0..<cols {
            // Average (or envelope) a few samples per column to smooth out jitter.
            let start = x * frame.wave.count / cols
            var sum: Float = 0, envelope: Float = 0
            for i in start..<min(start + chunk, frame.wave.count) {
                sum += frame.wave[i]
                envelope = max(envelope, abs(frame.wave[i]))
            }
            let value = sum / Float(chunk)
            let color = theme.color(0.5 + 0.5 * sin(time * 0.9 + Float(x) * 0.012))

            switch settings.waveShape {
            case .line:
                let y = clampRow(Int((center + value * amplitude).rounded()))
                let low = min(previous ?? y, y), high = max(previous ?? y, y)
                for row in low...high { add(x, row, color) }
                add(x, low - 1, color * 0.3)
                add(x, high + 1, color * 0.3)
                previous = y
            case .filled:
                let y = clampRow(Int((center + value * amplitude).rounded()))
                let middle = Int(center.rounded())
                for row in min(middle, y)...max(middle, y) {
                    let strength = 0.35 + 0.65 * abs(Float(row) - center) / max(amplitude, 1)
                    put(x, row, color * strength)
                }
            case .mirrored:
                let reach = envelope * amplitude
                for row in 0..<rows {
                    let distance = abs(Float(row) - center)
                    guard distance <= reach + 0.5 else { continue }
                    put(x, row, theme.color(distance / max(amplitude, 1)) * (1 - distance / (amplitude + 2) * 0.5))
                }
            }
        }
    }

    private func drawFire(_ frame: AudioFrame, _ theme: Theme) {
        let height = rows + 1
        if heat.count != cols * height { heat = [Float](repeating: 0, count: cols * height) }

        // Hidden bottom row feeds the flames; louder bands burn hotter.
        for x in 0..<cols {
            let energy = sample(frame.bands, at: position(x, of: cols))
            heat[x] = min(1.2, energy * 1.15 + flash * 0.25 + .random(in: -0.15...0.1))
        }
        let cooling = 1.5 / Float(rows)
        for y in stride(from: height - 1, through: 1, by: -1) {
            let below = (y - 1) * cols
            for x in 0..<cols {
                let left = heat[below + max(x - 1, 0)], middle = heat[below + x]
                let right = heat[below + min(x + 1, cols - 1)]
                heat[y * cols + x] = max(0, (left + middle * 2 + right) / 4 - .random(in: 0...cooling))
            }
        }
        for y in 0..<rows {
            for x in 0..<cols { put(x, y, theme.fire(heat[(y + 1) * cols + x])) }
        }
    }

    private func drawStars(_ frame: AudioFrame, _ theme: Theme) {
        if flash > 0.05 { fillAll(theme.color(0.15) * (flash * 0.2)) }
        let boost = (0.35 + frame.level * 4 + flash * 3) * Float(settings.speed)
        let middle = Float(cols) / 2
        let spread = Float(cols) * 0.04

        while stars.count < 220 {
            stars.append(Star(x: middle + .random(in: -spread...spread), y: .random(in: 0...Float(rows - 1)),
                              direction: Bool.random() ? 1 : -1, speed: .random(in: 0.15...1), hue: .random(in: 0...1)))
        }
        for i in stars.indices.reversed() {
            var star = stars[i]
            let distance = abs(star.x - middle) / middle
            let velocity = star.speed * boost * (0.4 + distance * 2.5)
            star.x += star.direction * velocity
            if star.x < 0 || star.x >= Float(cols) {
                stars.remove(at: i)
                continue
            }
            let color = (theme.color(star.hue) * 0.75 + RGB(repeating: 0.4)) * min(1.2, 0.55 + distance * 1.3)
            let trail = Int(min(14, velocity * 2.5))
            for k in 0...trail {
                add(Int(star.x) - Int(star.direction) * k, Int(star.y), color * (1 - Float(k) / Float(trail + 1)))
            }
            stars[i] = star
        }
    }

    private func drawPlasma(_ frame: AudioFrame, _ theme: Theme) {
        let aspect = Float(cols) / Float(rows)
        for x in 0..<cols {
            let energy = sample(frame.bands, at: position(x, of: cols))
            let px = Float(x) / Float(cols) * 66
            let glow = 0.3 + energy * 0.9 + flash * 0.25
            for y in 0..<rows {
                let py = Float(y) / Float(rows) * 2
                let dx = px - 33 - sin(time * 0.5) * 20, dy = (py - 1) * aspect * 0.06
                var v = sin(px * 0.35 + time * 1.3) + sin(py * 2.2 - time * 0.9)
                v += sin(px * 0.22 + py * 1.6 + time * 0.7) + sin(sqrt(dx * dx * 0.02 + dy * dy) + time)
                let t = (v + 4) / 8 + time * 0.03
                let wrapped = abs((t - t.rounded(.down)) * 2 - 1)  // ping-pong so colors never jump
                put(x, y, theme.color(wrapped) * glow)
            }
        }
    }

    private func drawSparks(_ theme: Theme) {
        for i in sparks.indices.reversed() {
            var spark = sparks[i]
            spark.x += spark.vx
            spark.y += spark.vy
            spark.vy -= 0.035
            spark.vx *= 0.97
            spark.life -= 0.022
            if spark.life <= 0 {
                sparks.remove(at: i)
                continue
            }
            add(Int(spark.x), Int(spark.y), (theme.color(spark.hue) + RGB(repeating: 0.5)) * spark.life)
            sparks[i] = spark
        }
    }

    // MARK: Pixel helpers (y = 0 is the bottom row)

    private func reset(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        canvas = [RGB](repeating: .zero, count: cols * rows)
        heat = []
        peaks = []
        stars = []
        lastStyle = settings.style
    }

    /// Where item `i` sits on the frequency axis: bass on the left, or in the middle when mirrored.
    private func position(_ i: Int, of count: Int) -> Float {
        let t = Float(i) / Float(max(count - 1, 1))
        return settings.mirror && settings.style.usesMirror ? abs(t * 2 - 1) : t
    }

    private func sample(_ values: [Float], at t: Float) -> Float {
        let position = min(max(t, 0), 1) * Float(values.count - 1)
        let index = min(Int(position), values.count - 2)
        let fraction = position - Float(index)
        return values[index] * (1 - fraction) + values[index + 1] * fraction
    }

    private func clampRow(_ y: Int) -> Int { min(max(y, 0), rows - 1) }

    @inline(__always) private func index(_ x: Int, _ y: Int) -> Int { (rows - 1 - y) * cols + x }

    private func put(_ x: Int, _ y: Int, _ color: RGB) {
        guard x >= 0, x < cols, y >= 0, y < rows else { return }
        let i = index(x, y)
        canvas[i] = pointwiseMax(canvas[i], color)
    }

    private func add(_ x: Int, _ y: Int, _ color: RGB) {
        guard x >= 0, x < cols, y >= 0, y < rows else { return }
        canvas[index(x, y)] += color
    }

    private func fade(_ amount: Float) {
        for i in canvas.indices { canvas[i] *= amount }
    }

    private func fillAll(_ color: RGB) {
        for i in canvas.indices { canvas[i] = pointwiseMax(canvas[i], color) }
    }

    private func makeImage(brightness: Float) -> CGImage? {
        var pixels = [UInt32](repeating: 0, count: canvas.count)
        for i in canvas.indices {
            let c = pointwiseMin(pointwiseMax(canvas[i] * brightness, .zero), RGB(repeating: 1)) * 255
            pixels[i] = 0xFF00_0000 | UInt32(c.x) << 16 | UInt32(c.y) << 8 | UInt32(c.z)
        }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
