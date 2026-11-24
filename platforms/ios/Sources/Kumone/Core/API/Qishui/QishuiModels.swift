import Foundation

struct QishuiError: LocalizedError {
    enum Kind {
        case authRequired
        case unavailable
        case network
        case invalidResponse
        case notPlayable
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

    var errorDescription: String? { message }

    var isTokenExpired: Bool { upstreamCode == "28001008" }
}

/// Account credential returned by the ticket-guard exchange.
struct QishuiCredential: Codable, Sendable {
    var deviceId: String
    var ticket: String
    /// Base64 of the raw 32-byte P-256 private key.
    var guardKey: String
    /// Base64 of the PEM client certificate.
    var guardCert: String
    var guardTsSign: String
    var accessCode: String
    var openId: String
    var expiresAt: TimeInterval
    var userId: String
    var nickname: String
    var avatarURL: String?
    var isVIP: Bool

    var expiryDate: Date { Date(timeIntervalSince1970: expiresAt) }
}

enum QishuiFields {
    static func text(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.lowercased() == "true" }
        return false
    }
}

enum QishuiMapping {
    /// Qishui media ids are numeric strings; keep a stable positive Int for the
    /// unified `Track.id` without relying on Swift's randomized `hashValue`.
    static func numericID(_ raw: String) -> Int {
        if let value = Int(raw), value > 0 { return value }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash & 0x3FFF_FFFF_FFFF_FFFF) + 1
    }

    /// Qishui returns an object, not a plain URL. The image only renders when
    /// the template suffix is present; without it the CDN answers 400.
    static func coverURL(_ value: Any?) -> String? {
        if let string = value as? String, string.hasPrefix("http") { return string }
        guard let object = value as? [String: Any] else { return nil }
        if let direct = object["url"] as? String, direct.hasPrefix("http") { return direct }
        let base = (object["urls"] as? [String])?.first
            ?? (object["urls"] as? String)?.split(separator: " ").first.map(String.init)
            ?? ""
        let uri = QishuiFields.text(object["uri"]) ?? ""
        guard !base.isEmpty, !uri.isEmpty else { return nil }
        let prefix = QishuiFields.text(object["template_prefix"]) ?? ""
        guard !prefix.isEmpty else { return base + uri }
        if let template = object["template"] as? String, !template.isEmpty {
            let resized = template.replacingOccurrences(
                of: #"resize:\d+:\d+"#,
                with: "resize:800:800",
                options: .regularExpression
            )
            return base + uri + "~\(prefix)-\(resized)"
        }
        return base + uri + "~\(prefix)-resize:800:800.image"
    }

    /// `BNTrackInfo` shape -> unified `Track`.
    static func track(from raw: [String: Any]) -> Track? {
        let wrapped = raw["entity"] as? [String: Any]
        let entity: [String: Any] = (raw["track_entity"] as? [String: Any])
            ?? (wrapped?["media"] as? [String: Any])
            ?? (wrapped?["track"] as? [String: Any])
            ?? (raw["track"] as? [String: Any])
            ?? raw
        let base = entity["base_info"] as? [String: Any] ?? entity
        let related = entity["related_info"] as? [String: Any] ?? [:]
        let display = entity["display_info"] as? [String: Any] ?? [:]
        let commerce = entity["commerce_info"] as? [String: Any] ?? [:]

        let rawID = QishuiFields.text(base["id"]) ?? QishuiFields.text(entity["id"])
        guard let rawID, !rawID.isEmpty else { return nil }
        let name = QishuiFields.text(base["name"]) ?? ""

        let artists: [ArtistRef] = QishuiFields.objects(related["artist_links"]).compactMap { item in
            guard let name = QishuiFields.text(item["name"]) else { return nil }
            let rawArtistID = QishuiFields.text(item["id"]) ?? name
            return ArtistRef(id: numericID(rawArtistID), name: name,
                             picUrl: coverURL(item["url_avatar"]))
        }
        let album = related["album_link"] as? [String: Any] ?? [:]
        let albumName = QishuiFields.text(album["name"]) ?? ""
        let albumID = QishuiFields.text(album["id"]) ?? ""
        let durationMS = QishuiFields.int(base["duration_ms"]) ?? 0

        var metadata: [String: String] = [
            "songmid": rawID,
            "songId": rawID,
        ]
        if !albumID.isEmpty { metadata["albumId"] = albumID }
        if let cover = coverURL(display["cover_url"]) { metadata["coverURL"] = cover }
        if let subName = QishuiFields.text(base["sub_name"]), !subName.isEmpty {
            metadata["subName"] = subName
        }
        // `commerce_info` carries the paywall flags; keep them for the VIP badge
        // instead of guessing from the presence of quality entries.
        if let condition = QishuiFields.text(commerce["playable_condition"]), !condition.isEmpty {
            metadata["playableCondition"] = condition
        }
        if QishuiFields.bool(commerce["payment_type"]) {
            metadata["vip"] = "1"
        }

        return Track(
            id: numericID(rawID),
            name: name,
            artists: artists,
            album: AlbumRef(id: albumID.isEmpty ? 0 : numericID(albumID),
                            name: albumName,
                            picUrl: coverURL(display["cover_url"])),
            durationMS: durationMS,
            source: "sd",
            sourceMetadata: metadata
        )
    }
}
