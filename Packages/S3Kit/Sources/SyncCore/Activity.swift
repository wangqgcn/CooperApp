import Foundation

/// 谁发起的操作。Finder 里的由 File Provider 扩展执行并记录，主窗口里的由主程序记录，
/// 两边各写各的记录文件，菜单栏合并显示。
public enum ActivitySource: String, Codable, Sendable {
    case finder
    case app
}

/// 改变存储桶内容的操作。下载和轮询发现的远端变化不记录。
public enum ActivityAction: String, Codable, Sendable {
    /// 上传文件；主窗口里也可能是一整个文件夹
    case upload
    /// 修改已有的文件后保存，整个文件重新上传
    case update
    case createFolder
    /// 在同一个文件夹里改名
    case rename
    /// 移到另一个文件夹，可能同时改名
    case move
    case delete
}

public enum ActivityStatus: Codable, Hashable, Sendable {
    case running
    case done
    case failed(String)
    case cancelled
    /// 进程被结束时还没做完
    case interrupted

    public var isRunning: Bool { self == .running }

    /// 失败或被中断，需要用户留意
    public var needsAttention: Bool {
        switch self {
        case .failed, .interrupted: true
        default: false
        }
    }
}

/// 开始一次操作时记下的内容
public struct ActivityDraft: Hashable, Sendable {
    public var action: ActivityAction
    public var connectionID: String
    /// 操作后的 key；删除时是被删除的 key
    public var key: String
    /// SyncStore 里的条目标识，改名后不变。新建时还不知道，完成时补上
    public var itemID: String?
    /// 改名、移动前的 key
    public var previousKey: String?
    public var size: Int64?
    /// 上传整个文件夹时里面的文件数
    public var fileCount: Int?

    public init(
        _ action: ActivityAction,
        connectionID: String,
        key: String,
        itemID: String? = nil,
        previousKey: String? = nil,
        size: Int64? = nil,
        fileCount: Int? = nil
    ) {
        self.action = action
        self.connectionID = connectionID
        self.key = key
        self.itemID = itemID
        self.previousKey = previousKey
        self.size = size
        self.fileCount = fileCount
    }
}

/// 一条操作记录。
public struct ActivityEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var source: ActivitySource
    public var action: ActivityAction
    public var connectionID: String
    public var key: String
    public var itemID: String?
    public var previousKey: String?
    public var size: Int64?
    public var fileCount: Int?
    public var status: ActivityStatus
    /// 开始时间；系统重试时更新为最近一次开始的时间
    public var date: Date
    public var finishedAt: Date?
    /// 第几次尝试，系统重试失败的操作时加一
    public var attempts: Int

    public init(id: UUID = UUID(), source: ActivitySource, draft: ActivityDraft, status: ActivityStatus = .running, date: Date) {
        self.id = id
        self.source = source
        action = draft.action
        connectionID = draft.connectionID
        key = draft.key
        itemID = draft.itemID
        previousKey = draft.previousKey
        size = draft.size
        fileCount = draft.fileCount
        self.status = status
        self.date = date
        finishedAt = nil
        attempts = 1
    }

    public var isFolder: Bool { S3Path.isFolder(key) }
    /// 存储桶文件夹本身（key 为空）时为空字符串
    public var name: String { S3Path.name(of: key) }
    public var parentKey: String { S3Path.parent(of: key) }
    public var previousName: String? { previousKey.map(S3Path.name(of:)) }
    /// 最近一次变化的时间：完成时间，没完成时是开始时间
    public var lastUpdate: Date { finishedAt ?? date }

    /// 同一个存储桶里同一个条目的同一种操作
    func matches(_ draft: ActivityDraft) -> Bool {
        guard connectionID == draft.connectionID, action == draft.action else { return false }
        if let itemID, let other = draft.itemID { return itemID == other }
        return key == draft.key
    }
}

/// 一个进程的操作记录，旧的在前。最多保留 maxCount 条、maxAge 以内的记录。
public struct ActivityLog: Sendable {
    public static let maxCount = 1000
    public static let maxAge: TimeInterval = 30 * 86_400

