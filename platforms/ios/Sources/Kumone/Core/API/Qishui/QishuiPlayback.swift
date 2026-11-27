import Foundation

/// Resolves a playable URL from the PC `/luna/pc/track_v2` player payload.
///
/// 汽水对每个档位都返回 CENC(`cenc-aes-ctr`) 加密媒体，并给出 `spade_a`
/// （或登录态下的 `PlayAuth`）。明文候选优先；只有加密候选时先下载，再用
/// `QishuiCrypto` 还原密钥解密成普通 m4a 交给播放器。
enum QishuiPlayback {
    struct EncryptedSource {
        let spadeA: String?
        let playAuth: String?
        let method: String?

        var isSupported: Bool {
            if spadeA?.isEmpty == false || playAuth?.isEmpty == false { return true }
            let method = (self.method ?? "").lowercased()
            return method.isEmpty || method.contains("cenc") || method.contains("ctr")
        }
    }

    struct AudioSource {
        let url: URL
        /// Canonical Echo tier (`AudioQuality.lxType`).
        let quality: String
        let preview: Bool
        let clipStartMS: Int
        let encryption: EncryptedSource?
        /// 容器内实际编码（`aac` / `flac`），决定解密后的文件扩展名。
        let codec: String

        var needsDecryption: Bool { encryption != nil }
        /// 解密后仍是 MP4 容器（`enca` 只是还原了 sample entry 的 fourcc），
        /// 因此统一用 `.m4a`，避免扩展名与容器不符导致播放器拒绝。
        var fileExtension: String { "m4a" }
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
        var candidates: [AudioSource] = []

        // 登录态优先：签名后的 PC track_v2 才能拿到整曲。
        if let credential,
           let entity = try? await QishuiCatalogService.trackEntity(id: trackID, credential: credential),
           let player = entity["player_info"] as? [String: Any],
           let source = try? await resolve(player: player, requested: requested) {
            if !source.preview { return source }
            candidates.append(source)
        }

        // 匿名 Web 的 track_v2（与 Coda 相同的来源，不涉及任何第三方签名）：
        // 未登录时通常只给试听，但它偶尔能拿到完整的明文流，作为优先候补。
        if let webPlayer = await webPlayerInfo(trackID: trackID),
           let source = try? await resolve(player: webPlayer, requested: requested) {
            if !source.preview, credential == nil { return source }
            candidates.append(source)
        }

        if let entity = try? await QishuiCatalogService.trackEntity(id: trackID),
           let player = entity["player_info"] as? [String: Any],
           let source = try? await resolve(player: player, requested: requested) {
            if !source.preview { return source }
            candidates.append(source)
        }

        if let best = candidates.first(where: { !$0.preview }) ?? candidates.first {
            return best
        }
        throw QishuiError(.notPlayable, "汽水没有返回可播放的音源")
    }

    private static let webUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

