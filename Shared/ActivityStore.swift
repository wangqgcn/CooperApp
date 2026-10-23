import FileProvider
import Foundation
import S3Kit
import SyncCore

/// 操作记录存在 App Group 容器的 Activity/ 目录里：扩展写 finder.json，主程序写 app.json。
/// 每个进程只写自己的文件；「清除记录」只记一个时间，显示时过滤，不去改对方的文件。
enum ActivityLocation {
    static func directory() -> URL? {
        guard let container = try? AppGroup.containerURL() else { return nil }
        let directory = container.appendingPathComponent("Activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func url(for source: ActivitySource) -> URL? {
        directory()?.appendingPathComponent("\(source.rawValue).json")
    }

    static func load(_ source: ActivitySource) -> [ActivityEvent] {
        guard let url = url(for: source), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ActivityEvent].self, from: data)) ?? []
    }

    private static let clearedKey = "activity.clearedBefore"

    /// 这个时间之前结束的记录不再显示
    static var clearedBefore: Date? {
        get { UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: clearedKey) as? Date }
        set { UserDefaults(suiteName: AppGroup.identifier)?.set(newValue, forKey: clearedKey) }
    }
}

/// 一个进程的操作记录。每个进程只建一个（扩展和主程序各自的 static 实例）。
/// 写盘合并 0.5 秒：Finder 拖入上千个文件时不会每个文件都重写一次。
actor ActivityRecorder {
    private var log: ActivityLog
    private let fileURL: URL?
    private var saveTask: Task<Void, Never>?
    private static let saveDelay: Duration = .milliseconds(500)

    init(source: ActivitySource) {
        fileURL = ActivityLocation.url(for: source)
        var log = ActivityLog(source: source, events: ActivityLocation.load(source))
        // 上次进程被结束时还在进行的操作不会完成了
        if log.markRunningInterrupted() {
            log.trim()
            Self.write(log, to: fileURL)
        }
        self.log = log
    }

    @discardableResult
    func begin(_ draft: ActivityDraft) -> UUID {
        let id = log.begin(draft)
        scheduleSave()
        return id
    }

    func finish(_ id: UUID, status: ActivityStatus, itemID: String? = nil, size: Int64? = nil, fileCount: Int? = nil) {
        log.finish(id, status: status, itemID: itemID, size: size, fileCount: fileCount)
        scheduleSave()
    }

    func discard(_ id: UUID) {
        log.discard(id)
        scheduleSave()
    }

    /// 记下失败。不需要记录的错误（同名冲突、取消）直接去掉这条
    func fail(_ id: UUID, error: Error) {
        if let message = ActivityFailure.message(for: error) {
            finish(id, status: .failed(message))
        } else {
            discard(id)
        }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: Self.saveDelay)
            save()
        }
    }

    private func save() {
        saveTask = nil
        log.trim()
        Self.write(log, to: fileURL)
    }

    private static func write(_ log: ActivityLog, to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(log.events) else { return }
        // 原子写入是在同一目录里改名，主程序靠监听目录发现变化
        try? data.write(to: url, options: .atomic)
    }
}

enum ActivityFailure {
    /// 失败原因的说明。同名冲突（系统会改名后重试）、取消这类正常流程返回 nil，不留记录
    static func message(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? nil : "无法连接到服务器"
        }
        if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled { return nil }
        if let s3Error = error as? S3Error {
            switch s3Error.statusCode {
            case 401, 403: return "访问密钥无效或没有权限"
            case 404: return "找不到这个项目，可能已在别处删除"
            default: return s3Error.localizedDescription
            }
        }
        if let fileProviderError = error as? NSFileProviderError {
            switch fileProviderError.code {
            case .filenameCollision, .excludedFromSync: return nil
            case .notAuthenticated: return "访问密钥无效或没有权限"
            case .serverUnreachable: return "无法连接到服务器"
            case .noSuchItem: return "找不到这个项目，可能已在别处删除"
            case .directoryNotEmpty: return "文件夹不是空的"
            case .deletionRejected: return "存储桶文件夹要在 Cooper 里移除"
            default: break
            }
        }
        return error.localizedDescription
    }
}
