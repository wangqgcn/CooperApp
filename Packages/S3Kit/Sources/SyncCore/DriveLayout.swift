import Foundation

/// CooperDrive 挂载里的条目标识。根目录下每个存储桶一个文件夹：
/// 存储桶文件夹的标识就是连接 id，其中条目的标识是「连接 id/SyncStore 里的标识」。
public enum DriveIdentifier: Hashable, Sendable {
    case bucket(connectionID: String)
    case item(connectionID: String, storeID: String)

    /// 每个存储桶的 SyncStore 根记录的标识，对应存储桶文件夹
    public static let storeRootID = "@root"

    /// 连接 id 是 UUID，不含 "/"，所以按第一个 "/" 拆分
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        guard let slash = rawValue.firstIndex(of: "/") else {
            self = .bucket(connectionID: rawValue)
            return
        }
        let connectionID = String(rawValue[..<slash])
        let storeID = String(rawValue[rawValue.index(after: slash)...])
        guard !connectionID.isEmpty, !storeID.isEmpty else { return nil }
        self = .item(connectionID: connectionID, storeID: storeID)
    }

    public static func forStoreID(_ storeID: String, connectionID: String) -> DriveIdentifier {
        storeID == storeRootID ? .bucket(connectionID: connectionID) : .item(connectionID: connectionID, storeID: storeID)
    }

    public var rawValue: String {
        switch self {
        case .bucket(let connectionID): connectionID
        case .item(let connectionID, let storeID): "\(connectionID)/\(storeID)"
        }
    }

    public var connectionID: String {
        switch self {
        case .bucket(let connectionID), .item(let connectionID, _): connectionID
        }
    }

    public var storeID: String {
        switch self {
        case .bucket: Self.storeRootID
        case .item(_, let storeID): storeID
        }
    }
}

public enum DriveNaming {
    /// 存储桶在 CooperDrive 里的文件夹名：去掉文件名里不能用的字符，重名时按顺序加序号。
    /// APFS 默认不区分大小写，比较时忽略大小写。
    public static func folderNames(_ entries: [(id: String, name: String)]) -> [String: String] {
        var used = Set<String>()
        var result: [String: String] = [:]
        for entry in entries {
            var base = entry.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 以 "." 开头会变成隐藏文件夹
            while base.hasPrefix(".") { base.removeFirst() }
            if base.isEmpty { base = "存储桶" }

            var candidate = base
            var number = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base) \(number)"
                number += 1
            }
            used.insert(candidate.lowercased())
            result[entry.id] = candidate
        }
        return result
    }
}

/// 工作集的同步锚点：每个存储桶各自的 SyncStore 锚点，加上当时的文件夹名。
/// 和当前状态对比，就能知道哪些存储桶是新加的、被删掉的或改了名。
public struct WorkingSetAnchor: Codable, Hashable, Sendable {
    public struct Bucket: Codable, Hashable, Sendable {
        public var storeAnchor: String
        public var folderName: String

        public init(storeAnchor: String, folderName: String) {
            self.storeAnchor = storeAnchor
            self.folderName = folderName
        }
    }

    public var buckets: [String: Bucket]

    public init(buckets: [String: Bucket] = [:]) {
        self.buckets = buckets
    }

    /// 解析失败（比如旧版本的锚点）返回 nil，调用方应当让系统重新枚举工作集
    public init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }

    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)) ?? Data()
    }
}
