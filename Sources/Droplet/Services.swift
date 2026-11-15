import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox
import IOKit.ps
import IOKit.pwr_mgt
import CoreImage

// MARK: - Now playing (Apple Music + Spotify)

final class MusicService: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    /// Pre-blurred copy of the cover for the lock-screen backdrop.
    @Published var backdrop: NSImage?
    @Published var accent: Color = .white
    @Published var duration: Double = 0
    @Published var source: String?

    var onTrackChange: (() -> Void)?
    private var posBase: Double = 0
    private var posDate = Date()
    private let queue = DispatchQueue(label: "droplet.applescript")
    private var artKey = ""

    var position: Double {
        let p = isPlaying ? posBase + Date().timeIntervalSince(posDate) : posBase
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }

    init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            self?.handle(n.userInfo ?? [:], app: "Music")
        }
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            self?.handle(n.userInfo ?? [:], app: "Spotify")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.initialFetch() }
    }

    private func handle(_ info: [AnyHashable: Any], app: String) {
        let state = (info["Player State"] as? String ?? "").lowercased()
        let playing = state == "playing"
        if state == "stopped" {
            if source == app { isPlaying = false }
            return
        }
        // Don't let a paused player steal the island from the one that's playing.
        if !playing, source != nil, source != app, isPlaying { return }
        let newTitle = info["Name"] as? String ?? ""
        let changed = newTitle != title || source != app
        source = app
        title = newTitle
        artist = info["Artist"] as? String ?? ""
        if app == "Spotify" {
            duration = ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
            if let p = (info["Playback Position"] as? NSNumber)?.doubleValue { posBase = p; posDate = Date() }
        } else {
            duration = ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000
        }
        if posDate.timeIntervalSinceNow < -0.01, !playing, isPlaying { posBase = position; posDate = Date() }
        isPlaying = playing
        refreshPosition()
        if changed {
            fetchArtwork()
            if playing { onTrackChange?() }
        }
    }

    private func script(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    private func running(_ app: String) -> Bool {
        let id = app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func initialFetch() {
        for app in ["Spotify", "Music"] where running(app) {
            queue.async { [weak self] in
                guard let self else { return }
                let s = "tell application \"\(app)\" to return (name of current track) & \"\n\" & (artist of current track) & \"\n\" & (player state as string) & \"\n\" & (duration of current track)"
                guard let out = self.script(s)?.stringValue else { return }
                let parts = out.components(separatedBy: "\n")
                guard parts.count >= 4 else { return }
                let dur = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
                DispatchQueue.main.async {
                    let playing = parts[2].lowercased().contains("playing")
                    if self.source != nil && !playing { return }
                    self.source = app
                    self.title = parts[0]
                    self.artist = parts[1]
                    self.duration = app == "Spotify" ? dur / 1000 : dur
                    self.isPlaying = playing
                    self.refreshPosition()
                    self.fetchArtwork()
                }
            }
        }
    }

    func refreshPosition() {
        guard let app = source, running(app) else { return }
        queue.async { [weak self] in
            guard let self, let d = self.script("tell application \"\(app)\" to return player position") else { return }
            let v = d.doubleValue != 0 ? d.doubleValue : Double((d.stringValue ?? "0").replacingOccurrences(of: ",", with: ".")) ?? 0
            DispatchQueue.main.async { self.posBase = v; self.posDate = Date(); self.objectWillChange.send() }
        }
    }

    private func fetchArtwork(retry: Bool = false) {
        guard let app = source else { return }
        let key = app + title + artist
        guard retry || key != artKey else { return }
        artKey = key
        queue.async { [weak self] in
            guard let self else { return }
            var image: NSImage?
            if app == "Spotify" {
                if let s = self.script("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
                   let url = URL(string: s), let data = try? Data(contentsOf: url) {
                    image = NSImage(data: data)
                }
            } else {
                for prop in ["raw data", "data"] {
                    if let d = self.script("tell application \"Music\" to return \(prop) of artwork 1 of current track") {
                        image = NSImage(data: d.data)
                        if image != nil { break }
                    }
                }
            }
            let color = image.flatMap(Self.dominant) ?? .white
            let blurred = image.flatMap(Self.blurred)
            DispatchQueue.main.async {
                guard self.artKey == key else { return }
                self.artwork = image
                self.backdrop = blurred
                // Streamed tracks can report their cover a moment late; try once more.
                if image == nil, !retry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if self.artKey == key { self.fetchArtwork(retry: true) }
                    }
                }
                self.accent = color
            }
        }
    }

    /// Used behind the lock-screen player when a track has no cover.
    static let placeholderBackdrop: NSImage = {
        let img = NSImage(size: NSSize(width: 480, height: 300), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.95, green: 0.3, blue: 0.5, alpha: 1), NSColor(red: 0.55, green: 0.3, blue: 0.9, alpha: 1), NSColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)])!.draw(in: r, angle: -35)
            return true
        }
        return blurred(img) ?? img
    }()

    static func blurred(_ image: NSImage) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let src = CIImage(data: tiff), src.extent.width > 0 else { return nil }
        let scale = 480 / max(src.extent.width, src.extent.height)
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let out = small.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: small.extent)
        guard let cg = CIContext().createCGImage(out, from: small.extent) else { return nil }
        return NSImage(cgImage: cg, size: small.extent.size)
    }

    static func dominant(_ image: NSImage) -> Color? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        guard let out = f?.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(1, s * 1.5 + 0.1)), brightness: Double(max(0.85, b)))
    }

    private func tell(_ cmd: String) {
        guard let app = source else { return }
        queue.async { [weak self] in _ = self?.script("tell application \"\(app)\" to \(cmd)") }
    }

    func toggle() {
        posBase = position; posDate = Date()
        isPlaying.toggle()
        tell("playpause")
    }
    func next() { tell("next track") }
    func previous() { tell("previous track") }

    func launch(_ bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

// MARK: - Volume + output device

final class AudioService {
    var onVolume: ((Double, Bool) -> Void)?
    var onDevice: ((String, String) -> Void)?
    private var device: AudioDeviceID = 0
    private var listened = Set<AudioDeviceID>()
    private var lastVolume: Double = -1
    private var lastMute = false

    private func addr(_ sel: AudioObjectPropertySelector, output: Bool = true) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel,
                                   mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    init() {
        device = currentDevice()
        attach()
        lastVolume = volume(); lastMute = muted()
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice, output: false)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            guard let self else { return }
            let d = self.currentDevice()
            guard d != self.device else { return }
            self.device = d
            self.attach()
            self.lastVolume = self.volume(); self.lastMute = self.muted()
            let name = self.name()
            self.onDevice?(name, self.icon(for: name))
        }
    }

    private func currentDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice, output: false)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    private func attach() {
        guard device != 0, !listened.contains(device) else { return }
        listened.insert(device)
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var a = addr(sel)
            AudioObjectAddPropertyListenerBlock(device, &a, .main) { [weak self] _, _ in self?.changed() }
        }
    }

    private func changed() {
        let v = volume(), m = muted()
        guard abs(v - lastVolume) > 0.001 || m != lastMute else { return }
        lastVolume = v; lastMute = m
        onVolume?(v, m)
    }

    func volume() -> Double {
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v)
        return Double(v)
    }

    func muted() -> Bool {
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var a = addr(kAudioDevicePropertyMute)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m)
        return m != 0
    }

    func name() -> String {
        var n: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var a = addr(kAudioObjectPropertyName, output: false)
        let r = withUnsafeMutablePointer(to: &n) { AudioObjectGetPropertyData(device, &a, 0, nil, &size, $0) }
        guard r == noErr, let n else { return "Audio Output" }
        return n.takeRetainedValue() as String
    }

    func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") || n.contains("headphone") { return "headphones" }
        var t = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var a = addr(kAudioDevicePropertyTransportType, output: false)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &t)
        if t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE { return "headphones" }
        if t == kAudioDeviceTransportTypeBuiltIn { return "laptopcomputer" }
        return "hifispeaker.fill"
    }
}

