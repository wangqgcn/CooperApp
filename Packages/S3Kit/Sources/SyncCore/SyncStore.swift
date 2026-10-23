import Foundation
import S3Kit

/// 系统已知的一个条目（文件或文件夹）的本地记录。
public struct ItemRecord: Codable, Hashable, Sendable {
    /// File Provider 条目标识。默认等于首次见到时的 key，改名、移动后保持不变
    public var id: String
    /// 当前的 S3 key。根目录为 ""，文件夹以 "/" 结尾
    public var key: String
    public var size: Int64
    public var etag: String?
    /// 文件为 S3 的 LastModified；文件夹为其直接子项里最新的修改时间
    public var modified: Date?
    /// 首次见到的时间。文件夹还不知道修改时间时用它显示，避免显示成 1970 年
    public var firstSeen: Date
    /// 最近一次需要通知系统的变化序号；0 表示系统已经知道当前状态
    public var changeSeq: Int64
    /// 墓碑：条目已删除，保留记录用于通知系统或防止旧的轮询结果把它加回来
    public var isDeleted: Bool
    /// 本地最后一次写入这条记录的时间。轮询开始得比它早时，轮询结果不能覆盖它
    public var touchedAt: Date

    public var isFolder: Bool { S3Path.isFolder(key) }
    public var name: String { S3Path.name(of: key) }
    /// 根目录没有上级
    public var parentKey: String? { key.isEmpty ? nil : S3Path.parent(of: key) }
}

/// 交给 File Provider 的条目：记录加上上级条目的标识。
public struct SyncItem: Hashable, Sendable {
    public var record: ItemRecord
    public var parentID: String
}

/// 需要轮询的文件夹。
public struct PollTarget: Hashable, Sendable {
    public var id: String
    public var key: String
}

