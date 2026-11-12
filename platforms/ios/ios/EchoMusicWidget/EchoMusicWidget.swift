import SwiftUI
import WidgetKit

private enum EchoWidgetStore {
    static let suiteName = "group.com.jiajia2222.moumusic"

    static func entry(at date: Date = Date()) -> EchoPlayEntry {
        let defaults = UserDefaults(suiteName: suiteName)
        let title = defaults?.string(forKey: "echo.widget.title") ?? ""
        let artist = defaults?.string(forKey: "echo.widget.artist") ?? ""
        let playing = defaults?.bool(forKey: "echo.widget.playing") ?? false
        return EchoPlayEntry(date: date, title: title, artist: artist, playing: playing)
    }
}

struct EchoPlayEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let playing: Bool

    var hasTrack: Bool { !title.isEmpty }
}

struct EchoPlayProvider: TimelineProvider {
    func placeholder(in context: Context) -> EchoPlayEntry {
        EchoPlayEntry(date: Date(), title: "Echo Music", artist: "点按打开播放器", playing: false)
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
        .description("在桌面查看当前歌曲，点按打开播放器。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct EchoOpenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EchoOpenPlayer", provider: EchoPlayProvider()) { entry in
            EchoOpenView(entry: entry)
        }
        .configurationDisplayName("打开播放器")
        .description("从桌面直接打开 Echo Music 播放页。")
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
        Group {
            if family == .systemMedium {
                HStack(spacing: 12) {
                    mark
                    VStack(alignment: .leading, spacing: 4) {
                        Text(titleText)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(subtitleText)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        status
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    mark
                    Spacer(minLength: 0)
                    Text(titleText)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    status
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "moumusic://nowplaying"))
        .echoWidgetChrome()
    }

    private var titleText: String { entry.hasTrack ? entry.title : "Echo Music" }

    private var subtitleText: String {
        if entry.hasTrack {
            return entry.artist.isEmpty ? "Echo Music" : entry.artist
        }
        return "打开播放器"
    }

    private var mark: some View {
        ZStack {
            Circle().fill(.white.opacity(0.16))
            Image(systemName: entry.playing ? "waveform" : "music.note")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }

    private var status: some View {
        Text(entry.playing ? "正在播放" : (entry.hasTrack ? "已暂停" : "点按继续"))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 1, green: 0.48, blue: 0.64))
    }
}

private struct EchoOpenView: View {
    let entry: EchoPlayEntry

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
            Text("Echo Music")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text(entry.hasTrack ? entry.title : "打开播放器")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "moumusic://nowplaying"))
        .echoWidgetChrome()
    }
}

private struct EchoWidgetBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.18, green: 0.07, blue: 0.16),
                Color(red: 0.07, green: 0.08, blue: 0.14)
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
