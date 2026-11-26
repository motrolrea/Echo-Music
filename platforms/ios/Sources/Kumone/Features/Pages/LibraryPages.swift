import SwiftUI

// MARK: - 最近播放

struct RecentsView: View {
    @EnvironmentObject private var player: PlayerService

    private var tracks: [Track] { player.recentTracks }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("按本机最近播放排序")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        player.play(tracks: tracks, source: .none, context: .recents)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(tracks.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if tracks.isEmpty {
                    EmptyStateView(icon: "clock", title: "暂无播放记录", subtitle: "在这里听过的歌会按时间出现")
                        .frame(minHeight: 300)
                } else {
                    recordList
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("最近播放")
    }

    private var recordList: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(tracks.enumerated()), id: \.element.playbackKey) { index, track in
                TrackRow(
                    track: track,
                    index: index + 1,
                    style: .compact
                ) {
                    player.play(tracks: tracks, source: .none, startAt: track, context: .recents)
                }
            }
        }
    }
}

// MARK: - 音乐云盘

struct CloudView: View {
    @State private var items: [CloudSongItem] = []
    @State private var sizeInfo: String?
    @State private var isLoading = true

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if let sizeInfo {
                        Text(sizeInfo)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        player.play(tracks: tracks, source: .cloud, context: .cloud)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(items.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if items.isEmpty {
                    EmptyStateView(icon: "icloud", title: "云盘还没有歌曲",
                                   subtitle: "在网易云音乐客户端上传的歌曲会出现在这里")
                        .frame(minHeight: 300)
                } else {
                    TrackListView(tracks: tracks, style: .compact, source: .cloud, context: .cloud)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("音乐云盘")
        .task {
            if items.isEmpty {
                await load()
            }
        }
    }

    private var tracks: [Track] {
        items.compactMap(\.simpleSong)
    }

    private func load() async {
        isLoading = items.isEmpty
        if let response = try? await NeteaseAPI.cloudSongs() {
            items = response.data ?? []
            if let size = response.size, let max = response.maxSize, max > 0 {
                let used = String(format: "%.1f", Double(size) / 1_073_741_824)
                let total = String(format: "%.0f", Double(max) / 1_073_741_824)
                sizeInfo = String(localized: "已使用 \(used) GB / \(total) GB")
            }
        }
        isLoading = false
    }
}