// MARK: - Brightness (best effort, private framework)

final class BrightnessService {
    var onChange: ((Double) -> Void)?
    private typealias Fn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private var fn: Fn?
    private var last: Float = -1
    private var timer: Timer?

    init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let sym = dlsym(h, "DisplayServicesGetBrightness") else { return }
        fn = unsafeBitCast(sym, to: Fn.self)
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard let fn else { return }
        var v: Float = 0
        guard fn(CGMainDisplayID(), &v) == 0 else { return }
        defer { last = v }
        guard last >= 0, abs(v - last) > 0.02 else { return }
        onChange?(Double(v))
    }
}

// MARK: - Power

extension Notification.Name { static let powerChanged = Notification.Name("droplet.power") }

struct Power: Equatable {
    var percent = 100
    var charging = false
    var plugged = false
    var hasBattery = false

    static func read() -> Power {
        var p = Power()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return p }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
            p.percent = mx > 0 ? cur * 100 / mx : cur
            p.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            p.plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            p.hasBattery = true
        }
        return p
    }

    static func startNotifications() {
        let src = IOPSNotificationCreateRunLoopSource({ _ in
            NotificationCenter.default.post(name: .powerChanged, object: nil)
        }, nil)?.takeRetainedValue()
        if let src { CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode) }
    }
}

