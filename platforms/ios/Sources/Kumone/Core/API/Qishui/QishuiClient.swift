import Foundation

/// HTTP layer for the Qishui PC protocol.
///
/// Account reads send the official-site cookie on an ordinary request.
/// Search, playback and scene feeds also ask the signer for `ms_token`
/// and `a_bogus`.
final class QishuiClient {
    static let shared = QishuiClient()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    func get(path: String, extras: [String: String] = [:],
             cookie: String? = nil) async throws -> [String: Any] {
        guard let url = QishuiProtocol.url(path: path, extras: extras) else {
            throw QishuiError(.invalidResponse, "汽水接口地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCommonHeaders(&request, cookie: cookie)
        let (body, _) = try await send(request)
        return try checked(body)
    }

    func post(path: String, extras: [String: String] = [:],
              body: [String: Any] = [:], cookie: String? = nil) async throws -> [String: Any] {
        guard let url = QishuiProtocol.url(path: path, extras: extras) else {
            throw QishuiError(.invalidResponse, "汽水接口地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyCommonHeaders(&request, cookie: cookie)
        request.httpBody = try jsonData(body)
        let (responseBody, _) = try await send(request)
        return try checked(responseBody)
    }

    func signedGet(path: String, extras: [String: String] = [:],
                   cookie: String? = nil) async throws -> [String: Any] {
        try await signed(method: "GET", path: path, extras: extras, body: nil, cookie: cookie)
    }

    func signedPost(path: String, extras: [String: String] = [:],
                    body: [String: Any] = [:], cookie: String? = nil) async throws -> [String: Any] {
        try await signed(method: "POST", path: path, extras: extras, body: body, cookie: cookie)
    }

    /// Unauthenticated GET used while resolving a play-info URL.
    func raw(_ url: URL) async throws -> (Any, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(QishuiProtocol.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    // MARK: - Signing

    private func signed(method: String, path: String, extras: [String: String],
                        body: [String: Any]?, cookie: String?) async throws -> [String: Any] {
        guard let unsigned = QishuiProtocol.url(path: path, extras: extras) else {
            throw QishuiError(.invalidResponse, "汽水接口地址无效")
        }
        let payload = try body.map(jsonData) ?? Data()
        var headers = signHeaders(cookie: cookie, stub: QishuiProtocol.md5Hex(payload))
        let signed = try await sign(url: unsigned.absoluteString, method: method,
                                    body: body ?? [:], headers: headers)
        guard var components = URLComponents(url: unsigned, resolvingAgainstBaseURL: false) else {
            throw QishuiError(.invalidResponse, "汽水接口地址无效")
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: signed.queryItems)
        components.queryItems = items
        guard let url = components.url else {
            throw QishuiError(.invalidResponse, "汽水签名地址无效")
        }
        for (key, value) in signed.headers { headers[key] = value }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if method != "GET" { request.httpBody = payload }
        let (responseBody, _) = try await send(request)
        return try checked(responseBody)
    }

    private struct SignedRequest {
        let headers: [String: String]
        let queryItems: [URLQueryItem]
    }

    private func sign(url: String, method: String, body: [String: Any],
                      headers: [String: String]) async throws -> SignedRequest {
        var request = URLRequest(url: QishuiProtocol.signerURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(QishuiProtocol.signerToken)", forHTTPHeaderField: "Authorization")
        let payload: [String: Any] = [
            "url": url,
            "method": method,
            "body": body,
            "headers": headers,
            "ts_ms": Int(Date().timeIntervalSince1970 * 1000),
        ]
        request.httpBody = try jsonData(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QishuiError(.unavailable, "汽水签名服务不可用")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QishuiError(.unavailable, "汽水签名服务没有返回可用结果")
        }
        if let ok = root["ok"] as? Bool, !ok {
            throw QishuiError(.unavailable, "汽水签名服务拒绝了这个请求")
        }
        var items: [URLQueryItem] = []
        if let token = QishuiFields.text(root["ms_token"]), !token.isEmpty {
            items.append(URLQueryItem(name: "ms_token", value: token))
        }
        if let bogus = QishuiFields.text(root["a_bogus"]), !bogus.isEmpty {
            items.append(URLQueryItem(name: "a_bogus", value: bogus))
        }
        var extra: [String: String] = [:]
        if let returned = root["headers"] as? [String: Any] {
            for (key, value) in returned {
                if let text = QishuiFields.text(value), !text.isEmpty { extra[key] = text }
            }
        }
        return SignedRequest(headers: extra, queryItems: items)
    }

    // MARK: - Response

    private func checked(_ body: Any) throws -> [String: Any] {
        guard let root = body as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水返回结构无法识别")
        }
        if let code = businessCode(root) {
            if QishuiProtocol.authErrorCodes.contains(code) {
                throw QishuiError(.authRequired, "汽水登录已失效，请重新登录", upstreamCode: String(code))
            }
            throw QishuiError(.unavailable, "汽水拒绝了这个请求", upstreamCode: String(code))
        }
        return root
    }

    private func businessCode(_ root: [String: Any]) -> Int? {
        for key in ["status_code", "error_code", "err_no"] {
            if let code = QishuiFields.int(root[key]), code != 0 { return code }
        }
        if let data = root["data"] as? [String: Any] {
            for key in ["status_code", "error_code", "err_no"] {
                if let code = QishuiFields.int(data[key]), code != 0 { return code }
            }
        }
        return nil
    }

    private func send(_ request: URLRequest) async throws -> (Any, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QishuiError(.network, "无法连接汽水服务，请检查网络")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QishuiError(.network, "汽水返回了异常响应")
        }
        if http.statusCode == 429 {
            throw QishuiError(.unavailable, "汽水请求过于频繁，请稍后再试")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw QishuiError(.authRequired, "汽水登录已失效，请重新登录")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QishuiError(.network, "汽水服务返回 HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw QishuiError(.invalidResponse, "汽水返回了空响应")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QishuiError(.invalidResponse, "汽水返回的内容不是 JSON")
        }
        return (object, http)
    }

    private func applyCommonHeaders(_ request: inout URLRequest, cookie: String?) {
        request.timeoutInterval = 20
        request.setValue(QishuiProtocol.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.httpMethod != "GET" {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if let header = cookieHeader(cookie) {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
    }

    private func signHeaders(cookie: String?, stub: String) -> [String: String] {
        var headers = [
            "User-Agent": QishuiProtocol.userAgent,
            "Accept": "application/json",
            "Content-Type": "application/json; charset=utf-8",
            "x-luna-background-type": "foreground",
            "x-luna-is-background-req": "0",
            "x-luna-is-local-user": "1",
            "X-SS-STUB": stub,
        ]
        if let header = cookieHeader(cookie) { headers["cookie"] = header }
        return headers
    }

    private func cookieHeader(_ cookie: String?) -> String? {
        guard let cookie else { return nil }
        let header = QishuiProtocol.accountCookie(cookie)
        return header.isEmpty ? nil : header
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw QishuiError(.invalidResponse, "汽水请求无法序列化")
        }
        do {
            return try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw QishuiError(.invalidResponse, "汽水请求无法序列化")
        }
    }
}
