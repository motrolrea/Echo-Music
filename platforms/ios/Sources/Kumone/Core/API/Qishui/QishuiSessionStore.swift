import Foundation
import Combine

/// Persists the Qishui PC cookie. Playback and catalogue reads only receive
/// the filtered account cookie, never the whole website data store.
@MainActor
final class QishuiSessionStore: ObservableObject {
    static let shared = QishuiSessionStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var avatarURL: String?
    @Published private(set) var isVIP = false
    @Published private(set) var sessionRevision = 0

    private(set) var credential: QishuiCredential?

    let deviceId = QishuiDeviceIdentity.current
    private let keychainService = "com.moumusic.qishui.session"

    private init() {
        restore()
        if credential != nil {
            isLoggedIn = true
            Task { @MainActor [weak self] in
                await self?.refreshProfile()
            }
        }
    }

    func apply(credential: QishuiCredential, profile: QishuiProfile) {
        var updated = credential
        updated.userId = profile.id
        updated.nickname = profile.nickname
        updated.avatarURL = profile.avatarURL
        updated.isVIP = profile.isVIP
        self.credential = updated
        profileName = profile.nickname.isEmpty ? "汽水音乐用户" : profile.nickname
        avatarURL = profile.avatarURL
        isVIP = profile.isVIP
        isLoggedIn = true
        persist(updated)
        sessionRevision &+= 1
    }

    func refreshProfile() async {
        guard credential != nil else { return }
        do {
            _ = try await QishuiAuthService.shared.refresh()
        } catch let error as QishuiError where error.kind == .authRequired {
            signOut()
        } catch {
            // A network failure should not drop a still-valid cookie.
        }
    }

    func signOut() {
        credential = nil
        profileName = nil
        avatarURL = nil
        isVIP = false
        isLoggedIn = false
        ProviderSessionSupport.deleteCookie(service: keychainService)
        sessionRevision &+= 1
    }

    private func restore() {
        guard let raw = ProviderSessionSupport.readCookie(service: keychainService),
              let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(QishuiCredential.self, from: data),
              stored.isValid else {
            return
        }
        credential = stored
        let name = stored.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        profileName = name.isEmpty ? nil : name
        avatarURL = stored.avatarURL
        isVIP = stored.isVIP
    }

    private func persist(_ credential: QishuiCredential) {
        guard let data = try? JSONEncoder().encode(credential),
              let json = String(data: data, encoding: .utf8) else { return }
        try? ProviderSessionSupport.writeCookie(json, service: keychainService)
    }
}
