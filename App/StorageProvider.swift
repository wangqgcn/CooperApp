import Foundation
import SwiftUI

/// 添加存储桶时可选的服务商预设：决定表单的默认值、提示和图标。连接里只存原始值字符串。
enum StorageProvider: String, CaseIterable, Identifiable {
    case r2
    case s3
    case b2
    case wasabi
    case minio
    case oss
    case cos
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .r2: "Cloudflare R2"
        case .s3: "Amazon S3"
        case .b2: "Backblaze B2"
        case .wasabi: "Wasabi"
        case .minio: "MinIO"
        case .oss: "Alibaba Cloud OSS"
        case .cos: "Tencent Cloud COS"
        case .other: "其他兼容 S3 的服务商"
        }
    }

    /// 图标里的缩写，nil 时显示通用图标
    var abbreviation: String? {
        switch self {
        case .r2: "R2"
        case .s3: "S3"
        case .b2: "B2"
        case .wasabi: "W"
        case .minio: "M"
        case .oss: "OSS"
        case .cos: "COS"
        case .other: nil
        }
    }

    var color: Color {
        switch self {
        case .r2: Color(light: 0xF38020, dark: 0xF38020)
        case .s3: Color(light: 0x232F3E, dark: 0x3D4F66)
        case .b2: Color(light: 0xD9272E, dark: 0xE2383F)
        case .wasabi: Color(light: 0x2EA44F, dark: 0x3CB55A)
        case .minio: Color(light: 0xC72C48, dark: 0xD23A57)
        case .oss: Color(light: 0xFF6A00, dark: 0xFF7A1A)
        case .cos: Color(light: 0x006EFF, dark: 0x2B87FF)
        case .other: Color(light: 0x6E6E73, dark: 0x7C7C82)
        }
    }

    /// 按区域生成 endpoint 的模板，「{region}」会被替换。R2 的地址含账户 ID，没有模板
    private var endpointTemplate: String? {
        switch self {
        case .s3: "https://s3.{region}.amazonaws.com"
        case .b2: "https://s3.{region}.backblazeb2.com"
        case .wasabi: "https://s3.{region}.wasabisys.com"
        case .oss: "https://s3.oss-{region}.aliyuncs.com"
        case .cos: "https://cos.{region}.myqcloud.com"
        case .r2, .minio, .other: nil
        }
    }

    func endpoint(forRegion region: String) -> String? {
        let region = region.trimmingCharacters(in: .whitespaces)
        guard let endpointTemplate, !region.isEmpty else { return nil }
        return endpointTemplate.replacingOccurrences(of: "{region}", with: region)
    }

    var endpointPlaceholder: String {
        switch self {
        case .r2: "https://<account>.r2.cloudflarestorage.com"
        case .minio: "http://localhost:9000"
        case .other: "https://s3.example.com"
        default: endpoint(forRegion: defaultRegion) ?? ""
        }
    }

    var endpointHint: String {
        switch self {
        case .r2: "可在 R2 存储桶设置中查看"
        case .b2: "可在存储桶详情中查看"
        case .s3, .wasabi, .oss, .cos: "根据区域自动填写"
        case .minio: "MinIO 服务地址"
        case .other: "服务商提供的 S3 API 地址"
        }
    }

    var defaultRegion: String {
        switch self {
        case .r2: "auto"
        case .b2: "us-west-004"
        case .oss: "cn-hangzhou"
        case .cos: "ap-guangzhou"
        case .s3, .wasabi, .minio, .other: "us-east-1"
        }
    }

    var regionHint: String {
        switch self {
        case .r2: "通常为 auto"
        case .minio: "默认 us-east-1"
        case .other: "不确定可填 us-east-1"
        default: "如 \(defaultRegion)"
        }
    }

    var bucketPlaceholder: String {
        self == .cos ? "examplebucket-1250000000" : "my-bucket"
    }

    var publicURLPlaceholder: String {
        self == .r2 ? "https://pub-xxx.r2.dev 或自定义域名" : "https://cdn.example.com"
    }

    var namePlaceholder: String {
        "个人 \(abbreviation ?? "存储")"
    }

    /// 阿里云、腾讯云、AWS 默认用虚拟主机式地址，其余用路径式
    var usesPathStyle: Bool {
        switch self {
        case .s3, .oss, .cos: false
        case .r2, .b2, .wasabi, .minio, .other: true
        }
    }

    /// 只有自建和其他服务商需要用户自己选地址形式
    var allowsPathStyleChoice: Bool {
        self == .minio || self == .other
    }

    /// 创建访问密钥的官方说明
    var tutorialURL: URL? {
        switch self {
        case .r2: URL(string: "https://developers.cloudflare.com/r2/api/tokens/")
        case .s3: URL(string: "https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html")
        case .b2: URL(string: "https://www.backblaze.com/docs/cloud-storage-create-and-manage-app-keys")
        case .wasabi: URL(string: "https://docs.wasabi.com/docs/creating-a-new-access-key")
        case .oss: URL(string: "https://help.aliyun.com/zh/oss/developer-reference/use-amazon-s3-sdks-to-access-oss")
        case .cos: URL(string: "https://cloud.tencent.com/document/product/436/37421")
        case .minio, .other: nil
        }
    }

    /// 连接保存的服务商；旧版本的连接没有这个字段，按 endpoint 推断
    static func of(_ connection: Connection) -> StorageProvider {
        connection.provider.flatMap(StorageProvider.init(rawValue:)) ?? infer(from: connection.config.endpoint)
    }

    static func infer(from endpoint: URL) -> StorageProvider {
        let host = endpoint.host()?.lowercased() ?? ""
        let suffixes: [(String, StorageProvider)] = [
            ("r2.cloudflarestorage.com", .r2),
            ("amazonaws.com", .s3),
            ("backblazeb2.com", .b2),
            ("wasabisys.com", .wasabi),
            ("aliyuncs.com", .oss),
            ("myqcloud.com", .cos),
        ]
        return suffixes.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1 ?? .other
    }
}

extension Connection {
    var storageProvider: StorageProvider { StorageProvider.of(self) }

    /// 列表里显示的 endpoint 主机名
    var endpointHost: String {
        config.endpoint.host() ?? config.endpoint.absoluteString
    }
}
