import SwiftUI
import AppKit

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var awake: KeepAwake
    @Namespace private var ns

    init(model: IslandModel) {
        self.model = model
        self.awake = model.awake
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                switch model.tab {
                case .home: HomeTab(model: model).transition(.blurPop)
                case .shelf: ShelfTab(shelf: model.shelf, targeted: model.dropTargeting).transition(.blurPop)
                case .clips: ClipsTab(clips: model.clips).transition(.blurPop)
                case .notes: NotesTab().transition(.blurPop)
                case .timer: TimerTab(timer: model.timer).transition(.blurPop)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.36, dampingFraction: 0.72), value: model.tab)
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(IslandTab.allCases, id: \.self) { t in
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) { model.tab = t }
                    } label: {
                        Image(systemName: t.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.tab == t ? .white : .white.opacity(0.45))
                            .frame(width: 34, height: 24)
                            .background {
                                if model.tab == t {
                                    Capsule().fill(Color.white.opacity(0.16)).matchedGeometryEffect(id: "tab", in: ns)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(Bouncy())
                }
            }
            .padding(.leading, 14)
            Spacer(minLength: model.notch.width)
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 20)) { c in
                    Text(c.date, format: .dateTime.hour().minute())
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.trailing, 4)
                toggle("cup.and.saucer.fill", on: awake.on, tint: .orange, help: "Keep Mac awake") { awake.on.toggle() }
                toggle("pin.fill", on: model.pinned, tint: .yellow, help: "Keep island open") { model.pinned.toggle() }
            }
            .padding(.trailing, 16)
        }
        .frame(height: model.notch.height)
    }

    private func toggle(_ icon: String, on: Bool, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(on ? tint : .white.opacity(0.45))
                .frame(width: 26, height: 24)
                .background(Capsule().fill(on ? tint.opacity(0.22) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy())
        .help(help)
    }
}

// MARK: - Home

struct HomeTab: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        HStack(spacing: 10) {
            MusicCard(music: model.music)
            VStack(spacing: 10) {
                DateCard()
                StatsCard(stats: model.stats)
            }
            .frame(width: 214)
        }
    }
}

struct MusicCard: View {
    @ObservedObject var music: MusicService

    var body: some View {
        HStack(spacing: 14) {
            ArtThumb(music: music, size: 104)
                .shadow(color: music.accent.opacity(music.isPlaying ? 0.55 : 0), radius: 16)
                .scaleEffect(music.isPlaying ? 1 : 0.88)
                .animation(.spring(response: 0.45, dampingFraction: 0.55), value: music.isPlaying)

            if music.source == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing playing").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Start something and it lives here.").font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    HStack(spacing: 8) {
                        pill("Music") { music.launch("com.apple.Music") }
                        pill("Spotify") { music.launch("com.spotify.client") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.title).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(music.artist).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        let pos = music.position
                        VStack(spacing: 4) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.15))
                                    Capsule().fill(music.accent)
                                        .frame(width: max(5, g.size.width * (music.duration > 0 ? pos / music.duration : 0)))
                                }
                            }
                            .frame(height: 5)
                            HStack {
                                Text(fmt(pos)); Spacer(); Text(fmt(music.duration))
                            }
                            .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    HStack(spacing: 22) {
                        ctl("backward.fill", 15) { music.previous() }
                        ctl(music.isPlaying ? "pause.fill" : "play.fill", 22) { music.toggle() }
                        ctl("forward.fill", 15) { music.next() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .bubbleCard(26)
    }

    private func fmt(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    private func ctl(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy(scale: 0.72))
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(Bouncy())
    }
}

