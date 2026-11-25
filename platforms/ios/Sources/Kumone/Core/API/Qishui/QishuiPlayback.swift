import Foundation

/// Resolves a playable URL from the `player_info` carried by `/media/mget/`.
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

    private static func resolve(entity: [String: Any], requested: Tier) async throws -> AudioSource {
        guard let player = entity["player_info"] as? [String: Any] else {
            throw QishuiError(.notPlayable, "汽水没有返回播放信息")
        }
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
        throw QishuiError(.notPlayable, "汽水没有返回可播放的音源")
    }

    private static func encryptionInfo(_ item: [String: Any]) -> EncryptedSource? {
        var spade: String?
        var method: String?
        if let encrypt = item["encrypt_info"] as? [String: Any] {
            method = QishuiFields.text(encrypt["encryption_method"])
            if let value = QishuiFields.text(encrypt["spade_a"]), !value.isEmpty { spade = value }
        }
        var playAuth: String?
        if let value = QishuiFields.text(item["PlayAuth"]), !value.isEmpty { playAuth = value }
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