import Foundation

/// 统一的汽水错误。`kind == .authRequired` 表示登录态失效，需要重新登录。
struct QishuiError: Error, LocalizedError {
    enum Kind {
        case authRequired
        case network
        case invalidResponse
        case notPlayable
        case unavailable
        case unsupported
    }

    let kind: Kind
    let message: String
    let upstreamCode: String?

    init(_ kind: Kind, _ message: String, upstreamCode: String? = nil) {
        self.kind = kind
        self.message = message
        self.upstreamCode = upstreamCode
    }

    var isTokenExpired: Bool { kind == .authRequired }
    var errorDescription: String? { message }
}

/// 汽水登录态：官网 `qishui.com` 的 Cookie + 展示资料。
struct QishuiCredential: Codable, Equatable {
    var cookie: String
    var userId: String
    var nickname: String?
    var avatarURL: String?
    var isVIP: Bool

    init(cookie: String, userId: String, nickname: String? = nil,
         avatarURL: String? = nil, isVIP: Bool = false) {
        self.cookie = cookie
        self.userId = userId
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.isVIP = isVIP
    }

    var sessionID: String? { QishuiProtocol.sessionID(from: cookie) }
    var isValid: Bool { sessionID != nil }
    var accountCookie: String { QishuiProtocol.accountCookie(cookie) }
}

/// 汽水个人资料。
struct QishuiProfile {
    let id: String
    let nickname: String
    let avatarURL: String?
    let isVIP: Bool

    var userID: String { id }
}

/// 宽松的类型取值工具：汽水同一字段在不同接口里可能是字符串、数字或 null。
enum QishuiFields {
    static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        case let double as Double: return Int(double)
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string) ?? 0
        default: return 0
        }
    }

    static func bool(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["1", "true", "yes"].contains(string.lowercased())
        case let bool as Bool: return bool
        default: return false
        }
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let string = value as? String, let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        array(value).compactMap { $0 as? [String: Any] }
    }

    static func array(_ value: Any?) -> [Any] {
        if let array = value as? [Any] { return array }
        if let dictionary = value as? [String: Any] {
            for key in ["url_list", "urls", "items", "list", "data"] {
                if let array = dictionary[key] as? [Any] { return array }
            }
        }
        return []
    }

    /// 封面可能是字符串、`{url_list:[...]}`、`{urls:[...]}` 或 `{uri,template_prefix}`。
    /// 汽水大多数图片对象形如
    /// `{"uri":"ies-music/pgc_cover_xxx","urls":["https://p3-luna.douyinpic.com/img/"],"template_prefix":"tplv-..."}`，
    /// 其中 `urls` 只是 CDN 目录前缀，直接使用会得到一张 404 的空白图 ——
    /// 这种情况下必须用 `urls[0] + uri + "~" + template_prefix + "-resize:..."` 拼出真实地址。
    static func imageURL(_ value: Any?, size: Int = 960) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let array = value as? [String] { return array.first(where: { !$0.isEmpty }) }
        guard let object = value as? [String: Any] else { return nil }

        let uri = text(object["uri"])
        let template = text(object["template_prefix"])
        // 已经给出完整图片地址时优先用它；只有「目录前缀」才需要和 uri 拼。
        if let full = fullImageURL(in: object) { return full }
        if let uri, !uri.contains("://") {
            if let prefix = basePrefix(in: object) {
                var url = prefix + uri
                if let template, !template.isEmpty {
                    url += "~\(template)-resize:\(size):\(size).png"
                }
                return url
            }
            if let template, !template.isEmpty {
                return "https://p3-luna.douyinpic.com/img/\(uri)~\(template)-resize:\(size):\(size).png"
            }
        }

        for key in ["url_list", "urls"] {
            if let list = object[key] as? [Any] {
                for item in list {
                    if let url = imageURL(item, size: size) { return url }
                }
            }
        }
        // 只剩目录前缀且没有 uri：拼不出可用地址，交给调用方走占位图。
        for key in ["url", "uri", "image", "cover", "avatar"] {
            if let url = text(object[key]) { return url }
        }
        return nil
    }

    /// 列表里已经存在的完整图片地址（不以 `/` 结尾、也不是纯域名）。
    private static func fullImageURL(in object: [String: Any]) -> String? {
        for key in ["url_list", "urls"] {
            let list = (object[key] as? [String]) ?? []
            if let full = list.first(where: { !$0.isEmpty && !$0.hasSuffix("/") && !$0.hasSuffix("/img") }) {
                return full
            }
        }
        return nil
    }

    /// 图片对象里的 CDN 基地址（`urls`/`url_list` 中的目录前缀）。
    private static func basePrefix(in object: [String: Any]) -> String? {
        for key in ["urls", "url_list"] {
            let list = (object[key] as? [String]) ?? []
            if let prefix = list.first(where: { !$0.isEmpty && ($0.hasSuffix("/") || $0.hasSuffix("/img")) }) {
                return prefix.hasSuffix("/") ? prefix : prefix + "/"
            }
        }
        return nil
    }
}

