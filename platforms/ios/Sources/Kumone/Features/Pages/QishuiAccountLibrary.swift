#if os(iOS)
import SwiftUI

/// 汽水账号在「我的」页的内容：我喜欢的音乐、最近播放、自建歌单与收藏歌单。
/// 车机协议里账号歌单来自 `/me/playlist/`（自建）与 `/me/collection/mixed/`（收藏）。
struct QishuiAccountLibrary: View {
    @ObservedObject private var session = QishuiSessionStore.shared
    @State private var playlists: [QishuiCatalogService.PlaylistSummary] = []
    @State private var recentTracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var liked: QishuiCatalogService.PlaylistSummary? {
        playlists.first(where: \.isLiked)
    }

    private var owned: [QishuiCatalogService.PlaylistSummary] {
        playlists.filter { $0.isOwned && !$0.isLiked }
    }

    private var collected: [QishuiCatalogService.PlaylistSummary] {
        playlists.filter { !$0.isOwned }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("汽水收藏")
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 0)
                if isLoading { ProgressView().controlSize(.small) }
            }

            if !session.isLoggedIn {
                Text("登录汽水音乐后，这里会显示我喜欢的音乐、最近播放、我的歌单和收藏歌单。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLoading && playlists.isEmpty && recentTracks.isEmpty {
                Text("正在读取汽水账号…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if playlists.isEmpty && recentTracks.isEmpty {
                Text(errorMessage ?? "汽水账号暂时没有可显示的内容")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 12) {
                    if let liked {
                        shortcutRow(title: "我喜欢的音乐",
                                    subtitle: liked.trackCount > 0 ? "\(liked.trackCount) 首" : "红心歌曲",
                                    cover: liked.coverURL,
                                    systemImage: "heart.fill",
                                    tint: .pink) {
                            AccountPlaylistTracksView(title: "我喜欢的音乐") {
                                let credential = await MainActor.run { QishuiSessionStore.shared.credential }
                                return try await QishuiCatalogService.likedTracks(limit: 300,
                                                                                 credential: credential)
                            }
                        }
                    }
                    if !recentTracks.isEmpty {
                        shortcutRow(title: "最近播放",
                                    subtitle: "\(recentTracks.count) 首",
                                    cover: recentTracks.first?.album.picUrl,
                                    systemImage: "clock.fill",
                                    tint: .orange) {
                            AccountPlaylistTracksView(title: "最近播放") {
                                () async throws -> [Track] in recentTracks
                            }
                        }
                    }
                }

                if !owned.isEmpty {
                    group("我的歌单", Array(owned.prefix(10)))
                }
                if !collected.isEmpty {
                    group("收藏的歌单", Array(collected.prefix(10)))
                }
            }

            if let errorMessage, !(playlists.isEmpty && recentTracks.isEmpty) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: session.sessionRevision) { await load() }
    }

    private func group(_ title: String, _ items: [QishuiCatalogService.PlaylistSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                playlistRow(item)
            }
        }
    }

    private func playlistRow(_ item: QishuiCatalogService.PlaylistSummary) -> some View {
        NavigationLink {
            AccountPlaylistTracksView(title: item.name) {
                let credential = await MainActor.run { QishuiSessionStore.shared.credential }
                return try await QishuiCatalogService.playlistDetail(
                    id: item.id, ownerId: item.ownerId, limit: 1000,
                    credential: credential
                ).tracks
            }
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: item.coverURL?.resizedImageURL(160)) {
                    RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.18))
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(item.trackCount > 0 ? "\(item.trackCount) 首"
                                             : (item.isOwned ? "我的歌单" : "收藏歌单"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortcutRow<Destination: View>(
        title: String, subtitle: String, cover: String?, systemImage: String, tint: Color,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if let cover {
                        CachedAsyncImage(url: cover.resizedImageURL(160)) {
                            tint.opacity(0.18)
                        }
                    } else {
                        LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard session.isLoggedIn, let credential = session.credential else {
            playlists = []
            recentTracks = []
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            playlists = try await QishuiCatalogService.myPlaylists(credential: credential)
            DiagnosticLogStore.shared.append(
                level: .info, category: "汽水",
                message: "账号歌单 \(playlists.count) 个（自建 \(owned.count)、收藏 \(collected.count)）")
        } catch {
            errorMessage = "歌单读取失败：\(error.localizedDescription)"
            DiagnosticLogStore.shared.append(level: .error, category: "汽水",
                                             message: "账号歌单读取失败", detail: "\(error)")
        }
        recentTracks = (try? await QishuiCatalogService.recentPlayed(limit: 60, credential: credential)) ?? []
    }
}
#endif
