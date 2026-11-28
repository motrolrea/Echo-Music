import Foundation

/// Catalogue reads for the Qishui PC protocol.
/// Account libraries use the saved website cookie. Search, scenes and playback
/// go through the signer.
enum QishuiCatalogService {
    static func search(_ keyword: String, limit: Int = 30, offset: Int = 0,
                       credential: QishuiCredential? = nil) async throws -> [Track] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let root = try await QishuiClient.shared.signedGet(
            path: "/luna/pc/search/track",
            extras: [
                "q": trimmed,
                "cursor": String(max(0, offset)),
                "count": String(max(1, min(limit, 50))),
            ],
            cookie: credential?.accountCookie
        )
        return Array(tracks(in: root).prefix(max(1, limit)))
    }

    /// Full track object, including `player_info` when the PC player payload is present.
    static func trackEntity(id: String,
                            credential: QishuiCredential? = nil) async throws -> [String: Any] {
        let root: [String: Any]
        if let credential {
            root = try await QishuiClient.shared.signedPost(
                path: "/luna/pc/track_v2",
                body: playerBody(id),
                cookie: credential.accountCookie
            )
        } else {
            root = try await QishuiClient.shared.get(
                path: "/luna/pc/track_v2",
                extras: [
                    "track_id": id,
                    "media_type": "track",
                    "device_platform": "web",
                    "channel": "pc_web",
                ]
            )
        }
        var entity = trackObject(in: root) ?? [:]
        if entity["player_info"] == nil, let player = playerObject(in: root) {
            entity["player_info"] = player
        }
        guard entity["player_info"] != nil || QishuiFields.text(entity["id"] ?? entity["track_id"]) != nil else {
            throw QishuiError(.notPlayable, "汽水没有返回这首歌")
        }
        return entity
    }

    struct PlaylistPage {
        let name: String
        let coverURL: String?
        let description: String?
        let author: String?
        let tracks: [Track]
        let hasMore: Bool
        let total: Int
    }

    static func playlistDetail(id: String, ownerId: String = "",
                               limit: Int = 100, offset: Int = 0,
                               credential: QishuiCredential? = nil,
                               playlistType: Int? = nil) async throws -> PlaylistPage {
        var cursor = "0"
        var seen: Set<String> = []
        var all: [Track] = []
        var playlist: [String: Any] = [:]
        var hasMore = false
        for _ in 0..<20 {
            seen.insert(cursor)
            var extras = [
                "playlist_id": id,
                "cursor": cursor,
                "count": "50",
            ]
            if !ownerId.isEmpty { extras["owner_id"] = ownerId }
            let root: [String: Any]
            if credential != nil {
                root = try await accountGet(path: "/luna/pc/playlist/detail", extras: extras,
                                            credential: credential)
            } else {
                // 收藏里的私人歌单需要登录态才看得到歌曲；未显式传入时借用当前账号 Cookie。
                root = try await QishuiClient.shared.get(path: "/luna/pc/playlist/detail", extras: extras,
                                                         cookie: await currentAccountCookie())
            }
            // PC 歌单详情把数据包在 data 里；直接读顶层会得到空列表。
            let body = (root["data"] as? [String: Any]) ?? root
            if playlist.isEmpty {
                playlist = (body["playlist"] as? [String: Any])
                    ?? (body["playlist_info"] as? [String: Any])
                    ?? [:]
            }
            let batch = QishuiFields.objects(body["media_resources"]).compactMap(track(fromResource:))
            all += batch
            hasMore = QishuiFields.bool(body["has_more"])
            if all.count >= offset + limit, limit > 0 { break }
            guard hasMore else { break }
            let next = QishuiFields.text(body["next_cursor"]) ?? ""
            guard !next.isEmpty, !seen.contains(next) else { break }
            cursor = next
        }

        let tracks = Array(all.dropFirst(max(0, offset)).prefix(max(1, limit)))
        let owner = (playlist["creator"] as? [String: Any])
            ?? (playlist["owner"] as? [String: Any])
            ?? [:]
        return PlaylistPage(
            name: QishuiFields.text(playlist["title"] ?? playlist["name"]) ?? "汽水歌单",
            coverURL: QishuiFields.imageURL(playlist["url_cover"] ?? playlist["cover"]),
            description: QishuiFields.text(playlist["desc"] ?? playlist["description"]),
            author: QishuiFields.text(owner["nickname"] ?? owner["name"]),
            tracks: tracks,
            hasMore: hasMore || all.count > offset + tracks.count,
            total: QishuiFields.int(playlist["count_tracks"] ?? playlist["track_count"]) ?? all.count
        )
    }

    struct PlaylistSummary: Identifiable, Hashable {
        let id: String
        let ownerId: String
        let name: String
        let coverURL: String?
        let trackCount: Int
        let author: String?
        let description: String?
        let isOwned: Bool
        /// 「我喜欢的音乐」：PC 用 special_type == 5，旧接口用 type == 1。
        let isLiked: Bool
    }

    static func myPlaylists(credential: QishuiCredential? = nil) async throws -> [PlaylistSummary] {
        guard credential != nil else { return [] }
        var items: [PlaylistSummary] = []
        var lastError: Error?
        let sources: [(String, String, Bool, [String: String])] = [
            ("/luna/pc/me/playlist", "playlists", true, [:]),
            ("/luna/me/collection/mixed", "mixed_collections", false, ["item_types": "playlist"]),
        ]
        for (path, field, owned, extra) in sources {
            do {
                var cursor = ""
                var seen: Set<String> = []
                for _ in 0..<20 {
                    seen.insert(cursor)
                    var extras = extra
                    extras["cursor"] = cursor
                    extras["count"] = "50"
                    let root = try await accountGet(path: path, extras: extras, credential: credential)
                    for row in QishuiFields.objects(root[field]) {
                        if let summary = playlistSummary(from: row, owned: owned) { items.append(summary) }
                    }
                    guard QishuiFields.bool(root["has_more"]) else { break }
                    let next = QishuiFields.text(root["next_cursor"]) ?? ""
                    guard !next.isEmpty, !seen.contains(next) else { break }
                    cursor = next
                }
            } catch {
                lastError = error
            }
        }
        if items.isEmpty, let lastError { throw lastError }
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    static func likedTracks(limit: Int = 300,
                            credential: QishuiCredential? = nil) async throws -> [Track] {
        guard let credential else { return [] }
        let lists = try await myPlaylists(credential: credential)
        guard let liked = lists.first(where: \.isLiked) else { return [] }
        return try await playlistDetail(id: liked.id, ownerId: liked.ownerId,
                                        limit: min(max(1, limit), 1000), offset: 0,
                                        credential: credential, playlistType: 1).tracks
    }

    static func recentPlayed(limit: Int = 60,
                             credential: QishuiCredential? = nil) async throws -> [Track] {
        guard credential != nil else { return [] }
        var cursor = ""
        var seenCursors: Set<String> = []
        var seenTracks: Set<Int> = []
        var tracks: [Track] = []
        for _ in 0..<8 {
            seenCursors.insert(cursor)
            let root = try await accountGet(
                path: "/luna/pc/me/recently-played-media",
                extras: ["media_type": "track", "cursor": cursor, "count": "50"],
                credential: credential
            )
            for row in QishuiFields.objects(root["media_resources"]) {
                guard let track = track(fromResource: row), seenTracks.insert(track.id).inserted else { continue }
                tracks.append(track)
                if tracks.count >= limit { break }
            }
            guard tracks.count < limit, QishuiFields.bool(root["has_more"]) else { break }
            let next = QishuiFields.text(root["next_cursor"]) ?? ""
            guard !next.isEmpty, !seenCursors.contains(next) else { break }
            cursor = next
        }
        return Array(tracks.prefix(max(1, limit)))
    }

    // MARK: - 收藏的专辑 / 歌手

    struct AlbumSummary: Identifiable, Hashable {
        let id: String
        let name: String
        let coverURL: String?
        let artistName: String
        let trackCount: Int
    }

    struct ArtistSummary: Identifiable, Hashable {
        let id: String
        let name: String
        let avatarURL: String?
    }

    /// 「我的 → 音乐收藏」里的专辑。PC 端把图片放在 `url_cover`、歌手放在 `artists`。
    static func collectedAlbums(limit: Int = 100,
                                credential: QishuiCredential? = nil) async throws -> [AlbumSummary] {
        let rows = try await collectionRows(kind: "album", credential: credential)
        return Array(rows.compactMap { raw -> AlbumSummary? in
            let album = (raw["album"] as? [String: Any]) ?? raw
            guard let id = QishuiFields.text(album["id"]), !id.isEmpty else { return nil }
            let name = QishuiFields.text(album["name"] ?? album["title"]) ?? "汽水专辑"
            let artists = (album["artists"] as? [[String: Any]] ?? [])
                .compactMap { QishuiFields.text($0["name"]) }
            return AlbumSummary(
                id: id,
                name: name,
                coverURL: QishuiFields.imageURL(album["url_cover"] ?? album["cover_url"]),
                artistName: artists.joined(separator: " / "),
                trackCount: QishuiFields.int(album["count_tracks"]) ?? 0
            )
        }.prefix(max(1, limit)))
    }

    /// 「我的 → 音乐收藏」里的歌手。歌手收藏走单独的 `/luna/me/collection/artist`。
    static func collectedArtists(limit: Int = 100,
                                 credential: QishuiCredential? = nil) async throws -> [ArtistSummary] {
        let rows = try await collectionRows(kind: "artist", credential: credential)
        return Array(rows.compactMap { raw -> ArtistSummary? in
            let artist = (raw["artist"] as? [String: Any]) ?? raw
            guard let id = QishuiFields.text(artist["id"]), !id.isEmpty else { return nil }
            let name = QishuiFields.text(artist["name"] ?? artist["simple_display_name"])
                ?? QishuiFields.text((artist["user_info"] as? [String: Any])?["nickname"])
            guard let name, !name.isEmpty else { return nil }
            return ArtistSummary(
                id: id,
                name: name,
                avatarURL: QishuiFields.imageURL(artist["url_avatar"] ?? artist["avatar_url"]
                                                 ?? artist["avatar"] ?? artist["url_cover"])
            )
        }.prefix(max(1, limit)))
    }

    private static func collectionRows(kind: String,
                                       credential: QishuiCredential?) async throws -> [[String: Any]] {
        guard let credential else { return [] }
        let path = kind == "artist" ? "/luna/me/collection/artist" : "/luna/me/collection/mixed"
        var rows: [[String: Any]] = []
        var cursor = ""
        var seen: Set<String> = []
        for _ in 0..<20 {
            seen.insert(cursor)
            var extras = ["cursor": cursor, "count": "100"]
            if kind != "artist" { extras["item_types"] = kind }
            let root = try await accountGet(path: path, extras: extras, credential: credential)
            let field = kind == "artist" ? "artists" : "mixed_collections"
            let batch = QishuiFields.objects(root[field])
                .isEmpty ? QishuiFields.objects(root["artist_collections"]) : QishuiFields.objects(root[field])
            rows += batch
            guard QishuiFields.bool(root["has_more"]) else { break }
            let next = QishuiFields.text(root["next_cursor"]) ?? ""
            guard !next.isEmpty, !seen.contains(next) else { break }
            cursor = next
        }
        return rows
    }

    /// 专辑详情里的歌曲（原生接口，不依赖搜索兜底）。
    static func albumTracks(id: String, credential: QishuiCredential? = nil) async throws -> [Track] {
        var cookie = credential?.accountCookie
        if cookie == nil { cookie = await currentAccountCookie() }
        let root = try await QishuiClient.shared.get(path: "/luna/pc/albums/\(id)",
                                                     extras: [:], cookie: cookie)
        let body = (root["data"] as? [String: Any]) ?? root
        let album = body["album_info"] as? [String: Any]
        let rows = QishuiFields.objects(body["tracks"])
        let tracks = rows.compactMap { row -> Track? in
            var item = row
            // 专辑歌曲行偶尔省略专辑信息；补上后封面和专辑名才不会缺。
            if item["album"] == nil, let album { item["album"] = album }
            return QishuiMapping.track(from: item) ?? track(fromResource: item)
        }
        guard !tracks.isEmpty else { throw QishuiError(.invalidResponse, "汽水专辑没有返回歌曲") }
        return tracks
    }

    /// 歌手歌曲：先用歌手详情的热门歌曲，再用 `/artists/<id>/tracks` 补全。
    static func artistTracks(id: String, limit: Int = 100) async throws -> [Track] {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else {
            throw QishuiError(.invalidResponse, "汽水歌手 ID 无效")
        }
        let cookie = await currentAccountCookie()
        var tracks: [Track] = []
        var seen: Set<Int> = []
        if let root = try? await QishuiClient.shared.get(path: "/luna/pc/artists/\(id)",
                                                         extras: [:], cookie: cookie) {
            let body = (root["data"] as? [String: Any]) ?? root
            for row in QishuiFields.objects(body["hot_tracks"]) {
                guard let track = QishuiMapping.track(from: row) ?? track(fromResource: row),
                      seen.insert(track.id).inserted else { continue }
                tracks.append(track)
            }
        }
        var cursor = ""
        var seenCursors: Set<String> = []
        while tracks.count < limit, seenCursors.count < 20 {
            seenCursors.insert(cursor)
            guard let root = try? await QishuiClient.shared.get(
                path: "/luna/pc/artists/\(id)/tracks",
                extras: ["cursor": cursor, "count": "50"], cookie: cookie
            ) else { break }
            let body = (root["data"] as? [String: Any]) ?? root
            let rows = QishuiFields.objects(body["tracks"])
            for row in rows {
                guard let track = QishuiMapping.track(from: row) ?? track(fromResource: row),
                      seen.insert(track.id).inserted else { continue }
                tracks.append(track)
                if tracks.count >= limit { break }
            }
            guard QishuiFields.bool(body["has_more"]) else { break }
            let next = QishuiFields.text(body["next_cursor"]) ?? ""
            guard !next.isEmpty, !seenCursors.contains(next) else { break }
            cursor = next
        }
        guard !tracks.isEmpty else { throw QishuiError(.invalidResponse, "汽水歌手没有返回歌曲") }
        return Array(tracks.prefix(max(1, limit)))
    }

    static func searchPlaylists(_ keyword: String, limit: Int = 30, offset: Int = 0,
                                credential: QishuiCredential? = nil) async throws -> [PlaylistSummary] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let root = try await QishuiClient.shared.signedGet(
            path: "/luna/pc/search/playlist",
            extras: [
                "q": trimmed,
                "cursor": String(max(0, offset)),
                "count": String(max(1, min(limit, 50))),
            ],
            cookie: credential?.accountCookie
        )
        let rows = searchRows(root).compactMap { row -> PlaylistSummary? in
            let playlist = ((row["entity"] as? [String: Any])?["playlist"] as? [String: Any])
                ?? (row["playlist"] as? [String: Any])
                ?? row
            return playlistSummary(from: playlist, owned: false)
        }
        return Array(rows.prefix(max(1, limit)))
    }

    struct LyricsPayload {
        let lrc: String
        let yrc: String?
    }

    static func lyrics(id: String) async throws -> LyricsPayload {
        let entity = try await trackEntity(id: id)
        let content = lyricText(entity)
        guard !content.isEmpty else {
            throw QishuiError(.invalidResponse, "汽水没有返回歌词")
        }
        return parseLyrics(content)
    }

    struct FeedMode: Identifiable {
        let id: String
        let name: String
        let group: String
        let coverURL: String?
    }

    /// 官方推荐模式（对应 Coda 的默认 / 熟悉 / 新鲜），始终排在场景前面。
    private static let preferenceModes: [FeedMode] = [
        FeedMode(id: "default", name: "默认推荐", group: "推荐模式", coverURL: nil),
        FeedMode(id: "familiar", name: "熟悉模式", group: "推荐模式", coverURL: nil),
        FeedMode(id: "fresh", name: "新鲜模式", group: "推荐模式", coverURL: nil),
    ]

    /// 推荐流需要登录态，未显式传入时读取当前汽水账号的 Cookie。
    private static func currentAccountCookie() async -> String? {
        await MainActor.run { QishuiSessionStore.shared.credential?.accountCookie }
    }

    /// 场景列表和榜单在短时间内不会变。汽水每个请求都要过一次外部签名服务，
    /// 每次进页面都重拉会让「封面/歌单」晚一拍才出现，所以缓存 10 分钟。
    @MainActor private static var cachedFeedModes: (modes: [FeedMode], expires: Date)?
    @MainActor private static var cachedCharts: (charts: [Chart], expires: Date)?
    private static let catalogCacheLifetime: TimeInterval = 600

    static func feedModes(credential: QishuiCredential? = nil) async throws -> [FeedMode] {
        if let cached = await MainActor.run(body: { cachedFeedModes }), cached.expires > Date() {
            return cached.modes
        }
        var cookie = credential?.accountCookie
        if cookie == nil { cookie = await currentAccountCookie() }
        let root = try await QishuiClient.shared.signedPost(
            path: "/luna/pc/feed/mode", body: [:], cookie: cookie
        )
        let rawBlocks = root["feed_mode_block"]
            ?? (root["data"] as? [String: Any])?["feed_mode_block"]
        var seen = Set(preferenceModes.map(\.id))
        let result = preferenceModes + modes(from: objectsOrSingle(rawBlocks)).filter { seen.insert($0.id).inserted }
        await MainActor.run {
            cachedFeedModes = (result, Date().addingTimeInterval(catalogCacheLifetime))
        }
        return result
    }

    /// 汽水部分接口会把「只有一个元素的数组」直接写成字典。
    private static func objectsOrSingle(_ value: Any?) -> [[String: Any]] {
        if let list = value as? [[String: Any]] { return list }
        if let single = value as? [String: Any] { return [single] }
        return QishuiFields.objects(value)
    }

    static func feed(scene: String? = nil, preference: String? = nil,
                     limit: Int = 20, credential: QishuiCredential? = nil) async throws -> [Track] {
        var cookie = credential?.accountCookie
        if cookie == nil { cookie = await currentAccountCookie() }
        var body: [String: Any] = [
            "played_media": [Any](),
            "did_first_use_time": Int(Date().timeIntervalSince1970),
            "is_first_request": true,
            "is_did_first_request": true,
            "feed_counts": ["mix_session_count": 1],
        ]
        if let scene, !scene.isEmpty {
            // 数字是场景 id；「default / familiar / fresh」是推荐模式。
            if let sceneID = Int(scene) {
                body["feed_preference"] = ["scene_mode_id": sceneID]
            } else if scene != "default" {
                body["feed_preference"] = ["preference_mode": scene]
            }
        } else if let preference, !preference.isEmpty, preference != "default" {
            body["feed_preference"] = ["preference_mode": preference]
        }
        let root = try await QishuiClient.shared.signedPost(
            path: "/luna/pc/feed/song-tab",
            body: body,
            cookie: cookie
        )
        let items = QishuiFields.objects(root["items"]).isEmpty
            ? QishuiFields.objects((root["data"] as? [String: Any])?["items"])
            : QishuiFields.objects(root["items"])
        return Array(items.compactMap { item -> Track? in
            if let type = item["type"] as? String, type != "track", item["entity"] == nil { return nil }
            return track(fromResource: item) ?? QishuiMapping.track(from: item)
        }.prefix(max(1, limit)))
    }

    /// 推荐页优先用发现页的热歌，场景流作为兜底。
    static func freshRecommendedTracks(limit: Int = 30) async -> [Track] {
        if let discovered = try? await discoverTracks(limit: limit), !discovered.isEmpty {
            return discovered
        }
        if let modes = try? await feedModes(), let pick = modes.randomElement(),
           let tracks = try? await feed(scene: pick.id, limit: limit), !tracks.isEmpty {
            return tracks
        }
        return (try? await feed(limit: limit)) ?? []
    }

    // MARK: - Account

    private static func accountGet(path: String, extras: [String: String],
                                   credential: QishuiCredential?) async throws -> [String: Any] {
        guard let credential else {
            throw QishuiError(.authRequired, "请先登录汽水音乐")
        }
        do {
            return try await QishuiClient.shared.get(path: path, extras: extras,
                                                     cookie: credential.accountCookie)
        } catch let error as QishuiError where error.kind == .authRequired {
            await MainActor.run { QishuiSessionStore.shared.signOut() }
            throw error
        }
    }

    private static func playlistSummary(from raw: [String: Any], owned: Bool) -> PlaylistSummary? {
        let nested = raw["playlist"] as? [String: Any]
        let playlist = nested ?? raw
        guard let id = QishuiFields.text(playlist["id"] ?? playlist["playlist_id"]), !id.isEmpty else {
            return nil
        }
        let owner = (playlist["creator"] as? [String: Any]) ?? (playlist["owner"] as? [String: Any]) ?? [:]
        let name = QishuiFields.text(playlist["title"] ?? playlist["name"]) ?? "汽水歌单"
        let special = QishuiFields.int(playlist["special_type"] ?? playlist["type"]) ?? 0
        let liked = special == 5 || special == 1 || name.contains("我喜欢")
        return PlaylistSummary(
            id: id,
            ownerId: QishuiFields.text(playlist["owner_id"] ?? owner["id"] ?? owner["user_id"]) ?? "",
            name: name,
            coverURL: QishuiFields.imageURL(playlist["url_cover"] ?? playlist["cover"] ?? playlist["cover_url"]),
            trackCount: QishuiFields.int(playlist["count_tracks"] ?? playlist["track_count"] ?? playlist["count"]) ?? 0,
            author: QishuiFields.text(owner["nickname"] ?? owner["name"]),
            description: QishuiFields.text(playlist["desc"] ?? playlist["description"]),
            isOwned: owned && !liked,
            isLiked: liked
        )
    }

    // MARK: - Discovery

    private static func discoverTracks(limit: Int) async throws -> [Track] {
        // 发现页和榜单一样需要签名请求，未签名会返回空 blocks。
        let root = try await QishuiClient.shared.signedPost(path: "/luna/pc/discover", body: [:],
                                                            cookie: await currentAccountCookie())
        let blocks = QishuiFields.objects(root["blocks"])
        let songs = blocks.first { QishuiFields.text($0["type"]) == "discover_top_song_list" } ?? blocks.first
        let rows = QishuiFields.objects(songs?["inner_block"])
        var tracks: [Track] = []
        var seen: Set<Int> = []
        for row in rows {
            // 榜单行本身只有元信息，歌曲在行内的 resources 里。
            var resources = QishuiFields.objects(row["resources"])
            if resources.isEmpty { resources = QishuiFields.objects(row["inner_block"]) }
            if resources.isEmpty { resources = [row] }
            for resource in resources {
                guard let track = track(fromResource: resource),
                      seen.insert(track.id).inserted else { continue }
                tracks.append(track)
                if tracks.count >= limit { return tracks }
            }
        }
        return tracks
    }

    struct Chart: Identifiable, Hashable {
        let id: String
        let name: String
        let coverURL: String?
    }

    /// 官方兜底榜单：即使 discover 接口结构变化也保证有榜可点。
    private static let knownCharts: [Chart] = [
        Chart(id: "7036274230471712007", name: "热歌榜",
              coverURL: chartCover("tos-cn-i-b829550vbb/discover-mix-tophits")),
        Chart(id: "7060812597884869927", name: "新歌榜",
              coverURL: chartCover("tos-cn-i-b829550vbb/discover-mix-newcharts")),
        Chart(id: "7061475546400005410", name: "欧美榜",
              coverURL: chartCover("tos-cn-i-b829550vbb/discover-mix-ushits")),
        Chart(id: "7415959718721494311", name: "音乐人歌曲榜",
              coverURL: chartCover("tos-cn-v-2774c002/o8FQKiQQBxHWa2hzsBNAgYOX6iEHEAibADAbfB")),
    ]

    private static func chartCover(_ uri: String) -> String {
        "https://p3-luna.douyinpic.com/img/\(uri)~tplv-b829550vbb-resize:960:960.png"
    }

    static func charts() async -> [Chart] {
        if let cached = await MainActor.run(body: { cachedCharts }), cached.expires > Date(),
           !cached.charts.isEmpty {
            return cached.charts
        }
        let root = try? await QishuiClient.shared.signedPost(path: "/luna/pc/discover", body: [:],
                                                             cookie: await currentAccountCookie())
        let blocks = QishuiFields.objects(root?["blocks"])
        let rows = blocks.filter { QishuiFields.text($0["type"]) == "discover_top_song_list" }
            .flatMap { QishuiFields.objects($0["inner_block"]) }
        var seen: Set<String> = []
        var result: [Chart] = []
        for row in rows {
            guard QishuiFields.text(row["type"]) == "discover_track_top_list",
                  let id = QishuiFields.text(row["inner_block_id"]), !id.isEmpty,
                  let title = QishuiFields.text(row["title"]), !title.isEmpty,
                  seen.insert(id).inserted else { continue }
            // 榜单行把歌曲放在 `resources`（行本身的 `inner_block` 是空/嵌套块）。
            var resources = QishuiFields.objects(row["resources"])
            if resources.isEmpty { resources = QishuiFields.objects(row["inner_block"]) }
            let cover = knownCharts.first { $0.id == id }?.coverURL
                ?? resources.lazy.compactMap { resource -> String? in
                    let entity = resource["entity"] as? [String: Any]
                    let ranked = (entity?["ranked_track"] as? [String: Any])
                        ?? (entity?["track_wrapper"] as? [String: Any])
                    let track = (ranked?["track"] as? [String: Any]) ?? (entity?["track"] as? [String: Any])
                    return QishuiFields.imageURL(track?["album"].flatMap { ($0 as? [String: Any])?["url_cover"] })
                        ?? QishuiFields.imageURL(track?["url_cover"])
                }.first
            result.append(Chart(id: id, name: title, coverURL: cover))
        }
        result += knownCharts.filter { seen.insert($0.id).inserted }
        let final = result
        await MainActor.run {
            cachedCharts = (final, Date().addingTimeInterval(catalogCacheLifetime))
        }
        return final
    }

    static func chartTracks(id: String, limit: Int = 100) async throws -> (name: String?, tracks: [Track]) {
        // 榜单详情只接受 GET；用 POST 会被服务器当成不存在的路由，直接返回 404。
        let root = try await QishuiClient.shared.signedGet(path: "/luna/pc/charts/\(id)",
                                                           cookie: await currentAccountCookie())
        let body = (root["data"] as? [String: Any]) ?? root
        let chart = (body["chart"] as? [String: Any]) ?? (root["chart"] as? [String: Any]) ?? [:]
        var rows = QishuiFields.objects(chart["track_ranks"])
        if rows.isEmpty { rows = QishuiFields.objects(body["track_ranks"]) }
        var tracks: [Track] = []
        for row in rows {
            if let track = track(fromResource: row) {
                tracks.append(track)
                continue
            }
            if let track = row["track"] as? [String: Any],
               let mapped = QishuiMapping.track(from: track) {
                tracks.append(mapped)
            }
        }
        guard !tracks.isEmpty else { throw QishuiError(.invalidResponse, "汽水榜单没有返回歌曲") }
        return (QishuiFields.text(chart["title"] ?? chart["name"]),
                Array(tracks.prefix(max(1, limit))))
    }

    private static func modes(from blocks: [[String: Any]]) -> [FeedMode] {
        blocks.flatMap { block -> [FeedMode] in
            let title = QishuiFields.text(block["title"] ?? block["text"]) ?? ""
            return objectsOrSingle(block["feed_mode"]).compactMap { item in
                let entity = item["entity"] as? [String: Any]
                // 场景真实挂在 entity.feed_scene_mode 下；旧代码读的是 feed_mode，导致整页场景为空。
                let mode = (entity?["feed_scene_mode"] as? [String: Any])
                    ?? (entity?["feed_mode"] as? [String: Any])
                    ?? item
                let scene = (mode["scene_mode"] as? [String: Any])?["scene_mode_id"] ?? mode["scene_mode_id"]
                guard let id = QishuiFields.text(scene ?? mode["sub_queue_type"]), !id.isEmpty else { return nil }
                return FeedMode(id: id,
                                name: QishuiFields.text(mode["text"] ?? mode["title"]) ?? "场景电台",
                                group: title,
                                coverURL: QishuiFields.imageURL(mode["url_info"] ?? mode["url_cover"]))
            }
        }
    }

    // MARK: - Parsing

    private static func playerBody(_ id: String) -> [String: Any] {
        // `queue_type` / `scene_name` 告诉服务端这次取流来自曲库播放：VIP 账号
        // 少了这两个字段时只会拿到 30 秒试听片段（Coda 的请求也是这么带的）。
        [
            "track_id": id,
            "media_type": "track",
            "queue_type": "favorite_track_playlist",
            "scene_name": "library",
            "aid": QishuiProtocol.aid,
            "device_platform": QishuiProtocol.devicePlatform,
        ]
    }

    private static func tracks(in root: [String: Any]) -> [Track] {
        searchRows(root).compactMap { row in
            track(fromResource: row) ?? QishuiMapping.track(from: row)
        }
    }

    private static func searchRows(_ root: [String: Any]) -> [[String: Any]] {
        let direct = QishuiFields.objects(root["search_results"])
        if !direct.isEmpty { return direct }
        let results = QishuiFields.objects(root["results"])
        if !results.isEmpty { return results }
        if let data = root["data"] as? [String: Any] {
            let nested = QishuiFields.objects(data["search_results"])
            if !nested.isEmpty { return nested }
            return QishuiFields.objects(data["results"])
        }
        return []
    }

    private static func track(fromResource row: [String: Any]) -> Track? {
        if let entity = row["entity"] as? [String: Any] {
            // 歌单详情 / 最近播放：真实歌曲挂在 entity.track_wrapper.track。
            if let wrapper = entity["track_wrapper"] as? [String: Any],
               let track = wrapper["track"] as? [String: Any],
               let mapped = QishuiMapping.track(from: track) {
                return mapped
            }
            if let track = entity["track"] as? [String: Any], let mapped = QishuiMapping.track(from: track) {
                return mapped
            }
            // 发现页 / 榜单行是 entity.ranked_track.track。
            if let ranked = entity["ranked_track"] as? [String: Any],
               let track = ranked["track"] as? [String: Any],
               let mapped = QishuiMapping.track(from: track) {
                return mapped
            }
            if let mapped = QishuiMapping.track(from: entity) { return mapped }
        }
        // 少数接口把 wrapper 直接放在行上。
        if let wrapper = row["track_wrapper"] as? [String: Any],
           let track = wrapper["track"] as? [String: Any],
           let mapped = QishuiMapping.track(from: track) {
            return mapped
        }
        if let track = row["track"] as? [String: Any], let mapped = QishuiMapping.track(from: track) {
            return mapped
        }
        return QishuiMapping.track(from: row)
    }

    private static func trackObject(in root: [String: Any]) -> [String: Any]? {
        if let seo = root["seo_track"] as? [String: Any], let track = seo["track"] as? [String: Any] {
            return track
        }
        if let track = root["track"] as? [String: Any] { return track }
        if let data = root["data"] as? [String: Any] { return trackObject(in: data) }
        return nil
    }

    private static func playerObject(in root: [String: Any]) -> [String: Any]? {
        if let seo = root["seo_track"] as? [String: Any],
           let player = seo["track_player"] as? [String: Any] { return player }
        if let player = root["track_player"] as? [String: Any] { return player }
        if let data = root["data"] as? [String: Any] { return playerObject(in: data) }
        return nil
    }

    private static func lyricText(_ value: Any?) -> String {
        if let text = value as? String {
            if text.contains("[") && (text.contains("]") || text.contains(",")) { return text }
            return ""
        }
        guard let object = value as? [String: Any] else { return "" }
        for key in ["content", "lyric", "lyrics", "lrc", "krc"] {
            let text = lyricText(object[key])
            if !text.isEmpty { return text }
        }
        for nested in object.values {
            let text = lyricText(nested)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func parseLyrics(_ content: String) -> LyricsPayload {
        guard content.range(of: #"^\[\d+,\d+\]"#, options: .regularExpression) != nil else {
            return LyricsPayload(lrc: content, yrc: nil)
        }
        var lines: [String] = []
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let header = String(line[line.index(after: line.startIndex)..<close])
            let parts = header.split(separator: ",")
            guard let start = parts.first.flatMap({ Int($0) }) else { continue }
            var text = String(line[line.index(after: close)...])
            text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let minutes = start / 60_000
            let seconds = (start % 60_000) / 1_000
            let centiseconds = (start % 1_000) / 10
            lines.append(String(format: "[%02d:%02d.%02d]%@", minutes, seconds, centiseconds, text))
        }
        return LyricsPayload(lrc: lines.joined(separator: "\n"), yrc: nil)
    }
}
