import SwiftUI
import AppKit
import Combine

// MARK: - Putting a window above the lock screen
//
// Ordinary window levels stop below the lock screen. The window server has
// "spaces" with their own absolute level; a window moved into a space whose
// level sits above the lock screen is drawn there. This uses private SkyLight
// calls looked up at runtime, so if Apple removes them the player simply
// doesn't appear and the rest of the app is unaffected.

enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String) -> T? {
        guard let handle, let s = dlsym(handle, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    private static var space: Int32?

    /// Moves `window` into a space above the lock screen. Returns false if unavailable.
    @discardableResult
    static func raiseAboveLockScreen(_ window: NSWindow) -> Bool {
        guard let conn: MainConnection = sym("SLSMainConnectionID"),
              let create: SpaceCreate = sym("SLSSpaceCreate"),
              let setLevel: SpaceSetLevel = sym("SLSSpaceSetAbsoluteLevel"),
              let show: ShowSpaces = sym("SLSShowSpaces"),
              let add: AddWindows = sym("SLSSpaceAddWindowsAndRemoveFromSpaces") else { return false }
        let c = conn()
        if space == nil {
            let s = create(c, 1, 0)
            _ = setLevel(c, s, 400)
            _ = show(c, [NSNumber(value: s)] as CFArray)
            space = s
        }
        guard let space, window.windowNumber > 0 else { return false }
        _ = add(c, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        return true
    }
}

// MARK: - Controller

final class LockScreenPlayer {
    private let music: MusicService
    private var window: NSPanel?
    private var backdrop: NSPanel?
    private var locked = false
    private var bag = Set<AnyCancellable>()
    private let state = LockState()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "lockPlayer") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lockPlayer"); refresh() }
    }

    /// Fill the lock screen behind the player with the song's cover.
    var backdropEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "lockBackdrop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lockBackdrop"); state.backdrop = newValue }
    }

    init(music: MusicService) {
        self.music = music
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.music.refreshPosition()
            self?.refresh()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
            self?.refresh()
        }
        music.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        // Build both windows up front so nothing is created at the moment of locking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            _ = self?.makeBackdrop()
            _ = self?.makeWindow()
        }
    }

    private func refresh() {
        // Appears when music is playing on a locked screen, then stays until
        // unlock so a paused track can be resumed from the lock screen.
        let wanted = enabled && locked && !music.title.isEmpty && (music.isPlaying || state.visible)
        if wanted { show() } else { hide() }
    }

    func makeWindow() -> NSPanel {
        if let window { return window }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = FirstMouseHost(rootView: LockPlayerView(music: music, state: state))
        host.safeAreaRegions = []
        p.contentView = host
        window = p
        return p
    }

    func makeBackdrop() -> NSPanel {
        if let backdrop { return backdrop }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.ignoresMouseEvents = true   // never block the password field or Touch ID prompt
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: LockBackdropView(music: music, state: state))
        host.safeAreaRegions = []
        p.contentView = host
        backdrop = p
        return p
    }

    func placeBackdrop(_ p: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        p.setFrame(screen.frame, display: true)
    }

    func place(_ p: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let f = screen.frame
        let size = CGSize(width: 420, height: 560)
        // Sits just under the lock-screen clock.
        let top = f.maxY - f.height * 0.26
        p.setFrame(CGRect(x: f.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func debugVisible(_ v: Bool) { state.visible = v }

    /// Debug: run the locked path while unlocked and report what happened.
    func debugLockTest() {
        print("title empty:", music.title.isEmpty, "source:", music.source ?? "nil", "playing:", music.isPlaying)
        print("artwork:", music.artwork != nil, "backdrop image:", music.backdrop != nil, "backdropEnabled:", backdropEnabled)
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for (n, w) in [("backdrop", self.backdrop), ("player", self.window)] {
                print(n, "visible:", w?.isVisible ?? false, "frame:", w?.frame ?? .zero, "num:", w?.windowNumber ?? -1, "alpha:", w?.alphaValue ?? -1)
            }
            let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in l where (w["kCGWindowOwnerName"] as? String) == "Droplet" {
                print("onscreen:", w["kCGWindowNumber"] ?? "", w["kCGWindowLayer"] ?? "", w["kCGWindowBounds"] ?? "")
            }
            NSApp.terminate(nil)
        }
    }

    private func show() {
        state.backdrop = backdropEnabled
        let b = makeBackdrop()
        placeBackdrop(b)
        b.orderFrontRegardless()
        SkyLight.raiseAboveLockScreen(b)
        let p = makeWindow()
        place(p)
        p.orderFrontRegardless()
        SkyLight.raiseAboveLockScreen(p)
        state.visible = true
        // The lock screen can settle after the notification arrives; re-assert
        // both windows a couple of times so neither is left behind it.
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.locked, self.state.visible else { return }
                self.state.tick += 1
                b.contentView?.needsLayout = true
                b.contentView?.needsDisplay = true
                b.displayIfNeeded()
                b.orderFrontRegardless()
                SkyLight.raiseAboveLockScreen(b)
                p.orderFrontRegardless()
                SkyLight.raiseAboveLockScreen(p)
            }
        }
    }

    private func hide() {
        guard state.visible else { return }
        state.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.state.visible else { return }
            self.window?.orderOut(nil)
            self.backdrop?.orderOut(nil)
        }
    }
}

