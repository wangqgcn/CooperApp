import Foundation

/// 一个 S3 兼容存储桶的连接参数，不含密钥。
public struct S3Config: Codable, Hashable, Sendable {
    /// 服务地址，如 R2 的 https://<ACCOUNT_ID>.r2.cloudflarestorage.com
    public var endpoint: URL
    public var bucket: String
    /// R2 固定为 "auto"
    public var region: String
    /// true 时使用 endpoint/bucket/key 的路径式地址，否则使用 bucket.endpoint/key
    public var usePathStyle: Bool

    public init(endpoint: URL, bucket: String, region: String = "auto", usePathStyle: Bool = true) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.usePathStyle = usePathStyle
    }
}

public struct S3Credentials: Codable, Hashable, Sendable {
    public var accessKeyId: String
    public var secretAccessKey: String

    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }
}

public struct S3Object: Hashable, Sendable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
    /// 去掉引号后的 ETag，用作内容版本号
    public var etag: String?
    public var contentType: String?

    public init(key: String, size: Int64, lastModified: Date? = nil, etag: String? = nil, contentType: String? = nil) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.etag = etag
        self.contentType = contentType
    }

    /// 从 HEAD / GET 的响应头构造。
    public init(key: String, response: HTTPURLResponse) {
        self.init(
            key: key,
            size: Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(HTTPDate.parse),
            etag: response.value(forHTTPHeaderField: "ETag").map(S3Object.unquote),
            contentType: response.value(forHTTPHeaderField: "Content-Type")
        )
    }

    static func unquote(_ etag: String) -> String {
        etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

public struct ListPage: Sendable {
    public var objects: [S3Object]
    /// 以 "/" 结尾的子前缀，即“文件夹”
    public var commonPrefixes: [String]
    public var nextContinuationToken: String?
    public var isTruncated: Bool
}

enum HTTPDate {
    /// 解析 RFC 1123 格式，如 "Wed, 12 Oct 2009 17:50:00 GMT"
    static func parse(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }

    /// 解析列举结果里的 ISO 8601 时间，有无毫秒都接受
    static func parseISO8601(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(string, strategy: Date.ISO8601FormatStyle())
    }
}
