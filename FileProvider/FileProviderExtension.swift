import FileProvider
import os
import S3Kit
import SyncCore
import UniformTypeIdentifiers

/// 调试：log stream --predicate 'subsystem == "app.getcooper"' --level debug
let logger = Logger(subsystem: "app.getcooper", category: "FileProvider")

/// CooperDrive 挂载的扩展。根目录下每个存储桶一个文件夹，所有操作先按标识找到对应的存储桶。
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let registry = BucketRegistry()
    private var pollTask: Task<Void, Never>?

    /// 扩展运行期间多久检查一次到期的文件夹
    private static let pollTick: Duration = .seconds(60)
    /// Finder 里的操作记录，菜单栏显示。整个扩展进程共用一个
    private static let activity = ActivityRecorder(source: .finder)

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        // 尽早把上次没做完的记录标成中断
        _ = Self.activity
        startPolling()
    }

    func invalidate() {
        pollTask?.cancel()
    }

    /// 扩展活着时定期轮询各存储桶；发现变化就通知系统来取（系统随后调用工作集的 enumerateChanges）。
    /// 扩展被系统结束后，由主程序的定时通知把它唤醒。
    private func startPolling() {
        let domain = Unchecked(domain)
        let registry = registry
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollTick)
                guard !Task.isCancelled else { break }
                var changed = false
                for context in await registry.all() where await context.remoteSync?.pollIfNeeded() == true {
                    changed = true
                }
                if changed, let manager = NSFileProviderManager(for: domain.value) {
                    try? await manager.signalEnumerator(for: .workingSet)
                }
            }
        }
    }

    /// 找到标识所属的存储桶，以及它在该存储桶 SyncStore 里的标识。根目录和不认识的标识返回 nil。
    private static func resolve(_ identifier: NSFileProviderItemIdentifier, in registry: BucketRegistry) async -> (BucketContext, String)? {
        guard identifier != .rootContainer, let parsed = DriveIdentifier(rawValue: identifier.rawValue),
              let context = await registry.context(for: parsed.connectionID) else { return nil }
        return (context, parsed.storeID)
    }

    // MARK: - 元数据

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .rootContainer {
            completionHandler(FileProviderItem.root(), nil)
            return progress
        }
        if identifier == .trashContainer || identifier == .workingSet {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let done = Unchecked(completionHandler)
        let registry = registry
        Task {
            do {
                guard let (context, storeID) = await Self.resolve(identifier, in: registry) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                if let item = await context.store.item(id: storeID) {
                    done.value(context.make(item), nil)
                } else {
                    // 本地记录里没有（比如同步记录被清掉了）：标识默认就是 key，按 key 查
                    let key = storeID
                    if S3Path.isFolder(key) {
                        done.value(context.make(await context.store.recordLocalUpsert(key: key, size: 0, etag: nil, modified: nil)), nil)
                    } else {
                        guard let client = context.client else { throw NSFileProviderError(.notAuthenticated) }
                        let object = try await client.headObject(key: key)
                        let item = await context.store.recordLocalUpsert(key: key, size: object.size, etag: object.etag, modified: object.lastModified)
                        done.value(context.make(item), nil)
                    }
                }
            } catch {
                done.value(nil, Self.fileProviderError(from: error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .workingSet:
            return WorkingSetEnumerator(registry: registry)
        case .trashContainer:
            return EmptyEnumerator()
        case .rootContainer:
            return RootEnumerator(registry: registry)
        default:
            return FolderEnumerator(identifier: containerItemIdentifier, registry: registry)
        }
    }

    // MARK: - 打开时下载

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        guard let manager = NSFileProviderManager(for: domain) else {
            completionHandler(nil, nil, NSFileProviderError(.providerNotFound))
            return progress
        }
        let destination: URL
        do {
            // 必须下载到系统给的临时目录，和用户文件在同一个卷上
            destination = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
        } catch {
            completionHandler(nil, nil, error)
            return progress
        }

        let done = Unchecked(completionHandler)
        let registry = registry
        Task {
            guard let (context, storeID) = await Self.resolve(itemIdentifier, in: registry) else {
                done.value(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }
            guard let client = context.client else {
                done.value(nil, nil, NSFileProviderError(.notAuthenticated))
                return
            }
            guard !progress.isCancelled else {
                done.value(nil, nil, CocoaError(.userCancelled))
                return
            }
            let key = await context.store.key(forID: storeID)
            logger.info("下载 \(key, privacy: .public)")
            let task = client.downloadTask(key: key, to: destination) { result in
                switch result {
                case .success(let response):
                    let object = S3Object(key: key, response: response)
                    Task {
                        let item = await context.store.recordLocalUpsert(key: key, size: object.size, etag: object.etag, modified: object.lastModified)
                        done.value(destination, context.make(item), nil)
                    }
                case .failure(let error):
                    logger.error("下载 \(key, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
                    done.value(nil, nil, Self.fileProviderError(from: error))
                }
            }
            progress.addChild(task.progress, withPendingUnitCount: 100)
            progress.cancellationHandler = { task.cancel() }
            task.resume()
        }
        return progress
    }

    // MARK: - 新建

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let name = itemTemplate.filename
        let parent = itemTemplate.parentItemIdentifier
        let isFolder = itemTemplate.contentType?.conforms(to: .directory) == true
        // 系统文件、符号链接这类没有内容的项，以及直接放在 CooperDrive 根目录（不在任何存储桶里）的项，只留在本地
        if SyncExclusion.isExcluded(name) || (!isFolder && url == nil) || parent == .rootContainer {
            completionHandler(nil, [], false, NSFileProviderError(.excludedFromSync))
            return progress
        }

        let mayAlreadyExist = options.contains(.mayAlreadyExist)
        let done = Unchecked(completionHandler)
        let registry = registry
        let task = Task {
            var eventID: UUID?
            do {
                guard let (context, parentStoreID) = await Self.resolve(parent, in: registry) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let parentKey = await context.store.key(forID: parentStoreID)
                guard S3Path.isFolder(parentKey) else { throw NSFileProviderError(.noSuchItem) }
                let key = parentKey + name + (isFolder ? "/" : "")
                // 系统重新导入已有条目时（mayAlreadyExist）不是用户的操作，不记录
                if !mayAlreadyExist {
                    let draft = ActivityDraft(isFolder ? .createFolder : .upload, connectionID: context.id, key: key, size: isFolder ? nil : url.map(Self.fileSize))
                    eventID = await Self.activity.begin(draft)
                }
                guard let client = context.client else { throw NSFileProviderError(.notAuthenticated) }
                let item = if isFolder {
                    try await Self.createFolder(key: key, mayAlreadyExist: mayAlreadyExist, client: client, store: context.store)
                } else {
                    try await Self.createFile(from: url!, key: key, mayAlreadyExist: mayAlreadyExist, client: client, store: context.store, progress: progress)
                }
                progress.completedUnitCount = progress.totalUnitCount
                done.value(context.make(item), [], false, nil)
                await Self.recordDone(eventID, item: item)
            } catch {
                logger.error("新建 \(name, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
                done.value(nil, [], false, Self.fileProviderError(from: error))
                await Self.recordFailure(eventID, error: error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// S3 没有目录，用一个以 "/" 结尾的空对象占位，空文件夹也能保留。
    private static func createFolder(key: String, mayAlreadyExist: Bool, client: S3Client, store: SyncStore) async throws -> SyncItem {
        if let existing = await store.liveItem(forKey: key) {
            guard mayAlreadyExist else { throw NSFileProviderError(.filenameCollision) }
            return existing
        }
        if try await prefixExists(key, client: client) {
            // 远端已有同名文件夹：系统重新导入时直接合并，否则让系统给本地文件夹改名
            guard mayAlreadyExist else { throw NSFileProviderError(.filenameCollision) }
        } else {
            logger.info("创建文件夹 \(key, privacy: .public)")
            try await client.putObject(key: key, data: Data())
        }
        return await store.recordLocalUpsert(key: key, size: 0, etag: nil, modified: Date())
    }

    private static func createFile(
        from url: URL,
        key: String,
        mayAlreadyExist: Bool,
        client: S3Client,
        store: SyncStore,
        progress: Progress
    ) async throws -> SyncItem {
        // 同名对象已存在时不覆盖：返回冲突，系统会把本地文件改名（如「a 2.txt」）后重新创建
        if !mayAlreadyExist, try await objectExists(key, client: client, store: store) {
            throw NSFileProviderError(.filenameCollision)
        }
        return try await upload(from: url, key: key, client: client, store: store, progress: progress)
    }

    // MARK: - 修改、改名、移动

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let identifier = item.itemIdentifier
        let newParent = item.parentItemIdentifier
        let filename = item.filename
        let movesItem = changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier)
        let contents = changedFields.contains(.contents) ? newContents : nil
        let done = Unchecked(completionHandler)
        let registry = registry
        let task = Task {
            var eventID: UUID?
            do {
                guard let (context, storeID) = await Self.resolve(identifier, in: registry),
                      var result = await context.store.item(id: storeID) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                if movesItem {
                    // 存储桶文件夹不能在 Finder 里改名或移动；条目不能移到 CooperDrive 根目录或别的存储桶。
                    // 返回原来的状态，系统会把它放回原处
                    let target = await Self.resolve(newParent, in: registry)
                    guard storeID != DriveIdentifier.storeRootID, let (targetContext, parentStoreID) = target, targetContext.id == context.id else {
                        logger.info("拒绝把 \(identifier.rawValue, privacy: .public) 移出所在的存储桶")
                        done.value(context.make(result), [], false, nil)
                        let message = storeID == DriveIdentifier.storeRootID ? "存储桶文件夹要在 Cooper 里改名" : "不能移到其他存储桶，已放回原处"
                        let rejected = await Self.activity.begin(ActivityDraft(.move, connectionID: context.id, key: result.record.key, itemID: storeID))
                        await Self.activity.finish(rejected, status: .failed(message))
                        return
                    }
                    let parentKey = await context.store.key(forID: parentStoreID)
                    let oldKey = result.record.key
                    let newKey = parentKey + filename + (result.record.isFolder ? "/" : "")
                    if newKey != oldKey {
                        let action: ActivityAction = S3Path.parent(of: newKey) == S3Path.parent(of: oldKey) ? .rename : .move
                        eventID = await Self.activity.begin(ActivityDraft(action, connectionID: context.id, key: newKey, itemID: storeID, previousKey: oldKey))
                        guard let client = context.client else { throw NSFileProviderError(.notAuthenticated) }
                        result = try await Self.move(result, to: newKey, newContents: contents, client: client, store: context.store, progress: progress)
                        progress.completedUnitCount = progress.totalUnitCount
                        done.value(context.make(result), [], false, nil)
                        await Self.recordDone(eventID, item: result)
                        return
                    }
                }

                if let contents {
                    eventID = await Self.activity.begin(ActivityDraft(.update, connectionID: context.id, key: result.record.key, itemID: storeID, size: Self.fileSize(contents)))
                    guard let client = context.client else { throw NSFileProviderError(.notAuthenticated) }
                    // 同时被别处修改时以这次保存为准（后写入的覆盖先写入的）
                    result = try await Self.upload(from: contents, key: result.record.key, client: client, store: context.store, progress: progress)
                }
                // 只改了修改时间、标签等元数据时 S3 不保存，直接返回当前状态
                progress.completedUnitCount = progress.totalUnitCount
                done.value(context.make(result), [], false, nil)
                await Self.recordDone(eventID, item: result)
            } catch {
                logger.error("修改 \(identifier.rawValue, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
                done.value(nil, [], false, Self.fileProviderError(from: error))
                await Self.recordFailure(eventID, error: error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// S3 没有改名操作：复制到新 key 再删除旧的。文件夹要处理前缀下的每个对象。
    private static func move(
        _ item: SyncItem,
        to newKey: String,
        newContents: URL?,
        client: S3Client,
        store: SyncStore,
        progress: Progress
    ) async throws -> SyncItem {
        let oldKey = item.record.key
        logger.info("移动 \(oldKey, privacy: .public) → \(newKey, privacy: .public)")

        if item.record.isFolder {
            var targetExists = await store.liveItem(forKey: newKey) != nil
            if !targetExists {
                targetExists = try await prefixExists(newKey, client: client)
            }
            if targetExists {
                throw NSFileProviderError(.filenameCollision)
            }
            try await client.moveFolder(from: oldKey, to: newKey, progress: progress)
            guard let moved = await store.recordLocalMove(id: item.record.id, toKey: newKey) else {
                throw NSFileProviderError(.noSuchItem)
            }
            return moved
        }

        if try await objectExists(newKey, client: client, store: store) {
            throw NSFileProviderError(.filenameCollision)
        }
        var size = item.record.size
        let etag: String?
        if let newContents {
            etag = try await client.uploadFile(key: newKey, fileURL: newContents, contentType: mimeType(for: newKey), progress: progress)
            size = fileSize(newContents)
        } else {
            etag = try await client.copyObject(from: oldKey, to: newKey, size: size)
        }
        try await client.deleteObject(key: oldKey)
        await store.recordLocalMove(id: item.record.id, toKey: newKey)
        return await store.recordLocalUpsert(key: newKey, size: size, etag: etag ?? item.record.etag, modified: Date())
    }

    // MARK: - 删除

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let recursive = options.contains(.recursive)
        let done = Unchecked(completionHandler)
        let registry = registry
        let task = Task {
            var eventID: UUID?
            do {
                guard let (context, storeID) = await Self.resolve(identifier, in: registry) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let key = await context.store.key(forID: storeID)
                eventID = await Self.activity.begin(ActivityDraft(.delete, connectionID: context.id, key: key, itemID: storeID))
                // 存储桶文件夹要在 App 里移除连接，不能在 Finder 里删
                guard storeID != DriveIdentifier.storeRootID else { throw NSFileProviderError(.deletionRejected) }
                guard let client = context.client else { throw NSFileProviderError(.notAuthenticated) }

                if S3Path.isFolder(key) {
                    let objects = try await client.listAllObjects(prefix: key)
                    if !recursive && objects.contains(where: { $0.key != key }) {
                        throw NSFileProviderError(.directoryNotEmpty)
                    }
                    logger.info("删除文件夹 \(key, privacy: .public)（\(objects.count) 个对象）")
                    try await client.deleteObjects(keys: objects.map(\.key))
                } else {
                    try await client.deleteObject(key: key)
                }
                await context.store.recordLocalDelete(id: storeID)
                progress.completedUnitCount = 1
                done.value(nil)
                if let eventID { await Self.activity.finish(eventID, status: .done) }
            } catch {
                logger.error("删除 \(identifier.rawValue, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
                done.value(Self.fileProviderError(from: error))
                await Self.recordFailure(eventID, error: error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: - 操作记录

    /// 记下完成，补上新建时才知道的条目标识和最终大小
    private static func recordDone(_ eventID: UUID?, item: SyncItem) async {
        guard let eventID else { return }
        await activity.finish(eventID, status: .done, itemID: item.record.id, size: item.record.isFolder ? nil : item.record.size)
    }

    private static func recordFailure(_ eventID: UUID?, error: Error) async {
        guard let eventID else { return }
        await activity.fail(eventID, error: error)
    }

    // MARK: - 工具

    private static func upload(from url: URL, key: String, client: S3Client, store: SyncStore, progress: Progress) async throws -> SyncItem {
        logger.info("上传 \(key, privacy: .public)")
        let etag = try await client.uploadFile(key: key, fileURL: url, contentType: mimeType(for: key), progress: progress)
        return await store.recordLocalUpsert(key: key, size: fileSize(url), etag: etag, modified: Date())
    }

    private static func objectExists(_ key: String, client: S3Client, store: SyncStore) async throws -> Bool {
        if await store.liveItem(forKey: key) != nil { return true }
        do {
            _ = try await client.headObject(key: key)
            return true
        } catch let error as S3Error where error.statusCode == 404 {
            return false
        }
    }

    private static func prefixExists(_ prefix: String, client: S3Client) async throws -> Bool {
        let page = try await client.listObjects(prefix: prefix, maxKeys: 1)
        return !page.objects.isEmpty || !page.commonPrefixes.isEmpty
    }

    private static func mimeType(for key: String) -> String? {
        UTType(filenameExtension: (key as NSString).pathExtension)?.preferredMIMEType
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func fileProviderError(from error: Error) -> Error {
        if let s3Error = error as? S3Error, let status = s3Error.statusCode {
            switch status {
            case 401, 403: return NSFileProviderError(.notAuthenticated)
            case 404: return NSFileProviderError(.noSuchItem)
            default: return NSFileProviderError(.serverUnreachable)
            }
        }
        if error is S3Error {
            return NSFileProviderError(.serverUnreachable)
        }
        if error is CancellationError {
            return CocoaError(.userCancelled)
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CocoaError(.userCancelled) : NSFileProviderError(.serverUnreachable)
        }
        return error
    }
}
