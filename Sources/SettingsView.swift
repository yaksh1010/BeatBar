import ServiceManagement
import SwiftUI

/// A live view of the visualizer, fed by the same renderer as the Touch Bar.
struct PixelPreview: NSViewRepresentable {
    let app: AppDelegate
    var crop: CGRect?

    func makeNSView(context: Context) -> PixelDisplayView {
        let view = PixelDisplayView(frame: .zero)
        view.crop = crop
        app.register(view)
        return view
    }

    func updateNSView(_ view: PixelDisplayView, context: Context) {
        view.crop = crop
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var app: AppDelegate
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            preview
            Form {
                visualSection
                movementSection
                colorSection
                pixelSection
                touchBarSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 760, height: 780)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LIVE PREVIEW").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Label(settings.motion == .music ? "Synced to your music" : "Constant movement",
                      systemImage: settings.motion == .music ? "music.note" : "infinity")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // The Touch Bar at true proportions: close button, then the full-width visualizer.
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.22))
                    .overlay(Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                    .frame(width: 34)
                PixelPreview(app: app)
                    .aspectRatio(1000 / 30, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 9).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12)))

            Text("CLOSE-UP").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 4)
            PixelPreview(app: app, crop: CGRect(x: 0.35, y: 0, width: 0.3, height: 1))
                .aspectRatio(10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Sections

    private var visualSection: some View {
        Section("Visual") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                ForEach(VisualStyle.allCases) { style in
                    Tile(selected: settings.style == style) { settings.style = style } content: {
                        VStack(spacing: 6) {
                            Image(systemName: style.symbol).font(.system(size: 20))
                            Text(style.title).font(.callout)
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
            if settings.style == .wave {
                Picker("Wave shape", selection: $settings.waveShape) {
                    ForEach(WaveShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if settings.style.usesMirror {
                Toggle("Mirror (bass in the middle)", isOn: $settings.mirror)
            }
            if settings.style == .bars {
                Toggle("Falling peak dots", isOn: $settings.peaks)
            }
        }
    }

    private var movementSection: some View {
        Section("Movement") {
            Picker("Mode", selection: $settings.motion) {
                ForEach(Motion.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if settings.motion == .music {
                Slider(value: $settings.sensitivity, in: 0.5...2.5) { Text("Sensitivity") }
                Text("Reacts to whatever your Mac is playing: Spotify, YouTube, Apple Music. macOS asks once for System Audio Recording permission. If nothing moves while music plays, allow BeatBar there.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem = app.audioProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Open Audio Recording Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            } else {
                Text("Animates on its own with a steady beat. No audio permission needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $settings.speed, in: 0.2...3) { Text("Animation speed") }
        }
    }

    private var colorSection: some View {
        Section("Colors") {
            let themes = Theme.presets + [Theme(id: Theme.customID, name: "Custom", stops: settings.customStops)]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                ForEach(themes) { theme in
                    Tile(selected: settings.themeID == theme.id) { settings.themeID = theme.id } content: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(LinearGradient(colors: theme.swiftUIColors, startPoint: .leading, endPoint: .trailing))
                                .frame(height: 22)
                            Text(theme.name).font(.caption)
                        }
                        .padding(8)
                    }
                }
            }
            if settings.themeID == Theme.customID {
                HStack(spacing: 24) {
                    ColorPicker("Low", selection: customColor(0))
                    ColorPicker("Middle", selection: customColor(1))
                    ColorPicker("High", selection: customColor(2))
                }
            }
        }
    }

    private var pixelSection: some View {
        Section("Pixels") {
            Picker("Pixel size", selection: $settings.pixelSize) {
                ForEach(Settings.pixelSizes, id: \.size) { Text($0.name).tag($0.size) }
            }
            .pickerStyle(.segmented)
            Toggle("LED grid between pixels", isOn: $settings.ledGrid)
            Slider(value: $settings.brightness, in: 0.3...1) { Text("Brightness") }
            Slider(value: $settings.afterglow, in: 0...0.9) { Text("Afterglow trail") }
        }
    }

    private var touchBarSection: some View {
        Section("Touch Bar") {
            HStack {
                Image(systemName: app.isOnTouchBar ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(app.isOnTouchBar ? .green : .secondary)
                Text(app.isOnTouchBar ? "Showing on your Touch Bar" : "Not on the Touch Bar")
                Spacer()
                Button(app.isOnTouchBar ? "Hide" : "Show on Touch Bar") { app.toggleTouchBar() }
                    .buttonStyle(.borderedProminent)
            }
            Toggle("Show automatically when music starts", isOn: $settings.autoShow)
                .disabled(settings.motion != .music)
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.orange)
            }
            Text("On the Touch Bar: swipe to change style · tap to change colors · drag your finger to throw sparks · ✕ to close. The waveform button in the Control Strip brings it back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func customColor(_ index: Int) -> Binding<Color> {
        Binding(get: { Color(rgb: settings.customStops[index]) },
                set: { settings.customStops[index] = RGB(color: $0) })
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription). Add BeatBar in System Settings → General → Login Items instead."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// A selectable card used for styles and color themes.
private struct Tile<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
