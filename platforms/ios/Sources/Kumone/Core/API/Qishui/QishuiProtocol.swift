import Foundation
import CryptoKit
import Security

/// Qishui (Luna) car / BYD open-SDK protocol.
///
/// Ported from `qishui-music-api@0.2.2` (MIT). This is the same protocol the
/// LIZI project uses: public reads are authorized by a client token, account
/// reads by a P-256 ticket-guard signature. No Gorgon/Argus/libguard involved.
enum QishuiProtocol {
    static let userAgent = "LunaOpenSDK/1.0.10"
    static let prefix = "/api/luna/v1/platform"
    static let clientKey = "aw4bbxfujo741d09"
    static let loginAID = "1128"

    /// Fixed common parameters of the car client. Order is preserved because
    /// the upstream reads them positionally in a few legacy paths.
    static let commonParams: [(String, String)] = [
        ("aid", "765213"),
        ("app_id", "765213"),
        ("app_name", "byte_autoservice_lite"),
        ("version_code", "100010"),
        ("version_name", "1.0.10"),
        ("channel", "bydSong"),
        ("sdk_aid", "753999"),
        ("caller_name", "luna_open_sdk"),
        ("sdk_version_code", "100000100"),
        ("sdk_version_name", "0.0.1"),
        ("sdk_channel", "Test"),
        ("vehicle_type", "BYD"),
        ("device_brand", "BYD"),
        ("device_type", "BYD"),
        ("device_platform", "android"),
        ("resolution", "1920x1080"),
        ("os_version", "13"),
        ("ac", "wifi"),
    ]

    static let authErrorCodes: Set<String> = ["28001003", "28001007", "28001008", "10007"]

    static let retryableReads: Set<String> = [
        "/search/", "/playlist/detail/", "/media/mget/", "/media/mcheck/",
        "/artist/detail/", "/artist/tracks/", "/feed/mode/", "/feed/song-tab/",
    ]

    // MARK: - Device identity

    /// 19 digit numeric device id. The car protocol treats it as the device
    /// identity, so it must be generated once and reused.
    static func makeDeviceId() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        let id = value % 9_000_000_000_000_000_000 + 1_000_000_000_000_000_000
        return String(id)
    }

    static func isDeviceId(_ value: String) -> Bool {
        value.count == 19 && value.allSatisfy { $0.isNumber }
    }

    // MARK: - Query

    static func query(deviceId: String, extras: [String: String] = [:]) -> String {
        var pairs: [(String, String)] = commonParams
        pairs += [
            ("device_id", deviceId),
            ("did", deviceId),
            ("iid", deviceId),
            ("vehicle_id", "qishui-\(deviceId)"),
            ("_timestamp", String(Int(Date().timeIntervalSince1970))),
            ("_nonce", String(UInt16.random(in: 0...UInt16.max))),
        ]
        for key in extras.keys.sorted() {
            if let value = extras[key] { pairs.append((key, value)) }
        }
        return pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Guard (ticket-guard)

    struct Guard {
        /// Raw 32-byte P-256 private key.
        let keyData: Data
        /// Base64 of the PEM encoded PKCS#10 request.
        let csr: String
    }

    static func makeGuard() throws -> Guard {
        let key = P256.Signing.PrivateKey()
        let subject = der(0x30, [
            der(0x31, [der(0x30, [oid([0x55, 0x04, 0x03]), der(0x0C, [Data("bd-ticket-guard".utf8)])])]),
            der(0x31, [der(0x30, [oid([0x55, 0x04, 0x0B]), der(0x0C, [Data()])])]),
            der(0x31, [der(0x30, [oid([0x55, 0x04, 0x0A]), der(0x0C, [Data()])])]),
        ])
        let info = der(0x30, [
            der(0x02, [Data([0])]),
            subject,
            spki(for: key.publicKey),
            der(0xA0, []),
        ])
        let signature = try key.signature(for: info).derRepresentation
        let algorithm = der(0x30, [oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])])
        let request = der(0x30, [info, algorithm, der(0x03, [Data([0]), signature])])
        let body = request.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN CERTIFICATE REQUEST-----\n\(body)\n-----END CERTIFICATE REQUEST-----\n"
        return Guard(keyData: key.rawRepresentation, csr: Data(pem.utf8).base64EncodedString())
    }

    static func guardHeaders(_ credential: QishuiCredential, path: String) throws -> [String: String] {
        guard let keyData = Data(base64Encoded: credential.guardKey) else {
            throw QishuiError(.invalidResponse, "汽水登录密钥已损坏，请重新扫码")
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(rawRepresentation: keyData)
        } catch {
            throw QishuiError(.invalidResponse, "汽水登录密钥无法读取，请重新扫码")
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let content = "ticket=\(credential.ticket)&path=\(prefix)\(path)&timestamp=\(timestamp)"
        let signature = try key.signature(for: Data(content.utf8)).derRepresentation.base64EncodedString()
        let payload: [String: Any] = [
            "ts_sign": credential.guardTsSign,
            "req_content": "ticket,path,timestamp",
            "req_sign": signature,
            "timestamp": timestamp,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return [
            "access-token": credential.ticket,
            "bd-ticket-guard-version": "1",
            "bd-ticket-guard-client-cert": credential.guardCert,
            "bd-ticket-guard-client-data": json.base64EncodedString(),
        ]
    }

    /// Reads the `bd-ticket-guard-server-data` header returned by the ticket
    /// exchange endpoint.
    static func readGuard(serverData: String) throws -> (ticket: String, tsSign: String, cert: String) {
        guard let data = Data(base64Encoded: serverData),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = object["ticket"] as? String, !ticket.isEmpty,
              let tsSign = object["ts_sign"] as? String, !tsSign.isEmpty,
              let cert = object["client_cert"] as? String, !cert.isEmpty else {
            throw QishuiError(.invalidResponse, "汽水授权数据不完整，请重新扫码")
        }
        let normalized = cert.contains("-----BEGIN") ? Data(cert.utf8).base64EncodedString() : cert
        return (ticket, tsSign, normalized)
    }

    static func credentialExpiry(_ raw: Double) -> Date {
        let value = raw
        let milliseconds: Double
        if value > 1_000_000_000_000 { milliseconds = value }
        else if value > 1_000_000_000 { milliseconds = value * 1000 }
        else if value > 0 { milliseconds = Date().timeIntervalSince1970 * 1000 + value * 1000 }
        else { milliseconds = Date().timeIntervalSince1970 * 1000 + 6 * 3600 * 1000 }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    // MARK: - DER

    private static func der(_ tag: UInt8, _ parts: [Data]) -> Data {
        let body = parts.reduce(into: Data()) { $0.append($1) }
        var output = Data([tag])
        output.append(derLength(body.count))
        output.append(body)
        return output
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        if length < 0x100 { return Data([0x81, UInt8(length)]) }
        return Data([0x82, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
    }

    private static func oid(_ bytes: [UInt8]) -> Data {
        der(0x06, [Data(bytes)])
    }

    private static func spki(for publicKey: P256.Signing.PublicKey) -> Data {
        let algorithm = der(0x30, [
            oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
            oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]),
        ])
        let point = der(0x03, [Data([0]), publicKey.x963Representation])
        return der(0x30, [algorithm, point])
    }
}

/// Persisted device identity for the car protocol.
enum QishuiDeviceIdentity {
    private static let key = "qishui.deviceId"

    static var current: String {
        if let value = UserDefaults.standard.string(forKey: key),
           QishuiProtocol.isDeviceId(value) {
            return value
        }
        let value = QishuiProtocol.makeDeviceId()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
