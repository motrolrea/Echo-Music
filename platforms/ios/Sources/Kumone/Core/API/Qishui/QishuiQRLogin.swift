import CryptoKit
import Foundation
import Security
import WebKit

/// 汽水 PC 扫码登录。
///
/// 手机确认之后，未签名的轮询不会下发会话。这里把登录请求放进
/// `api.qishui.com` 的网页里，由官方安全脚本签名后再读取 Cookie。
@MainActor
final class QishuiQRLogin: NSObject, WKNavigationDelegate {
    struct Code {
        let token: String
        let scanURL: URL
        let expiresAt: Date
    }

    enum Status: Equatable {
        case waiting
        case scanned
        case processing
        case expired
        case confirmed(String)
    }

    private var webView: WKWebView?
    private var ready: Task<Void, Error>?
    private var navigation: CheckedContinuation<Void, Error>?
    private var navigationTimeout: Task<Void, Never>?
    private var closed = false
    private var scanned = false
    private var transientFailures = 0
    private var securitySeed: String?
    private var reactInstalled = false
    private let bridge = QishuiVerificationBridge()
    var onVerification: ((Bool) -> Void)?
    private let portrait: String
    private let deviceID: String
    private let installID: String

    override init() {
        let identity = QishuiPassportIdentity.current
        portrait = identity.portrait
        deviceID = identity.deviceID
        installID = identity.installID
        super.init()
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.userContentController.addScriptMessageHandler(
            bridge,
            contentWorld: .page,
            name: QishuiVerificationBridge.name
        )
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        view.customUserAgent = Self.userAgent
        return view
    }

    func attach(_ view: WKWebView) {
        guard webView == nil else { return }
        bridge.web = view
        view.navigationDelegate = self
        webView = view
    }

