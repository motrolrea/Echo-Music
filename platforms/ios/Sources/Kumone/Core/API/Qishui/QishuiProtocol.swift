import Foundation
import CommonCrypto

/// 汽水音乐 PC 协议常量与工具。
///
/// 与车机（open.douyin.com + ticket-guard）不同，PC 端只依赖：
/// - `api.qishui.com` + `LunaPC` UA 的普通请求（账号读取，手动携带 Cookie）；
/// - 第三方签名服务补 `ms_token` / `a_bogus`（搜索、播放、场景流）。
enum QishuiProtocol {
    static let pcHost = "https://api.qishui.com"
    static let userAgent = "LunaPC/3.3.0(359450208)"
    static let browserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

    static let aid = "386088"
    static let appName = "luna_pc"
    static let versionName = "3.3.0"
    static let versionCode = "30030000"
    static let channel = "official"
    static let buildMode = "master"
    static let region = "cn"
    static let timeZone = "Asia/Shanghai"
    static let devicePlatform = "windows"
    static let deviceType = "Windows"
    static let osVersion = "Windows 11"

    /// 签名服务（把请求 URL/头/体交给它，换回 ms_token 与 a_bogus）。
    static let signerURL = URL(string: "http://103.236.75.83:8899/sign")!
    static let signerToken = "b356ad402bc31ee9e5a99cfdbf41eaa39961a562251c3359"

    /// 需要重新登录的业务错误码。
    static let authErrorCodes: Set<Int> = [1000016]

    /// 允许回传给汽水的 Cookie 字段：官网 WKWebView 会写入大量无关 Cookie，
    /// 只保留登录真正需要的这些，避免请求头过大或被风控。
    static let allowedCookieKeys: Set<String> = [
        "sessionid", "sessionid_ss", "sid_guard", "sid_tt", "uid_tt", "uid_tt_ss",
        "ssid_ucp_v1", "session_tlb_tag", "passport_csrf_token", "passport_csrf_token_default",
    ]

    // MARK: - 查询参数

    /// 所有 PC 接口共用的基础参数（按 key 升序拼接）。
    static func baseQuery(deviceID: String) -> [String: String] {
        [
            "ac": "wifi",
            "aid": aid,
            "app_name": appName,
            "build_mode": buildMode,
            "channel": channel,
            "device_id": deviceID,
            "device_platform": devicePlatform,
            "device_type": deviceType,
            "fp": deviceID,
            "geo_region": region,
            "iid": QishuiDeviceIdentity.iid,
            "os_region": region,
            "os_version": osVersion,
            "region": region,
            "tz": timeZone,
            "version_code": versionCode,
            "version_name": versionName,
        ]
    }

    /// 拼出带完整查询串的 URL（排序后逐项编码）。
    static func url(path: String, deviceID: String = QishuiDeviceIdentity.deviceID,
                    extras: [String: String] = [:]) -> URL? {
        var parameters = baseQuery(deviceID: deviceID)
        for (key, value) in extras { parameters[key] = value }
        var components = URLComponents(string: pcHost + path)
        components?.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url
    }

    static func queryString(_ url: URL) -> String {
        url.query ?? ""
    }

    // MARK: - MD5

    static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func md5Hex(_ string: String) -> String {
        md5Hex(Data(string.utf8))
    }

    // MARK: - Cookie

    static func cookieDictionary(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[piece.startIndex..<index]).trimmingCharacters(in: .whitespaces)
            let value = String(piece[piece.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    static func cookieHeader(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.contains {
            $0.isWhitespace || $0 == ";" || ($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false)
        }
    }

    /// 只保留登录必需的 Cookie 字段。
    static func accountCookie(_ cookie: String) -> String {
        let dictionary = cookieDictionary(cookie)
            .filter { allowedCookieKeys.contains($0.key) && !$0.value.isEmpty }
        return cookieHeader(dictionary)
    }

    /// 从 Cookie 串里取登录态；没有有效 `sessionid` 视为未登录。
    static func sessionID(from cookie: String) -> String? {
        let value = cookieDictionary(cookie)["sessionid"] ?? ""
        return validSessionID(value) ? value : nil
    }
}

/// PC 端设备标识：固定一次后复用，避免每次请求都换设备被风控。
enum QishuiDeviceIdentity {
    private static let deviceKey = "qishui.pc.deviceID"
    private static let iidKey = "qishui.pc.iid"

    static var deviceID: String {
        if let stored = UserDefaults.standard.string(forKey: deviceKey), !stored.isEmpty {
            return stored
        }
        let value = String(Int(Date().timeIntervalSince1970 * 1000))
        UserDefaults.standard.set(value, forKey: deviceKey)
        return value
    }

    static var iid: String {
        if let stored = UserDefaults.standard.string(forKey: iidKey), !stored.isEmpty {
            return stored
        }
        let base = Int(deviceID) ?? Int(Date().timeIntervalSince1970 * 1000)
        let value = String(base + 1)
        UserDefaults.standard.set(value, forKey: iidKey)
        return value
    }

    /// 兼容旧代码里的 `current`。
    static var current: String { deviceID }
}