    public let source: ActivitySource
    public private(set) var events: [ActivityEvent]

    public init(source: ActivitySource, events: [ActivityEvent] = []) {
        self.source = source
        self.events = events
    }

    /// 开始一次操作，返回记录的 id。同一条目的同一种操作上次失败或被中断时，
    /// 沿用那条记录并把尝试次数加一，系统反复重试不会刷出一串失败记录。
    @discardableResult
    public mutating func begin(_ draft: ActivityDraft, now: Date = Date()) -> UUID {
        if let index = events.lastIndex(where: { $0.status.needsAttention && $0.matches(draft) }) {
            var event = events.remove(at: index)
            event.key = draft.key
            event.itemID = draft.itemID ?? event.itemID
            event.previousKey = draft.previousKey
            event.size = draft.size ?? event.size
            event.fileCount = draft.fileCount ?? event.fileCount
            event.status = .running
            event.date = now
            event.finishedAt = nil
            event.attempts += 1
            events.append(event)
            return event.id
        }
        let event = ActivityEvent(source: source, draft: draft, date: now)
        events.append(event)
        return event.id
    }

    /// 记下结果，顺带补上完成后才知道的条目标识、大小和文件数
    public mutating func finish(
        _ id: UUID,
        status: ActivityStatus,
        itemID: String? = nil,
        size: Int64? = nil,
        fileCount: Int? = nil,
        now: Date = Date()
    ) {
        guard let index = events.lastIndex(where: { $0.id == id }) else { return }
        events[index].status = status
        events[index].finishedAt = now
        if let itemID { events[index].itemID = itemID }
        if let size { events[index].size = size }
        if let fileCount { events[index].fileCount = fileCount }
    }

    /// 不留记录：同名冲突（系统会改名后重试）、用户取消这类正常流程
    public mutating func discard(_ id: UUID) {
        events.removeAll { $0.id == id }
    }

    /// 进程启动时调用：上次留下的进行中记录已经不会完成了。返回是否有改动
    @discardableResult
    public mutating func markRunningInterrupted(now: Date = Date()) -> Bool {
        var changed = false
        for index in events.indices where events[index].status.isRunning {
            events[index].status = .interrupted
            events[index].finishedAt = now
            changed = true
        }
        return changed
    }

    public mutating func trim(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        events.removeAll { !$0.status.isRunning && $0.lastUpdate < cutoff }
        if events.count > Self.maxCount {
            events.removeFirst(events.count - Self.maxCount)
        }
    }
}

// MARK: - 显示

/// 菜单栏列表里的一行：一条记录，或合并在一起的几条。
public struct ActivityRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case single
        /// 新建文件夹加上随后传进这个文件夹（含子文件夹）的内容，对应 Finder 里拖入一整个文件夹
        case folder
        /// 同一个文件夹里短时间内的同一种操作，比如一次拖入多个文件、多选删除
        case batch
    }

    public let kind: Kind
    /// 新的在前。folder 时最后一条（最早的）是文件夹本身
    public let events: [ActivityEvent]

    /// 用最早的一条做标识，新记录并进来时这一行的标识不变
    public var id: UUID { events[events.count - 1].id }
    /// single、batch 时是最新的一条；folder 时是文件夹本身
    public var primary: ActivityEvent { kind == .folder ? events[events.count - 1] : events[0] }
    public var date: Date { events.map(\.lastUpdate).max() ?? events[0].date }
    public var totalSize: Int64 { events.compactMap(\.size).reduce(0, +) }
    /// 其中的文件数，不算文件夹
    public var fileCount: Int { events.filter { !$0.isFolder }.count }
    /// 同一个文件反复修改保存
    public var isRepeatedUpdate: Bool { kind == .batch && Set(events.map(\.key)).count == 1 }
}

/// 按天分的一段
public struct ActivitySection: Identifiable, Hashable, Sendable {
    public enum Period: Int, Hashable, Sendable {
        case today, yesterday, pastWeek, earlier
    }

