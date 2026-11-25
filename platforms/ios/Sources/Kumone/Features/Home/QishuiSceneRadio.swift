#if os(iOS)
import SwiftUI

/// 场景卡片的封面来源：每个场景取它前几首歌的专辑封面，卡片每隔几秒换一张。
@MainActor
final class QishuiSceneCoverStore: ObservableObject {
    static let shared = QishuiSceneCoverStore()

    @Published private(set) var covers: [String: [String]] = [:]
    private var loading: Set<String> = []

    func covers(for sceneID: String) async -> [String] {
        if let cached = covers[sceneID], !cached.isEmpty { return cached }
        guard !loading.contains(sceneID) else { return covers[sceneID] ?? [] }
        loading.insert(sceneID)
        defer { loading.remove(sceneID) }
        let tracks = (try? await QishuiCatalogService.feed(scene: sceneID, limit: 10)) ?? []
        var seen = Set<String>()
        let urls = tracks.compactMap { $0.album.picUrl }.filter { seen.insert($0).inserted }
        let trimmed = Array(urls.prefix(5))
        if !trimmed.isEmpty { covers[sceneID] = trimmed }
        return trimmed
    }
}

/// 汽水「场景电台」：横向场景卡片，点一下就把该场景的歌打乱随机播。
/// 卡片封面循环展示这个场景里几首歌的专辑封面；拿不到封面时退回渐变。
struct QishuiSceneRadio: View {
    var title: String = "场景电台"

    @EnvironmentObject private var player: PlayerService
    @State private var modes: [QishuiCatalogService.FeedMode] = []
    @State private var loading = true
    @State private var busy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 0)
                if loading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)

            if modes.isEmpty {
                if !loading {
                    Text("暂时拿不到汽水场景，稍后再试")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Layout.contentInset)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(modes) { mode in
                            QishuiSceneCard(mode: mode, busy: busy == mode.id) {
                                Task { await play(mode) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let modes = try? await QishuiCatalogService.feedModes() {
            self.modes = dedupe(modes)
        }
        loading = false
    }

    /// 同一个场景在不同分组里可能重复出现。
    private func dedupe(_ modes: [QishuiCatalogService.FeedMode]) -> [QishuiCatalogService.FeedMode] {
        var seen = Set<String>()
        return modes.filter { seen.insert($0.id).inserted }
    }

    private func play(_ mode: QishuiCatalogService.FeedMode) async {
        guard busy == nil else { return }
        busy = mode.id
        defer { busy = nil }
        guard let tracks = try? await QishuiCatalogService.feed(scene: mode.id, limit: 40),
              !tracks.isEmpty else { return }
        player.play(tracks: tracks.shuffled(), source: .none)
    }
}

/// 单张场景卡：封面轮播 + 底部渐变文字。
private struct QishuiSceneCard: View {
    let mode: QishuiCatalogService.FeedMode
    let busy: Bool
    let action: () -> Void

    @State private var covers: [String] = []
    private let cardWidth: CGFloat = 168
    private let cardHeight: CGFloat = 104

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                background
                LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.74)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.group.isEmpty ? "场景电台" : mode.group)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(mode.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "shuffle")
                            .font(.system(size: 10, weight: .bold))
                            .opacity(0.8)
                    }
                    .foregroundStyle(.white)
                }
                .padding(12)

                if busy {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(10)
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.name)，随机播放")
        .task(id: mode.id) {
            covers = await QishuiSceneCoverStore.shared.covers(for: mode.id)
        }
    }

    @ViewBuilder
    private var background: some View {
        if covers.isEmpty {
            LinearGradient(colors: palette(for: mode.name),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            // TimelineView 只负责给当前这张卡一个时间刻度，不需要每张卡各自起 Timer。
            TimelineView(.periodic(from: .now, by: 3.2)) { context in
                let index = Int(context.date.timeIntervalSince1970 / 3.2) % max(covers.count, 1)
                ZStack {
                    ForEach(covers.indices, id: \.self) { offset in
                        CachedAsyncImage(url: covers[offset].resizedImageURL(320)) {
                            Color.black.opacity(0.3)
                        }
                        .opacity(offset == index ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: 0.7), value: index)
            }
        }
    }

    private func palette(for name: String) -> [Color] {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        let base = Double(seed)
        return [
            Color(hue: base / 360, saturation: 0.52, brightness: 0.62),
            Color(hue: ((base + 42).truncatingRemainder(dividingBy: 360)) / 360,
                  saturation: 0.66, brightness: 0.34),
        ]
    }
}
#endif