// MARK: - System stats

final class StatsService: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memory: Double = 0
    @Published var power = Power.read()
    var active = false { didSet { if active { update() } } }
    private var prev: (busy: Double, total: Double) = (0, 0)
    private var timer: Timer?

    init() {
        _ = sampleCPU()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            self.update()
        }
        NotificationCenter.default.addObserver(forName: .powerChanged, object: nil, queue: .main) { [weak self] _ in
            self?.power = Power.read()
        }
    }

    private func update() {
        cpu = sampleCPU()
        memory = sampleMemory()
        power = Power.read()
    }

    private func sampleCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return cpu }
        let t = info.cpu_ticks
        let busy = Double(t.0) + Double(t.1) + Double(t.3)
        let total = busy + Double(t.2)
        defer { prev = (busy, total) }
        let dt = total - prev.total
        return dt > 0 ? min(1, max(0, (busy - prev.busy) / dt)) : cpu
    }

    private func sampleMemory() -> Double {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return memory }
        let used = Double(s.active_count + s.wire_count + s.compressor_page_count) * Double(vm_kernel_page_size)
        return min(1, used / Double(ProcessInfo.processInfo.physicalMemory))
    }
}

// MARK: - Keep awake

final class KeepAwake: ObservableObject {
    @Published var on = false { didSet { apply() } }
    private var id: IOPMAssertionID = 0

    private func apply() {
        if on {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Droplet keep awake" as CFString, &id)
        } else if id != 0 {
            IOPMAssertionRelease(id); id = 0
        }
    }
}

// MARK: - Clipboard history (memory only)

final class ClipboardService: ObservableObject {
    @Published var items: [String] = []
    private var change = NSPasteboard.general.changeCount
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != change else { return }
        change = pb.changeCount
        let types = pb.types?.map(\.rawValue) ?? []
        // Respect password managers: never keep concealed or transient entries.
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
        if items.count > 15 { items.removeLast() }
    }

    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        change = pb.changeCount
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
    }
}

// MARK: - File shelf

final class ShelfStore: ObservableObject {
    @Published var items: [URL] = [] {
        didSet { UserDefaults.standard.set(items.map(\.path), forKey: "shelf") }
    }

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: "shelf") ?? []
        items = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func add(_ url: URL) { if !items.contains(url) { items.append(url) } }
    func remove(_ url: URL) { items.removeAll { $0 == url } }

    func airdrop() {
        guard !items.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: items)
    }
}

// MARK: - Timer

final class TimerService: ObservableObject {
    @Published var remaining: TimeInterval = 25 * 60
    @Published var total: TimeInterval = 25 * 60
    @Published var running = false
    var onFinish: (() -> Void)?
    private var end = Date()
    private var tick: Timer?

    var progress: Double { total > 0 ? 1 - remaining / total : 0 }

    var text: String {
        let s = Int(remaining.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    func set(minutes: Double) {
        stop()
        total = minutes * 60
        remaining = total
    }

    func start() {
        guard !running else { return }
        if remaining <= 0 { remaining = total }
        end = Date().addingTimeInterval(remaining)
        running = true
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let r = self.end.timeIntervalSinceNow
            if r <= 0 {
                self.stop()
                self.remaining = self.total
                self.onFinish?()
            } else if Int(r.rounded(.up)) != Int(self.remaining.rounded(.up)) {
                self.remaining = r
            }
        }
    }

    func stop() {
        tick?.invalidate(); tick = nil
        running = false
    }

    func reset() { stop(); remaining = total }
}
