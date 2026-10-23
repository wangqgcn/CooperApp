import Foundation
import Observation
import SyncCore

/// 菜单栏面板的操作记录：读扩展（Finder 操作）和主程序各自的记录文件，监听变化，合并成按天分段的列表。
/// 主窗口里改动存储桶的操作也通过它记录。
@MainActor
@Observable
final class ActivityModel {
    enum Filter: Hashable, CaseIterable {
        case all, running, attention

        var title: String {
            switch self {
            case .all: "全部"
            case .running: "进行中"
            case .attention: "失败"
            }
        }
    }

    /// 两份记录合并后的结果，新的在前，已去掉「清除记录」之前的
    private(set) var events: [ActivityEvent] = []
    var filter = Filter.all
    /// 只看某个存储桶，nil 表示全部
    var bucketFilter: String?

    @ObservationIgnored let recorder = ActivityRecorder(source: .app)
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0

    /// 顶部状态只提醒最近这段时间里的失败，更早的在「失败」筛选里看
    private static let attentionWindow: TimeInterval = 24 * 3600

    func start() {
        guard watcher == nil, let directory = ActivityLocation.directory() else { return }
        watcher = DirectoryWatcher(url: directory) { [weak self] in
            self?.scheduleReload()
        }
        reload()
    }

    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let clearedBefore = ActivityLocation.clearedBefore
        Task {
            let merged = await Task.detached(priority: .utility) {
                ActivityFeed.merge([ActivityLocation.load(.finder), ActivityLocation.load(.app)], clearedBefore: clearedBefore)
            }.value
            // 连续读取时只用最后一次的结果
            guard generation == loadGeneration else { return }
            events = merged
        }
    }

    /// 记录文件写得很频繁（拖入大量文件时），合并成一次读取
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    /// 清空列表。不删除文件，只记下时间，之前结束的记录不再显示
    func clear() {
        ActivityLocation.clearedBefore = Date()
        reload()
    }

    // MARK: - 显示

    /// 当前筛选下按天分段的列表。只显示现存连接的记录，移除了的存储桶不再出现
    func sections(connectionIDs: Set<String>, now: Date = Date()) -> [ActivitySection] {
        var visible = events.filter { connectionIDs.contains($0.connectionID) }
        // 选中的存储桶被移除后当作全部
        if let bucketFilter, connectionIDs.contains(bucketFilter) {
            visible = visible.filter { $0.connectionID == bucketFilter }
        }
        switch filter {
        case .all: break
        case .running: visible = visible.filter(\.status.isRunning)
        case .attention: visible = visible.filter(\.status.needsAttention)
        }
        return ActivityFeed.sections(from: ActivityFeed.rows(from: visible), now: now)
    }

    func runningCount(connectionIDs: Set<String>) -> Int {
        events.filter { $0.status.isRunning && connectionIDs.contains($0.connectionID) }.count
    }

    func attentionCount(connectionIDs: Set<String>) -> Int {
        events.filter { $0.status.needsAttention && connectionIDs.contains($0.connectionID) }.count
    }

    /// 最近 24 小时里的失败，顶部状态和菜单栏图标据此提醒
    func recentAttentionCount(connectionIDs: Set<String>, now: Date = Date()) -> Int {
        events.filter {
            $0.status.needsAttention && connectionIDs.contains($0.connectionID) && now.timeIntervalSince($0.lastUpdate) < Self.attentionWindow
        }.count
    }

    // MARK: - 记录主窗口里的操作

    /// 开始 → 执行 → 完成或失败，错误照常抛出。一次操作涉及多个条目（多选删除）时每个条目一条记录
    func track(_ drafts: [ActivityDraft], _ work: () async throws -> Void) async throws {
        var ids: [UUID] = []
        for draft in drafts {
            ids.append(await recorder.begin(draft))
        }
        do {
            try await work()
            for id in ids {
                await recorder.finish(id, status: .done)
            }
        } catch {
            for id in ids {
                await recorder.fail(id, error: error)
            }
            throw error
        }
    }
}

/// 监听目录里的文件变化。记录文件是原子写入（在同一目录里改名），目录会收到 write 事件。
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
