import Foundation

/// Signs in with the cookie captured from the Qishui app QR flow, then
/// checks it against `/luna/pc/me`.
@MainActor
final class QishuiAuthService {
    static let shared = QishuiAuthService()

    private init() {}

    func signIn(cookie: String) async throws -> QishuiProfile {
        let filtered = QishuiProtocol.accountCookie(cookie)
        guard QishuiProtocol.sessionID(from: filtered) != nil else {
            throw QishuiError(.authRequired, "没有读取到汽水登录状态，请先完成扫码")
        }
        let profile = try await profile(cookie: filtered)
        let credential = QishuiCredential(cookie: filtered, userId: profile.id,
                                          nickname: profile.nickname, avatarURL: profile.avatarURL,
                                          isVIP: profile.isVIP)
        QishuiSessionStore.shared.apply(credential: credential, profile: profile)
        return profile
    }

    /// Re-reads the stored account. An auth failure means the cookie is dead.
    func refresh() async throws -> QishuiProfile {
        guard let credential = QishuiSessionStore.shared.credential, credential.isValid else {
            throw QishuiError(.authRequired, "请先登录汽水音乐")
        }
        let profile = try await profile(cookie: credential.accountCookie)
        QishuiSessionStore.shared.apply(credential: credential, profile: profile)
        return profile
    }

    private func profile(cookie: String) async throws -> QishuiProfile {
        let root = try await QishuiClient.shared.get(path: "/luna/pc/me",
                                                     extras: ["aid": QishuiProtocol.aid],
                                                     cookie: cookie)
        let info = (root["my_info"] as? [String: Any])
            ?? (root["user"] as? [String: Any])
            ?? ((root["data"] as? [String: Any])?["my_info"] as? [String: Any])
            ?? [:]
        guard let id = QishuiFields.text(info["user_id"] ?? info["uid"] ?? info["id"]), !id.isEmpty else {
            throw QishuiError(.authRequired, "汽水登录已失效，请重新登录")
        }
        let thumb = info["avatar_thumb"] as? [String: Any]
        let avatar = QishuiFields.text(info["avatar_url"])
            ?? QishuiFields.imageURL(thumb)
            ?? QishuiFields.imageURL(info["avatar"])
        return QishuiProfile(
            id: id,
            nickname: QishuiFields.text(info["nickname"] ?? info["name"]) ?? "",
            avatarURL: avatar,
            isVIP: QishuiFields.bool(info["is_vip"] ?? info["vip"])
        )
    }
}