    /// 汽水 PC Web 的曲目接口，返回 `track_player`（内含 `video_model`）。
    /// 只发一条普通 GET，不需要登录 Cookie 或签名服务。
    private static func webPlayerInfo(trackID: String) async -> [String: Any]? {
        var components = URLComponents(string: "https://api.qishui.com/luna/pc/track_v2")
        components?.queryItems = [
            URLQueryItem(name: "track_id", value: trackID),
            URLQueryItem(name: "media_type", value: "track"),
            URLQueryItem(name: "aid", value: "386088"),
            URLQueryItem(name: "device_platform", value: "web"),
            URLQueryItem(name: "channel", value: "pc_web"),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let player = (root["seo_track"] as? [String: Any])?["track_player"] as? [String: Any] {
            return player
        }
        if let player = root["track_player"] as? [String: Any] { return player }
        if let player = (root["data"] as? [String: Any])?["track_player"] as? [String: Any] {
            return player
        }
        return nil
    }

    /// 把解析结果变成播放器可以直接打开的地址：明文直链原样返回，
    /// 加密媒体下载并解密到缓存目录。
    static func playableURL(for source: AudioSource, trackID: String) async throws -> URL {
        guard let encryption = source.encryption else { return source.url }
        let key: [UInt8]
        if let spade = encryption.spadeA, !spade.isEmpty {
            let hex = try QishuiCrypto.extractKey(fromPlayAuth: spade)
            guard let bytes = QishuiCrypto.hexDecode(hex), bytes.count == 16 else {
                throw QishuiError(.notPlayable, "汽水密钥无效")
            }
            key = bytes
        } else if let auth = encryption.playAuth, !auth.isEmpty {
            let hex = try QishuiCrypto.extractKey(fromPlayAuth: auth)
            guard let bytes = QishuiCrypto.hexDecode(hex), bytes.count == 16 else {
                throw QishuiError(.notPlayable, "汽水密钥无效")
            }
            key = bytes
        } else {
            throw QishuiError(.notPlayable, "汽水未提供解密密钥")
        }

        let cached = cacheFileURL(trackID: trackID, quality: source.quality,
                                  key: key, fileExtension: source.fileExtension)
        if FileManager.default.fileExists(atPath: cached.path) {
            let values = try? cached.resourceValues(forKeys: [.fileSizeKey])
            if (values?.fileSize ?? 0) > 1024 {
                return cached
            }
        }

        let (data, response) = try await URLSession.shared.data(from: source.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QishuiError(.network, "汽水音频下载失败（HTTP \(http.statusCode)）")
        }
        guard data.count > 4096 else {
            throw QishuiError(.network, "汽水音频数据为空")
        }

        let plain = try await Task.detached(priority: .userInitiated) { () -> Data in
            try QishuiCrypto.decryptAudio(withKey: key, data: data)
        }.value

        let directory = cached.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent("\(UUID().uuidString).part")
        try plain.write(to: temp, options: .atomic)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: temp, to: cached)
        trimCache(directory: directory)
        return cached
    }

