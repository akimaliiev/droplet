import SwiftUI
import AppKit
import ServiceManagement

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHost<V: View>: NSHostingView<V> {
    required init(rootView: V) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = IslandModel.shared
    var panel: IslandPanel!
    var statusItem: NSStatusItem!
    let audio = AudioService()
    let brightness = BrightnessService()
    lazy var lockPlayer = LockScreenPlayer(music: model.music)
    var lastPower = Power.read()
    var dragChange = NSPasteboard(name: .drag).changeCount
    var monitors: [Any] = []
    var ticker: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        let host = FirstMouseHost(rootView: IslandRoot(model: model, music: model.music, timer: model.timer))
        host.safeAreaRegions = []
        panel.contentView = host
        model.panel = panel
        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.place()
        }

        _ = lockPlayer
        setupMenu()
        setupInput()
        setupSystem()
        if let dir = ProcessInfo.processInfo.environment["DROPLET_SNAPSHOT"] { runSnapshots(dir) }
        else if let out = ProcessInfo.processInfo.environment["DROPLET_PROBE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let ly = Online.lyrics(title: "Yesterday", artist: "The Beatles", duration: 125)
                let t0 = Date()
                let cv = Online.cover(title: ProcessInfo.processInfo.environment["PROBE_TITLE"] ?? "Yesterday", artist: ProcessInfo.processInfo.environment["PROBE_ARTIST"] ?? "The Beatles")
                print("cover seconds:", String(format: "%.2f", Date().timeIntervalSince(t0)))
                print("lyrics lines:", ly?.count ?? -1, "synced:", ly?.first?.time != nil, "cover:", cv?.size ?? .zero)
                let line = self.model.music.debugProbe() + " artwork=\(self.model.music.artwork != nil) title=\(!self.model.music.title.isEmpty)\n"
                try? line.write(toFile: out, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        else if ProcessInfo.processInfo.environment["DROPLET_LOCKTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["DROPLET_LOCKTEST"] ?? "") ?? 4)) { self.lockPlayer.debugLockTest() }
        }
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.model.show(HUD(icon: "drop.fill", title: "Droplet", detail: "On", tint: .cyan), for: 1.6)
            }
        }
    }

    // Opening the app again while it is running switches it off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.close()
        model.show(HUD(icon: "drop.fill", title: "Droplet", detail: "Off", tint: .gray), for: 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { NSApp.terminate(nil) }
        return false
    }

    /// Made-up cover used only for README screenshots.
    static func sampleArt() -> NSImage {
        NSImage(size: NSSize(width: 600, height: 600), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.02, green: 0.1, blue: 0.32, alpha: 1), NSColor(red: 0.1, green: 0.38, blue: 0.75, alpha: 1), NSColor(red: 0.95, green: 0.6, blue: 0.45, alpha: 1)])!.draw(in: r, angle: 90)
            NSColor(red: 1, green: 0.92, blue: 0.8, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: 380, y: 400, width: 110, height: 110)).fill()
            for i in 0..<7 {
                let y = CGFloat(40 + i * 42)
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 0, y: y))
                p.curve(to: NSPoint(x: 600, y: y), controlPoint1: NSPoint(x: 200, y: y + 46), controlPoint2: NSPoint(x: 400, y: y - 46))
                p.lineWidth = 3
                NSColor(white: 1, alpha: 0.10 + CGFloat(i) * 0.03).setStroke()
                p.stroke()
            }
            return true
        }
    }

    func lockState(_ v: Bool) { lockPlayer.debugVisible(v) }

    // Debug: render each island state to PNG (DROPLET_SNAPSHOT=/some/dir).
    func runSnapshots(_ dir: String) {
        let m = model
        let steps: [(String, () -> Void)] = [
            ("1-home", { m.pinned = true; m.open(.home) }),
            ("2-shelf", { m.shelf.add(URL(fileURLWithPath: "/Applications/Safari.app")); m.tab = .shelf }),
            ("3-clips", { m.clips.items = ["git push origin main", "https://example.com/a/long/link", "{\n  \"hello\": 1\n}"]; m.tab = .clips }),
            ("4-notes", { m.tab = .notes }),
            ("5-timer", { m.timer.set(minutes: 5); m.timer.start(); m.tab = .timer }),
            ("6-compact-timer", { m.shelf.items = []; m.pinned = false; m.close() }),
            ("7-music-bubble", { m.music.source = "Music"; m.music.title = "Midnight Drive"; m.music.artist = "The Tide Pools"; m.music.isPlaying = true; m.music.artwork = nil; m.music.accent = .white }),
            ("8-peek", { m.showPeek() }),
            ("9-hud", { m.peek = false; m.show(HUD(icon: "speaker.wave.2.fill", title: "Volume", level: 0.6), for: 5) }),
            ("10-hud-device", { m.show(HUD(icon: "airpodspro", title: "Audio", detail: "Connected", subtitle: "AirPods Pro", tint: .cyan), for: 5) }),
            ("11-home-music", { m.music.artwork = Self.sampleArt(); m.music.duration = 222; m.open(.home)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    m.lyrics.lines = ["Streetlights fold into the rain", "Radio low, the city hums", "Every mile a little lighter", "Midnight drive, we come undone", "Windows down, the cold air sings", "Nothing left we need to say"].enumerated().map { LyricLine(time: Double($0.offset) * 6, text: $0.element) }
                    m.lyrics.status = .ready
                } }),
            ("12-lock", { m.music.artwork = Self.sampleArt(); m.music.duration = 222; m.close(); let w = self.lockPlayer.makeWindow(); self.lockPlayer.place(w); w.orderFrontRegardless(); print("skylight:", SkyLight.raiseAboveLockScreen(w)); self.lockState(true) }),
            ("13-lock-backdrop", { m.music.artwork = Self.sampleArt(); m.music.backdrop = MusicService.blurred(Self.sampleArt()); let b = self.lockPlayer.makeBackdrop(); b.alphaValue = 0; self.lockPlayer.placeBackdrop(b); b.orderFrontRegardless() }),
        ]
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 2.4) {
                step.1()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    guard let v = (step.0 == "12-lock" ? self.lockPlayer.makeWindow().contentView : step.0 == "13-lock-backdrop" ? self.lockPlayer.makeBackdrop().contentView : self.panel.contentView), let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(step.0).png"))
                    if i == steps.count - 1 { m.timer.reset(); NSApp.terminate(nil) }
                }
            }
        }
    }

    // MARK: Placement

    func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0 {
            let l = screen.auxiliaryTopLeftArea?.width ?? 0
            let r = screen.auxiliaryTopRightArea?.width ?? 0
            let w = f.width - l - r
            model.notch = CGSize(width: w > 60 ? w : 190, height: screen.safeAreaInsets.top)
        } else {
            model.notch = CGSize(width: 190, height: max(24, f.maxY - screen.visibleFrame.maxY))
        }
        model.screenFrame = f
        let size = CGSize(width: 820, height: 420)
        panel.setFrame(CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: Input

    func setupInput() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp], handler: { [weak self] e in
            self?.mouse(e)
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel], handler: { [weak self] e in
            if e.type == .scrollWheel { self?.model.handleScroll(e) } else { self?.mouse(e) }
            return e
        }) { monitors.append(m) }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateHover()
            if self.model.dropTargeting && NSEvent.pressedMouseButtons == 0 { self.model.endDrop() }
        }
    }

    func mouse(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            dragChange = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            let pb = NSPasteboard(name: .drag)
            if !model.dropTargeting, pb.changeCount != dragChange, pb.types?.contains(.fileURL) == true {
                let f = model.screenFrame
                let zone = CGRect(x: f.midX - model.notch.width / 2 - 60, y: f.maxY - model.notch.height - 30,
                                  width: model.notch.width + 120, height: model.notch.height + 32)
                if zone.contains(NSEvent.mouseLocation) { model.beginDrop() }
            }
        default: break
        }
        updateHover()
    }

    func updateHover() {
        let pad: CGFloat = model.expanded ? 14 : 5
        var rect = model.islandRect.insetBy(dx: -pad, dy: 0)
        rect.origin.y -= pad
        rect.size.height += pad
        model.setHover(rect.contains(NSEvent.mouseLocation))
        let ignore = !(model.hovering || model.expanded || model.dropTargeting)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    func windowDidResignKey(_ notification: Notification) { model.panelResignedKey() }

    // MARK: System events → island

    func setupSystem() {
        audio.onVolume = { [weak self] v, muted in
            let level = muted ? 0 : v
            let icon = level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            self?.model.show(HUD(icon: icon, title: "Volume", level: level))
        }
        audio.onDevice = { [weak self] name, icon in
            self?.model.show(HUD(icon: icon, title: "Audio", detail: "Connected", subtitle: name, tint: .cyan), for: 2.6)
        }
        brightness.onChange = { [weak self] v in
            guard UserDefaults.standard.object(forKey: "brightnessHUD") as? Bool ?? true else { return }
            self?.model.show(HUD(icon: v < 0.5 ? "sun.min.fill" : "sun.max.fill", title: "Display", level: v, tint: .yellow))
        }
        Power.startNotifications()
        NotificationCenter.default.addObserver(forName: .powerChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let p = Power.read()
            defer { self.lastPower = p }
            guard p.hasBattery, p.plugged != self.lastPower.plugged else { return }
            self.model.show(p.plugged
                ? HUD(icon: "bolt.fill", title: "Charging", detail: "\(p.percent)%", tint: .green)
                : HUD(icon: "battery.75percent", title: "Battery", detail: "\(p.percent)%", tint: p.percent <= 20 ? .red : .white), for: 2.6)
        }
    }

    // MARK: Menu bar

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Droplet")
        let menu = NSMenu()
        menu.addItem(item("Open on Hover", #selector(toggleHover), on: model.openOnHover))
        menu.addItem(item("Brightness in Island", #selector(toggleBrightness), on: UserDefaults.standard.object(forKey: "brightnessHUD") as? Bool ?? true))
        menu.addItem(item("Lock Screen Player", #selector(toggleLock), on: lockPlayer.enabled))
        menu.addItem(item("Lock Screen Cover Backdrop", #selector(toggleBackdrop), on: lockPlayer.backdropEnabled))
        menu.addItem(item("Online Lyrics & Covers", #selector(toggleOnline), on: Online.enabled))
        menu.addItem(item("Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit Droplet", #selector(quit), on: false, key: "q"))
        statusItem.menu = menu
    }

    func item(_ title: String, _ sel: Selector, on: Bool, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    @objc func toggleHover(_ s: NSMenuItem) {
        model.openOnHover.toggle()
        s.state = model.openOnHover ? .on : .off
    }

    @objc func toggleBrightness(_ s: NSMenuItem) {
        let v = !(UserDefaults.standard.object(forKey: "brightnessHUD") as? Bool ?? true)
        UserDefaults.standard.set(v, forKey: "brightnessHUD")
        s.state = v ? .on : .off
    }

    @objc func toggleLock(_ s: NSMenuItem) {
        lockPlayer.enabled.toggle()
        s.state = lockPlayer.enabled ? .on : .off
    }

    @objc func toggleBackdrop(_ s: NSMenuItem) {
        lockPlayer.backdropEnabled.toggle()
        s.state = lockPlayer.backdropEnabled ? .on : .off
    }

    @objc func toggleOnline(_ s: NSMenuItem) {
        Online.enabled.toggle()
        s.state = Online.enabled ? .on : .off
    }

    @objc func toggleLogin(_ s: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        s.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
