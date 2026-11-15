import SwiftUI
import AppKit

enum IslandTab: Int, CaseIterable {
    case home, shelf, clips, notes, timer
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.full.fill"
        case .clips: return "doc.on.clipboard.fill"
        case .notes: return "note.text"
        case .timer: return "timer"
        }
    }
}

struct HUD: Equatable {
    var icon: String
    var title: String
    var level: Double? = nil
    var detail: String? = nil
    var subtitle: String? = nil
    var tint: Color = .white
}

enum Presentation { case idle, compact, peek, hud, expanded }
enum Activity { case none, music, timer }

final class IslandModel: ObservableObject {
    static let shared = IslandModel()

    @Published var expanded = false
    @Published var hovering = false
    @Published var hud: HUD?
    @Published var peek = false
    @Published var tab: IslandTab = .home
    @Published var pinned = false
    @Published var dropTargeting = false
    @Published var squish = false
    @Published var notch = CGSize(width: 190, height: 32)

    var screenFrame: CGRect = .zero
    weak var panel: NSPanel?

    let music = MusicService()
    let timer = TimerService()
    let shelf = ShelfStore()
    let clips = ClipboardService()
    let stats = StatsService()
    let awake = KeepAwake()

    private var hudTask: DispatchWorkItem?
    private var peekTask: DispatchWorkItem?
    private var hoverTask: DispatchWorkItem?
    private var closeTask: DispatchWorkItem?
    private var accX: CGFloat = 0, accY: CGFloat = 0, fired = false

    var openOnHover: Bool {
        get { UserDefaults.standard.object(forKey: "openOnHover") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openOnHover") }
    }

    init() {
        music.onTrackChange = { [weak self] in self?.showPeek() }
        timer.onFinish = { [weak self] in
            NSSound(named: "Glass")?.play()
            self?.show(HUD(icon: "bell.fill", title: "Timer", detail: "Done", subtitle: "Time's up", tint: .orange), for: 4)
        }
    }

    // MARK: Layout

    var activity: Activity {
        if music.isPlaying { return .music }
        if timer.running { return .timer }
        return .none
    }

    var presentation: Presentation {
        if expanded { return .expanded }
        if hud != nil { return .hud }
        if peek && !music.title.isEmpty { return .peek }
        if activity != .none { return .compact }
        return .idle
    }

    var wing: CGFloat { activity == .timer ? 62 : 44 }

    var showBubble: Bool {
        !expanded && hud == nil && music.isPlaying && timer.running
    }

    func size(_ p: Presentation) -> CGSize {
        let n = notch
        let h: CGFloat = hovering ? 1 : 0
        switch p {
        case .expanded: return CGSize(width: 620, height: n.height + 180)
        case .hud: return CGSize(width: n.width + 208, height: n.height + (hud?.subtitle != nil ? 30 : 0))
        case .peek: return CGSize(width: max(n.width + wing * 2, 330), height: n.height + 34)
        case .compact: return CGSize(width: n.width + wing * 2 + h * 8, height: n.height + h * 3)
        case .idle: return CGSize(width: n.width + h * 10, height: n.height + h * 4)
        }
    }

    var islandRect: CGRect {
        let s = size(presentation)
        return CGRect(x: screenFrame.midX - s.width / 2, y: screenFrame.maxY - s.height,
                      width: s.width, height: s.height + 2)
    }

    // MARK: Hover / open / close

    func setHover(_ h: Bool) {
        guard h != hovering else { return }
        hovering = h
        if h {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            closeTask?.cancel()
            if openOnHover && !expanded {
                let t = DispatchWorkItem { [weak self] in
                    guard let self, self.hovering, !self.expanded else { return }
                    self.open()
                }
                hoverTask = t
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: t)
            }
        } else {
            hoverTask?.cancel()
            scheduleClose(after: 0.45)
        }
    }

    func scheduleClose(after delay: Double) {
        closeTask?.cancel()
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.expanded, !self.hovering, !self.pinned, !self.dropTargeting else { return }
            if self.tab == .notes, self.panel?.isKeyWindow == true { return }
            self.close()
        }
        closeTask = t
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: t)
    }

    func tapOpen() {
        squish = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            self?.squish = false
            self?.open()
        }
    }

    func open(_ t: IslandTab? = nil) {
        if let t { tab = t }
        hud = nil
        peek = false
        expanded = true
        stats.active = true
        music.refreshPosition()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func close() {
        expanded = false
        stats.active = false
        if let p = panel, p.isKeyWindow {
            p.orderOut(nil)
            p.orderFrontRegardless()
        }
    }

    func panelResignedKey() {
        if expanded && !hovering { scheduleClose(after: 0.2) }
    }

    // MARK: Transient UI

    func show(_ h: HUD, for seconds: Double = 1.7) {
        guard !expanded else { return }
        hud = h
        hudTask?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.hud = nil }
        hudTask = t
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: t)
    }

    func showPeek() {
        guard !expanded else { return }
        peek = true
        peekTask?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.peek = false }
        peekTask = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: t)
    }

    // MARK: Drag & drop

    func beginDrop() {
        guard !dropTargeting else { return }
        dropTargeting = true
        open(.shelf)
    }

    func endDrop() {
        guard dropTargeting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.dropTargeting = false
            if self?.hovering == false { self?.scheduleClose(after: 1.2) }
        }
    }

    // MARK: Gestures

    func handleScroll(_ e: NSEvent) {
        guard hovering, !e.phase.isEmpty else { return }
        if e.phase == .began { accX = 0; accY = 0; fired = false }
        guard !fired else { return }
        let s: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        accX += e.scrollingDeltaX * s
        accY += e.scrollingDeltaY * s
        let inTopBar = NSEvent.mouseLocation.y > screenFrame.maxY - notch.height - 4
        let freeTab = tab == .home || tab == .timer || inTopBar

        if abs(accY) > 36, abs(accY) > abs(accX) * 1.5 {
            fired = true
            if accY > 0 { if !expanded { open() } }
            else if expanded, freeTab { pinned = false; close() }
        } else if abs(accX) > 46, abs(accX) > abs(accY) * 1.5 {
            if expanded {
                guard freeTab || tab == .notes else { return }
                fired = true
                let all = IslandTab.allCases
                let i = (tab.rawValue + (accX < 0 ? 1 : -1) + all.count) % all.count
                tab = all[i]
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } else if music.source != nil {
                fired = true
                accX < 0 ? music.next() : music.previous()
                squish = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.squish = false }
            }
        }
    }
}