    private static func cacheFileURL(trackID: String, quality: String, key: [UInt8],
                                     fileExtension: String) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QishuiAudio", isDirectory: true)
        let keyTag = key.prefix(4).map { String(format: "%02x", $0) }.joined()
        let safeID = trackID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safeID)-\(quality)-\(keyTag).\(fileExtension)")
    }

    /// 汽水无损单曲约 20MB；缓存上限 400MB，超出按最后访问时间淘汰。
    private static func trimCache(directory: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let date = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            return (url, values.fileSize ?? 0, date)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > 400 * 1024 * 1024 else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) {
            guard total > 300 * 1024 * 1024 else { break }
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
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

    private static func resolve(player: [String: Any], requested: Tier) async throws -> AudioSource {
        for variant in ["full", "preview"] {
            guard let info = (player[variant] as? [String: Any])?["video_model_info"] as? [String: Any] else {
                continue
            }
            var candidates: [(url: URL, tier: Tier, bitrate: Int, codec: String, encryption: EncryptedSource?)] = []
            if let modelValue = info["video_model"] {
                let model: [String: Any]?
                if let text = modelValue as? String, let data = text.data(using: .utf8) {
                    model = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                } else {
                    model = modelValue as? [String: Any]
                }
                for item in QishuiFields.objects(model?["video_list"]) {
                    guard let raw = item["main_url"] as? String,
                          let url = trustedURL(raw) else { continue }
                    let encryption = encryptionInfo(item)
                    if encryption?.isSupported == false { continue }
                    let meta = item["video_meta"] as? [String: Any] ?? [:]
                    let tier = Tier(name: QishuiFields.text(meta["quality"])) ?? .standard
                    let codec = (QishuiFields.text(meta["codec_type"]) ?? "").lowercased()
                    candidates.append((url, tier, QishuiFields.int(meta["bitrate"]) ?? 0, codec, encryption))
                }
            }
            if candidates.isEmpty, let playInfoURL = info["url_player_info"] as? String,
               let url = trustedURL(playInfoURL) {
                if let list = try? await fetchPlayInfoList(url) {
                    for item in list {
                        guard let raw = item["MainPlayUrl"] as? String,
                              let mediaURL = trustedURL(raw) else { continue }
                        let encryption = encryptionInfo(item)
                        if encryption?.isSupported == false { continue }
                        let tier = Tier(name: QishuiFields.text(item["Quality"])) ?? .standard
                        let codec = (QishuiFields.text(item["CodecType"]) ?? "").lowercased()
                        candidates.append((mediaURL, tier, QishuiFields.int(item["Bitrate"]) ?? 0, codec, encryption))
                    }
                }
            }
            guard !candidates.isEmpty else { continue }
            let allowed = candidates.filter { $0.tier.rawValue <= requested.rawValue }
            let pool = allowed.isEmpty ? candidates : allowed
            let ranked = pool.sorted(by: {
                // 同一档位优先明文，省掉一次下载与解密。
                if $0.tier.rawValue != $1.tier.rawValue { return $0.tier.rawValue > $1.tier.rawValue }
                let lhsPlain = $0.encryption == nil
                let rhsPlain = $1.encryption == nil
                if lhsPlain != rhsPlain { return lhsPlain }
                return $0.bitrate > $1.bitrate
            })
            guard let best = ranked.first else { continue }

            let preview = variant == "preview"
            let previewInfo = player["preview"] as? [String: Any]
            let previewDuration = previewInfo?["duration"] as? [String: Any]
            let clipStart = preview ? (QishuiFields.int(previewDuration?["start_ms"]) ?? 0) : 0
            return AudioSource(url: best.url, quality: best.tier.lxToken,
                               preview: preview, clipStartMS: clipStart,
                               encryption: best.encryption, codec: best.codec)
        }

        // 字段结构不标准时（PC Web 的 track_v2、旧版本返回），递归扫描
        // 任意层级的可播放地址，尽量把能播的音源捡回来。
        var modelSource: Any = player
        if let value = player["video_model"] { modelSource = value }
        else if let value = player["full"] { modelSource = value }
        else if let value = player["preview"] { modelSource = value }
        let tolerant = tolerantCandidates(modelSource)
            if let best = tolerant.max(by: {
                ($0.preview ? 0 : 1, $0.tier.rawValue, $0.bitrate) < ($1.preview ? 0 : 1, $1.tier.rawValue, $1.bitrate)
            }) {
                return AudioSource(url: best.url, quality: best.tier.lxToken,
                                   preview: best.preview, clipStartMS: 0,
                                   encryption: best.encryption, codec: best.codec)
        }
        throw QishuiError(.notPlayable, "汽水没有返回可播放的音源")
    }

    private struct RawCandidate {
        let url: URL
        let tier: Tier
        let bitrate: Int
        let codec: String
        let encryption: EncryptedSource?
        let preview: Bool
    }

    private static func tolerantCandidates(_ node: Any,
                                           depth: Int = 0,
                                           inheritedAuth: String = "") -> [RawCandidate] {
        guard depth < 12 else { return [] }
        if let text = node as? String, let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            return tolerantCandidates(parsed, depth: depth + 1, inheritedAuth: inheritedAuth)
        }
        if let list = node as? [Any] {
            return list.flatMap { tolerantCandidates($0, depth: depth + 1, inheritedAuth: inheritedAuth) }
        }
        guard let entry = node as? [String: Any] else { return [] }

        let meta = entry["video_meta"] as? [String: Any] ?? [:]
        let encrypt = entry["encrypt_info"] as? [String: Any] ?? [:]
        var auth = inheritedAuth
        for key in ["play_auth", "PlayAuth", "spade_a", "SpadeA", "spadeA"] {
            if let value = QishuiFields.text(entry[key]), !value.isEmpty { auth = value; break }
        }
        if auth.isEmpty {
            for key in ["spade_a", "SpadeA", "spadeA", "play_auth", "PlayAuth"] {
                if let value = QishuiFields.text(encrypt[key]), !value.isEmpty { auth = value; break }
            }
        }

        var results: [RawCandidate] = []
        let addresses = ["main_url", "main_play_url", "MainPlayUrl", "MainUrl",
                         "url", "backup_url", "backup_play_url", "BackupPlayUrl", "BackupUrl"]
        if let raw = addresses.lazy.compactMap({ QishuiFields.text(entry[$0]) }).first,
           let url = trustedURL(raw) {
            let tier = Tier(name: QishuiFields.text(entry["quality"] ?? entry["Quality"] ?? meta["quality"])) ?? .standard
            let codec = (QishuiFields.text(entry["codec_type"])
                ?? QishuiFields.text(meta["codec_type"]) ?? "").lowercased()
            let bitrate = QishuiFields.int(entry["bitrate"]) ?? QishuiFields.int(meta["bitrate"]) ?? 0
            // 条目自带时长且明显短于整曲（约 30 秒）时按试听处理。
            let rawDuration = QishuiFields.int(entry["video_duration"]
                ?? entry["duration"] ?? entry["Duration"] ?? meta["duration"]) ?? 0
            let durationMS = rawDuration > 1000 ? rawDuration : rawDuration * 1000
            let range = (entry["playable_range"] as? [String: Any]) ?? (meta["playable_range"] as? [String: Any])
            let rangeStart = QishuiFields.int(range?["start"]) ?? 0
            let rangeDuration = QishuiFields.int(range?["duration"]) ?? 0
            let rangeMS = rangeDuration > 1000 ? rangeDuration : (rangeDuration > 0 ? rangeDuration * 1000 : 0)
            let looksPreview = rangeStart != 0
                || (rangeMS > 0 && rangeMS < 60_000)
                || (durationMS > 0 && durationMS < 60_000)
            results.append(RawCandidate(url: url,
                                        tier: tier,
                                        bitrate: bitrate,
                                        codec: codec,
                                        encryption: auth.isEmpty
                                            ? nil
                                            : EncryptedSource(spadeA: auth, playAuth: nil, method: nil),
                                        preview: looksPreview))
        }
        for value in entry.values {
            results += tolerantCandidates(value, depth: depth + 1, inheritedAuth: auth)
        }
        return results
    }

    private static func encryptionInfo(_ item: [String: Any]) -> EncryptedSource? {
        var spade: String?
        var method: String?
        var playAuth: String?
        if let encrypt = item["encrypt_info"] as? [String: Any] {
            method = QishuiFields.text(encrypt["encryption_method"])
            for key in ["spade_a", "SpadeA", "spadeA"] {
                if let value = QishuiFields.text(encrypt[key]), !value.isEmpty { spade = value; break }
            }
            for key in ["play_auth", "PlayAuth"] {
                if let value = QishuiFields.text(encrypt[key]), !value.isEmpty { playAuth = value; break }
            }
        }
        if spade == nil {
            for key in ["spade_a", "SpadeA", "spadeA"] {
                if let value = QishuiFields.text(item[key]), !value.isEmpty { spade = value; break }
            }
        }
        if playAuth == nil {
            for key in ["play_auth", "PlayAuth"] {
                if let value = QishuiFields.text(item[key]), !value.isEmpty { playAuth = value; break }
            }
        }
        var flagged = spade != nil || playAuth != nil
            || QishuiFields.bool((item["encrypt_info"] as? [String: Any])?["encrypt"])
        if let encrypt = QishuiFields.int(item["Encrypt"]), encrypt != 0 { flagged = true }
        guard flagged else { return nil }
        return EncryptedSource(spadeA: spade, playAuth: playAuth, method: method)
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