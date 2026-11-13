import SwiftUI
import AppIntents
import WidgetKit

struct EchoQueueRow: Codable, Hashable, Identifiable {
    var title: String
    var artist: String
    var index: Int
    var current: Bool

    var id: String { "\(index)|\(title)" }
}

private enum EchoWidgetStore {
    static let suiteName = "group.com.motrolrea.echomusic"

    static func entry(at date: Date = Date()) -> EchoPlayEntry {
        if let file = containerURL()?.appendingPathComponent("echo-widget-snapshot.json"),
           let data = try? Data(contentsOf: file),
           let snapshot = try? JSONDecoder().decode(WidgetFile.self, from: data) {
            return EchoPlayEntry(
                date: date,
                title: snapshot.title,
                artist: snapshot.artist,
                playing: snapshot.playing,
                elapsed: snapshot.elapsed,
                duration: snapshot.duration,
                cover: coverImage(),
                queue: snapshot.queue.map {
                    EchoQueueRow(title: $0.title, artist: $0.artist, index: $0.index, current: $0.current)
                }
            )
        }
        let defaults = UserDefaults(suiteName: suiteName)
        let title = defaults?.string(forKey: "echo.widget.title") ?? ""
        return EchoPlayEntry(
            date: date,
            title: title,
            artist: defaults?.string(forKey: "echo.widget.artist") ?? "",
            playing: defaults?.bool(forKey: "echo.widget.playing") ?? false,
            elapsed: defaults?.double(forKey: "echo.widget.elapsed") ?? 0,
            duration: defaults?.double(forKey: "echo.widget.duration") ?? 0,
            cover: coverImage(),
            queue: queue(from: defaults)
        )
    }

    private struct WidgetFile: Codable {
        var title: String
        var artist: String
        var playing: Bool
        var elapsed: Double
        var duration: Double
        var queue: [Row]
        struct Row: Codable { var title: String; var artist: String; var index: Int; var current: Bool }
    }

    private static func queue(from defaults: UserDefaults?) -> [EchoQueueRow] {
        guard let data = defaults?.data(forKey: "echo.widget.queue"),
              let rows = try? JSONDecoder().decode([EchoQueueRow].self, from: data) else { return [] }
        return rows
    }

    private static func coverImage() -> UIImage? {
        guard let file = containerURL()?.appendingPathComponent("echo-widget-cover.jpg"),
              let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data)
    }

    private static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }
}

struct EchoPlayEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let playing: Bool
    let elapsed: Double
    let duration: Double
    let cover: UIImage?
    let queue: [EchoQueueRow]

    var hasTrack: Bool { !title.isEmpty }

    var progress: Double {
        guard duration > 1 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    var upcoming: [EchoQueueRow] { queue.filter { !$0.current } }
}

struct EchoPlayProvider: TimelineProvider {
    func placeholder(in context: Context) -> EchoPlayEntry {
        sample
    }

    func getSnapshot(in context: Context, completion: @escaping (EchoPlayEntry) -> Void) {
        completion(context.isPreview ? sample : EchoWidgetStore.entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EchoPlayEntry>) -> Void) {
        let entry = EchoWidgetStore.entry()
        var entries = [entry]
        if entry.playing, entry.duration > 1 {
            entries = (0..<30).map { step in
                let elapsed = min(entry.elapsed + Double(step) * 2, entry.duration)
                return EchoPlayEntry(
                    date: Date().addingTimeInterval(Double(step) * 2),
                    title: entry.title,
                    artist: entry.artist,
                    playing: elapsed < entry.duration,
                    elapsed: elapsed,
                    duration: entry.duration,
                    cover: entry.cover,
                    queue: entry.queue
                )
            }
        }
        let refresh = entry.hasTrack ? 20.0 : 5 * 60
        completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(refresh))))
    }

    private var sample: EchoPlayEntry {
        EchoPlayEntry(
            date: Date(), title: "晴天", artist: "周杰伦",
            playing: true, elapsed: 46, duration: 269, cover: nil,
            queue: [
                EchoQueueRow(title: "晴天", artist: "周杰伦", index: 0, current: true),
                EchoQueueRow(title: "七里香", artist: "周杰伦", index: 1, current: false),
                EchoQueueRow(title: "稻香", artist: "周杰伦", index: 2, current: false),
                EchoQueueRow(title: "夜曲", artist: "周杰伦", index: 3, current: false),
                EchoQueueRow(title: "青花瓷", artist: "周杰伦", index: 4, current: false),
                EchoQueueRow(title: "告白气球", artist: "周杰伦", index: 5, current: false)
            ]
        )
    }
}

private enum EchoCardStyle {
    case compact, regular, expanded
}

struct EchoNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EchoNowPlaying", provider: EchoPlayProvider()) { entry in
            EchoNowPlayingView(entry: entry)
        }
        .configurationDisplayName("正在播放")
        .description("封面、进度和控制。中号和大号还会列出接下来的歌。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct EchoOpenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EchoOpenPlayer", provider: EchoPlayProvider()) { entry in
            EchoPlayerCard(entry: entry, style: .compact)
        }
        .configurationDisplayName("播放卡片")
        .description("桌面上的迷你播放器，显示当前歌曲和控制。")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct EchoWidgetBundle: WidgetBundle {
    var body: some Widget {
        EchoNowPlayingWidget()
        EchoOpenWidget()
    }
}

private struct EchoNowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: EchoPlayEntry

    private var style: EchoCardStyle {
        switch family {
        case .systemMedium: return .regular
        case .systemLarge: return .expanded
        default: return .compact
        }
    }

    var body: some View {
        EchoPlayerCard(entry: entry, style: style)
    }
}

