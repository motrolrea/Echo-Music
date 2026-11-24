import Foundation
import CryptoKit
import Security

enum QishuiLoginState: Equatable {
    case waiting
    case scanned
    case confirmed
    case expired
    case failed(String)
}

struct QishuiProfile: Sendable {
    let id: String
    let nickname: String
    let avatarURL: String?
    let isVIP: Bool
}

/// Douyin QR sign-in for the Qishui car protocol.
@MainActor
final class QishuiAuthService {
    static let shared = QishuiAuthService()

    private struct PendingQR {
        let token: String
        let image: String
        let expires: Date
    }

    private var pending: [String: PendingQR] = [:]
    private var generation = 0

    private init() {}

    // MARK: - QR lifecycle

    func start() async throws -> String {
        pending = pending.filter { $0.value.expires > Date() }
        generation &+= 1
        let mine = generation
        let query = Self.qrQuery()
        guard let url = URL(string: "https://open.douyin.com/oauth/get_qrcode/?\(query)") else {
            throw QishuiError(.invalidResponse, "汽水登录地址无效")
        }
        let (body, _) = try await QishuiClient.shared.raw(url)
        guard let root = body as? [String: Any],
              let data = root["data"] as? [String: Any],
              let token = data["token"] as? String,
              let image = data["qrcode"] as? String else {
            throw QishuiError(.invalidResponse, "汽水没有返回登录二维码")
        }
        guard mine == generation else {
            throw QishuiError(.unavailable, "登录已取消")
        }
        let key = Self.randomKey()
        pending[key] = PendingQR(token: token,
                                 image: "data:image/png;base64,\(image)",
                                 expires: Date().addingTimeInterval(300))
        return key
    }

    func image(for key: String) -> String? {
        pending[key]?.image
    }

    func cancel(_ key: String) {
        pending.removeValue(forKey: key)
    }

    func check(_ key: String) async throws -> QishuiLoginState {
        guard let entry = pending[key] else { return .expired }
        let query = Self.qrQuery() + "&token=\(Self.encode(entry.token))&timestamp=\(Int(Date().timeIntervalSince1970 * 1000))"
        guard let url = URL(string: "https://open.douyin.com/oauth/check_qrcode/?\(query)") else {
            throw QishuiError(.invalidResponse, "汽水登录地址无效")
        }
        let (body, _) = try await QishuiClient.shared.raw(url)
        guard let root = body as? [String: Any],
              let data = root["data"] as? [String: Any],
              let status = data["status"] as? String else {
            throw QishuiError(.invalidResponse, "汽水登录状态无法识别")
        }

        switch status {
        case "new":
            return .waiting
        case "scanned":
            return .scanned
        case "expired", "refused":
            pending.removeValue(forKey: key)
            return status == "refused" ? .failed("扫码被拒绝，请重新扫码") : .expired
        case "confirmed":
            guard let code = data["code"] as? String ?? data["auth_code"] as? String, !code.isEmpty else {
                throw QishuiError(.invalidResponse, "汽水没有返回授权码")
            }
            let access = try await accessCode(code)
            let credential = try await ticket(access: access)
            let profile = try await profile(for: credential)
            pending.removeValue(forKey: key)
            QishuiSessionStore.shared.apply(credential: credential, profile: profile)
            return .confirmed
        default:
            return .waiting
        }
    }

    // MARK: - Session renewal

    func refresh() async throws -> QishuiProfile {
        guard let old = QishuiSessionStore.shared.credential else {
            throw QishuiError(.authRequired, "请先用抖音扫码登录汽水音乐")
        }
        var candidate = old
        if old.expiresAt < Date().timeIntervalSince1970 + 3600 {
            let access = try await refreshAccessCode(old.accessCode, deviceId: old.deviceId)
            candidate = try await ticket(access: access, guardKey: old.guardKey,
                                         guardCert: old.guardCert, deviceId: old.deviceId,
                                         openId: access.openId.isEmpty ? old.openId : access.openId)
        }
        let profile = try await profile(for: candidate)
        guard profile.id == old.userId || old.userId.isEmpty else {
            QishuiSessionStore.shared.signOut()
            throw QishuiError(.authRequired, "汽水账号已更换，请重新扫码")
        }
        candidate.userId = profile.id
        candidate.nickname = profile.nickname
        candidate.avatarURL = profile.avatarURL
        candidate.isVIP = profile.isVIP
        QishuiSessionStore.shared.apply(credential: candidate, profile: profile)
        return profile
    }

    // MARK: - Steps

    private struct AccessCode {
        let accessCode: String
        let openId: String
        let expiresAt: TimeInterval
    }

