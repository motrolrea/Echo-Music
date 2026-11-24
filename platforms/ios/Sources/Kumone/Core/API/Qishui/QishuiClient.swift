import Foundation

/// HTTP layer for the Qishui car protocol.
///
/// Public reads use a short-lived client token; account reads and writes use
/// the ticket-guard headers produced by `QishuiProtocol`.
final class QishuiClient {
    static let shared = QishuiClient()

    private let session: URLSession
    private let lock = NSLock()
    private var cachedToken: String?
    private var inflightToken: Task<String, Error>?
    private var tokenRevision = 0

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    // MARK: - Public entry points

    func platform(path: String, body: [String: Any] = [:],
                  credential: QishuiCredential? = nil) async throws -> [String: Any] {
        if let credential {
            let headers = try QishuiProtocol.guardHeaders(credential, path: path)
            return try await platformRequest(path: path, body: body, headers: headers,
                                             deviceId: credential.deviceId, userId: credential.userId)
        }

        var forceRefresh = false
        for attempt in 0..<2 {
            let token = try await clientToken(forceRefresh: forceRefresh)
            do {
                return try await platformRequest(path: path, body: body,
                                                 headers: ["access-token": token],
                                                 deviceId: QishuiDeviceIdentity.current, userId: "")
            } catch let error as QishuiError {
                if error.isTokenExpired, attempt == 0,
                   QishuiProtocol.retryableReads.contains(path) {
                    invalidate(token: token)
                    forceRefresh = true
                    continue
                }
                throw error
            }
        }
        throw QishuiError(.unavailable, "汽水服务暂时不可用")
    }

    func command(path: String, body: [String: Any] = [:],
                 credential: QishuiCredential) async throws -> [String: Any] {
        let headers = try QishuiProtocol.guardHeaders(credential, path: path)
        return try await platformRequest(path: path, body: body, headers: headers,
                                         deviceId: credential.deviceId, userId: credential.userId)
    }

    /// Unauthenticated request used by the login flow (QR code, access code,
    /// ticket exchange). Returns the decoded body and the raw response so the
    /// caller can read `bd-ticket-guard-server-data`.
    func raw(_ url: URL, method: String = "GET",
             headers: [String: String] = [:], body: Data? = nil) async throws -> (Any, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(QishuiProtocol.userAgent, forHTTPHeaderField: "user-agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
            request.httpBody = body
        }
        return try await send(request)
    }

    /// Same as `raw`, but tolerates an empty body. Used by the ticket exchange,
    /// where the credential travels in a response header.
    func rawResponse(_ url: URL, method: String = "GET",
                     headers: [String: String] = [:], body: Data? = nil) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(QishuiProtocol.userAgent, forHTTPHeaderField: "user-agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
            request.httpBody = body
        }
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw QishuiError(.network, "无法连接汽水服务，请检查网络")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QishuiError(.network, "汽水返回了异常响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw QishuiError(.authRequired, "汽水授权已失效，请重新扫码")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QishuiError(.network, "汽水授权服务返回 HTTP \(http.statusCode)")
        }
        return http
    }

    func clientToken(forceRefresh: Bool = false) async throws -> String {
        lock.lock()
        if !forceRefresh, let cachedToken {
            lock.unlock()
            return cachedToken
        }
        if let inflightToken {
            lock.unlock()
            return try await inflightToken.value
        }
        let revision = tokenRevision
        let task = Task<String, Error> { try await self.fetchClientToken() }
        inflightToken = task
        lock.unlock()

        do {
            let token = try await task.value
            lock.lock()
            if tokenRevision == revision { cachedToken = token }
            inflightToken = nil
            lock.unlock()
            return token
        } catch {
            lock.lock()
            inflightToken = nil
            lock.unlock()
            throw error
        }
    }

    private func invalidate(token: String) {
        lock.lock()
        if cachedToken == token { cachedToken = nil }
        tokenRevision &+= 1
        lock.unlock()
    }

    // MARK: - Requests

    private func fetchClientToken() async throws -> String {
        let query = QishuiProtocol.query(deviceId: QishuiDeviceIdentity.current,
                                         extras: ["trigger_type": "cold_start"])
        guard let url = URL(string: "https://open.qishui.com\(QishuiProtocol.prefix)/client/token/get/?\(query)") else {
            throw QishuiError(.invalidResponse, "汽水地址无效")
        }
        let (body, _) = try await raw(url)
        guard let root = body as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水令牌响应无法识别")
        }
        let data = root["data"] as? [String: Any] ?? root
        guard let token = data["client_token"] as? String, !token.isEmpty else {
            throw QishuiError(.invalidResponse, "汽水没有返回客户端令牌")
        }
        return token
    }

    private func platformRequest(path: String, body: [String: Any],
                                 headers: [String: String], deviceId: String,
                                 userId: String) async throws -> [String: Any] {
        let query = QishuiProtocol.query(deviceId: deviceId)
        guard let url = URL(string: "https://open.douyin.com\(QishuiProtocol.prefix)\(path)?\(query)") else {
            throw QishuiError(.invalidResponse, "汽水接口地址无效")
        }
        var payload = body
        var common = payload["common_params"] as? [String: Any] ?? [:]
        if !userId.isEmpty { common["user_id"] = userId }
        payload["common_params"] = common

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(QishuiProtocol.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw QishuiError(.invalidResponse, "汽水请求无法序列化")
        }
        let (bodyJSON, _) = try await send(request)
        return try checkedData(bodyJSON)
    }

    private func checkedData(_ body: Any) throws -> [String: Any] {
        guard let root = body as? [String: Any] else {
            throw QishuiError(.invalidResponse, "汽水返回结构无法识别")
        }
        let dataObject = root["data"] as? [String: Any]
        let rawCode: Any? = root["err_no"] ?? dataObject?["error_code"]
        let code = QishuiFields.text(rawCode)
        if let code, code != "0" {
            if QishuiProtocol.authErrorCodes.contains(code) {
                throw QishuiError(.authRequired, "汽水登录已失效，请重新扫码", upstreamCode: code)
            }
            throw QishuiError(.unavailable, "汽水拒绝了这个请求", upstreamCode: code)
        }
        guard let data = dataObject else {
            throw QishuiError(.invalidResponse, "汽水返回缺少 data")
        }
        return data
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
            throw QishuiError(.authRequired, "汽水登录已失效，请重新扫码")
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
}
