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
    private var locked = false
    private var bag = Set<AnyCancellable>()
    private let state = LockState()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "lockPlayer") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lockPlayer"); refresh() }
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
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = FirstMouseHost(rootView: LockPlayerView(music: music, state: state))
        host.safeAreaRegions = []
        p.contentView = host
        window = p
        return p
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

    private func show() {
        let p = makeWindow()
        place(p)
        p.orderFrontRegardless()
        SkyLight.raiseAboveLockScreen(p)
        state.visible = true
    }

    private func hide() {
        guard state.visible else { return }
        state.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.state.visible else { return }
            self.window?.orderOut(nil)
        }
    }
}

final class LockState: ObservableObject {
    @Published var visible = false
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

struct LockPlayerView: View {
    @ObservedObject var music: MusicService
    @ObservedObject var state: LockState

    var body: some View {
        VStack(spacing: 18) {
            ArtThumb(music: music, size: 300)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
                .scaleEffect(music.isPlaying ? 1 : 0.86)
                .animation(.spring(response: 0.5, dampingFraction: 0.58), value: music.isPlaying)
                .id(music.title + music.artist)
                .transition(.scale(scale: 0.82).combined(with: .opacity))

            VStack(spacing: 8) {
                VStack(spacing: 1) {
                    Text(music.title).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(music.artist).font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let pos = music.position
                    HStack(spacing: 8) {
                        Text(fmt(pos))
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.22))
                                Capsule().fill(Color.white)
                                    .frame(width: max(5, g.size.width * (music.duration > 0 ? pos / music.duration : 0)))
                            }
                        }
                        .frame(height: 5)
                        Text("-" + fmt(max(0, music.duration - pos)))
                    }
                    .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 30) {
                    ctl("backward.fill", 17) { music.previous() }
                    ctl(music.isPlaying ? "pause.fill" : "play.fill", 24) { music.toggle() }
                    ctl("forward.fill", 17) { music.next() }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(width: 300)
            .background(
                ZStack {
                    GlassBackground()
                    Color.white.opacity(0.08)
                }
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            )
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 20)
        .scaleEffect(state.visible ? 1 : 0.8, anchor: .top)
        .opacity(state.visible ? 1 : 0)
        .blur(radius: state.visible ? 0 : 12)
        .animation(.spring(response: 0.5, dampingFraction: 0.66), value: state.visible)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: music.title)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    private func fmt(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    private func ctl(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy(scale: 0.72))
    }
}