    private func accessCode(_ code: String) async throws -> AccessCode {
        let query = QishuiProtocol.query(deviceId: QishuiDeviceIdentity.current,
                                         extras: ["auth_code": code])
        guard let url = URL(string: "https://open.qishui.com\(QishuiProtocol.prefix)/access/code/get/?\(query)") else {
            throw QishuiError(.invalidResponse, "汽水授权地址无效")
        }
        let (body, _) = try await QishuiClient.shared.raw(url)
        guard let root = body as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水授权响应无法识别")
        }
        let data = root["data"] as? [String: Any] ?? root
        guard let accessCode = data["access_code"] as? String, !accessCode.isEmpty else {
            throw QishuiError(.authRequired, "汽水授权失败，请重新扫码")
        }
        let openId = (data["open_id"] as? String) ?? (data["open_uid"] as? String) ?? ""
        let expiry = QishuiProtocol.credentialExpiry(QishuiFields.double(data["expires_time"]) ?? 0)
        return AccessCode(accessCode: accessCode, openId: openId,
                          expiresAt: expiry.timeIntervalSince1970)
    }

    private func refreshAccessCode(_ accessCode: String, deviceId: String) async throws -> AccessCode {
        let query = QishuiProtocol.query(deviceId: deviceId, extras: ["access_code": accessCode])
        guard let url = URL(string: "https://open.qishui.com\(QishuiProtocol.prefix)/access/code/refresh/?\(query)") else {
            throw QishuiError(.invalidResponse, "汽水续期地址无效")
        }
        let (body, _) = try await QishuiClient.shared.raw(url)
        guard let root = body as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水续期响应无法识别")
        }
        let data = root["data"] as? [String: Any] ?? root
        guard let code = data["access_code"] as? String, !code.isEmpty else {
            throw QishuiError(.authRequired, "汽水登录已失效，请重新扫码")
        }
        let openId = (data["open_id"] as? String) ?? (data["open_uid"] as? String) ?? ""
        let expiry = QishuiProtocol.credentialExpiry(QishuiFields.double(data["expires_time"]) ?? 0)
        return AccessCode(accessCode: code, openId: openId,
                          expiresAt: expiry.timeIntervalSince1970)
    }

    private func ticket(access: AccessCode) async throws -> QishuiCredential {
        let guardValue = try QishuiProtocol.makeGuard()
        return try await ticket(access: access, guardKey: guardValue.keyData.base64EncodedString(),
                                guardCert: "", deviceId: QishuiDeviceIdentity.current,
                                openId: access.openId, csr: guardValue.csr)
    }

    private func ticket(access: AccessCode, guardKey: String, guardCert: String,
                        deviceId: String, openId: String, csr: String? = nil) async throws -> QishuiCredential {
        let query = Self.encodePairs([
            ("aid", QishuiProtocol.loginAID),
            ("client_key", QishuiProtocol.clientKey),
            ("device_platform", "android"),
        ])
        guard let url = URL(string: "https://open-client.douyin.com/passport/open/get_access_ticket/?\(query)") else {
            throw QishuiError(.invalidResponse, "汽水登录地址无效")
        }
        let form = Self.encodePairs([
            ("access_code", access.accessCode),
            ("open_id", openId),
        ])
        var headers = ["bd-ticket-guard-version": "1"]
        if let csr, !csr.isEmpty {
            headers["bd-ticket-guard-client-csr"] = csr
        } else if !guardCert.isEmpty {
            headers["bd-ticket-guard-client-cert"] = guardCert
        }
        let response = try await QishuiClient.shared.rawResponse(
            url, method: "POST", headers: headers, body: Data(form.utf8)
        )
        guard let serverData = response.value(forHTTPHeaderField: "bd-ticket-guard-server-data") else {
            throw QishuiError(.invalidResponse, "汽水没有返回授权凭据")
        }
        let guardData = try QishuiProtocol.readGuard(serverData: serverData)
        return QishuiCredential(
            deviceId: deviceId,
            ticket: guardData.ticket,
            guardKey: guardKey,
            guardCert: guardData.cert,
            guardTsSign: guardData.tsSign,
            accessCode: access.accessCode,
            openId: openId,
            expiresAt: access.expiresAt,
            userId: "",
            nickname: "",
            avatarURL: nil,
            isVIP: false
        )
    }

    private func profile(for credential: QishuiCredential) async throws -> QishuiProfile {
        let data = try await QishuiClient.shared.platform(path: "/me/info/", credential: credential)
        guard let user = data["my_info"] as? [String: Any] else {
            throw QishuiError(.authRequired, "汽水没有返回账号信息，请重新扫码")
        }
        let id = QishuiFields.text(user["id"]) ?? ""
        guard !id.isEmpty else {
            throw QishuiError(.invalidResponse, "汽水账号标识缺失")
        }
        return QishuiProfile(
            id: id,
            nickname: QishuiFields.text(user["nickname"]) ?? "",
            avatarURL: Self.avatarURL(user),
            isVIP: QishuiFields.bool(user["is_vip"])
        )
    }

    private static func avatarURL(_ user: [String: Any]) -> String? {
        for key in ["medium_avatar_url", "avatar_url", "thumb_avatar_url"] {
            if let value = user[key] as? String, value.hasPrefix("http") { return value }
            if let object = user[key] as? [String: Any] {
                if QishuiFields.bool(object["need_complete_url"]) == false { continue }
                if let url = (object["urls"] as? [String])?.first, url.hasPrefix("http") { return url }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func qrQuery() -> String {
        let identity = Insecure.MD5.hash(data: Data("com.luna.music.car".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return encodePairs([
            ("aid", QishuiProtocol.loginAID),
            ("client_key", QishuiProtocol.clientKey),
            ("scope", "user_info,luna.openapi.platform.interaction,luna.openapi.platform.me_tab,luna.commerce.openapi_platform.vip_info"),
            ("state", ""),
            ("next", ""),
            ("jump_type", "native"),
            ("optional_scope_check", ""),
            ("optional_scope_uncheck", ""),
            ("customize_params", "{\"source\":\"pc_auth\",\"not_skip_confirm\":\"true\"}"),
            ("source_from", "native"),
            ("device_platform", "android"),
            ("app_identity", identity),
            ("signature", "cf9024ea72d9c71813238b13ea107a3d"),
        ])
    }

    private static func encodePairs(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
