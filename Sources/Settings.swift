import AppKit
import SwiftUI

typealias RGB = SIMD3<Float>

enum VisualStyle: String, CaseIterable, Identifiable {
    case bars, wave, fire, stars, plasma
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .bars: "chart.bar.fill"
        case .wave: "waveform.path"
        case .fire: "flame.fill"
        case .stars: "sparkles"
        case .plasma: "circle.hexagongrid.fill"
        }
    }
    var usesMirror: Bool { self == .bars || self == .fire || self == .plasma }
}

enum Motion: String, CaseIterable, Identifiable {
    case music, ambient
    var id: String { rawValue }
    var title: String { self == .music ? "Music Sync" : "Constant Movement" }
}

enum WaveShape: String, CaseIterable, Identifiable {
    case line, filled, mirrored
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Theme: Identifiable {
    let id: String
    let name: String
    let stops: [RGB]

    static let customID = "custom"
    static let presets: [Theme] = [
        Theme(id: "neon", name: "Neon", stops: [RGB(0, 0.85, 1), RGB(0.95, 0.2, 0.95), RGB(1, 0.85, 0.95)]),
        Theme(id: "sunset", name: "Sunset", stops: [RGB(0.5, 0.1, 0.85), RGB(1, 0.4, 0.15), RGB(1, 0.92, 0.35)]),
        Theme(id: "matrix", name: "Matrix", stops: [RGB(0, 0.35, 0.12), RGB(0.1, 1, 0.35), RGB(0.85, 1, 0.9)]),
        Theme(id: "ocean", name: "Ocean", stops: [RGB(0, 0.15, 0.6), RGB(0, 0.6, 1), RGB(0.7, 1, 1)]),
        Theme(id: "lava", name: "Lava", stops: [RGB(0.6, 0, 0), RGB(1, 0.35, 0), RGB(1, 0.85, 0.2)]),
        Theme(id: "candy", name: "Candy", stops: [RGB(1, 0.4, 0.7), RGB(0.6, 0.5, 1), RGB(0.4, 0.95, 1)]),
        Theme(id: "mono", name: "Mono", stops: [RGB(0.3, 0.3, 0.35), RGB(0.7, 0.7, 0.75), RGB(1, 1, 1)]),
        Theme(id: "rainbow", name: "Rainbow", stops: [RGB(1, 0.15, 0.15), RGB(1, 0.6, 0), RGB(1, 1, 0.1),
                                                     RGB(0.2, 1, 0.3), RGB(0.1, 0.5, 1), RGB(0.7, 0.2, 1)]),
    ]

    func color(_ t: Float) -> RGB { gradient(stops, t) }

    /// Black → theme → white, for flames.
    func fire(_ t: Float) -> RGB {
        gradient([RGB(0, 0, 0), stops[0] * 0.6, stops[stops.count / 2], stops[stops.count - 1], RGB(1, 1, 1)], t)
    }

    var swiftUIColors: [Color] { stops.map(Color.init(rgb:)) }
}

func gradient(_ stops: [RGB], _ t: Float) -> RGB {
    let position = min(max(t, 0), 1) * Float(stops.count - 1)
    let index = min(Int(position), stops.count - 2)
    let fraction = position - Float(index)
    return stops[index] + (stops[index + 1] - stops[index]) * fraction
}

extension Color {
    init(rgb: RGB) {
        self.init(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

extension RGB {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent))
    }
}

/// Every choice in the settings window, saved between launches.
final class Settings: ObservableObject {
    static let shared = Settings(defaults: .standard)
    private let defaults: UserDefaults

