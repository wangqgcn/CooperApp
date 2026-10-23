import FileProvider
import S3Kit
import SyncCore

/// 一个存储桶在扩展里的运行时：连接、客户端、同步记录和轮询。
struct BucketContext: Sendable {
    let connection: Connection
    /// 在 CooperDrive 根目录下显示的文件夹名
    let folderName: String
    /// 钥匙串里没有密钥时为 nil
    let client: S3Client?
    let store: SyncStore
    let remoteSync: RemoteSync?

    var id: String { connection.id }

    func identifier(forStoreID storeID: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(DriveIdentifier.forStoreID(storeID, connectionID: id).rawValue)
    }

    func make(_ item: SyncItem) -> FileProviderItem {
        if item.record.id == DriveIdentifier.storeRootID {
            return .bucket(identifier: identifier(forStoreID: item.record.id), name: folderName, record: item.record)
        }
        return .item(item.record, identifier: identifier(forStoreID: item.record.id), parent: identifier(forStoreID: item.parentID))
    }

    /// 存储桶文件夹本身
    func bucketItem() async -> FileProviderItem {
        let root = await store.item(id: DriveIdentifier.storeRootID)
        return .bucket(identifier: identifier(forStoreID: DriveIdentifier.storeRootID), name: folderName, record: root?.record)
    }
}

/// 按连接配置文件维护各存储桶的运行时。配置文件变了（主程序增删改了连接）就重新加载；
/// 连接配置不变的存储桶沿用原来的同步记录，只有密钥变了时换新的客户端。
actor BucketRegistry {
    private struct Entry {
        var context: BucketContext
        var credentials: S3Credentials?
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var loadedModificationDate: Date?
    private var hasLoaded = false

    func all() -> [BucketContext] {
        reloadIfNeeded()
        return order.compactMap { entries[$0]?.context }
    }

    func context(for connectionID: String) -> BucketContext? {
        reloadIfNeeded()
        return entries[connectionID]?.context
    }

    private func reloadIfNeeded() {
        let url = try? ConnectionStore.fileURL()
        let modified = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        guard !hasLoaded || modified != loadedModificationDate else { return }

        let connections: [Connection]
        do {
            connections = try ConnectionStore.loadAll()
        } catch {
            logger.error("读取连接配置失败：\(error.localizedDescription, privacy: .public)")
            return
        }
        hasLoaded = true
        loadedModificationDate = modified

        let names = DriveNaming.folderNames(connections.map { ($0.id, $0.name) })
        var next: [String: Entry] = [:]
        for connection in connections {
            let credentials = (try? CredentialStore.load(for: connection.id)) ?? nil
            if credentials == nil {
                logger.error("钥匙串里没有连接 \(connection.id, privacy: .public) 的密钥")
            }
            let old = entries[connection.id]
            let sameBucket = old?.context.connection.config == connection.config

            let store = sameBucket ? old!.context.store : SyncStore(
                fileURL: SyncStateLocation.url(forConnection: connection.id),
                rootID: DriveIdentifier.storeRootID,
                scope: "\(connection.config.endpoint.absoluteString)|\(connection.config.bucket)"
            )
            var client = old?.context.client
            var remoteSync = old?.context.remoteSync
            if !sameBucket || old?.credentials != credentials {
                client = credentials.map { S3Client(config: connection.config, credentials: $0) }
                remoteSync = client.map { RemoteSync(client: $0, store: store, connectionID: connection.id) }
            }

            let context = BucketContext(
                connection: connection,
                folderName: names[connection.id] ?? connection.name,
                client: client,
                store: store,
                remoteSync: remoteSync
            )
            next[connection.id] = Entry(context: context, credentials: credentials)
        }
        entries = next
        order = connections.map(\.id)
        logger.info("已加载 \(connections.count) 个存储桶")
    }
}
