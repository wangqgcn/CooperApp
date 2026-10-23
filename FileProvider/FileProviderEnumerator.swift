import FileProvider
import S3Kit
import SyncCore

/// 把 File Provider 的回调和观察者对象带进 Task。这些 Objective-C 对象没有标注 Sendable，
/// 但系统允许在任意线程调用它们。
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension NSFileProviderPage {
    /// 两个初始页常量在 Swift 里被导入成 NSData
    var isInitial: Bool {
        rawValue == NSFileProviderPage.initialPageSortedByName as Data || rawValue == NSFileProviderPage.initialPageSortedByDate as Data
    }
}

/// CooperDrive 根目录：每个存储桶一个文件夹。增删改存储桶的变化通过工作集上报。
final class RootEnumerator: NSObject, NSFileProviderEnumerator {
    private let registry: BucketRegistry

    init(registry: BucketRegistry) {
        self.registry = registry
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = Unchecked(observer)
        let registry = registry
        Task {
            var items: [NSFileProviderItem] = []
            for context in await registry.all() {
                items.append(await context.bucketItem())
            }
            observer.value.didEnumerate(items)
            observer.value.finishEnumerating(upTo: nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data(ISO8601DateFormatter().string(from: Date()).utf8)))
    }
}

/// 列出存储桶里一个文件夹的直接子项，每页对应一次 ListObjectsV2。完整列举后这个文件夹开始被轮询。
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let identifier: String
    private let registry: BucketRegistry
    private let session = ListingSession()
    private var task: Task<Void, Never>?

    init(identifier: NSFileProviderItemIdentifier, registry: BucketRegistry) {
        self.identifier = identifier.rawValue
        self.registry = registry
    }

    func invalidate() {
        task?.cancel()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let isFirstPage = page.isInitial
        let token = isFirstPage ? nil : String(data: page.rawValue, encoding: .utf8)
        let observer = Unchecked(observer)
        let (identifier, registry, session) = (identifier, registry, session)

        task = Task {
            do {
                guard let parsed = DriveIdentifier(rawValue: identifier), let context = await registry.context(for: parsed.connectionID) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                guard let client = context.client else { throw NSFileProviderError(.notAuthenticated) }
                let folderID = parsed.storeID
                let folderKey = await context.store.key(forID: folderID)
                guard S3Path.isFolder(folderKey) else { throw NSFileProviderError(.noSuchItem) }
                if isFirstPage { await session.restart() }

                let page = try await client.listObjects(prefix: folderKey, continuationToken: token, maxKeys: 1000)
                let items = await context.store.recordListed(folderKey: folderKey, objects: page.objects, folderPrefixes: page.commonPrefixes)
                await session.add(page)
                observer.value.didEnumerate(items.map(context.make))

                if let next = page.nextContinuationToken {
                    observer.value.finishEnumerating(upTo: NSFileProviderPage(Data(next.utf8)))
                } else {
                    let summary = await session.summary()
                    await context.store.finishListing(folderID: folderID, seenKeys: summary.seen, newestModified: summary.newest, startedAt: summary.startedAt)
                    observer.value.finishEnumerating(upTo: nil)
                }
            } catch {
                logger.error("列举 \(identifier, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
                observer.value.finishEnumeratingWithError(FileProviderExtension.fileProviderError(from: error))
            }
        }
    }

    /// 远端变化统一通过工作集上报。万一系统查询单个文件夹的变化，让它重新完整列举。
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data(ISO8601DateFormatter().string(from: Date()).utf8)))
    }
}

/// 跨分页累计一次完整列举：看到的 key、最新修改时间（含文件夹占位对象）、开始时间。
private actor ListingSession {
    private var startedAt = Date()
    private var seen = Set<String>()
    private var newest: Date?

    func restart() {
        startedAt = Date()
        seen = []
        newest = nil
    }

    func add(_ page: ListPage) {
        seen.formUnion(page.objects.map(\.key))
        seen.formUnion(page.commonPrefixes)
        newest = (page.objects.compactMap(\.lastModified) + [newest].compactMap { $0 }).max()
    }

    func summary() -> (seen: Set<String>, newest: Date?, startedAt: Date) {
        (seen, newest, startedAt)
    }
}

/// 工作集 = 所有存储桶文件夹，加上各存储桶里系统已知的条目。
/// 远端变化、文件夹日期、存储桶的增删改都从这里上报。
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let registry: BucketRegistry
    private static let pageSize = 500
    private static let batchSize = 200

    init(registry: BucketRegistry) {
        self.registry = registry
    }

    func invalidate() {}

    /// 只在系统重建工作集时调用（比如锚点失效后）
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let offset = page.isInitial ? 0 : Int(String(decoding: page.rawValue, as: UTF8.self)) ?? 0
        let observer = Unchecked(observer)
        let registry = registry
        Task {
            var all: [NSFileProviderItem] = []
            for context in await registry.all() {
                all.append(await context.bucketItem())
                all += await context.store.allItems().map(context.make)
            }
            let slice = all.dropFirst(offset).prefix(Self.pageSize)
            observer.value.didEnumerate(Array(slice))
            let next = offset + slice.count
            observer.value.finishEnumerating(upTo: next < all.count ? NSFileProviderPage(Data(String(next).utf8)) : nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let observer = Unchecked(observer)
        let registry = registry
        Task {
            let contexts = await registry.all()
            for context in contexts {
                await context.remoteSync?.pollIfNeeded()
            }
            guard let previous = WorkingSetAnchor(data: anchor.rawValue) else {
                observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }

            var updated: [NSFileProviderItem] = []
            var deleted: [NSFileProviderItemIdentifier] = []
            var next = WorkingSetAnchor()
            for context in contexts {
                guard let entry = previous.buckets[context.id] else {
                    // 新加的存储桶：先只上报文件夹本身，里面的内容等用户打开时再列举
                    updated.append(await context.bucketItem())
                    next.buckets[context.id] = .init(storeAnchor: await context.store.currentAnchor(), folderName: context.folderName)
                    continue
                }
                switch await context.store.changes(since: entry.storeAnchor) {
                case .expired:
                    observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                case .changes(let items, let deletedIDs, let storeAnchor):
                    updated += items.map(context.make)
                    deleted += deletedIDs.map(context.identifier(forStoreID:))
                    let bucketReported = items.contains { $0.record.id == DriveIdentifier.storeRootID }
                    if entry.folderName != context.folderName && !bucketReported {
                        updated.append(await context.bucketItem())
                    }
                    next.buckets[context.id] = .init(storeAnchor: storeAnchor, folderName: context.folderName)
                }
            }
            // 被删除的存储桶：系统会递归移除整个文件夹
            for connectionID in previous.buckets.keys where !contexts.contains(where: { $0.id == connectionID }) {
                deleted.append(NSFileProviderItemIdentifier(connectionID))
            }

            for batch in deleted.chunked(Self.batchSize) {
                observer.value.didDeleteItems(withIdentifiers: Array(batch))
            }
            for batch in updated.chunked(Self.batchSize) {
                observer.value.didUpdate(Array(batch))
            }
            observer.value.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(next.data), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let done = Unchecked(completionHandler)
        let registry = registry
        Task {
            var anchor = WorkingSetAnchor()
            for context in await registry.all() {
                anchor.buckets[context.id] = .init(storeAnchor: await context.store.currentAnchor(), folderName: context.folderName)
            }
            done.value(NSFileProviderSyncAnchor(anchor.data))
        }
    }
}

/// 回收站：不支持，始终为空。
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(Data("empty".utf8))

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor)
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
