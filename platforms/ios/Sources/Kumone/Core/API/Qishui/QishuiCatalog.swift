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
                               credential: QishuiCredential? = nil) async throws -> PlaylistPage {
        let data = try await QishuiClient.shared.platform(
            path: "/playlist/detail/",
            body: [
                "playlist_id": id,
                "owner_id": ownerId,
                "count": 100,
                "cursor": "0",
                "type": NSNull(),
            ],
            credential: credential
        )
        let playlist = data["playlist"] as? [String: Any] ?? [:]
        let base = playlist["base_info"] as? [String: Any] ?? playlist
        let display = playlist["display_info"] as? [String: Any] ?? [:]
        let relation = playlist["relation_info"] as? [String: Any] ?? [:]
        let owner = relation["owner"] as? [String: Any] ?? [:]
        let stats = playlist["stats"] as? [String: Any] ?? [:]

        let tracks = QishuiFields.objects(data["media_entities"])
            .compactMap { QishuiMapping.track(from: $0) }
            .dropFirst(max(0, offset))
            .prefix(max(1, limit))

        let coverValue: Any? = display["url_cover"] ?? display["cover_url"]
        return PlaylistPage(
            name: QishuiFields.text(base["title"]) ?? QishuiFields.text(base["name"]) ?? "汽水歌单",
            coverURL: QishuiMapping.coverURL(coverValue),
            description: QishuiFields.text(base["description"]),
            author: QishuiFields.text(owner["nickname"]) ?? QishuiFields.text(owner["name"]),
            tracks: Array(tracks),
            hasMore: QishuiFields.bool(data["has_more"]),
            total: QishuiFields.int(base["resource_cnt"]) ?? QishuiFields.int(stats["count"]) ?? 0
        )
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
}