    @Published var style: VisualStyle { didSet { defaults.set(style.rawValue, forKey: "style") } }
    @Published var motion: Motion { didSet { defaults.set(motion.rawValue, forKey: "motion") } }
    @Published var waveShape: WaveShape { didSet { defaults.set(waveShape.rawValue, forKey: "waveShape") } }
    @Published var themeID: String { didSet { defaults.set(themeID, forKey: "theme") } }
    @Published var customStops: [RGB] {
        didSet { defaults.set(customStops.map { [$0.x, $0.y, $0.z] }, forKey: "customStops") }
    }
    @Published var pixelSize: Double { didSet { defaults.set(pixelSize, forKey: "pixelSize") } }
    @Published var ledGrid: Bool { didSet { defaults.set(ledGrid, forKey: "ledGrid") } }
    @Published var mirror: Bool { didSet { defaults.set(mirror, forKey: "mirror") } }
    @Published var peaks: Bool { didSet { defaults.set(peaks, forKey: "peaks") } }
    @Published var brightness: Double { didSet { defaults.set(brightness, forKey: "brightness") } }
    @Published var afterglow: Double { didSet { defaults.set(afterglow, forKey: "afterglow") } }
    @Published var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: "sensitivity") } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed") } }
    @Published var autoShow: Bool { didSet { defaults.set(autoShow, forKey: "autoShow") } }

    static let pixelSizes: [(name: String, size: Double)] = [
        ("Tiny", 1), ("Small", 1.5), ("Medium", 2), ("Large", 3), ("Huge", 5),
    ]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        style = VisualStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .bars
        motion = Motion(rawValue: defaults.string(forKey: "motion") ?? "") ?? .music
        waveShape = WaveShape(rawValue: defaults.string(forKey: "waveShape") ?? "") ?? .line
        themeID = defaults.string(forKey: "theme") ?? "neon"
        let saved = (defaults.array(forKey: "customStops") as? [[Float]])?.filter { $0.count == 3 }
        customStops = saved?.count == 3
            ? saved!.map { RGB($0[0], $0[1], $0[2]) }
            : [RGB(0.1, 0.2, 1), RGB(1, 0.2, 0.5), RGB(1, 0.9, 0.3)]
        pixelSize = defaults.object(forKey: "pixelSize") as? Double ?? 1.5
        ledGrid = defaults.object(forKey: "ledGrid") as? Bool ?? true
        mirror = defaults.object(forKey: "mirror") as? Bool ?? true
        peaks = defaults.object(forKey: "peaks") as? Bool ?? true
        brightness = defaults.object(forKey: "brightness") as? Double ?? 1
        afterglow = defaults.object(forKey: "afterglow") as? Double ?? 0.35
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 1
        speed = defaults.object(forKey: "speed") as? Double ?? 1
        autoShow = defaults.bool(forKey: "autoShow")
    }

    var theme: Theme {
        if themeID == Theme.customID { return Theme(id: Theme.customID, name: "Custom", stops: customStops) }
        return Theme.presets.first { $0.id == themeID } ?? Theme.presets[0]
    }

    func nextStyle(_ step: Int) {
        let all = VisualStyle.allCases
        let index = all.firstIndex(of: style) ?? 0
        style = all[(index + step + all.count) % all.count]
    }

    func nextTheme() {
        let ids = Theme.presets.map(\.id)
        let index = ids.firstIndex(of: themeID) ?? -1
        themeID = ids[(index + 1) % ids.count]
    }
}

/// Fake "music" for Constant Movement mode: no microphone or audio permission needed.
final class AmbientGenerator {
    private var time: Float = 0
    private var nextBeat: Float = 0
    private var kick: Float = 0

    func frame(speed: Float) -> AudioFrame {
        time += speed / 60
        var beat = false
        if time >= nextBeat {
            beat = true
            kick = 1
            nextBeat = time + 0.6
        }
        kick *= 0.9

        let bands = (0..<SpectrumAnalyzer.bandCount).map { band -> Float in
            let x = Float(band) / Float(SpectrumAnalyzer.bandCount - 1)
            // Waves rolling across the spectrum, plus a kick drum in the bass.
            let base = 0.18 + 0.3 * exp(-x * 2)
            let roll = 0.32 * (sin(x * 7 - time * 2.2) * 0.5 + 0.5)
            let swell = 0.22 * (sin(x * 2.3 + time * 0.9) * 0.5 + 0.5)
            let shimmer = 0.14 * (sin(x * 29 + time * 5.7) * 0.5 + 0.5) * (sin(time * 1.7 + x * 4) * 0.5 + 0.5)
            let thump = kick * 0.4 * pow(1 - x, 2)
            return min(1, (base + roll + swell + shimmer + thump) * 0.8)
        }
        let wave = (0..<SpectrumAnalyzer.sampleCount).map { i -> Float in
            let p = Float(i) / Float(SpectrumAnalyzer.sampleCount) * 2 * .pi
            let mix = 0.55 * sin(p * 3 + time * 4) + 0.3 * sin(p * 7 - time * 6) + 0.15 * sin(p * 13 + time * 9)
            return mix * (0.75 + 0.25 * kick)
        }
        return AudioFrame(bands: bands, wave: wave, level: 0.3 + 0.2 * kick, beat: beat, silent: false)
    }
}
