import SwiftUI
import AppKit

// MARK: - Online lookups
//
// Two things can't be read from the player itself: lyrics, and covers for some
// streamed tracks. Both are looked up by song title and artist — lyrics from
// lrclib.net, covers from Apple's iTunes Search and then Deezer. Nothing else is sent, and
// "Online Lyrics & Covers" in the menu turns both off.

enum Online {
    static var enabled: Bool {
        get {
            if ProcessInfo.processInfo.environment["DROPLET_SNAPSHOT"] != nil { return false }
            return UserDefaults.standard.object(forKey: "online") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "online") }
    }

    private static func get(_ base: String, _ items: [String: String]) -> Data? {
        guard var c = URLComponents(string: base) else { return nil }
        c.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Droplet/1.0", forHTTPHeaderField: "User-Agent")
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 14)
        return result
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: " (").first ?? ""
    }

    private static func image(at string: String?) -> NSImage? {
        guard let string, let url = URL(string: string), let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// Blocking; call off the main thread. Tries Apple's catalogue, then Deezer's.
    static func cover(title: String, artist: String) -> NSImage? {
        guard !title.isEmpty else { return nil }
        let t = norm(title), a = norm(artist)
        NSLog("Droplet cover lookup start t=[%@] a=[%@]", t, a)
        func artistMatches(_ other: String) -> Bool {
            let o = norm(other)
            return a.isEmpty || o.contains(a.prefix(5)) || a.contains(o.prefix(5))
        }

        if let data = get("https://itunes.apple.com/search", ["term": "\(title) \(artist)", "entity": "song", "limit": "8"]),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let hit = results.first(where: { norm($0["trackName"] as? String ?? "") == t && artistMatches($0["artistName"] as? String ?? "") }),
           let small = hit["artworkUrl100"] as? String,
           let img = image(at: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")) {
            return img
        }

        // Deezer: full query first, then title only (artist spellings vary).
        for query in ["\(title) \(artist)", title] {
            guard let data = get("https://api.deezer.com/search", ["q": query, "limit": "10"]),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["data"] as? [[String: Any]], !results.isEmpty else { continue }
            func name(_ r: [String: Any]) -> String { (r["artist"] as? [String: Any])?["name"] as? String ?? "" }
            func track(_ r: [String: Any]) -> String { norm(r["title"] as? String ?? "") }
            let hit = results.first { track($0) == t && artistMatches(name($0)) }
                ?? results.first { artistMatches(name($0)) && !track($0).isEmpty && (track($0).contains(t) || t.contains(track($0))) }
                ?? results.first { track($0) == t && a.isEmpty }
            NSLog("Droplet deezer results=%d hit=%d", results.count, hit == nil ? 0 : 1)
            let album = hit?["album"] as? [String: Any]
            for key in ["cover_xl", "cover_big", "cover_medium"] {
                if let img = image(at: album?[key] as? String) { return img }
            }
        }
        NSLog("Droplet cover lookup: nothing found")
        return nil
    }

    /// Blocking; call off the main thread. Returns timed lines when available.
    static func lyrics(title: String, artist: String, duration: Double) -> [LyricLine]? {
        guard !title.isEmpty,
              let data = get("https://lrclib.net/api/search", ["track_name": title, "artist_name": artist]),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty else { return nil }
        func gap(_ r: [String: Any]) -> Double { abs(((r["duration"] as? NSNumber)?.doubleValue ?? 0) - duration) }
        let usable = list.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false || ($0["plainLyrics"] as? String)?.isEmpty == false }
        let close = duration > 0 ? usable.filter { gap($0) < 4 } : usable
        let pool = close.isEmpty ? usable : close
        let pick = pool.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }.min { gap($0) < gap($1) }
            ?? pool.min { gap($0) < gap($1) }
        guard let pick else { return nil }
        // Only trust timings when the recording length matches.
        if let synced = pick["syncedLyrics"] as? String, !synced.isEmpty, duration <= 0 || gap(pick) < 4 {
            let lines = LyricLine.parse(lrc: synced)
            if !lines.isEmpty { return lines }
        }
        let plain = (pick["plainLyrics"] as? String) ?? LyricLine.parse(lrc: (pick["syncedLyrics"] as? String) ?? "").map(\.text).joined(separator: "\n")
        let lines = plain.components(separatedBy: "\n").map { LyricLine(time: nil, text: $0.trimmingCharacters(in: .whitespaces)) }
        return lines.contains { !$0.text.isEmpty } ? lines : nil
    }
}

struct LyricLine: Equatable {
    var time: Double?
    var text: String

    static func parse(lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.components(separatedBy: "\n") {
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { continue }
            let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let sec = Double(stamp[1]) else { continue }
            let text = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
            out.append(LyricLine(time: m * 60 + sec, text: text))
        }
        return out
    }
}

final class LyricsService: ObservableObject {
    enum Status { case idle, loading, ready, none, off }
    @Published var lines: [LyricLine] = []
    @Published var status: Status = .idle
    private var key = ""
    private let queue = DispatchQueue(label: "droplet.lyrics")

    var synced: Bool { lines.first?.time != nil }

    func load(title: String, artist: String, duration: Double) {
        let k = title + "|" + artist
        guard k != key || status == .off else { return }
        key = k
        lines = []
        guard !title.isEmpty else { status = .idle; return }
        guard Online.enabled else { status = .off; return }
        status = .loading
        queue.async { [weak self] in
            let found = Online.lyrics(title: title, artist: artist, duration: duration)
            DispatchQueue.main.async {
                guard let self, self.key == k else { return }
                self.lines = found ?? []
                self.status = found == nil ? .none : .ready
            }
        }
    }

    func index(at position: Double) -> Int? {
        guard synced else { return nil }
        var idx: Int?
        for (i, l) in lines.enumerated() {
            guard let t = l.time else { continue }
            if t <= position + 0.25 { idx = i } else { break }
        }
        return idx
    }
}

// MARK: - View

struct LyricsCard: View {
    @ObservedObject var music: MusicService
    @ObservedObject var lyrics: LyricsService

    var body: some View {
        Group {
            switch lyrics.status {
            case .ready:
                if lyrics.synced { syncedView } else { plainView }
            case .loading:
                note("Finding lyrics…")
            case .none:
                note("No lyrics for this song")
            case .off:
                note("Online lyrics are turned off")
            case .idle:
                note("Lyrics appear here")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bubbleCard(18)
        .task(id: music.title + "|" + music.artist + "|\(Int(music.duration))") {
            lyrics.load(title: music.title, artist: music.artist, duration: music.duration)
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
    }

    private var syncedView: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let current = lyrics.index(at: music.position)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.text.isEmpty ? "···" : line.text)
                                .font(.system(size: 13, weight: i == current ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(i == current ? 1 : 0.32))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 70)
                    .animation(.easeInOut(duration: 0.25), value: current)
                }
                .onChange(of: current) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(new, anchor: .center) }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    private var plainView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }
}
