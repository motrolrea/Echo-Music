import Foundation

/// Resolves a playable URL from the `player_info` carried by `/media/mget/`.
///
/// Only plaintext resources are selected. The car interface encrypts the
/// lossless tiers, so the best reachable quality is `high` even for a VIP
/// account; encrypted candidates are skipped instead of being decrypted.
enum QishuiPlayback {
    struct AudioSource {
        let url: URL
        /// Canonical Echo tier (`AudioQuality.lxType`).
        let quality: String
        let preview: Bool
        let clipStartMS: Int
    }

    private enum Tier: Int {
        case standard = 0
        case high = 1
        case lossless = 2
        case hires = 3

        var lxToken: String {
            switch self {
            case .standard: return "128k"
            case .high: return "320k"
            case .lossless: return "flac"
            case .hires: return "flac24bit"
            }
        }

        init?(name: String?) {
            switch (name ?? "").lowercased() {
            case "standard", "medium", "1": self = .standard
            case "high", "higher", "highest", "2": self = .high
            case "lossless", "3": self = .lossless
            case "hires", "hi_res", "4": self = .hires
            default: return nil
            }
        }
    }

    private static let trustedHosts = [
        "365yg.com", "douyinvod.com", "douyinscdn.com", "bytefcdn.com", "bytecdn.cn",
        "byteicdn.com", "ibytedtos.com", "pstatp.com", "snssdk.com", "bytedance.com",
        "bytetos.com", "volcvideo.com", "volccdn.com", "volces.com", "volcengineapi.com",
        "douyin.com", "qishui.com", "zijieapi.com", "zjcdn.com",
    ]

    static func resolve(trackID: String, lxQuality: String) async throws -> AudioSource {
        let requested = requestedTier(lxQuality)
        let credential = await MainActor.run { QishuiSessionStore.shared.credential }

        if let credential {
            if let entity = try? await QishuiCatalogService.trackEntity(id: trackID, credential: credential),
               let source = try? await resolve(entity: entity, requested: requested),
               !source.preview {
                return source
            }
        }

        let entity = try await QishuiCatalogService.trackEntity(id: trackID)
        return try await resolve(entity: entity, requested: requested)
    }

    private static func requestedTier(_ lxQuality: String) -> Tier {
        switch lxQuality.lowercased() {
        case "128k", "standard", "128": return .standard
        case "320k", "exhigh", "higher", "320": return .high
        case "flac", "lossless": return .lossless
        case "flac24bit", "hires", "master", "jymaster", "atmos", "dolby", "surround": return .hires
        default: return .high
        }
    }

    private static func resolve(entity: [String: Any], requested: Tier) async throws -> AudioSource {
        guard let player = entity["player_info"] as? [String: Any] else {
            throw QishuiError(.notPlayable, "汽水没有返回播放信息")
        }
        for variant in ["full", "preview"] {
            guard let info = (player[variant] as? [String: Any])?["video_model_info"] as? [String: Any] else {
                continue
            }
            var candidates: [(url: URL, tier: Tier, bitrate: Int)] = []
            if let modelValue = info["video_model"] {
                let model: [String: Any]?
                if let text = modelValue as? String, let data = text.data(using: .utf8) {
                    model = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                } else {
                    model = modelValue as? [String: Any]
                }
                for item in QishuiFields.objects(model?["video_list"]) where !isEncrypted(item) {
                    guard let raw = item["main_url"] as? String,
                          let url = trustedURL(raw) else { continue }
                    let meta = item["video_meta"] as? [String: Any] ?? [:]
                    let tier = Tier(name: QishuiFields.text(meta["quality"])) ?? .standard
                    candidates.append((url, tier, QishuiFields.int(meta["bitrate"]) ?? 0))
                }
            }
            if candidates.isEmpty, let playInfoURL = info["url_player_info"] as? String,
               let url = trustedURL(playInfoURL) {
                if let list = try? await fetchPlayInfoList(url) {
                    for item in list where !isEncrypted(item) {
                        guard let raw = item["MainPlayUrl"] as? String,
                              let mediaURL = trustedURL(raw) else { continue }
                        let tier = Tier(name: QishuiFields.text(item["Quality"])) ?? .standard
                        candidates.append((mediaURL, tier, QishuiFields.int(item["Bitrate"]) ?? 0))
                    }
                }
            }
            guard !candidates.isEmpty else { continue }
            let allowed = candidates.filter { $0.tier.rawValue <= requested.rawValue }
            let pool = allowed.isEmpty ? candidates : allowed
            guard let best = pool.sorted(by: {
                if $0.tier.rawValue != $1.tier.rawValue { return $0.tier.rawValue > $1.tier.rawValue }
                return $0.bitrate > $1.bitrate
            }).first else { continue }

            let preview = variant == "preview"
            let previewInfo = player["preview"] as? [String: Any]
            let previewDuration = previewInfo?["duration"] as? [String: Any]
            let clipStart = preview ? (QishuiFields.int(previewDuration?["start_ms"]) ?? 0) : 0
            return AudioSource(url: best.url, quality: best.tier.lxToken,
                               preview: preview, clipStartMS: clipStart)
        }
        throw QishuiError(.notPlayable, "汽水只返回了加密音源，当前不支持下解密")
    }

    private static func fetchPlayInfoList(_ url: URL) async throws -> [[String: Any]] {
        let (body, _) = try await QishuiClient.shared.raw(url)
        guard let root = body as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水播放信息无法识别")
        }
        let result = root["Result"] as? [String: Any]
        let data = result?["Data"] as? [String: Any] ?? root["data"] as? [String: Any]
        let list = data?["PlayInfoList"] ?? root["PlayInfoList"]
        return QishuiFields.objects(list)
    }

    private static func isEncrypted(_ item: [String: Any]) -> Bool {
        if let encrypt = item["encrypt_info"] as? [String: Any] {
            if QishuiFields.bool(encrypt["encrypt"]) || QishuiFields.bool(encrypt["spade_a"]) {
                return true
            }
        }
        if let playAuth = item["PlayAuth"] as? String, !playAuth.isEmpty { return true }
        if let playAuth = item["PlayAuth"], !(playAuth is NSNull) { return true }
        if let encrypt = QishuiFields.int(item["Encrypt"]), encrypt != 0 { return true }
        return false
    }

    private static func trustedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return nil }
        let trusted = trustedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        return trusted ? url : nil
    }
}
