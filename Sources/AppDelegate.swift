import AppKit
import Combine
import SwiftUI

/// C functions from the private DFRFoundation framework, looked up at runtime.
enum DFR {
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    static func setControlStripPresence(_ identifier: NSTouchBarItem.Identifier, _ present: Bool) {
        typealias Fn = @convention(c) (CFString, Bool) -> Void
        function("DFRElementSetControlStripPresenceForIdentifier", as: Fn.self)?(identifier.rawValue as CFString, present)
    }

    static func setShowsCloseBox(_ show: Bool) {
        typealias Fn = @convention(c) (Bool) -> Void
        function("DFRSystemModalShowsCloseBoxWhenFrontMost", as: Fn.self)?(show)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    static let trayIdentifier = NSTouchBarItem.Identifier("dev.beatbar.tray")

    @Published private(set) var isOnTouchBar = false
    @Published private(set) var audioProblem: String?

    let settings = Settings.shared
    private lazy var renderer = PixelRenderer(settings: settings)
    private let tap = SystemAudioTap()
    private let analyzer = SpectrumAnalyzer()
    private let ambient = AmbientGenerator()
    private let displays = NSHashTable<PixelDisplayView>.weakObjects()
    private lazy var touchBarView = TouchBarVisualizerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 30))
    private lazy var stripButton = NSButton(
        image: NSImage(systemSymbolName: "waveform", accessibilityDescription: "BeatBar")!,
        target: self, action: #selector(toggleTouchBar))
    private var touchBar: NSTouchBar?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var shownAutomatically = false
    private var autoShowArmed = true
    private var loudTicks = 0, quietTicks = 0
    private var lastAudioLog = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = false
        DFR.setShowsCloseBox(true)
        let item = NSCustomTouchBarItem(identifier: Self.trayIdentifier)
        item.view = stripButton
        NSTouchBarItem.addSystemTrayItem(item)
        DFR.setControlStripPresence(Self.trayIdentifier, true)

        touchBarView.onVisibilityChange = { [weak self] in self?.updateRunState() }
        touchBarView.onSwipe = { [weak self] in self?.settings.nextStyle($0) }
        touchBarView.onTap = { [weak self] in self?.settings.nextTheme() }
        touchBarView.onDrag = { [weak self] point, count in self?.renderer.spawnSparks(at: point, count: count) }
        register(touchBarView)
        touchBarView.cellSize = CGFloat(settings.pixelSize)

        subscription = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }
        setUpMenus()
        showWindow()
        showOnTouchBar()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    /// Any view registered here shows the live visualizer (Touch Bar, preview, close-up).
    func register(_ view: PixelDisplayView) {
        displays.add(view)
        view.ledGrid = settings.ledGrid
        view.image = renderer.image
    }

    private func applySettings() {
        for display in displays.allObjects { display.ledGrid = settings.ledGrid }
        touchBarView.cellSize = CGFloat(settings.pixelSize)
        updateRunState()
    }

    // MARK: Touch Bar

    @objc func toggleTouchBar() {
        isOnTouchBar ? hideFromTouchBar() : showOnTouchBar()
    }

    func showOnTouchBar() {
        let bar = NSTouchBar()
        let item = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier("dev.beatbar.visualizer"))
        item.view = touchBarView
        bar.templateItems = [item]
        bar.defaultItemIdentifiers = [item.identifier]
        touchBar = bar

        let fullWidth = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        if NSTouchBar.responds(to: fullWidth) {
            NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: Self.trayIdentifier)
        } else {
            NSTouchBar.presentSystemModalTouchBar(bar, systemTrayItemIdentifier: Self.trayIdentifier)
        }
        DispatchQueue.main.async { self.updateRunState() }
    }

    func hideFromTouchBar() {
        if let touchBar { NSTouchBar.dismissSystemModalTouchBar(touchBar) }
        touchBar = nil
        shownAutomatically = false
        DispatchQueue.main.async { self.updateRunState() }
    }

    // MARK: Frame loop

    /// Only listen and animate while something can actually see it.
    private func updateRunState() {
        let onBar = touchBarView.window != nil
        if isOnTouchBar != onBar { isOnTouchBar = onBar }
        let music = settings.motion == .music
        let needFrames = onBar || window?.isVisible == true || (music && settings.autoShow)

        if needFrames, music, !tap.isActive {
            tap.start { [weak self] error in
                guard let self else { return }
                if let error {
                    self.audioProblem = "Couldn't listen to system audio: \(error)"
                    Log.write("Audio tap failed: \(error)")
                } else if self.audioProblem != nil {
                    self.audioProblem = nil
                }
            }
        } else if !needFrames || !music {
            tap.stop()
        }

        if needFrames, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needFrames {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        var frame: AudioFrame
        if settings.motion == .music {
            frame = analyzer.analyze(tap.buffer.latest(SpectrumAnalyzer.sampleCount), sampleRate: tap.sampleRate)
            if !frame.silent {
                let exponent = 1 / Float(settings.sensitivity)
                frame.bands = frame.bands.map { min(1, pow($0, exponent)) }
            }
            logAudio(frame)
        } else {
            frame = ambient.frame(speed: Float(settings.speed))
        }

        if touchBarView.window != nil, touchBarView.bounds.width > 100 {
            renderer.logicalSize = touchBarView.bounds.size
        }
        renderer.advance(frame)
        for display in displays.allObjects {
            // Skip previews in a hidden or covered window; the Touch Bar always updates.
            let onScreen = display === touchBarView || display.window?.occlusionState.contains(.visible) == true
            if onScreen { display.image = renderer.image }
        }
        autoShowIfNeeded(frame)
    }

    private func autoShowIfNeeded(_ frame: AudioFrame) {
        guard settings.autoShow, settings.motion == .music else { return }
        if touchBarView.window == nil {
            // Wait for a pause in the music before popping up again after being closed.
            if frame.silent {
                loudTicks = 0
                quietTicks += 1
                if quietTicks > 120 { autoShowArmed = true }
            } else {
                quietTicks = 0
                loudTicks += 1
                if autoShowArmed, loudTicks > 90 {
                    autoShowArmed = false
                    shownAutomatically = true
                    showOnTouchBar()
                }
            }
        } else if shownAutomatically {
            quietTicks = frame.silent ? quietTicks + 1 : 0
            if quietTicks > 600 { hideFromTouchBar() }
        }
    }

    private func logAudio(_ frame: AudioFrame) {
        guard Date().timeIntervalSince(lastAudioLog) > 5 else { return }
        lastAudioLog = Date()
        Log.write(frame.silent ? "Audio: silent" : String(format: "Audio: hearing sound (level %.2f)", frame.level))
    }

    // MARK: Window and menus

    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "BeatBar"
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, app: self))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.updateRunState() }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { self.updateRunState() }
    }

    private func setUpMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About BeatBar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide BeatBar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit BeatBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "BeatBar")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open BeatBar…", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show / Hide on Touch Bar", action: #selector(toggleTouchBar), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit BeatBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        statusItem = status
    }
}