    public let period: Period
    public let rows: [ActivityRow]
    public var id: Period { period }
}

/// 把两个进程的记录合并成菜单栏的列表。
public enum ActivityFeed {
    /// 相邻两条记录相隔不超过它才合并成一行
    public static let batchGap: TimeInterval = 5 * 60

    /// 合并多份记录，新的在前。clearedBefore 之前结束的记录不显示（「清除记录」），进行中的始终显示
    public static func merge(_ logs: [[ActivityEvent]], clearedBefore: Date? = nil) -> [ActivityEvent] {
        logs.joined()
            .filter { event in
                guard let clearedBefore else { return true }
                return event.status.isRunning || event.lastUpdate >= clearedBefore
            }
            .sorted { $0.date > $1.date }
    }

    /// 合并成行，新的在前。只合并已完成的记录，进行中、失败的始终单独一行。
    public static func rows(from events: [ActivityEvent]) -> [ActivityRow] {
        let ascending = events.sorted { $0.date < $1.date }
        var absorbed = Set<UUID>()
        var rows: [ActivityRow] = []

        // 文件夹：新建之后陆续传进去的内容
        for (index, folder) in ascending.enumerated()
        where folder.action == .createFolder && folder.status == .done && !absorbed.contains(folder.id) {
            var members: [ActivityEvent] = []
            var last = folder.date
            for candidate in ascending[(index + 1)...] {
                guard !absorbed.contains(candidate.id),
                      candidate.source == folder.source,
                      candidate.connectionID == folder.connectionID,
                      candidate.status == .done,
                      candidate.action == .upload || candidate.action == .createFolder,
                      candidate.key.hasPrefix(folder.key),
                      candidate.key != folder.key else { continue }
                guard candidate.date.timeIntervalSince(last) <= batchGap else { break }
                members.append(candidate)
                last = candidate.date
            }
            guard !members.isEmpty else { continue }
            absorbed.insert(folder.id)
            absorbed.formUnion(members.map(\.id))
            rows.append(ActivityRow(kind: .folder, events: ([folder] + members).reversed()))
        }

        // 其余的：同来源、同存储桶、同一个文件夹里的同一种操作
        struct BatchKey: Hashable {
            var source: ActivitySource
            var connectionID: String
            var action: ActivityAction
            var parentKey: String
        }
        var groups: [[ActivityEvent]] = []
        var open: [BatchKey: Int] = [:]
        for event in ascending where !absorbed.contains(event.id) {
            guard event.status == .done else {
                groups.append([event])
                continue
            }
            let key = BatchKey(source: event.source, connectionID: event.connectionID, action: event.action, parentKey: event.parentKey)
            if let index = open[key], let last = groups[index].last, event.date.timeIntervalSince(last.date) <= batchGap {
                groups[index].append(event)
            } else {
                open[key] = groups.count
                groups.append([event])
            }
        }
        rows += groups.map { ActivityRow(kind: $0.count == 1 ? .single : .batch, events: $0.reversed()) }

        return rows.sorted { $0.date > $1.date }
    }

    /// 按今天、昨天、过去 7 天、更早分段。rows 需要是新的在前
    public static func sections(from rows: [ActivityRow], now: Date = Date(), calendar: Calendar = .current) -> [ActivitySection] {
        var sections: [ActivitySection] = []
        var current: (period: ActivitySection.Period, rows: [ActivityRow])?
        for row in rows {
            let period = period(of: row.date, now: now, calendar: calendar)
            if let open = current, open.period == period {
                current?.rows.append(row)
            } else {
                if let open = current { sections.append(ActivitySection(period: open.period, rows: open.rows)) }
                current = (period, [row])
            }
        }
        if let open = current { sections.append(ActivitySection(period: open.period, rows: open.rows)) }
        return sections
    }

    static func period(of date: Date, now: Date, calendar: Calendar) -> ActivitySection.Period {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return .yesterday }
        // 今天加上之前 6 天
        if let weekStart = calendar.date(byAdding: .day, value: -6, to: today), date >= weekStart { return .pastWeek }
        return .earlier
    }
}
