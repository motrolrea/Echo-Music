#if os(iOS)
import SwiftUI
import WebKit

/// Official-site sign-in for Qishui. The page keeps the captured cookie and
/// checks it with `/luna/pc/me`.
struct QishuiLoginSheet: View {
    @ObservedObject private var session = QishuiSessionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var isReadingCookies = false
    @State private var errorMessage: String?

    private let pageURL = URL(string: "https://www.qishui.com/")!

    var body: some View {
        NavigationStack {
            Group {
                if session.isLoggedIn {
                    accountBody
                } else {
                    loginBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 12)
            .navigationTitle("汽水音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if !session.isLoggedIn {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("登录完成") { readCookiesAndSignIn() }
                            .fontWeight(.semibold)
                            .disabled(isReadingCookies || webView == nil)
                    }
                }
            }
            .task(id: webView != nil) {
                guard !session.isLoggedIn else { return }
                await monitorCookies()
            }
            .alert("登录失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "请完成登录后重试")
            }
        }
    }

    private var accountBody: some View {
        VStack(spacing: 18) {
            Group {
                if let avatar = session.avatarURL, let url = URL(string: avatar) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(Color.pink, in: Circle())
                }
            }
            .padding(.top, 24)

            VStack(spacing: 6) {
                Text(session.profileName ?? "汽水音乐用户")
                    .font(.title3.weight(.semibold))
                Text(session.isVIP ? "会员 · 整曲可用" : "已登录 · 可读取收藏和歌单")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("登录只用于读取汽水账号的歌单、收藏和播放权限。凭据保存在本机钥匙串，不上传服务器。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            Button(role: .destructive) {
                session.signOut()
                dismiss()
            } label: {
                Text("退出汽水音乐")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal, 28)

            Spacer()
        }
    }

    private var loginBody: some View {
        VStack(spacing: 12) {
            Text("在汽水官网登录后会自动保存。收藏、自建歌单和「我喜欢」都会保留，登录后可以播放完整歌曲。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)

            QishuiSiteWebView(webView: $webView, url: pageURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 12)
                .overlay {
                    if isReadingCookies {
                        ProgressView("正在确认登录状态…")
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
        }
    }

    private func readCookiesAndSignIn() {
        guard !isReadingCookies else { return }
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else {
            errorMessage = "登录页面还没有准备好，请稍后重试"
            return
        }
        isReadingCookies = true
        store.getAllCookies { cookies in
            let header = Self.cookieHeader(cookies)
            Task { @MainActor in
                guard Self.isLoggedIn(header) else {
                    isReadingCookies = false
                    errorMessage = "还没有检测到汽水登录状态，请先在网页里完成登录"
                    return
                }
                await signIn(cookie: header)
            }
        }
    }

    @MainActor
    private func monitorCookies() async {
        while !Task.isCancelled, !session.isLoggedIn {
            guard !isReadingCookies,
                  let store = webView?.configuration.websiteDataStore.httpCookieStore else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let header = await Self.cookieHeader(from: store)
            if Self.isLoggedIn(header) {
                await signIn(cookie: header)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    @MainActor
    private func signIn(cookie: String) async {
        isReadingCookies = true
        do {
            _ = try await QishuiAuthService.shared.signIn(cookie: cookie)
            isReadingCookies = false
            ToastCenter.shared.show("汽水音乐登录成功")
            dismiss()
        } catch {
            isReadingCookies = false
            errorMessage = error.localizedDescription
        }
    }

    private static func isLoggedIn(_ header: String) -> Bool {
        QishuiProtocol.sessionID(from: header) != nil
    }

    private static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        var values: [String: String] = [:]
        let ordered = cookies.filter { accepts($0.domain) }.sorted { lhs, rhs in
            let left = lhs.domain.lowercased().contains("qishui.com")
            let right = rhs.domain.lowercased().contains("qishui.com")
            if left != right { return !left && right }
            return lhs.name < rhs.name
        }
        for cookie in ordered {
            values[cookie.name] = cookie.value
        }
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func cookieHeader(from store: WKHTTPCookieStore) async -> String {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookieHeader(cookies))
            }
        }
    }

    private static func accepts(_ domain: String) -> Bool {
        let host = domain.lowercased()
        return host.contains("qishui.com") || host.contains("douyin.com")
    }
}

private struct QishuiSiteWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = QishuiProtocol.browserUserAgent
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        DispatchQueue.main.async { webView = view }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastURL: URL?

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url { lastURL = url }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let url = lastURL ?? webView.url {
                webView.load(URLRequest(url: url))
            } else {
                webView.reload()
            }
        }
    }
}
#endif
