import Foundation

/// 每个存储桶的同步记录存在 App Group 容器的 Sync/ 目录里，按连接 id 命名。
/// 系统提供的 stateDirectoryURL 要求 macOS 15，所以不用它。
enum SyncStateLocation {
    private static func directory() -> URL? {
        guard let container = try? AppGroup.containerURL() else { return nil }
        return container.appendingPathComponent("Sync", isDirectory: true)
    }

    static func url(forConnection connectionID: String) -> URL? {
        guard let directory = directory() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(connectionID).json")
    }

    static func remove(forConnection connectionID: String) {
        guard let url = url(forConnection: connectionID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 重新挂载或卸载 CooperDrive 时全部作废
    static func removeAll() {
        guard let directory = directory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 主程序请求立即刷新：扩展下次轮询这个存储桶时检查所有打开过的文件夹，而不只是到期的。
enum RefreshRequest {
    private static func key(_ connectionID: String) -> String { "refresh.\(connectionID)" }

    static func request(connectionID: String) {
        UserDefaults(suiteName: AppGroup.identifier)?.set(true, forKey: key(connectionID))
    }

    /// 读取并清除请求
    static func consume(connectionID: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier), defaults.bool(forKey: key(connectionID)) else { return false }
        defaults.removeObject(forKey: key(connectionID))
        return true
    }
}
