import Foundation
import Combine

/// 咪咕音乐账号会话。登录走官方网页，只保存登录后的 Cookie；
/// 曲库与播放仍使用公开接口，账号歌单暂不同步。
@MainActor
final class MiguSessionStore: ObservableObject {
    static let shared = MiguSessionStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var sessionRevision = 0

    private(set) var cookie: String?

    private let keychainService = "com.moumusic.migu.session"

    private init() {
        guard let raw = ProviderSessionSupport.readCookie(service: keychainService),
              ProviderSessionSupport.looksLikeCookie(raw) else { return }
        cookie = raw
        profileName = Self.nickname(from: raw)
        isLoggedIn = true
    }

    func signIn(cookie raw: String) throws {
        let normalized = ProviderSessionSupport.normalizedCookie(raw)
        guard ProviderSessionSupport.looksLikeCookie(normalized) else {
            throw MiguSessionError.invalidCookie
        }
        try ProviderSessionSupport.writeCookie(normalized, service: keychainService)
        cookie = normalized
        profileName = Self.nickname(from: normalized)
        isLoggedIn = true
        sessionRevision &+= 1
    }

    func signOut() {
        cookie = nil
        profileName = nil
        isLoggedIn = false
        ProviderSessionSupport.deleteCookie(service: keychainService)
        sessionRevision &+= 1
    }

    /// 部分网页登录会把昵称写入 Cookie（URL 编码的 UTF-8）。
    private static func nickname(from cookie: String) -> String? {
        for item in cookie.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2 else { continue }
            let key = pair[0].lowercased()
            guard key == "nickname" || key == "nick" || key == "username" || key == "migu_nickname" else {
                continue
            }
            if let decoded = pair[1].removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
        }
        return nil
    }
}

enum MiguSessionError: LocalizedError {
    case invalidCookie

    var errorDescription: String? {
        "没有读取到有效的咪咕登录信息，请完成登录后再点“登录完成”"
    }
}