final class LockState: ObservableObject {
    @Published var visible = false
    @Published var backdrop = true
    /// Bumped after locking to force the lock-screen views to redraw.
    @Published var tick = 0
}

// MARK: - View

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// The song's cover, blurred, filling the whole lock screen. It draws its own
/// clock because it covers the system one.
struct LockBackdropView: View {
    @ObservedObject var music: MusicService
    @ObservedObject var state: LockState

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if state.backdrop {
                    Image(nsImage: music.backdrop ?? MusicService.placeholderBackdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.22))
                        .id(music.title + music.artist)
                        .transition(.opacity)

                    TimelineView(.periodic(from: .now, by: 5)) { c in
                        VStack(spacing: -4) {
                            Text(c.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                .font(.system(size: 22, weight: .semibold))
                            Text(c.date, format: .dateTime.hour().minute())
                                .font(.system(size: 104, weight: .bold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white.opacity(0.82))
                        .shadow(color: .black.opacity(0.2), radius: 10)
                    }
                    .padding(.top, geo.size.height * 0.07)
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        // No fade tied to the lock moment: an animation started while the
        // screen is locking can stall at fully transparent.
        .id(state.tick)
        .animation(.easeInOut(duration: 0.7), value: music.title)
        .animation(.easeInOut(duration: 0.5), value: music.backdrop == nil)
        .ignoresSafeArea()
    }
}

struct LockPlayerView: View {
    @ObservedObject var music: MusicService
    @ObservedObject var state: LockState
    private let width: CGFloat = 280

    var body: some View {
        VStack(spacing: 14) {
            ArtThumb(music: music, size: width, radius: 18)
                .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
                .scaleEffect(music.isPlaying ? 1 : 0.9)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: music.isPlaying)
                .id(music.title + music.artist)
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(music.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let pos = music.position
                    VStack(spacing: 5) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule().fill(Color.white.opacity(0.9))
                                    .frame(width: max(3, g.size.width * (music.duration > 0 ? pos / music.duration : 0)))
                            }
                        }
                        .frame(height: 3)
                        HStack {
                            Text(fmt(pos)); Spacer(); Text("-" + fmt(max(0, music.duration - pos)))
                        }
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
                HStack(spacing: 34) {
                    ctl("backward.fill", 15) { music.previous() }
                    ctl(music.isPlaying ? "pause.fill" : "play.fill", 21) { music.toggle() }
                    ctl("forward.fill", 15) { music.next() }
                }
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(width: width)
            .background(GlassBackground().clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 20)
        .scaleEffect(state.visible ? 1 : 0.94, anchor: .top)
        .opacity(state.visible ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: state.visible)
        .animation(.easeInOut(duration: 0.35), value: music.title)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    private func fmt(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    private func ctl(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy(scale: 0.85))
    }
}