struct DateCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { c in
            let cal = Calendar.current
            let today = cal.startOfDay(for: c.date)
            let start = cal.date(byAdding: .day, value: -3, to: today) ?? today
            VStack(alignment: .leading, spacing: 6) {
                Text(c.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        let d = cal.date(byAdding: .day, value: i, to: start) ?? today
                        let isToday = i == 3
                        VStack(spacing: 3) {
                            Text(d, format: .dateTime.weekday(.narrow))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("\(cal.component(.day, from: d))")
                                .font(.system(size: 11.5, weight: isToday ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isToday ? .black : .white.opacity(0.7))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(isToday ? Color.white : .clear))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .bubbleCard()
        }
    }
}

struct StatsCard: View {
    @ObservedObject var stats: StatsService
    var body: some View {
        HStack(spacing: 0) {
            if stats.power.hasBattery {
                gauge(Double(stats.power.percent) / 100,
                      stats.power.charging || stats.power.plugged ? "bolt.fill" : "battery.75percent",
                      stats.power.percent <= 20 ? .red : .green)
            }
            gauge(stats.cpu, "cpu", .cyan)
            gauge(stats.memory, "memorychip", .purple)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bubbleCard()
    }

    private func gauge(_ v: Double, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: 4)
                Circle().trim(from: 0, to: max(0.01, v))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.6), value: v)
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            }
            .frame(width: 36, height: 36)
            Text("\(Int((v * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shelf

struct ShelfTab: View {
    @ObservedObject var shelf: ShelfStore
    var targeted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if shelf.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 26, weight: .semibold))
                            .symbolEffect(.bounce, value: targeted)
                        Text("Drag files onto the notch to park them here")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(targeted ? 0.9 : 0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(shelf.items, id: \.self) { url in
                                ShelfItem(url: url) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { shelf.remove(url) }
                                }
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.white.opacity(targeted ? 0.7 : 0.16), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .scaleEffect(targeted ? 1.015 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: targeted)

            VStack(spacing: 10) {
                side("AirDrop", "dot.radiowaves.left.and.right", .blue) { shelf.airdrop() }
                side("Clear", "trash.fill", .red) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { shelf.items = [] }
                }
            }
            .frame(width: 84)
            .opacity(shelf.items.isEmpty ? 0.35 : 1)
            .disabled(shelf.items.isEmpty)
        }
    }

    private func side(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bubbleCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy(scale: 0.9))
    }
}

struct ShelfItem: View {
    var url: URL
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 52, height: 52)
            Text(url.lastPathComponent)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 80)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(hover ? 0.13 : 0.06)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .gray)
                }
                .buttonStyle(Bouncy()).offset(x: 4, y: -4).transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(hover ? 1.05 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: hover)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path)
    }
}

// MARK: - Clipboard

struct ClipsTab: View {
    @ObservedObject var clips: ClipboardService
    @State private var copied: String?

    var body: some View {
        if clips.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 24, weight: .semibold))
                Text("Things you copy show up here").font(.system(size: 12.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bubbleCard(26)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(clips.items, id: \.self) { s in
                        Button {
                            clips.copy(s)
                            copied = s
                            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if copied == s { copied = nil } }
                        } label: {
                            Text(s)
                                .font(.system(size: 11.5, design: s.contains("\n") || s.contains("{") ? .monospaced : .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                                .multilineTextAlignment(.leading)
                                .frame(width: 138, alignment: .topLeading)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .padding(12)
                                .bubbleCard()
                                .overlay {
                                    if copied == s {
                                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.green.opacity(0.85))
                                            .overlay(Label("Copied", systemImage: "checkmark.circle.fill")
                                                .font(.system(size: 13, weight: .bold, design: .rounded)))
                                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Bouncy(scale: 0.92))
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: copied)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

// MARK: - Notes

struct NotesTab: View {
    @AppStorage("notes") private var notes = ""
    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $notes)
                .font(.system(size: 13, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(10)
            if notes.isEmpty {
                Text("Jot something down…")
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
        }
        .bubbleCard(26)
    }
}

// MARK: - Timer

struct TimerTab: View {
    @ObservedObject var timer: TimerService

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                TimerRing(timer: timer, line: 8).padding(14)
                Text(timer.text)
                    .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: timer.text)
            }
            .frame(width: 168)
            .frame(maxHeight: .infinity)
            .bubbleCard(26)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([1, 5, 15, 25, 45, 60], id: \.self) { m in
                        Button { timer.set(minutes: Double(m)); timer.start() } label: {
                            Text("\(m)m")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Capsule().fill(Color.white.opacity(timer.total == Double(m) * 60 ? 0.2 : 0.075)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Bouncy())
                    }
                }
                HStack(spacing: 8) {
                    big(timer.running ? "Pause" : "Start", timer.running ? "pause.fill" : "play.fill", .orange) {
                        timer.running ? timer.stop() : timer.start()
                    }
                    big("Reset", "arrow.counterclockwise", .white.opacity(0.14)) { timer.reset() }
                }
            }
        }
    }

    private func big(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(color))
                .contentShape(Rectangle())
        }
        .buttonStyle(Bouncy(scale: 0.92))
    }
}
