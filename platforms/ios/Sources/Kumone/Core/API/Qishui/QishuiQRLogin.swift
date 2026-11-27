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

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        view.customUserAgent = userAgent
        return view
    }

    func attach(_ view: WKWebView) {
        guard webView == nil else { return }
        view.navigationDelegate = self
        webView = view
    }

    func close() {
        closed = true
        ready?.cancel()
        ready = nil
        navigationTimeout?.cancel()
        webView?.stopLoading()
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
        guard Date() < expiresAt else { return .expired }
        let body = try await request(
            path: "/passport/web/check_qrconnect/",
            query: [:],
            form: [
                "token": token,
                "need_logo": "false",
                "need_short_url": "false",
                "is_frontier": "true",
                "is_new_login": "1",
                "next": "https://api.qishui.com",
            ]
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
            throw QishuiError(.unavailable, "汽水要求额外安全验证，请刷新二维码后再试")
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
            let seed = try Self.securitySeed()
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
        if url.scheme == "https", url.host?.lowercased() == "api.qishui.com" {
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

    private static func securitySeed() throws -> String {
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
    const nativeOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, address, ...rest) {
        try {
            const destination = new URL(address, location.href);
            if (destination.origin === location.origin && (destination.pathname.startsWith('/passport/web/') || destination.pathname.startsWith('/passport/safe/pack_verify_ways_data'))) {
                const signature = destination.searchParams.get('a_bogus') || '';
                const token = destination.searchParams.get('msToken') || '';
                window.codaPassportSignatureLength = signature.length;
                window.codaPassportTokenLength = token.length;
                window.codaPassportTokenMatches = token === window.codaPassportToken;
            }
        } catch (_) {}
        return nativeOpen.call(this, method, address, ...rest);
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
