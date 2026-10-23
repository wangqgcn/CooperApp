import CryptoKit
import Foundation

/// AWS Signature Version 4 签名，只实现 S3 用到的请求头签名方式。
public struct SigV4Signer: Sendable {
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    /// 上传大文件时不对请求体做哈希，HTTPS 下 S3 和 R2 都接受
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    public let credentials: S3Credentials
    public let region: String
    public let service: String

    public init(credentials: S3Credentials, region: String, service: String = "s3") {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    /// 返回要加到请求上的签名头（x-amz-date、x-amz-content-sha256、Authorization）。
    /// `headers` 是除 host 以外需要参与签名的请求头，如 range、content-type。
    /// URL 必须已按 S3 规则编码（见 `uriEncode`），发出的地址要和签名时完全一致。
    public func sign(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        payloadHash: String,
        date: Date = Date()
    ) -> [String: String] {
        let (amzDate, dateStamp) = Self.timestamps(for: date)

        var signed: [String: String] = [:]
        for (name, value) in headers {
            signed[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        signed["host"] = Self.hostHeader(for: url)
        signed["x-amz-date"] = amzDate
        signed["x-amz-content-sha256"] = payloadHash

        let names = signed.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(signed[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [
            method,
            Self.canonicalURI(for: url),
            Self.canonicalQuery(for: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        let signature = Self.hex(HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: signingKey(dateStamp: dateStamp)
        ))

        return [
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash,
            "Authorization": "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
        ]
    }

    /// 生成预签名地址（签名放在查询参数里），持有地址的人在有效期内无需密钥就能访问。
    /// expires 为有效秒数，S3 规定最长 7 天（604800 秒）。
    public func presign(method: String, url: URL, expires: Int, date: Date = Date()) -> URL {
        let (amzDate, dateStamp) = Self.timestamps(for: date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = (components.queryItems ?? []) + [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: "\(credentials.accessKeyId)/\(scope)"),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(expires)),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]
        let canonicalQuery = Self.canonicalQuery(items)
        let canonicalRequest = [
            method,
            Self.canonicalURI(for: url),
            canonicalQuery,
            "host:\(Self.hostHeader(for: url))\n",
            "host",
            Self.unsignedPayload,
        ].joined(separator: "\n")
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: signingKey(dateStamp: dateStamp)
        ))
        components.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=" + signature
        return components.url!
    }

    /// S3 的 URI 编码：只保留 A-Z a-z 0-9 - . _ ~，其余按 UTF-8 转成大写 %XX。
    public static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if !encodeSlash {
            allowed.insert("/")
        }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func signingKey(dateStamp: String) -> SymmetricKey {
        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return key
    }

    static func timestamps(for date: Date) -> (amzDate: String, dateStamp: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateStamp = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        let amzDate = dateStamp + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!)
        return (amzDate, dateStamp)
    }

    static func hostHeader(for url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port else { return host }
        let isDefault = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }

    static func canonicalURI(for url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return path.isEmpty ? "/" : path
    }

    static func canonicalQuery(for url: URL) -> String {
        canonicalQuery(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    }

    static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        let encoded: [(name: String, value: String)] = items.map {
            (uriEncode($0.name, encodeSlash: true), uriEncode($0.value ?? "", encodeSlash: true))
        }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