/// 挂载的同步状态：标识 ↔ key 映射、各条目的版本、待通知系统的变化，以及要轮询的文件夹。
/// 每次修改后立即写回磁盘，扩展进程随时可能被系统结束。
public actor SyncStore {
    /// 文件夹轮询间隔：有变化时回到最短，连续没变化时逐步拉长，控制请求费用
    public static let minPollInterval: TimeInterval = 60
    public static let maxPollInterval: TimeInterval = 15 * 60
    static let maxTombstones = 2000
    static let localTombstoneLifetime: TimeInterval = 10 * 60

    public enum Changes: Sendable {
        /// 系统持有的锚点已失效，需要重新完整枚举工作集
        case expired
        case changes(updated: [SyncItem], deletedIDs: [String], anchor: String)
    }

    struct WatchState: Codable, Hashable {
        var lastPolled: Date
        var interval: TimeInterval
    }

    struct State: Codable {
        /// 记录所属的连接（endpoint + bucket），换了存储桶就作废
        var scope: String
        /// 每次新建状态时生成，锚点里带上它，用来识别状态是否被重置过
        var generation: String
        var seq: Int64 = 0
        /// 比它小的锚点已失效（对应的墓碑被清理掉了）
        var minValidSeq: Int64 = 0
        var records: [String: ItemRecord] = [:]
        /// 被系统完整枚举过的文件夹，按标识索引
        var watched: [String: WatchState] = [:]
    }

    public let rootID: String
    private let fileURL: URL?
    private var state: State
    private var idByKey: [String: String]

    /// fileURL 为 nil 时只保存在内存里（测试用）。
    public init(fileURL: URL?, rootID: String, scope: String, now: Date = Date()) {
        self.fileURL = fileURL
        self.rootID = rootID
        var loaded: State?
        if let fileURL, let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(State.self, from: data), decoded.scope == scope {
            loaded = decoded
        }
        var state = loaded ?? State(scope: scope, generation: UUID().uuidString)
        if state.records[rootID] == nil {
            state.records[rootID] = ItemRecord(
                id: rootID, key: "", size: 0, etag: nil, modified: nil,
                firstSeen: now, changeSeq: 0, isDeleted: false, touchedAt: .distantPast
            )
        }
        self.state = state
        self.idByKey = Self.makeIndex(state.records)
    }

    // MARK: - 查询

    public func currentAnchor() -> String {
        "\(state.generation):\(state.seq)"
    }

    public func item(id: String) -> SyncItem? {
        guard let record = state.records[id], !record.isDeleted else { return nil }
        return syncItem(record)
    }

    public func liveItem(forKey key: String) -> SyncItem? {
        guard let id = idByKey[key], let record = state.records[id], !record.isDeleted else { return nil }
        return syncItem(record)
    }

    public func isLive(id: String) -> Bool {
        state.records[id].map { !$0.isDeleted } ?? false
    }

    /// 已知条目的 key；不认识的标识当作 key 本身（默认标识就是 key）。
    public func key(forID id: String) -> String {
        if let record = state.records[id] { return record.key }
        return id == rootID ? "" : id
    }

    /// 工作集：除根目录外所有存活的条目，上级排在下级前面。
    public func allItems() -> [SyncItem] {
        state.records.values
            .filter { !$0.isDeleted && $0.id != rootID }
            .sorted { $0.key < $1.key }
            .map(syncItem)
    }

    // MARK: - 枚举

    /// 记录一页枚举结果，返回带稳定标识的条目。系统通过枚举已经拿到这些状态，不算变化。
    public func recordListed(folderKey: String, objects: [S3Object], folderPrefixes: [String], now: Date = Date()) -> [SyncItem] {
        var items: [SyncItem] = []
        for prefix in folderPrefixes where prefix != folderKey {
            var record = existingOrNewRecord(forKey: prefix, now: now)
            record.isDeleted = false
            record.touchedAt = now
            put(record)
            items.append(syncItem(record))
        }
        // key 等于前缀本身的是文件夹占位对象，不是子项
        for object in objects where object.key != folderKey {
            var record = existingOrNewRecord(forKey: object.key, now: now)
            record.isDeleted = false
            record.size = object.size
            record.etag = object.etag
            record.modified = object.lastModified
            record.touchedAt = now
            put(record)
            items.append(syncItem(record))
        }
        save()
        return items
    }

    /// 一个文件夹完整枚举完毕：去掉不再存在的子项，开始轮询它，并更新文件夹日期。
    public func finishListing(folderID: String, seenKeys: Set<String>, newestModified: Date?, startedAt: Date, now: Date = Date()) {
        guard let folder = state.records[folderID], !folder.isDeleted else { return }
        for child in children(of: folder.key) where !seenKeys.contains(child.key) && child.touchedAt < startedAt {
            removeRecord(child)
        }
        updateFolderDate(folderID: folderID, newest: newestModified)
        var watch = state.watched[folderID] ?? WatchState(lastPolled: now, interval: Self.minPollInterval)
        watch.lastPolled = now
        state.watched[folderID] = watch
        save()
    }

    // MARK: - 本地操作（系统发起，系统已经知道结果，不算变化）

    /// 创建、上传、下载后记录对象的最新状态。
    @discardableResult
    public func recordLocalUpsert(key: String, size: Int64, etag: String?, modified: Date?, now: Date = Date()) -> SyncItem {
        let parentKey = S3Path.parent(of: key)
        ensureFolderChain(parentKey, now: now)
        var record = existingOrNewRecord(forKey: key, now: now)
        record.isDeleted = false
        record.size = size
        record.etag = etag
        record.modified = modified ?? record.modified
        record.changeSeq = 0
        record.touchedAt = now
        put(record)
        resetPollInterval(folderKey: parentKey)
        save()
        return syncItem(record)
    }

    /// 改名或移动。文件夹的所有下级记录一起改 key，标识都不变。
    @discardableResult
    public func recordLocalMove(id: String, toKey newKey: String, now: Date = Date()) -> SyncItem? {
        guard var record = state.records[id], !record.isDeleted else { return nil }
        let oldKey = record.key
        guard oldKey != newKey else { return syncItem(record) }

        // 目标 key 上残留的墓碑作废
        if let otherID = idByKey[newKey], otherID != id {
            state.records[otherID] = nil
            state.watched[otherID] = nil
        }
        ensureFolderChain(S3Path.parent(of: newKey), now: now)
        record.key = newKey
        record.changeSeq = 0
        record.touchedAt = now
        state.records[id] = record
        if record.isFolder {
            for var descendant in state.records.values where descendant.id != id && descendant.key.hasPrefix(oldKey) {
                descendant.key = newKey + descendant.key.dropFirst(oldKey.count)
                descendant.touchedAt = now
                state.records[descendant.id] = descendant
            }
        }
        removeDuplicateKeys()
        resetPollInterval(folderKey: S3Path.parent(of: oldKey))
        resetPollInterval(folderKey: S3Path.parent(of: newKey))
        save()
        return syncItem(record)
    }

    /// 删除。留下一个不通知系统的墓碑，防止删除前开始的轮询把它加回来。
    public func recordLocalDelete(id: String, now: Date = Date()) {
        guard var record = state.records[id], !record.isDeleted, id != rootID else { return }
        record.isDeleted = true
        record.changeSeq = 0
        record.touchedAt = now
        put(record)
        state.watched[id] = nil
        if record.isFolder {
            removeDescendants(of: record.key)
        }
        resetPollInterval(folderKey: S3Path.parent(of: record.key))
        save()
    }

    // MARK: - 轮询

    /// 到期需要轮询的文件夹，上级排在前面。force 为 true 时返回全部。
    public func foldersDueForPoll(now: Date = Date(), force: Bool) -> [PollTarget] {
        state.watched
            .compactMap { id, watch -> PollTarget? in
                guard let record = state.records[id], !record.isDeleted, record.isFolder else { return nil }
                guard force || now.timeIntervalSince(watch.lastPolled) >= watch.interval else { return nil }
                return PollTarget(id: id, key: record.key)
            }
            .sorted { lhs, rhs in
                let (l, r) = (lhs.key.count(where: { $0 == "/" }), rhs.key.count(where: { $0 == "/" }))
                return l == r ? lhs.key < rhs.key : l < r
            }
    }

    /// 用一次轮询的列举结果更新文件夹的直接子项，返回是否发现了变化。
    /// listedKey 是列举时使用的前缀；轮询期间文件夹被改名的话，结果作废。
    @discardableResult
    public func applyPoll(
        folderID: String,
        listedKey: String,
        objects: [S3Object],
        folderPrefixes: [String],
        startedAt: Date,
        now: Date = Date()
    ) -> Bool {
        guard let folder = state.records[folderID], !folder.isDeleted, folder.key == listedKey else { return false }
        let folderKey = folder.key
        var seen = Set<String>()
        var changed = false

        for prefix in folderPrefixes where prefix != folderKey {
            seen.insert(prefix)
            var record = existingOrNewRecord(forKey: prefix, now: now)
            let isNew = state.records[record.id] == nil
            guard isNew || record.isDeleted else { continue }
            // 本地刚删除，这次列举是删除前的旧结果
            if !isNew && record.touchedAt >= startedAt { continue }
            record.isDeleted = false
            record.touchedAt = now
            bump(&record)
            put(record)
            changed = true
        }

        for object in objects where object.key != folderKey {
            seen.insert(object.key)
            var record = existingOrNewRecord(forKey: object.key, now: now)
            let isNew = state.records[record.id] == nil
            if !isNew {
                // 本地在轮询开始后改过它，以本地为准
                if record.touchedAt >= startedAt { continue }
                if !record.isDeleted && record.etag == object.etag && record.size == object.size { continue }
            }
            record.isDeleted = false
            record.size = object.size
            record.etag = object.etag
            record.modified = object.lastModified
            record.touchedAt = now
            bump(&record)
            put(record)
            changed = true
        }

        for child in children(of: folderKey) where !seen.contains(child.key) && child.touchedAt < startedAt {
            tombstone(child)
            changed = true
        }

        // 占位对象的时间也算在文件夹日期里
        if updateFolderDate(folderID: folderID, newest: objects.compactMap(\.lastModified).max()) {
            changed = true
        }

        var watch = state.watched[folderID] ?? WatchState(lastPolled: now, interval: Self.minPollInterval)
        watch.lastPolled = now
        watch.interval = changed ? Self.minPollInterval : min(watch.interval * 2, Self.maxPollInterval)
        state.watched[folderID] = watch
        pruneTombstones(now: now)
        save()
        return changed
    }

    // MARK: - 增量变化

    public func changes(since anchor: String) -> Changes {
        let parts = anchor.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == state.generation, let seq = Int64(parts[1]),
              seq >= state.minValidSeq, seq <= state.seq else {
            return .expired
        }
        var updated: [SyncItem] = []
        var deleted: [String] = []
        for record in state.records.values where record.changeSeq > seq {
            if record.isDeleted {
                deleted.append(record.id)
            } else {
                updated.append(syncItem(record))
            }
        }
        updated.sort { $0.record.key < $1.record.key }
        return .changes(updated: updated, deletedIDs: deleted, anchor: currentAnchor())
    }

    // MARK: - 内部

    private func syncItem(_ record: ItemRecord) -> SyncItem {
        SyncItem(record: record, parentID: parentID(of: record))
    }

    private func parentID(of record: ItemRecord) -> String {
        guard let parentKey = record.parentKey, !parentKey.isEmpty else { return rootID }
        if let id = idByKey[parentKey], let parent = state.records[id], !parent.isDeleted { return id }
        return parentKey
    }

    /// 找到 key 对应的记录（包括墓碑），没有就构造一条新记录（尚未写入）。
    private func existingOrNewRecord(forKey key: String, now: Date) -> ItemRecord {
        if let id = idByKey[key], let record = state.records[id] { return record }
        return ItemRecord(
            id: newID(for: key), key: key, size: 0, etag: nil, modified: nil,
            firstSeen: now, changeSeq: 0, isDeleted: false, touchedAt: now
        )
    }

    /// 默认用 key 作标识；被改过名的旧条目占用了这个标识时，改用随机标识。
    private func newID(for key: String) -> String {
        let candidate = key.isEmpty ? rootID : key
        return state.records[candidate] == nil ? candidate : UUID().uuidString
    }

    private func put(_ record: ItemRecord) {
        state.records[record.id] = record
        idByKey[record.key] = record.id
    }

    private func bump(_ record: inout ItemRecord) {
        state.seq += 1
        record.changeSeq = state.seq
    }

    private func children(of folderKey: String) -> [ItemRecord] {
        state.records.values.filter { !$0.isDeleted && $0.id != rootID && $0.parentKey == folderKey }
    }

    /// 远端删除：留下通知系统的墓碑。文件夹的下级记录直接去掉，系统会递归删除。
    private func tombstone(_ record: ItemRecord) {
        var deleted = record
        deleted.isDeleted = true
        bump(&deleted)
        put(deleted)
        state.watched[record.id] = nil
        if record.isFolder {
            removeDescendants(of: record.key)
        }
    }

    private func removeRecord(_ record: ItemRecord) {
        state.records[record.id] = nil
        state.watched[record.id] = nil
        if idByKey[record.key] == record.id { idByKey[record.key] = nil }
        if record.isFolder {
            removeDescendants(of: record.key)
        }
    }

    private func removeDescendants(of folderKey: String) {
        guard !folderKey.isEmpty else { return }
        for descendant in state.records.values where descendant.key.hasPrefix(folderKey) && descendant.key != folderKey {
            state.records[descendant.id] = nil
            state.watched[descendant.id] = nil
            if idByKey[descendant.key] == descendant.id { idByKey[descendant.key] = nil }
        }
    }

    /// 补齐上级文件夹记录（系统可能在旧版本里就认识它们）。
    private func ensureFolderChain(_ folderKey: String, now: Date) {
        guard !folderKey.isEmpty, liveItem(forKey: folderKey) == nil else { return }
        ensureFolderChain(S3Path.parent(of: folderKey), now: now)
        var record = existingOrNewRecord(forKey: folderKey, now: now)
        record.isDeleted = false
        record.touchedAt = now
        put(record)
    }

    /// 文件夹日期变了就作为变化通知系统，返回是否有变化。
    @discardableResult
    private func updateFolderDate(folderID: String, newest: Date?) -> Bool {
        guard let newest, var folder = state.records[folderID], folder.modified != newest else { return false }
        folder.modified = newest
        bump(&folder)
        put(folder)
        return true
    }

    private func resetPollInterval(folderKey: String) {
        let id = folderKey.isEmpty ? rootID : idByKey[folderKey]
        guard let id, state.watched[id] != nil else { return }
        state.watched[id]?.interval = Self.minPollInterval
    }

    private func pruneTombstones(now: Date) {
        var dropped = false
        for record in state.records.values where record.isDeleted && record.changeSeq == 0
            && now.timeIntervalSince(record.touchedAt) > Self.localTombstoneLifetime {
            state.records[record.id] = nil
            dropped = true
        }
        let remote = state.records.values.filter { $0.isDeleted && $0.changeSeq > 0 }.sorted { $0.changeSeq < $1.changeSeq }
        if remote.count > Self.maxTombstones {
            let removed = remote.prefix(remote.count - Self.maxTombstones)
            for record in removed { state.records[record.id] = nil }
            state.minValidSeq = max(state.minValidSeq, removed.last!.changeSeq)
            dropped = true
        }
        if dropped { idByKey = Self.makeIndex(state.records) }
    }

    /// 同一个 key 只保留一条记录，存活记录优先于墓碑。
    private func removeDuplicateKeys() {
        var winners: [String: ItemRecord] = [:]
        for record in state.records.values {
            guard let existing = winners[record.key] else {
                winners[record.key] = record
                continue
            }
            if existing.isDeleted && !record.isDeleted {
                state.records[existing.id] = nil
                winners[record.key] = record
            } else {
                state.records[record.id] = nil
            }
        }
        idByKey = Self.makeIndex(state.records)
    }

    private static func makeIndex(_ records: [String: ItemRecord]) -> [String: String] {
        var index: [String: String] = [:]
        for record in records.values {
            if let existing = index[record.key], let other = records[existing], !other.isDeleted { continue }
            index[record.key] = record.id
        }
        return index
    }

    private func save() {
        guard let fileURL else { return }
        // 写失败不影响当前运行，下次修改时会再写
        try? JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
    }
}