/// 把汽水 PC 接口的歌曲对象映射成 Echo 的统一 `Track`。
enum QishuiMapping {
    static func track(_ object: [String: Any]) -> Track? {
        let rawID = QishuiFields.text(object["id"])
            ?? QishuiFields.text(object["track_id"])
            ?? QishuiFields.text(object["item_id"])
        guard let rawID, let id = Int(rawID) else { return nil }

        let name = QishuiFields.text(object["name"])
            ?? QishuiFields.text(object["title"])
            ?? ""
        guard !name.isEmpty else { return nil }

        var duration = QishuiFields.int(object["duration"])
            ?? QishuiFields.int(object["duration_ms"])
            ?? 0
        // 汽水的 duration 是毫秒；少数接口给秒，用 1000 的阈值兜底。
        if duration > 0, duration < 1000 { duration *= 1000 }

        let albumObject = QishuiFields.dictionary(object["album"])
        let albumID = QishuiFields.int(albumObject?["id"]) ?? 0
        let albumName = QishuiFields.text(albumObject?["name"]) ?? ""
        let albumCover = QishuiFields.imageURL(albumObject?["url_cover"])
            ?? QishuiFields.imageURL(albumObject?["cover"])
            ?? QishuiFields.imageURL(object["url_cover"])
            ?? QishuiFields.imageURL(object["cover_url"])
            ?? QishuiFields.imageURL(object["cover"])

        var artists: [ArtistRef] = []
        if let list = object["artists"] as? [[String: Any]] {
            artists = list.map {
                ArtistRef(id: QishuiFields.int($0["id"]) ?? 0,
                          name: QishuiFields.text($0["name"]) ?? "",
                          picUrl: QishuiFields.imageURL($0["avatar"]) ?? QishuiFields.imageURL($0["url_cover"]))
            }
        } else if let list = object["singers"] as? [[String: Any]] {
            artists = list.map {
                ArtistRef(id: QishuiFields.int($0["id"]) ?? 0,
                          name: QishuiFields.text($0["name"]) ?? "",
                          picUrl: QishuiFields.imageURL($0["avatar"]))
            }
        } else if let artist = QishuiFields.text(object["artist"] ?? object["singer"]) {
            artists = [ArtistRef(id: 0, name: artist)]
        }
        artists = artists.filter { !$0.name.isEmpty }

        let album = AlbumRef(id: albumID, name: albumName, picUrl: albumCover)
        return Track(id: id, name: name, artists: artists, album: album,
                     durationMS: max(0, duration), source: "sd",
                     sourceMetadata: ["songmid": rawID])
    }

    static func coverURL(_ value: Any?) -> String? { QishuiFields.imageURL(value) }

    static func track(from object: [String: Any]) -> Track? { track(object) }

    /// 从任意层级的字典里尽量找出歌曲对象（兼容 `entity.track`、`track`、直接歌曲）。
    static func track(fromEntity value: Any?) -> Track? {
        guard let object = value as? [String: Any] else { return nil }
        if let track = track(object) { return track }
        for key in ["track", "entity", "track_entity", "song"] {
            if let nested = object[key] as? [String: Any], let track = track(nested) {
                return track
            }
        }
        return nil
    }
}
