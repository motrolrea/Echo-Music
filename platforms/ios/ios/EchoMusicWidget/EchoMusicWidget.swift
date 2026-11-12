import SwiftUI
import WidgetKit

private enum EchoWidgetStore {
    static let suiteName = "group.com.jiajia2222.moumusic"

    static func entry(at date: Date = Date()) -> EchoPlayEntry {
        let defaults = UserDefaults(suiteName: suiteName)
        let title = defaults?.string(forKey: "echo.widget.title") ?? ""
        let artist = defaults?.string(forKey: "echo.widget.artist") ?? ""
        let playing = defaults?.bool(forKey: "echo.widget.playing") ?? false
        let elapsed = defaults?.double(forKey: "echo.widget.elapsed") ?? 0
        let duration = defaults?.double(forKey: "echo.widget.duration") ?? 0
        return EchoPlayEntry(
            date: date,
            title: title,
            artist: artist,
            playing: playing,
            elapsed: elapsed,
            duration: duration,
            cover: coverImage()
        )
    }

    private static func coverImage() -> UIImage? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else { return nil }
        let file = container.appendingPathComponent("echo-widget-cover.jpg")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return UIImage(data: data)
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

    var hasTrack: Bool { !title.isEmpty }

    var progress: Double {
        guard duration > 1 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }
}

struct EchoPlayProvider: TimelineProvider {
    func placeholder(in context: Context) -> EchoPlayEntry {
        EchoPlayEntry(
            date: Date(), title: "晴天", artist: "周杰伦",
            playing: true, elapsed: 46, duration: 269, cover: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (EchoPlayEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : EchoWidgetStore.entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EchoPlayEntry>) -> Void) {
        let entry = EchoWidgetStore.entry()
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct EchoNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EchoNowPlaying", provider: EchoPlayProvider()) { entry in
            EchoNowPlayingView(entry: entry)
        }
        .configurationDisplayName("正在播放")
        .description("封面、歌名、歌手和播放进度，点按进入播放页。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct EchoOpenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EchoOpenPlayer", provider: EchoPlayProvider()) { entry in
            EchoPlayerCard(entry: entry, compact: true)
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

    var body: some View {
        EchoPlayerCard(entry: entry, compact: family == .systemSmall)
    }
}

private struct EchoPlayerCard: View {
    let entry: EchoPlayEntry
    var compact: Bool

    private var title: String { entry.hasTrack ? entry.title : "Echo Music" }
    private var artist: String { entry.hasTrack ? (entry.artist.isEmpty ? "未知歌手" : entry.artist) : "还没有在播放" }
    private let accent = Color(red: 1, green: 0.42, blue: 0.55)

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        cover(side: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    progressBar
                    controls
                }
            } else {
                HStack(spacing: 12) {
                    cover(side: 92)
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(artist)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                        progressBar
                        controls
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "moumusic://nowplaying"))
        .echoWidgetChrome()
    }

    private func cover(side: CGFloat) -> some View {
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
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(accent).frame(width: max(4, geo.size.width * entry.progress))
            }
        }
        .frame(height: 3)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            control("backward.fill", "moumusic://previous")
            control(entry.playing ? "pause.fill" : "play.fill", "moumusic://toggle")
            control("forward.fill", "moumusic://next")
        }
    }

    private func control(_ symbol: String, _ link: String) -> some View {
        Link(destination: URL(string: link)!) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 13 : 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(.white.opacity(0.12), in: Capsule())
        }
    }
}

private struct EchoWidgetBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.20, green: 0.07, blue: 0.14),
                Color(red: 0.08, green: 0.07, blue: 0.13)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private extension View {
    @ViewBuilder
    func echoWidgetChrome() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { EchoWidgetBackground() }
        } else {
            padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(EchoWidgetBackground())
        }
    }
}
