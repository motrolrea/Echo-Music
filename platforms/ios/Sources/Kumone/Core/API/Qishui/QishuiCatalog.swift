import Foundation

/// Catalogue reads for the Qishui car protocol. Public reads work anonymously;
/// passing a credential switches to the account's own entitlement.
enum QishuiCatalogService {
    static func search(_ keyword: String, limit: Int = 30, offset: Int = 0,
                       credential: QishuiCredential? = nil) async throws -> [Track] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let searchID = UUID().uuidString.lowercased()
        let data = try await QishuiClient.shared.platform(
            path: "/search/",
            body: [
                "q": trimmed,
                "cursor": String(offset),
                "search_id": searchID,
                "from_search_id": searchID,
                "search_method": "input",
                "search_type": "track",
                "search_scene": "normal",
                "scene_name": "search",
                "ab_param": "",
                "last_viewed_media": [String: Any](),
            ],
            credential: credential
        )
        let groups = QishuiFields.objects(data["result_groups"])
        let group = groups.first { QishuiFields.text($0["id"]) == "tracks" } ?? groups.first
        guard let group else { return [] }
        let rows = QishuiFields.objects(group["data"])
        let items = rows.compactMap { row -> [String: Any]? in
            let entity = row["entity"] as? [String: Any]
            return entity?["track"] as? [String: Any]
        }
        return items.prefix(max(1, limit)).compactMap { QishuiMapping.track(from: $0) }
    }

    /// Full `track_entity` including `player_info`; needed by playback.
    static func trackEntity(id: String,
                            credential: QishuiCredential? = nil) async throws -> [String: Any] {
        let data = try await QishuiClient.shared.platform(
            path: "/media/mget/",
            body: [
                "media_list": [["id": id, "type": "track"]],
                "card_context": [String: Any](),
            ],
            credential: credential
        )
        let mediaList = QishuiFields.objects(data["media_list"])
        let media = mediaList.first { item in
            let entity = item["track_entity"] as? [String: Any]
            let entityID = QishuiFields.text((entity?["base_info"] as? [String: Any])?["id"])
            let itemID = QishuiFields.text(item["media_id"]) ?? entityID
            return itemID == id
        } ?? mediaList.first
        guard let entity = media?["track_entity"] as? [String: Any] else {
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
        // 歌单游标不是行号，要从头顺序翻页；只取首页会把 100 首以上的歌单截断。
        var cursor = "0"
        var seen: Set<String> = []
        var all: [Track] = []
        var firstPage: [String: Any] = [:]
        let typeValue: Any
        if let playlistType {
            typeValue = playlistType
        } else {
            typeValue = NSNull()
        }
        for _ in 0..<12 {
            seen.insert(cursor)
            let data = try await QishuiClient.shared.platform(
                path: "/playlist/detail/",
                body: [
                    "playlist_id": id,
                    "owner_id": ownerId,
                    "count": 100,
                    "cursor": cursor,
                    "type": typeValue,
                ],
                credential: credential
            )
            if firstPage.isEmpty { firstPage = data }
            var batch = QishuiFields.objects(data["media_entities"])
            if batch.isEmpty { batch = QishuiFields.objects(data["media_list"]) }
            all += batch.compactMap { QishuiMapping.track(from: $0) }
            if all.count >= offset + limit, limit > 0 { break }
            guard QishuiFields.bool(data["has_more"]) else { break }
            let next = QishuiFields.text(data["next_cursor"]) ?? ""
            guard !next.isEmpty, !seen.contains(next) else { break }
            cursor = next
        }

        let playlist = firstPage["playlist"] as? [String: Any] ?? [:]
        let base = playlist["base_info"] as? [String: Any] ?? playlist
        let display = playlist["display_info"] as? [String: Any] ?? [:]
        let relation = playlist["relation_info"] as? [String: Any] ?? [:]
        let owner = relation["owner"] as? [String: Any] ?? [:]
        let stats = playlist["stats"] as? [String: Any] ?? [:]
        let tracks = Array(all.dropFirst(max(0, offset)).prefix(max(1, limit)))

        let coverValue: Any? = display["url_cover"] ?? display["cover_url"]
        return PlaylistPage(
            name: QishuiFields.text(base["title"]) ?? QishuiFields.text(base["name"]) ?? "汽水歌单",
            coverURL: QishuiMapping.coverURL(coverValue),
            description: QishuiFields.text(base["description"]),
            author: QishuiFields.text(owner["nickname"]) ?? QishuiFields.text(owner["name"]),
            tracks: tracks,
            hasMore: all.count > offset + tracks.count,
            total: QishuiFields.int(base["resource_cnt"]) ?? QishuiFields.int(stats["count"]) ?? all.count
        )
    }

    // MARK: - Account library

    struct PlaylistSummary: Identifiable, Hashable {
        let id: String
        let ownerId: String
        let name: String
        let coverURL: String?
        let trackCount: Int
        let author: String?
        let description: String?
        /// 自己创建的歌单（否则是收藏的歌单）。
        let isOwned: Bool
        /// 汽水的「我喜欢的音乐」是 type == 1 的内置歌单。
        let isLiked: Bool
    }

    private static func playlistSummary(from raw: [String: Any], owned: Bool) -> PlaylistSummary? {
        let playlist = raw["playlist"] as? [String: Any] ?? raw
        let base = playlist["base_info"] as? [String: Any] ?? playlist
        guard let id = QishuiFields.text(base["id"]), !id.isEmpty else { return nil }
        let display = playlist["display_info"] as? [String: Any] ?? [:]
        let relation = playlist["relation_info"] as? [String: Any] ?? [:]
        let owner = relation["owner"] as? [String: Any] ?? [:]
        let stats = playlist["stats"] as? [String: Any] ?? [:]
        let coverValue: Any? = display["url_cover"] ?? display["cover_url"]
        return PlaylistSummary(
            id: id,
            ownerId: QishuiFields.text(base["owner_id"]) ?? QishuiFields.text(owner["id"]) ?? "",
            name: QishuiFields.text(base["title"]) ?? QishuiFields.text(base["name"]) ?? "汽水歌单",
            coverURL: QishuiMapping.coverURL(coverValue),
            trackCount: QishuiFields.int(base["resource_cnt"]) ?? QishuiFields.int(stats["count"]) ?? 0,
            author: QishuiFields.text(owner["nickname"]) ?? QishuiFields.text(owner["name"]),
            description: QishuiFields.text(base["description"]),
            isOwned: owned,
            isLiked: QishuiFields.int(base["type"]) == 1
        )
    }

    /// 车机协议里账号歌单只有两个来源：`/me/playlist/`（自建）和
    /// `/me/collection/mixed/`（收藏）。两个都要按游标翻页。
    static func myPlaylists(credential: QishuiCredential? = nil) async throws -> [PlaylistSummary] {
        guard let credential else { return [] }
        var items: [PlaylistSummary] = []
        var lastError: Error?
        for (path, field, owned) in [("/me/playlist/", "playlists", true),
                                     ("/me/collection/mixed/", "mixed_collections", false)] {
            do {
                var cursor = ""
                var seen: Set<String> = []
                for _ in 0..<20 {
                    seen.insert(cursor)
                    let data = try await QishuiClient.shared.platform(
                        path: path,
                        body: ["count": 100, "cursor": cursor, "item_types": ["playlist"]],
                        credential: credential
                    )
                    var rows = QishuiFields.objects(data[field])
                    if path == "/me/playlist/" { rows += QishuiFields.objects(data["playlist_list"]) }
                    for row in rows {
                        if let summary = playlistSummary(from: row, owned: owned) { items.append(summary) }
                    }
                    guard QishuiFields.bool(data["has_more"]) else { break }
                    let next = QishuiFields.text(data["next_cursor"]) ?? ""
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

    /// 找到「我喜欢的音乐」歌单（type == 1）。它的 id 不固定，只能从自建歌单里认。
    private static func likedPlaylist(credential: QishuiCredential) async throws -> PlaylistSummary? {
        var cursor = ""
        var seen: Set<String> = []
        for _ in 0..<20 {
            seen.insert(cursor)
            let data = try await QishuiClient.shared.platform(
                path: "/me/playlist/",
                body: ["count": 100, "cursor": cursor],
                credential: credential
            )
            let rows = QishuiFields.objects(data["playlists"]) + QishuiFields.objects(data["playlist_list"])
            if let summary = rows.compactMap({ playlistSummary(from: $0, owned: true) })
                .first(where: { $0.isLiked }) {
                return summary
            }
            guard QishuiFields.bool(data["has_more"]) else { return nil }
            let next = QishuiFields.text(data["next_cursor"]) ?? ""
            guard !next.isEmpty, !seen.contains(next) else { return nil }
            cursor = next
        }
        return nil
    }

    static func likedTracks(limit: Int = 300,
                            credential: QishuiCredential? = nil) async throws -> [Track] {
        guard let credential, let liked = try await likedPlaylist(credential: credential) else { return [] }
        return try await playlistDetail(id: liked.id, ownerId: liked.ownerId,
                                        limit: min(max(1, limit), 1000), offset: 0,
                                        credential: credential, playlistType: 1).tracks
    }

    /// `/me/recent-played/`：每行 `media.track_entity`，另有 `play_start_timestamp`。
    static func recentPlayed(limit: Int = 60,
                             credential: QishuiCredential? = nil) async throws -> [Track] {
        guard let credential else { return [] }
        var cursor = ""
        var seenCursors: Set<String> = []
        var seenTracks: Set<Int> = []
        var tracks: [Track] = []
        for _ in 0..<6 {
            seenCursors.insert(cursor)
            let data = try await QishuiClient.shared.platform(
                path: "/me/recent-played/",
                body: ["count": 100, "cursor": cursor, "media_type": "track", "scene": "me_tab"],
                credential: credential
            )
            for row in QishuiFields.objects(data["media"]) {
                guard let media = row["media"] as? [String: Any],
                      media["track_entity"] != nil,
                      let track = QishuiMapping.track(from: media),
                      seenTracks.insert(track.id).inserted else { continue }
                tracks.append(track)
                if tracks.count >= limit { break }
            }
            guard tracks.count < limit, QishuiFields.bool(data["has_more"]) else { break }
            let next = QishuiFields.text(data["next_cursor"]) ?? ""
            guard !next.isEmpty, !seenCursors.contains(next) else { break }
            cursor = next
        }
        return Array(tracks.prefix(max(1, limit)))
    }

    /// `/search/` 的 playlist 组：返回真实歌单（汽水没有歌单广场，但搜索有）。
    static func searchPlaylists(_ keyword: String, limit: Int = 30, offset: Int = 0,
                                credential: QishuiCredential? = nil) async throws -> [PlaylistSummary] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let searchID = UUID().uuidString.lowercased()
        let data = try await QishuiClient.shared.platform(
            path: "/search/",
            body: [
                "q": trimmed,
                "cursor": String(offset),
                "search_id": searchID,
                "from_search_id": searchID,
                "search_method": "input",
                "search_type": "playlist",
                "search_scene": "normal",
                "scene_name": "search",
                "ab_param": "",
                "last_viewed_media": [String: Any](),
            ],
            credential: credential
        )
        let groups = QishuiFields.objects(data["result_groups"])
        let group = groups.first {
            (QishuiFields.text($0["id"]) ?? "").hasPrefix("playlist")
        } ?? groups.first
        guard let group else { return [] }
        let rows = QishuiFields.objects(group["data"]).compactMap { row -> PlaylistSummary? in
            guard let playlist = (row["entity"] as? [String: Any])?["playlist"] as? [String: Any] else { return nil }
            return playlistSummary(from: playlist, owned: false)
        }
        return Array(rows.prefix(max(1, limit)))
    }

    struct LyricsPayload {
        let lrc: String
        let yrc: String?
    }

    /// Qishui returns KRC (`[startMs,durationMs]<offset,dur,0>字…`) for most
    /// tracks and plain LRC for a few. Emit line-level LRC for the existing
    /// lyrics pipeline; word timing is intentionally not claimed.
    static func lyrics(id: String) async throws -> LyricsPayload {
        let entity = try await trackEntity(id: id)
        let display = entity["display_info"] as? [String: Any] ?? [:]
        let lyricInfo = display["lyric_info"] as? [String: Any] ?? [:]
        let lyricEntity = lyricInfo["lyric_entity"] as? [String: Any] ?? [:]
        let content = QishuiFields.text(lyricEntity["content"]) ?? ""
        guard !content.isEmpty else {
            throw QishuiError(.invalidResponse, "汽水没有返回歌词")
        }
        return parseLyrics(content)
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

    struct FeedMode: Identifiable {
        let id: String
        let name: String
        let group: String
        let coverURL: String?
    }

    static func feedModes() async throws -> [FeedMode] {
        let data = try await QishuiClient.shared.platform(path: "/feed/mode/")
        let blocks = QishuiFields.objects(data["feed_mode_block"])
        return blocks.flatMap { block -> [FeedMode] in
            let title = QishuiFields.text(block["title"]) ?? ""
            return QishuiFields.objects(block["feed_mode"]).compactMap { item in
                let mode = (item["entity"] as? [String: Any])?["feed_mode"] as? [String: Any]
                let scene = (mode?["scene_mode"] as? [String: Any])?["scene_mode_id"]
                guard let id = QishuiFields.text(scene) else { return nil }
                return FeedMode(id: id,
                                name: QishuiFields.text(mode?["text"]) ?? "场景电台",
                                group: title,
                                coverURL: QishuiMapping.coverURL(mode?["url_info"]))
            }
        }
    }

    static func feed(scene: String? = nil, preference: String? = nil,
                     limit: Int = 20) async throws -> [Track] {
        var feedPreference: [String: Any] = [
            "total_request_count": 1,
            "preference_mode_request_count": 1,
            "current_mode_request_count": 1,
        ]
        if let scene { feedPreference["scene_mode_id"] = Int(scene) ?? 0 }
        if let preference { feedPreference["preference_mode"] = preference }
        let data = try await QishuiClient.shared.platform(
            path: "/feed/song-tab/",
            body: [
                "played_media": [Any](),
                "is_first_request": true,
                "with_client_cache": false,
                "is_did_first_request": false,
                "count": max(1, limit),
                "feed_preference": feedPreference,
            ]
        )
        let items = QishuiFields.objects(data["items"])
        return items.compactMap { item -> Track? in
            if let type = item["type"] as? String, type != "track" { return nil }
            return QishuiMapping.track(from: item)
        }
    }

    /// 「推荐歌曲」用随机场景的第一屏，比固定的首刷歌单更新鲜。
    static func freshRecommendedTracks(limit: Int = 30) async -> [Track] {
        if let modes = try? await feedModes(), let pick = modes.randomElement(),
           let tracks = try? await feed(scene: pick.id, limit: limit), !tracks.isEmpty {
            return tracks.shuffled()
        }
        return (try? await feed(limit: limit)) ?? []
    }
}
