import Foundation

/// 汽水 PC 扫码登录。
///
/// 官网首页只是下载页，没有登录入口。这里直接走官方
/// `/passport/web/get_qrcode/`，二维码内容用手机能识别的
/// `scan_login` 地址，而不是接口附带的那张已失效网页图。
final class QishuiQRLogin {
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

    private let session: URLSession
    private let storage = HTTPCookieStorage()
    private let portrait: String
    private let deviceID: String
    private let installID: String
    private var scanned = false
    private var transientFailures = 0

    init() {
        storage.cookieAcceptPolicy = .always
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        let identity = QishuiPassportIdentity.current
        portrait = identity.portrait
        deviceID = identity.deviceID
        installID = identity.installID
    }

    func fetch() async throws -> Code {
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
            store(cookieHeader: sessionCookie)
        }
        let error = QishuiFields.int(data["error_code"] ?? body["error_code"] ?? body["status_code"]) ?? 0
        let status = (QishuiFields.text(data["status"] ?? data["qr_status"] ?? body["status"]) ?? "").lowercased()
        if ["expired", "cancelled", "canceled", "timeout", "-1"].contains(status) || [2, 10001].contains(error) {
            return .expired
        }
        let seenScan = ["1", "scanned", "scaned", "confirmed", "3", "success", "confirm"].contains(status)
        scanned = scanned || seenScan
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
        switch status {
        case "new", "unscanned", "":
            return .waiting
        case "1", "scanned", "scaned":
            return .scanned
        case "confirmed", "3", "success", "confirm":
            guard let cookie = accountCookie() else { return .processing }
            return .confirmed(cookie)
        default:
            throw QishuiError(.invalidResponse, "汽水登录状态无法识别，请刷新二维码")
        }
    }

    /// 接口返回的图片指向已下线的 sdk-next 页。手机扫描认的是这条地址。
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
        var parameters = commonQuery()
        for (key, value) in query { parameters[key] = value }
        var components = URLComponents(string: QishuiProtocol.pcHost + path)
        components?.queryItems = parameters.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let url = components?.url else {
            throw QishuiError(.invalidResponse, "汽水登录地址无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.setValue("app://resources/", forHTTPHeaderField: "Referer")
        request.setValue(portrait, forHTTPHeaderField: "X-Tt-Passport-Verify-Portrait")
        if let csrf = cookieValue("passport_csrf_token") ?? cookieValue("passport_csrf_token_default") {
            request.setValue(csrf, forHTTPHeaderField: "X-Tt-Passport-Csrf-Token")
        }
        if let form {
            var encoded = URLComponents()
            encoded.queryItems = form.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
            let text = encoded.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
            request.httpMethod = "POST"
            request.httpBody = text.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(QishuiProtocol.md5Hex(text), forHTTPHeaderField: "X-Ss-Stub")
        } else {
            request.httpMethod = "GET"
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QishuiError(.network, "无法连接汽水登录服务，请检查网络")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QishuiError(.network, "汽水登录返回了异常响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QishuiError(.network, "汽水登录服务返回 HTTP \(http.statusCode)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水登录返回了无法识别的数据")
        }
        return root
    }

    private func commonQuery() -> [String: String] {
        [
            "aid": "386088",
            "passport_jssdk_version": "2.4.13",
            "passport_jssdk_type": "normal",
            "is_from_ttaccountsdk": "1",
            "language": "zh",
            "account_sdk_source": "web",
            "device_platform": "PC",
            "version_code": "3.5.2",
            "device_id": deviceID,
            "did": deviceID,
            "install_id": installID,
            "iid": installID,
            "is_new_login": "1",
        ]
    }

    private func cookieValue(_ name: String) -> String? {
        storage.cookies?.first { $0.name == name }?.value
    }

    private func store(cookieHeader: String) {
        let values = QishuiProtocol.cookieDictionary(cookieHeader)
        for (name, value) in values {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: ".qishui.com",
                .path: "/",
                .secure: "TRUE",
            ]
            if let cookie = HTTPCookie(properties: properties) {
                storage.setCookie(cookie)
            }
        }
    }

    private func accountCookie() -> String? {
        var values: [String: String] = [:]
        for cookie in storage.cookies ?? [] where QishuiProtocol.allowedCookieKeys.contains(cookie.name) {
            values[cookie.name] = cookie.value
        }
        if values["sessionid"] == nil, let alternate = values["sessionid_ss"] {
            values["sessionid"] = alternate
        }
        let header = QishuiProtocol.accountCookie(QishuiProtocol.cookieHeader(values))
        return QishuiProtocol.sessionID(from: header) == nil ? nil : header
    }

    private static func expiration(_ value: Any?) -> Date {
        let expiry = QishuiFields.double(value)
        if expiry > 1_000_000_000 { return Date(timeIntervalSince1970: expiry) }
        return Date().addingTimeInterval(expiry > 0 ? min(expiry, 600) : 180)
    }

    private static func failureText(code: Int, data: [String: Any], secret: String) -> String {
        var detail = QishuiFields.text(data["description"] ?? data["status_msg"]) ?? ""
        if !secret.isEmpty {
            detail = detail.replacingOccurrences(of: secret, with: "")
        }
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
