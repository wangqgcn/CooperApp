import Foundation
import S3Kit
import Security

/// 主程序和扩展共用的 App Group，标识在构建时写进各自的 Info.plist。
enum AppGroup {
    static var identifier: String {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "CooperAppGroupIdentifier") as? String, !id.isEmpty else {
            fatalError("Info.plist 缺少 CooperAppGroupIdentifier，检查签名设置里的 DEVELOPMENT_TEAM")
        }
        return id
    }

    static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group 容器 \(identifier)"])
        }
        return url
    }
}

/// 唯一的 Finder 挂载。根目录下每个存储桶连接是一个子文件夹。
enum CooperDrive {
    static let domainID = "CooperDrive"
    /// 用在本地目录名上：~/Library/CloudStorage/Cooper-CooperDrive
    static let displayName = "CooperDrive"
    /// Finder 侧栏显示的是装着扩展的 App 的名字，不是 displayName
    static let sidebarName = "Cooper"
}

/// 一个已保存的存储桶连接。id 是 UUID，同时是它在 CooperDrive 里的文件夹标识。
struct Connection: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var config: S3Config
    /// 公开访问域名（可选），如 R2 的 https://pub-xxx.r2.dev 或绑定的自定义域名。旧配置里没有这个字段
    var publicBaseURL: URL?
    /// 添加时选的服务商（主程序 StorageProvider 的原始值），只用于界面显示。旧配置里没有这个字段
    var provider: String?
}

/// 连接配置（不含密钥）存在 App Group 容器里，按添加顺序排列。
enum ConnectionStore {
    static func fileURL() throws -> URL {
        try AppGroup.containerURL().appendingPathComponent("connections.json")
    }

    /// 旧版本只支持一个连接
    private static func legacyFileURL() throws -> URL {
        try AppGroup.containerURL().appendingPathComponent("connection.json")
    }

    /// 所有连接。第一次读取时把旧版本的 connection.json 迁移过来。
    static func loadAll() throws -> [Connection] {
        let url = try fileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode([Connection].self, from: Data(contentsOf: url))
        }
        let legacyURL = try legacyFileURL()
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return [] }
        let legacy = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: legacyURL))
        try saveAll([legacy])
        try? FileManager.default.removeItem(at: legacyURL)
        return [legacy]
    }

    static func saveAll(_ connections: [Connection]) throws {
        let data = try JSONEncoder().encode(connections)
        try data.write(to: fileURL(), options: .atomic)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
        return "钥匙串错误 \(status)：\(message)"
    }
}

/// 访问密钥存在数据保护钥匙串里，放进共享钥匙串组，主程序和扩展都能读取。
enum CredentialStore {
    private static let service = "app.getcooper.credentials"

    /// 形如 "TEAMID.app.getcooper.shared"，必须出现在两个 target 的 keychain-access-groups 权限里
    private static var accessGroup: String {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "CooperKeychainAccessGroup") as? String, !group.isEmpty else {
            fatalError("Info.plist 缺少 CooperKeychainAccessGroup，检查签名设置里的 DEVELOPMENT_TEAM")
        }
        return group
    }

    private static func query(for connectionID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func save(_ credentials: S3Credentials, for connectionID: String) throws {
        SecItemDelete(query(for: connectionID) as CFDictionary)
        var attributes = query(for: connectionID)
        attributes[kSecValueData as String] = try JSONEncoder().encode(credentials)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load(for connectionID: String) throws -> S3Credentials? {
        var request = query(for: connectionID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(S3Credentials.self, from: data)
    }

    static func delete(for connectionID: String) {
        SecItemDelete(query(for: connectionID) as CFDictionary)
    }
}
