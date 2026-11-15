import SwiftUI
import AppKit

// MARK: - Shapes & styles

struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = max(0, top)
        let b = max(0, min(bottom, r.height - t, (r.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct Bouncy: ButtonStyle {
    var scale: CGFloat = 0.84
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

struct BlurPop: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 14 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.86 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurPop: AnyTransition {
        .modifier(active: BlurPop(active: true), identity: BlurPop(active: false))
    }
}

extension View {
    func bubbleCard(_ radius: CGFloat = 22) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.075)))
    }
}

// MARK: - Gooey detached bubble (second live activity)

struct GooBubble<Content: View>: View, Animatable {
    var progress: CGFloat
    var islandWidth: CGFloat
    var height: CGFloat
    @ViewBuilder var content: () -> Content

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(progress, islandWidth) }
        set { progress = newValue.first; islandWidth = newValue.second }
    }

    var body: some View {
        let d = height - 5
        let hiddenX = islandWidth / 2 - d / 2 - 4
        let shownX = islandWidth / 2 + 9 + d / 2
        let x = hiddenX + (shownX - hiddenX) * progress
        GeometryReader { geo in
            let cx = geo.size.width / 2
            ZStack {
                Canvas { ctx, _ in
                    ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
                    ctx.addFilter(.blur(radius: 5))
                    ctx.drawLayer { l in
                        l.fill(Path(roundedRect: CGRect(x: cx + islandWidth / 2 - 28, y: 5, width: 26, height: height - 10),
                                    cornerRadius: 8), with: .color(.black))
                        l.fill(Path(ellipseIn: CGRect(x: cx + x - d / 2, y: (height - d) / 2 + 1, width: d, height: d)),
                               with: .color(.black))
                    }
                }
                content()
                    .frame(width: d, height: d)
                    .scaleEffect(0.4 + 0.6 * min(1, max(0, progress)))
                    .opacity(Double(min(1, max(0, progress * 1.4 - 0.4))))
                    .position(x: cx + x, y: height / 2 + 1)
            }
        }
        .frame(height: height + 12)
        .opacity(progress > 0.01 ? 1 : 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Root

private struct AnimKey: Equatable {
    var size: CGSize
    var p: Presentation
    var bubble: Bool
    var squish: Bool
}

struct IslandRoot: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var music: MusicService
    @ObservedObject var timer: TimerService

    var body: some View {
        let p = model.presentation
        let size = model.size(p)
        let tr: CGFloat = p == .expanded ? 14 : 7
        let br: CGFloat = p == .expanded ? 36 : (p == .idle || p == .compact ? 11 : 20)

        ZStack(alignment: .top) {
            GooBubble(progress: model.showBubble ? 1 : 0, islandWidth: size.width, height: model.notch.height) {
                TimerRing(timer: timer, line: 2.5).padding(5)
            }

            ZStack(alignment: .top) {
                NotchShape(top: tr, bottom: br)
                    .fill(Color.black)
                    .frame(width: size.width + tr * 2, height: size.height)
                    .shadow(color: .black.opacity(p == .expanded ? 0.5 : 0), radius: 18, y: 8)

                ZStack(alignment: .top) {
                    switch p {
                    case .expanded:
                        ExpandedView(model: model).transition(.blurPop)
                    case .hud:
                        if let h = model.hud { HUDView(hud: h, notch: model.notch).transition(.blurPop) }
                    case .peek:
                        PeekView(model: model, music: music, timer: timer).transition(.blurPop)
                    case .compact:
                        CompactView(model: model, music: music, timer: timer).transition(.blurPop)
                    case .idle:
                        Color.clear
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(top: 0, bottom: br))
            }
            .scaleEffect(x: model.squish ? 1.06 : 1, y: model.squish ? 0.88 : 1, anchor: .top)
            .contentShape(Rectangle())
            .onTapGesture { if !model.expanded { model.tapOpen() } }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for pr in providers {
                    _ = pr.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.shelf.add(url) } }
                    }
                }
                model.tab = .shelf
                return true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(model.expanded ? .spring(response: 0.46, dampingFraction: 0.64)
                                  : .spring(response: 0.38, dampingFraction: 0.7),
                   value: AnimKey(size: size, p: p, bubble: model.showBubble, squish: model.squish))
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}

// MARK: - Collapsed states

struct ArtThumb: View {
    @ObservedObject var music: MusicService
    var size: CGFloat
    var radius: CGFloat? = nil
    var body: some View {
        Group {
            if let img = music.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [.pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius ?? size * 0.26, style: .continuous))
    }
}

struct MusicBars: View {
    var color: Color
    var playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.2) {
                ForEach(0..<5, id: \.self) { i in
                    let v = playing ? abs(sin(t * (3.1 + Double(i) * 0.9) + Double(i) * 1.7)) : 0.12
                    Capsule().fill(color).frame(width: 2.6, height: 4 + 12 * v)
                }
            }
            .frame(height: 18)
        }
    }
}

struct TimerRing: View {
    @ObservedObject var timer: TimerService
    var line: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(Color.orange.opacity(0.25), lineWidth: line)
            Circle().trim(from: 0, to: max(0.001, 1 - timer.progress))
                .stroke(Color.orange, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: timer.remaining)
        }
    }
}

struct CompactView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var music: MusicService
    @ObservedObject var timer: TimerService

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if model.activity == .music {
                    ArtThumb(music: music, size: 22)
                } else {
                    TimerRing(timer: timer, line: 2.5).frame(width: 18, height: 18)
                }
            }
            .frame(width: model.wing)
            Spacer(minLength: 0)
            Group {
                if model.activity == .music {
                    MusicBars(color: music.accent, playing: music.isPlaying)
                } else {
                    Text(timer.text)
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: model.wing)
        }
        .frame(height: model.notch.height)
    }
}

struct PeekView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var music: MusicService
    @ObservedObject var timer: TimerService

    var body: some View {
        VStack(spacing: 0) {
            CompactView(model: model, music: music, timer: timer)
            HStack(spacing: 6) {
                Text(music.title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                if !music.artist.isEmpty {
                    Text(music.artist).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(height: 28)
        }
    }
}

/// Draws the symbol as a static template bitmap; some multi-layer symbols
/// (the speaker family) come out blank through SwiftUI's symbol renderer here.
struct HUDIcon: View {
    var name: String
    var body: some View {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            Image(nsImage: img).renderingMode(.template)
        } else {
            Image(systemName: "circle.fill").font(.system(size: 9))
        }
    }
}

struct HUDView: View {
    var hud: HUD
    var notch: CGSize

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    HUDIcon(name: hud.icon)
                        .foregroundStyle(hud.tint)
                        .frame(width: 22)
                    Text(hud.title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                }
                .frame(width: 96, alignment: .leading)
                .padding(.leading, 8)
                Spacer(minLength: 0)
                Group {
                    if let level = hud.level {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.18))
                                Capsule().fill(hud.tint)
                                    .frame(width: max(6, g.size.width * level))
                                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: level)
                            }
                        }
                        .frame(width: 74, height: 6)
                    } else if let d = hud.detail {
                        Text(d).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(hud.tint).lineLimit(1)
                    }
                }
                .frame(width: 88, alignment: .trailing)
                .padding(.trailing, 14)
            }
            .frame(height: notch.height)
            if let s = hud.subtitle {
                Text(s).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    .padding(.horizontal, 16).frame(height: 24)
            }
        }
    }
}