    func close() {
        closed = true
        ready?.cancel()
        ready = nil
        navigationTimeout?.cancel()
        bridge.isActive = false
        onVerification?(false)
        webView?.evaluateJavaScript("window.codaCancelVerification?.()", completionHandler: nil)
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: QishuiVerificationBridge.name,
            contentWorld: .page
        )
        finishNavigation(.failure(CancellationError()))
    }

    func fetch() async throws -> Code {
        scanned = false
        transientFailures = 0
        let body = try await request(
            path: "/passport/web/get_qrcode/",
            query: [
                "next": "https://api.qishui.com",
                "need_logo": "false",
                "need_short_url": "false",
                "is_new_login": "1",
            ],
            form: nil
        )
        let data = body["data"] as? [String: Any] ?? body
        let token = QishuiFields.text(data["token"]) ?? ""
        let index = QishuiFields.text(data["qrcode_index_url"]) ?? ""
        guard !token.isEmpty, let scanURL = Self.scanURL(indexURL: index) else {
            throw QishuiError(.invalidResponse, "汽水没有返回可扫描的登录二维码")
        }
        return Code(token: token, scanURL: scanURL, expiresAt: Self.expiration(data["expire_time"]))
    }

    func poll(token: String, expiresAt: Date) async throws -> Status {
        try await check(token: token, expiresAt: expiresAt, extra: [:], allowVerification: true)
    }

    private func check(token: String, expiresAt: Date, extra: [String: String], allowVerification: Bool) async throws -> Status {
        guard Date() < expiresAt else { return .expired }
        var form = [
            "token": token,
            "need_logo": "false",
            "need_short_url": "false",
            "is_frontier": "true",
            "is_new_login": "1",
            "next": "https://api.qishui.com",
        ]
        for (key, value) in extra { form[key] = value }
        if !extra.isEmpty { form["isResend"] = "true" }
        let body = try await request(
            path: "/passport/web/check_qrconnect/",
            query: [:],
            form: form
        )
        let data = body["data"] as? [String: Any] ?? body
        if let sessionCookie = QishuiFields.text(data["session_cookie"]) {
            await store(cookieHeader: sessionCookie)
        }
        let error = QishuiFields.int(data["error_code"] ?? body["error_code"] ?? body["status_code"]) ?? 0
        let status = (QishuiFields.text(data["status"] ?? data["qr_status"] ?? body["status"]) ?? "").lowercased()
        if ["expired", "cancelled", "canceled", "timeout", "-1"].contains(status) || [2, 10001].contains(error) {
            return .expired
        }
        scanned = scanned || ["1", "scanned", "scaned", "confirmed", "3", "success", "confirm"].contains(status)
        if error == 2046 {
            guard allowVerification else {
                throw QishuiError(.unavailable, "安全验证未完成，请刷新二维码后重新登录")
            }
            try await verify(data)
            ready = nil
            if let cookie = await accountCookie() { return .confirmed(cookie) }
            let resent = try Self.verificationParameters(data["biz_params"], protectingIdentity: true)
            return try await check(token: token, expiresAt: expiresAt, extra: resent, allowVerification: false)
        }
        if error != 0 {
            if error == 7 || (error == 1049 && scanned) {
                transientFailures += 1
                if transientFailures <= 3 { return .processing }
            }
            throw QishuiError(.unavailable, Self.failureText(code: error, data: data, secret: token))
        }
        transientFailures = 0
        if let cookie = await accountCookie() {
            return .confirmed(cookie)
        }
        switch status {
        case "new", "unscanned", "":
            return .waiting
        case "1", "scanned", "scaned":
            return .scanned
        case "confirmed", "3", "success", "confirm":
            guard let cookie = await accountCookie() else { return .processing }
            return .confirmed(cookie)
        default:
            throw QishuiError(.invalidResponse, "汽水登录状态无法识别，请刷新二维码")
        }
    }

    static func scanURL(indexURL: String) -> URL? {
        guard let source = URLComponents(string: indexURL),
              source.scheme == "https",
              source.host?.lowercased() == "bff-pc.qishui.com",
              let token = source.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return nil }
        var destination = URLComponents()
        destination.scheme = "https"
        destination.host = "bff-pc.qishui.com"
        destination.path = "/light/invoke/scan_login"
        destination.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "os", value: "Windows"),
            URLQueryItem(name: "computer_name", value: "PC"),
        ]
        destination.percentEncodedQuery = destination.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return destination.url
    }

    private func request(path: String, query: [String: String], form: [String: String]?) async throws -> [String: Any] {
        guard let webView else { throw QishuiError(.unavailable, "汽水登录组件还没有准备好") }
        try await prepare()
        var parameters = commonQuery()
        for (key, value) in query { parameters[key] = value }
        let trace = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        parameters["biz_trace_id"] = String(trace.prefix(8))
        var components = URLComponents(string: "https://api.qishui.com" + path)
        components?.queryItems = parameters.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let url = components?.url else {
            throw QishuiError(.invalidResponse, "汽水登录地址无效")
        }
        var headers = [
            "Accept": "application/json, text/javascript",
            "X-Tt-Passport-Verify-Portrait": portrait,
            "X-Tt-Passport-Trace-Id": String(trace.prefix(8)),
            "X-Tt-Trace-Id": "00-\(trace)-\(trace.prefix(16))-01",
        ]
        var csrf = await cookieValue("passport_csrf_token")
        if csrf == nil {
            csrf = await cookieValue("passport_csrf_token_default")
        }
        if let csrf {
            headers["X-Tt-Passport-Csrf-Token"] = csrf
        }
        let bodyText: String?
        if let form {
            var encoded = URLComponents()
            encoded.queryItems = form.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
            bodyText = encoded.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            headers["X-Ss-Stub"] = QishuiProtocol.md5Hex(bodyText ?? "")
        } else {
            bodyText = nil
        }
        let arguments: [String: Any] = [
            "address": url.absoluteString,
            "method": bodyText == nil ? "GET" : "POST",
            "headers": headers,
            "body": bodyText as Any? ?? NSNull(),
        ]
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                Self.sendScript,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw QishuiError(.network, "无法连接汽水登录服务，请检查网络")
        }
        guard !closed else { throw CancellationError() }
        guard let response = value as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水登录返回了无法识别的数据")
        }
        let signatureLength = (response["signatureLength"] as? NSNumber)?.intValue ?? 0
        let tokenLength = (response["msTokenLength"] as? NSNumber)?.intValue ?? 0
        let browserLength = (response["browserInfoLength"] as? NSNumber)?.intValue ?? 0
        let tokenMatches = response["sessionTokenMatches"] as? Bool == true
        guard signatureLength == 44, tokenLength == 120, browserLength > 0, tokenMatches else {
            throw QishuiError(.unavailable, "汽水登录安全校验未就绪，请稍后重试")
        }
        let statusCode = (response["status"] as? NSNumber)?.intValue ?? 0
        guard (200..<300).contains(statusCode) else {
            throw QishuiError(.network, "汽水登录服务返回 HTTP \(statusCode)")
        }
        guard let text = response["text"] as? String,
              let bytes = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水登录返回了无法识别的数据")
        }
        return root
    }

    private func prepare() async throws {
        guard !closed else { throw CancellationError() }
        if let ready {
            try await ready.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self, let webView = self.webView else { throw CancellationError() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.navigation = continuation
                self.navigationTimeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, self.navigation != nil else { return }
                    self.webView?.stopLoading()
                    self.finishNavigation(.failure(QishuiError(.unavailable, "汽水登录安全组件未能加载，请稍后重试")))
                }
                webView.load(URLRequest(url: URL(string: "https://api.qishui.com/")!))
            }
            try Task.checkCancellation()
            let seed = try Self.securitySeed(existing: securitySeed)
            securitySeed = seed
            let loaded = try await webView.callAsyncJavaScript(
                Self.bootstrap,
                arguments: ["securitySeed": seed],
                in: nil,
                contentWorld: .page
            )
            guard loaded as? Bool == true else {
                throw QishuiError(.unavailable, "汽水登录安全组件未能加载，请稍后重试")
            }
        }
        ready = task
        do {
            try await task.value
        } catch {
            ready = nil
            throw error
        }
    }

    private func commonQuery() -> [String: String] {
        [
            "aid": "386088",
            "passport_jssdk_version": "2.4.13",
            "passport_jssdk_type": "normal",
            "is_from_ttaccountsdk": "1",
            "language": "zh",
            "account_sdk_source": "web",
            "p_js_v": "2.4.13",
            "p_js_t": "pro",
            "p_zt": "3.3.5",
            "p_ver": "1.0.29",
            "p_bd": "1.0.0.41",
            "is_from_iesaccountsaas": "1",
            "request_host": "app://resources",
            "is_new_login": "1",
            "device_platform": "PC",
            "version_code": "3.5.2",
            "device_id": deviceID,
            "did": deviceID,
            "install_id": installID,
            "iid": installID,
        ]
    }

    private func cookies() async -> [HTTPCookie] {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return [] }
        return await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func cookieValue(_ name: String) async -> String? {
        await cookies().first { $0.name == name }?.value
    }

    private func store(cookieHeader: String) async {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        let values = QishuiProtocol.cookieDictionary(cookieHeader)
        for (name, value) in values {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: ".qishui.com",
                .path: "/",
                .secure: "TRUE",
            ]
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private func accountCookie() async -> String? {
        var values: [String: String] = [:]
        for cookie in await cookies() {
            let domain = cookie.domain.lowercased()
            guard domain == "qishui.com" || domain.hasSuffix(".qishui.com"),
                  QishuiProtocol.allowedCookieKeys.contains(cookie.name) else { continue }
            values[cookie.name] = cookie.value
        }
        if values["sessionid"] == nil, let alternate = values["sessionid_ss"] {
            values["sessionid"] = alternate
        }
        let header = QishuiProtocol.accountCookie(QishuiProtocol.cookieHeader(values))
        return QishuiProtocol.sessionID(from: header) == nil ? nil : header
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        navigationTimeout?.cancel()
        navigationTimeout = nil
        let continuation = navigation
        navigation = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(QishuiError(.unavailable, "汽水登录安全组件未能加载，请稍后重试")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(QishuiError(.unavailable, "汽水登录安全组件未能加载，请稍后重试")))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false,
           url.absoluteString == "about:blank" || Self.isOfficialHost(url) {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "https", Self.isOfficialHost(url) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    private static func isOfficialHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["qishui.com", "zijieapi.com", "yhgfb-cn-static.com", "bytetos.com", "bytegoofy.com", "bytegecko.com"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func securitySeed(existing: String?) throws -> String {
        if let existing, existing.range(of: #"^[A-Za-z0-9_-]{118}==$"#, options: .regularExpression) != nil {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 88)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw QishuiError(.unavailable, "汽水登录安全组件未能加载，请稍后重试")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    private static func expiration(_ value: Any?) -> Date {
        let expiry = QishuiFields.double(value)
        if expiry > 1_000_000_000 { return Date(timeIntervalSince1970: expiry) }
        return Date().addingTimeInterval(expiry > 0 ? min(expiry, 600) : 180)
    }

    private static func failureText(code: Int, data: [String: Any], secret: String) -> String {
        var detail = QishuiFields.text(data["description"] ?? data["status_msg"]) ?? ""
        if !secret.isEmpty { detail = detail.replacingOccurrences(of: secret, with: "") }
        detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            switch code {
            case 1049: return "汽水没有接受这次登录，请刷新二维码"
            case 7: return "登录请求太频繁，请稍后刷新二维码"
            default: return "汽水拒绝了这次登录，请刷新二维码"
            }
        }
        return String(detail.prefix(120))
    }

    private func verify(_ data: [String: Any]) async throws {
        let decision = try await resolvedDecision(data)
        guard let webView else {
            throw QishuiError(.unavailable, "汽水安全验证组件暂时不可用，请稍后重试")
        }
        onVerification?(true)
        bridge.isActive = true
        defer {
            bridge.isActive = false
            onVerification?(false)
        }
        try await installReact()
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                Self.verificationScript,
                arguments: ["decision": decision, "general": commonQuery()],
                in: nil,
                contentWorld: .page
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if webView.url.flatMap(Self.isOfficialHost) == true,
               webView.url?.host?.lowercased() != "api.qishui.com" {
                return
            }
            throw QishuiError(.unavailable, "汽水安全验证组件暂时不可用，请稍后重试")
        }
        guard let result = value as? [String: Any], result["status"] as? Bool == true else {
            throw QishuiError(.unavailable, "安全验证未完成，请刷新二维码后重新登录")
        }
    }

    private func resolvedDecision(_ data: [String: Any]) async throws -> [String: Any] {
        var payload: Any = data["verify_center_decision_conf"] ?? data["verify_ticket"] ?? data
        if let text = payload as? String,
           let bytes = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            payload = object
        }
        if QishuiFields.text(data["verify_from"]) == "verify_center" {
            var form = try Self.verificationParameters(payload, protectingIdentity: false)
            form["mix_mode"] = "1"
            form["verify_from"] = "verify_center"
            if form["verify_ticket"] == nil, let ticket = QishuiFields.text(data["verify_ticket"]) {
                form["verify_ticket"] = ticket
            }
            if form["verify_scene"] == nil, let scene = QishuiFields.text(data["verify_scene"]) {
                form["verify_scene"] = scene
            }
            let body = try await request(
                path: "/passport/safe/pack_verify_ways_data/",
                query: ["aid": "386088"],
                form: form
            )
            let nested = ((body["data"] as? [String: Any])?["decision"] as? [String: Any]) ?? [:]
            guard !nested.isEmpty else {
                throw QishuiError(.unavailable, "汽水安全验证组件暂时不可用，请稍后重试")
            }
            payload = nested
        }
        guard var decision = payload as? [String: Any],
              let url = Self.verificationURL(decision["url"]) else {
            throw QishuiError(.unavailable, "汽水安全验证组件暂时不可用，请稍后重试")
        }
        decision["url"] = url.absoluteString
        return decision
    }

    private func installReact() async throws {
        guard !reactInstalled, let webView else { return }
        for (name, hash) in Self.reactAssets {
            guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "QishuiVerification"),
                  let data = try? Data(contentsOf: url),
                  Data(SHA256.hash(data: data)).base64EncodedString() == hash,
                  let source = String(data: data, encoding: .utf8) else {
                throw QishuiError(.unavailable, "汽水安全验证组件暂时不可用，请稍后重试")
            }
            _ = try await webView.evaluateJavaScript(source)
        }
        reactInstalled = true
    }

    private static let reactAssets = [
        ("react.production.min", "Ipu/TQ50iCCVZBUsZyNJfxrDk0E2yhaEIz0vqI+kFG8="),
        ("react-dom.production.min", "nbMykgB6tsOFJ7OdVmPpdqMFVk4ZsqWocT6issAPUF0="),
    ]

    private static func verificationURL(_ value: Any?) -> URL? {
        let address: String
        if let text = value as? String {
            address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let object = value as? [String: Any] {
            var host = (object["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if host.lowercased().hasPrefix("https://") { host = String(host.dropFirst(8)) }
            guard !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.contains("?"), !host.contains("#") else { return nil }
            var path = (object["path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.hasPrefix("/") { path = "/" + path }
            address = "https://" + host + path
        } else {
            return nil
        }
        guard !address.isEmpty,
              let url = URL(string: address, relativeTo: URL(string: "https://api.qishui.com/"))?.absoluteURL,
              isOfficialHost(url) else { return nil }
        return url
    }

    private static func verificationParameters(_ value: Any?, protectingIdentity: Bool) throws -> [String: String] {
        let object: [String: Any]
        if let text = value as? String {
            guard let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QishuiError(.unavailable, "汽水安全验证数据无法识别")
            }
            object = parsed
        } else if let parsed = value as? [String: Any] {
            object = parsed
        } else if value == nil {
            return [:]
        } else {
            throw QishuiError(.unavailable, "汽水安全验证数据无法识别")
        }
        var result: [String: String] = [:]
        for (key, raw) in object {
            if protectingIdentity, ["user_id", "mobile", "email", "account"].contains(key) { continue }
            if let nested = raw as? [String: Any] {
                let child = try verificationParameters(nested, protectingIdentity: protectingIdentity)
                for (name, item) in child where result[name] == nil { result[name] = item }
            } else if let text = raw as? String {
                result[key] = text
            } else if let number = raw as? NSNumber {
                result[key] = number.stringValue
            }
        }
        return result
    }

    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) SodaMusic/3.5.2 Chrome/136.0.7103.59 Electron/36.4.0 Safari/537.36"

    private static let bootstrap = #"""
    if (location.origin !== 'https://api.qishui.com') throw new Error('origin');
    if (!/^[A-Za-z0-9_-]{118}==$/.test(securitySeed)) throw new Error('security context');
    localStorage.setItem('xmst', securitySeed);
    localStorage.setItem('xmsty', securitySeed);
    window.codaPassportToken = securitySeed;
    let estimate = {};
    try { estimate = await navigator.storage.estimate(); } catch (_) {}
    let storageSize = 0;
    for (let i = 0; i < localStorage.length; i++) storageSize += (localStorage.getItem(localStorage.key(i)) || '').length;
    let permissions = [];
    try {
        const permission = await navigator.permissions.query({name:'notifications'});
        permissions = [{name:'notifications',state:permission.state}];
    } catch (_) {}
    let graphics = {};
    try {
        const canvas = document.createElement('canvas');
        const gl = canvas.getContext('webgl');
        const extension = gl?.getExtension('WEBGL_debug_renderer_info');
        if (extension) graphics = {vendor:gl.getParameter(extension.UNMASKED_VENDOR_WEBGL),renderer:gl.getParameter(extension.UNMASKED_RENDERER_WEBGL)};
    } catch (_) {}
    const timing = performance.getEntriesByType('navigation')[0] || {};
    const context = {
        hardwareConcurrency:navigator.hardwareConcurrency, webdriver:Boolean(navigator.webdriver),
        chromedriver:typeof window.chromedriver !== 'undefined', shelldriver:typeof window.shelldriver !== 'undefined',
        plugins:navigator.plugins?.length || 0, permissions,
        innerHeight:window.innerHeight, innerWidth:window.innerWidth, outerHeight:window.outerHeight, outerWidth:window.outerWidth,
        stoargeStatus:{
            indexedDB:{idb:typeof indexedDB,open:typeof indexedDB?.open,indexedDB:typeof indexedDB,IDBKeyRange:typeof IDBKeyRange,
                openDatabase:typeof window.openDatabase,isSafari:/Safari/.test(navigator.userAgent) && !/Chrome/.test(navigator.userAgent),hasFetch:typeof fetch === 'function'},
            localStorage:{isSupportLStorage:true,size:storageSize,write:true},
            storageQuotaStatus:{usage:estimate.usage,quota:estimate.quota,isPrivate:Boolean(estimate.quota && estimate.quota < 120000000)}
        },
        webgl:graphics, notificationPermission:window.Notification?.permission || 'none',
        performance:{timeOrigin:performance.timeOrigin,usedJSHeapSize:performance.memory?.usedJSHeapSize || 'unsupport',
            navigationTiming:{decodedBodySize:timing.decodedBodySize,entryType:timing.entryType,initiatorType:timing.initiatorType,
                name:timing.name,renderBlockingStatus:timing.renderBlockingStatus,serverTiming:(timing.serverTiming||[]).map(t=>t.name).join(','),guleStart:'none',guleDuration:'none'}},
        request_host:'resources', request_pathname:'/main.asar/main.html',
        browser:{t:String(Date.now()).split('').reverse().join(''),bit_protocol:'false',bit_helper:false}
    };
    const bytes = new TextEncoder().encode(JSON.stringify(context));
    window.codaPassportSourceInfo = Array.from(bytes,b=>(b^5).toString(16)).join('');
    window.codaPassportSignatureLength = 0;
    const bridgeHosts = new Set(['auth.zijieapi.com','bff-pc.qishui.com']);
    const bridgeTarget = address => {
        try {
            const parsed = new URL(String(address), location.href);
            return parsed.protocol === 'https:' && !parsed.username && !parsed.password && bridgeHosts.has(parsed.hostname) ? parsed.href : null;
        } catch (_) { return null; }
    };
    const bridgeSend = request => {
        const handler = window.webkit?.messageHandlers?.codaVerificationBridge;
        if (!handler) return Promise.reject(new Error('bridge unavailable'));
        return handler.postMessage({...request, userAgent:navigator.userAgent});
    };
    const nativeOpen = XMLHttpRequest.prototype.open;
    const nativeSetHeader = XMLHttpRequest.prototype.setRequestHeader;
    const nativeSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, address) {
        const parsed = new URL(address, location.href);
        if (parsed.origin === location.origin && (parsed.pathname.startsWith('/passport/web/') || parsed.pathname.startsWith('/passport/safe/pack_verify_ways_data'))) {
            window.codaPassportSignatureLength = (parsed.searchParams.get('a_bogus') || '').length;
            window.codaPassportTokenLength = (parsed.searchParams.get('msToken') || '').length;
            window.codaPassportTokenMatches = parsed.searchParams.get('msToken') === window.codaPassportToken;
        }
        this.codaBridgeTarget = bridgeTarget(address);
        this.codaBridgeMethod = String(method || 'GET').toUpperCase();
        this.codaBridgeHeaders = {};
        return nativeOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        if (this.codaBridgeTarget) this.codaBridgeHeaders[String(name)] = String(value);
        return nativeSetHeader.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function(body) {
        if (!this.codaBridgeTarget) return nativeSend.apply(this, arguments);
        const xhr = this;
        const define = (name, value) => { try { Object.defineProperty(xhr, name, {configurable:true, value}); } catch (_) {} };
        const emit = name => { try { xhr.dispatchEvent(new Event(name)); } catch (_) {} };
        bridgeSend({method:xhr.codaBridgeMethod, url:xhr.codaBridgeTarget, headers:xhr.codaBridgeHeaders, body:body == null ? null : String(body)}).then(response => {
            const text = String(response.body || '');
            let parsed = text;
            if (xhr.responseType === 'json') { try { parsed = JSON.parse(text); } catch (_) { parsed = null; } }
            const headers = String(response.headers || '');
            define('status', Number(response.status) || 0);
            define('statusText', '');
            define('responseText', text);
            define('response', parsed);
            define('responseURL', String(response.url || xhr.codaBridgeTarget));
            define('readyState', 4);
            xhr.getAllResponseHeaders = () => headers;
            xhr.getResponseHeader = name => {
                const wanted = String(name || '').toLowerCase();
                const line = headers.split(/\r?\n/).find(item => item.toLowerCase().startsWith(wanted + ':'));
                return line ? line.slice(line.indexOf(':') + 1).trim() : null;
            };
            emit('readystatechange'); emit('load'); emit('loadend');
        }).catch(() => {
            define('status', 0);
            define('readyState', 4);
            emit('readystatechange'); emit('error'); emit('loadend');
        });
    };
    const nativeFetch = window.fetch;
    window.fetch = function(input, init) {
        const address = typeof input === 'string' || input instanceof URL ? String(input) : input?.url;
        const target = bridgeTarget(address);
        if (!target) return nativeFetch.apply(this, arguments);
        const request = new Request(input, init);
        const method = request.method.toUpperCase();
        return (method === 'GET' || method === 'HEAD' ? Promise.resolve(null) : request.text()).then(body =>
            bridgeSend({method, url:target, headers:Object.fromEntries(request.headers.entries()), body})
        ).then(response => {
            const status = Number(response.status) || 0;
            if (status < 200 || status > 599) throw new TypeError('Failed to fetch');
            const headers = new Headers();
            for (const line of String(response.headers || '').split(/\r?\n/)) {
                const index = line.indexOf(':');
                if (index > 0) { try { headers.append(line.slice(0, index).trim(), line.slice(index + 1).trim()); } catch (_) {} }
            }
            const empty = [101, 204, 205, 304].includes(status) || method === 'HEAD';
            return new Response(empty ? null : String(response.body || ''), {status, headers});
        }, () => { throw new TypeError('Failed to fetch'); });
    };
    await new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.charset = 'utf-8';
        const timeout = setTimeout(() => reject(new Error('sdk timeout')), 15000);
        script.src = 'https://lf-headquarters-speed.yhgfb-cn-static.com/obj/rc-client-security/web/stable/1.0.0.41/bdms.js';
        script.onload = () => { clearTimeout(timeout); resolve(); };
        script.onerror = () => { clearTimeout(timeout); reject(new Error('sdk unavailable')); };
        document.head.appendChild(script);
    });
    if (typeof window.bdms?.init !== 'function') throw new Error('sdk unavailable');
    await window.bdms.init({aid: 386088, paths: ['/passport']});
    return true;
    """#

    private static let sendScript = #"""
    const destination = new URL(address);
    if (destination.origin !== location.origin || !(destination.pathname.startsWith('/passport/web/') || destination.pathname.startsWith('/passport/safe/pack_verify_ways_data'))) throw new Error('destination');
    if (!window.codaPassportToken || !window.codaPassportSourceInfo) throw new Error('security context');
    destination.searchParams.set('msToken',window.codaPassportToken);
    destination.searchParams.set('account_sdk_source_info',window.codaPassportSourceInfo);
    window.codaPassportSignatureLength = 0;
    window.codaPassportTokenLength = 0;
    window.codaPassportTokenMatches = false;
    return await new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open(method, destination.href, true);
        xhr.withCredentials = true;
        xhr.timeout = 20000;
        for (const [name, value] of Object.entries(headers)) xhr.setRequestHeader(name, String(value));
        xhr.onload = () => resolve({status:xhr.status,text:xhr.responseText,signatureLength:window.codaPassportSignatureLength,
            msTokenLength:window.codaPassportTokenLength,browserInfoLength:window.codaPassportSourceInfo.length,sessionTokenMatches:window.codaPassportTokenMatches});
        xhr.onerror = () => reject(new Error('network'));
        xhr.ontimeout = () => reject(new Error('timeout'));
        xhr.send(body === null ? null : body);
    });
    """#

    /// 官方验证页和扫码请求共用同一个网页、同一份 Cookie。
    /// 滑块或验证码只能由用户完成。
    private static let verificationScript = #"""
    window.codaVerificationCancelled=false;
    const setMeta = (selector, create) => { document.head.querySelectorAll(selector).forEach(n=>n.remove()); document.head.prepend(create()); };
    setMeta('meta[name="viewport"]', () => Object.assign(document.createElement('meta'), {name:'viewport', content:'width=device-width,initial-scale=1,viewport-fit=cover'}));
    setMeta('meta[charset]', () => { const m = document.createElement('meta'); m.setAttribute('charset','utf-8'); return m; });
    if (!document.getElementById('coda-verify-style')) {
        const style = document.createElement('style');
        style.id = 'coda-verify-style';
        style.textContent = 'html,body{margin:0;padding:0;width:100%;height:100%;background:#fff;}';
        document.head.appendChild(style);
    }
    const resource = new URL(decision.url, location.href);
    const allowed = ['qishui.com','zijieapi.com','yhgfb-cn-static.com','bytetos.com','bytegoofy.com','bytegecko.com'];
    if (resource.protocol !== 'https:' || !allowed.some(h=>resource.hostname===h || resource.hostname.endsWith('.'+h))) throw new Error('verification origin');
    const load = address => new Promise((resolve,reject)=>{
        const script = document.createElement('script');
        script.charset='utf-8';
        script.crossOrigin='anonymous';
        script.src=address;
        const timeout=setTimeout(()=>reject(new Error('component timeout')),15000);
        script.onload=()=>{clearTimeout(timeout);resolve();};
        script.onerror=()=>{clearTimeout(timeout);reject(new Error('component unavailable'));};
        document.head.appendChild(script);
    });
    if (!window.React || !window.ReactDOM) throw new Error('react unavailable');
    window.ucSecondVerifyReact=window.React;
    window.ucSecondVerifyReactDom=window.ReactDOM;
    let event={};
    if (typeof decision.event_params==='string') {try{event=JSON.parse(decision.event_params);}catch(_){}}
    else if (decision.event_params && typeof decision.event_params==='object') event=decision.event_params;
    resource.searchParams.set('aid','386088');
    resource.searchParams.set('verify_reason',String(event.verify_reason||''));
    resource.searchParams.set('verify_scene',String(event.verify_scene||''));
    window.$$account_verify_portrait_id=String(decision.verify_portrait_id||'');
    if (typeof window.ucWebSecondVerify!=='function') await load(resource.href);
    if (typeof window.ucWebSecondVerify!=='function') throw new Error('verification unavailable');
    if (window.codaVerificationCancelled) return {status:false};
    document.body.replaceChildren();
    return await new Promise(resolve=>{
        let finished=false;
        const timer=setTimeout(()=>finish({status:false}),600000);
        const finish=result=>{
            if(finished)return;
            finished=true;clearTimeout(timer);window.codaCancelVerification=null;
            resolve({status:result?.status===true});
        };
        window.codaCancelVerification=()=>finish({status:false});
        window.ucWebSecondVerify({
            ...decision,aid:386088,isNewVerifyUI:true,event_params:event,generalParams:general,
            verifyFinishCallback:finish,
            newSecondVerifyWebOptions:{host:'https://api.qishui.com',verifyAppName:'汽水音乐移动端'},
            newSecondVerificationCall:{reportAppLog:()=>{}},
            fun:decision.verify_from==='verify_center'?'verify_center':'verify',uc_account_verify_version:'1.0.29',
            monitorTime:{startTime:Date.now(),fetchEndTime:Date.now(),scriptLoadStartTime:0,scriptLoadEndTime:Date.now(),renderStartTime:Date.now()}
        });
    });
    """#
}

private enum QishuiPassportIdentity {
    struct Value {
        let deviceID: String
        let installID: String
        let portrait: String
    }

    static var current: Value {
        Value(
            deviceID: digits(key: "qishui.passport.deviceID", count: 16),
            installID: digits(key: "qishui.passport.installID", count: 15),
            portrait: portrait()
        )
    }

    private static func digits(key: String, count: Int) -> String {
        if let stored = UserDefaults.standard.string(forKey: key),
           stored.count == count,
           stored.allSatisfy(\.isNumber),
           stored.first != "0" {
            return stored
        }
        var value = ""
        for index in 0..<count {
            let digit = index == 0 ? Int.random(in: 1...9) : Int.random(in: 0...9)
            value.append(String(digit))
        }
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static func portrait() -> String {
        let key = "qishui.passport.portraitID"
        if let stored = UserDefaults.standard.string(forKey: key),
           stored.hasSuffix(".login"),
           UUID(uuidString: String(stored.dropLast(6))) != nil {
            return stored
        }
        let value = UUID().uuidString.lowercased() + ".login"
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

/// 验证组件会请求另外两个官方域名。页面自己发会被跨域拦住，
/// 所以由原生请求代发，并继续使用这一次扫码的 Cookie。
@MainActor
final class QishuiVerificationBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "codaVerificationBridge"
    weak var web: WKWebView?
    var isActive = false

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard isActive, let web, message.webView === web, message.frameInfo.isMainFrame,
              origin.`protocol` == "https", origin.host == "api.qishui.com",
              origin.port == 0 || origin.port == 443,
              let request = Self.request(from: message.body) else {
            return (nil, "rejected")
        }
        do {
            return (try await Self.perform(request, store: web.configuration.websiteDataStore.httpCookieStore), nil)
        } catch {
            return (nil, "network")
        }
    }

    private static func request(from body: Any) -> URLRequest? {
        guard let object = body as? [String: Any],
              let address = object["url"] as? String,
              let url = URL(string: address),
              isBridgeable(url) else { return nil }
        let method = (object["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "HEAD"].contains(method) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let blocked: Set<String> = ["cookie", "cookie2", "host", "origin", "referer", "content-length", "connection", "user-agent"]
        for (name, value) in object["headers"] as? [String: Any] ?? [:]
        where !blocked.contains(name.lowercased()) && !name.lowercased().hasPrefix("sec-") {
            request.setValue(String(describing: value), forHTTPHeaderField: name)
        }
        if method == "POST", let text = object["body"] as? String { request.httpBody = Data(text.utf8) }
        if let agent = object["userAgent"] as? String, !agent.isEmpty {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("https://api.qishui.com", forHTTPHeaderField: "Origin")
        request.setValue("https://api.qishui.com/", forHTTPHeaderField: "Referer")
        return request
    }

    private static func isBridgeable(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return ["auth.zijieapi.com", "bff-pc.qishui.com"].contains(host)
    }

    private static func matching(_ cookies: [HTTPCookie], url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let domainMatches = host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare))
            let expired = cookie.expiresDate.map { $0 < Date() } ?? false
            return domainMatches && path.hasPrefix(cookie.path) && !expired
        }
    }

    private static func perform(_ request: URLRequest, store: WKHTTPCookieStore) async throws -> [String: Any] {
        guard let url = request.url else { throw URLError(.badURL) }
        var request = request
        let jar = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let header = matching(jar, url: url).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !header.isEmpty { request.setValue(header, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request, delegate: QishuiNoRedirect())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.url ?? url) {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
        let headers = fields
            .filter { $0.key.lowercased() != "set-cookie" }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        return [
            "status": http.statusCode,
            "body": String(decoding: data, as: UTF8.self),
            "headers": headers,
            "url": (http.url ?? url).absoluteString,
        ]
    }
}

private final class QishuiNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
