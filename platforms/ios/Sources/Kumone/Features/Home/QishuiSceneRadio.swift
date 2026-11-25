#if os(iOS)
import SwiftUI

/// 汽水「场景电台」：横向场景卡片，点一下就把该场景的歌打乱随机播。
/// 不加载远端封面，只用渐变 + 声波，进入页面几乎没有等待。
struct QishuiSceneRadio: View {
    @EnvironmentObject private var player: PlayerService
    @State private var modes: [QishuiCatalogService.FeedMode] = []
    @State private var loading = true
    @State private var busy: String?

    private let cardWidth: CGFloat = 168
    private let cardHeight: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("场景电台")
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
                    HStack(spacing: 12) {
                        ForEach(modes) { mode in
                            card(mode)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
            }
        }
        .task { await load() }
    }

    private func card(_ mode: QishuiCatalogService.FeedMode) -> some View {
        Button {
            Task { await play(mode) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: palette(for: mode.name),
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                // 声波纹理，让纯色卡片不至于太平。
                HStack(spacing: 3) {
                    ForEach(0..<9, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.16))
                            .frame(width: 3,
                                   height: 14 + CGFloat((index * 37) % 34))
                    }
                }
                .rotationEffect(.degrees(-12))
                .offset(x: cardWidth * 0.34, y: -cardHeight * 0.18)

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

                if busy == mode.id {
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
