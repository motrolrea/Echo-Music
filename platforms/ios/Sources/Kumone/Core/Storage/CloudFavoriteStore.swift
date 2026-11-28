import Foundation
import Combine

/// 云端收藏索引：把各音乐平台账号里的歌单（「我喜欢的音乐」+ 自己收藏/创建的歌单）
/// 以及已经同步到本地的平台歌单汇总成一组歌曲 key，供歌曲列表显示红心。
/// 只用于界面标记，不参与播放。
@MainActor
final class CloudFavoriteStore: ObservableObject {
    static let shared = CloudFavoriteStore()

    @Published private(set) var keys: Set<String> = []

    private let storageKey = "moumusic.cloudFavorites.v1"
    private let refreshInterval: TimeInterval = 600
    /// 每个平台最多读取的手机歌单数：账号里可能有几十个歌单，全量拉取会被平台限流。
    private let maxPlaylistsPerPlatform = 6
    private var lastRefreshAt: Date?
    private var isRefreshing = false

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: storageKey) {
            keys = Set(saved)
        }
    }

    func contains(_ track: Track) -> Bool {
        keys.contains(Self.key(for: track))
    }

    /// 与 `Track.playbackKey` 同源，只保留「来源 + 平台 ID」，因此同一首歌在
    /// 不同歌单里名称带后缀（Live、伴奏版等）也能匹配上。
    static func key(for track: Track) -> String {
        let parts = track.playbackKey.split(separator: ":", maxSplits: 2,
                                           omittingEmptySubsequences: false)
        let source = parts.first.map(String.init) ?? ""
        // 酷狗同一首歌在不同接口里的 audio_id 可能缺失，hash 才是稳定标识。
        if source == "kg", let hash = track.sourceMetadata["hash"], !hash.isEmpty {
            return "kg|\(hash.lowercased())"
        }
        return parts.prefix(2).joined(separator: "|")
    }

    func refreshIfNeeded(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let lastRefreshAt,
           Date().timeIntervalSince(lastRefreshAt) < refreshInterval {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var collected = Set<String>()

        // 已经同步到本地的平台歌单。
        for playlist in LocalPlaylistStore.shared.playlists where playlist.remoteSource != nil {
            for track in playlist.tracks {
                collected.insert(Self.key(for: track))
            }
        }

        await collectNetease(&collected)
        await collectQishui(&collected)
        await collectQQ(&collected)
        await collectKugou(&collected)

        // 账号信息还没加载完时先不写缓存，下次进入前台会再试一次。
        guard !collected.isEmpty else { return }
        keys = collected
        lastRefreshAt = Date()
        UserDefaults.standard.set(Array(collected), forKey: storageKey)
    }

    // MARK: - Platforms

    /// 网易云：「我喜欢的音乐」+ 自己创建/收藏的歌单。
    private func collectNetease(_ collected: inout Set<String>) async {
        for id in AccountStore.shared.likedTrackIDs {
            collected.insert("wy|\(id)")
        }
        guard AccountStore.shared.profile != nil else { return }
        for list in AccountStore.shared.createdPlaylists.prefix(maxPlaylistsPerPlatform) {
            guard let response = try? await NeteaseAPI.playlistDetail(id: list.id) else { continue }
            for track in response.playlist.tracks {
                collected.insert(Self.key(for: track.withSource("wy")))
            }
        }
    }

    /// 汽水音乐：「喜欢」和收藏的歌单。
    private func collectQishui(_ collected: inout Set<String>) async {
        guard let credential = QishuiSessionStore.shared.credential,
              let lists = try? await QishuiCatalogService.myPlaylists(credential: credential) else {
            return
        }
        let picked = lists.sorted { $0.isLiked && !$1.isLiked }.prefix(maxPlaylistsPerPlatform)
        for list in picked {
            guard let page = try? await QishuiCatalogService.playlistDetail(
                id: list.id, ownerId: list.ownerId, limit: 200, offset: 0,
                credential: credential, playlistType: 1
            ) else { continue }
            for track in page.tracks {
                collected.insert(Self.key(for: track))
            }
        }
    }

    /// QQ 音乐：「我喜欢」和账号里的歌单。
    private func collectQQ(_ collected: inout Set<String>) async {
        guard QQMusicSessionStore.shared.isLoggedIn,
              let cookie = QQMusicSessionStore.shared.cookie,
              let lists = try? await QQMusicAPI.shared.userPlaylists(cookie: cookie) else {
            return
        }
        let picked = lists.sorted { $0.name.contains("喜欢") && !$1.name.contains("喜欢") }
            .prefix(maxPlaylistsPerPlatform)
        for list in picked {
            guard let detail = try? await LXCatalogService.playlistDetail(source: .tx,
                                                                          id: list.id) else { continue }
            for track in detail.tracks {
                collected.insert(Self.key(for: track))
            }
        }
    }

    /// 酷狗音乐：「我喜欢」和账号里的歌单。
    private func collectKugou(_ collected: inout Set<String>) async {
        guard KugouSessionStore.shared.isLoggedIn,
              let cookie = await KugouSessionStore.shared.cookieWithDevice(),
              let lists = try? await KugouAPI.shared.userPlaylists(cookie: cookie) else {
            return
        }
        let picked = lists.sorted {
            ($0.name.contains("喜欢") || $0.name.contains("收藏"))
                && !($1.name.contains("喜欢") || $1.name.contains("收藏"))
        }
        .prefix(maxPlaylistsPerPlatform)
        for list in picked {
            guard let rows = try? await KugouAPI.shared.cloudPlaylistSongs(id: list.id,
                                                                           cookie: cookie) else { continue }
            for row in rows {
                if let track = Self.kugouTrack(row) {
                    collected.insert(Self.key(for: track))
                }
            }
        }
    }

    /// 云端歌单行把歌曲写成「歌手 - 歌名」，解析前先拆开。
    private static func kugouTrack(_ raw: [String: Any]) -> Track? {
        var item = raw
        if item["songname"] == nil, let full = (raw["name"] ?? raw["filename"]) as? String {
            let parts = full.components(separatedBy: " - ")
            if parts.count >= 2 {
                item["singername"] = item["singername"] ?? parts[0]
                item["songname"] = parts.dropFirst().joined(separator: " - ")
            } else {
                item["songname"] = full
            }
        }
        if item["timelength"] == nil, let seconds = raw["timelen"] as? Int {
            item["timelength"] = seconds
        }
        return LXCatalogService.parseTrack(item, source: .kg)
    }
}