private struct EchoPlayerCard: View {
    let entry: EchoPlayEntry
    var style: EchoCardStyle

    private var title: String { entry.hasTrack ? entry.title : "Echo Music" }
    private var artist: String { entry.hasTrack ? (entry.artist.isEmpty ? "未知歌手" : entry.artist) : "还没有在播放" }
    private let accent = Color(red: 1, green: 0.42, blue: 0.55)

    private var rows: [EchoQueueRow] {
        switch style {
        case .compact: return []
        case .regular: return Array(entry.upcoming.prefix(2))
        case .expanded: return Array(entry.upcoming.prefix(5))
        }
    }

    var body: some View {
        Group {
            if style == .expanded {
                VStack(alignment: .leading, spacing: 10) {
                    nowPlaying(coverSide: 86)
                    queueList
                }
            } else if style == .regular {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        cover(side: 72)
                        VStack(alignment: .leading, spacing: 6) {
                            titles(titleSize: 15, artistSize: 12)
                            progressBar
                            controls
                        }
                    }
                    if !rows.isEmpty { queueList }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        cover(side: 52)
                        titles(titleSize: 14, artistSize: 11)
                    }
                    progressBlock
                    controls
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .echoWidgetChrome(cover: entry.cover)
    }

    private func nowPlaying(coverSide: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            cover(side: coverSide)
            VStack(alignment: .leading, spacing: 8) {
                titles(titleSize: 18, artistSize: 13)
                progressBlock
                controls
            }
        }
    }

    private func titles(titleSize: CGFloat, artistSize: CGFloat) -> some View {
        Link(destination: URL(string: "moumusic://nowplaying")!) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(artist)
                    .font(.system(size: artistSize))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cover(side: CGFloat) -> some View {
        Link(destination: URL(string: "moumusic://nowplaying")!) {
            ZStack {
                if let image = entry.cover {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.95, green: 0.35, blue: 0.48), Color(red: 0.35, green: 0.18, blue: 0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.18, style: .continuous)
                    .stroke(.white.opacity(0.32), lineWidth: 0.8)
            )
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 4) {
            progressBar
            if style == .expanded {
                HStack {
                    Text(clock(entry.elapsed))
                    Spacer(minLength: 0)
                    Text(clock(entry.duration))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(accent)
                    .frame(width: max(4, geo.size.width * entry.progress))
            }
        }
        .frame(height: 3)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            playbackControl("backward.fill", command: "previous", primary: false)
            playbackControl(entry.playing ? "pause.fill" : "play.fill", command: entry.playing ? "pause" : "play", primary: true)
            playbackControl("forward.fill", command: "next", primary: false)
        }
    }

    private func playbackControl(_ symbol: String, command: String, primary: Bool) -> some View {
        let label = Image(systemName: symbol)
            .font(.system(size: style == .compact ? 13 : 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: style == .expanded ? 30 : 26)
            .background(primary ? accent.opacity(0.95) : Color.white.opacity(0.14), in: Capsule())
        return playbackControlBody(command: command, label: label)
    }

    @ViewBuilder
    private func playbackControlBody(command: String, label: some View) -> some View {
        if #available(iOS 17.0, *) {
            Button(intent: EchoPlaybackIntent(command: command)) { label }
                .buttonStyle(.plain)
        } else {
            Link(destination: URL(string: playbackLink(command))!) { label }
        }
    }

    private func playbackLink(_ command: String) -> String {
        if command == "play" { return "moumusic://toggle?play=1" }
        if command == "pause" { return "moumusic://toggle?play=0" }
        return "moumusic://\(command)"
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if style == .expanded {
                Text("接下来")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
            }
            if rows.isEmpty {
                Text(entry.hasTrack ? "播放后显示接下来的歌" : "还没有队列")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            } else {
                ForEach(rows) { row in
                    queueRow(row)
                }
            }
        }
    }

    private func queueRow(_ row: EchoQueueRow) -> some View {
        let link = row.index >= 0 ? "moumusic://play?index=\(row.index)" : "moumusic://nowplaying"
        return Link(destination: URL(string: link)!) {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 12)
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(row.artist.isEmpty ? "未知歌手" : row.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: style == .expanded ? 26 : 22)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct EchoWidgetBackground: View {
    let cover: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.24, green: 0.08, blue: 0.16),
                    Color(red: 0.07, green: 0.06, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 28)
                    .scaleEffect(1.35)
                    .opacity(0.78)
            }
            LinearGradient(
                colors: [Color.black.opacity(0.12), Color.black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Color(red: 1, green: 0.42, blue: 0.55).opacity(0.34))
                .frame(width: 160, height: 160)
                .blur(radius: 36)
                .offset(x: 110, y: -80)
        }
    }
}

private extension View {
    @ViewBuilder
    func echoWidgetChrome(cover: UIImage?) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { EchoWidgetBackground(cover: cover) }
        } else {
            padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(EchoWidgetBackground(cover: cover))
        }
    }
}

@available(iOS 17.0, *)
struct EchoPlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放控制"
    static var openAppWhenRun = false

    @Parameter(title: "命令")
    var command: String

    init() { command = "play" }
    init(command: String) { self.command = command }

    func perform() async throws -> some IntentResult {
        let suite = "group.com.motrolrea.echomusic"
        let defaults = UserDefaults(suiteName: suite)
        defaults?.set(command, forKey: "echo.widget.command")
        defaults?.set(Date().timeIntervalSince1970, forKey: "echo.widget.commandAt")
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suite) {
            let file = container.appendingPathComponent("echo-widget-command.txt")
            try? Data(command.utf8).write(to: file, options: .atomic)
        }
        let name = CFNotificationName("com.motrolrea.echomusic.widget.command" as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
        return .result()
    }
}
