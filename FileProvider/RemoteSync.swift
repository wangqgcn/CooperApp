import Foundation
import S3Kit
import SyncCore

/// 轮询远端变化。S3 没有变更通知，只能定期重新列举打开过的文件夹，
/// 每个文件夹的间隔由 SyncStore 按变化频率在 1–15 分钟之间调整。
actor RemoteSync {
    private let client: S3Client
    private let store: SyncStore
    private let connectionID: String
    private var isPolling = false
    private var lastPoll = Date.distantPast
    /// 系统可能连续查询变化，两次轮询之间至少隔这么久
    private static let minimumGap: TimeInterval = 15

    init(client: S3Client, store: SyncStore, connectionID: String) {
        self.client = client
        self.store = store
        self.connectionID = connectionID
    }

    /// 轮询到期的文件夹（主程序请求刷新时轮询全部），返回是否发现了变化。
    @discardableResult
    func pollIfNeeded() async -> Bool {
        let force = RefreshRequest.consume(connectionID: connectionID)
        guard !isPolling, force || Date().timeIntervalSince(lastPoll) >= Self.minimumGap else { return false }
        isPolling = true
        defer {
            isPolling = false
            lastPoll = Date()
        }

        let startedAt = Date()
        var changed = false
        for target in await store.foldersDueForPoll(now: startedAt, force: force) {
            // 上级文件夹的轮询结果可能已经把它删掉了
            guard await store.isLive(id: target.id) else { continue }
            do {
                let listing = try await client.listFolder(prefix: target.key)
                let folderChanged = await store.applyPoll(
                    folderID: target.id,
                    listedKey: target.key,
                    objects: listing.objects,
                    folderPrefixes: listing.folderPrefixes,
                    startedAt: startedAt
                )
                changed = changed || folderChanged
            } catch {
                // 断网或密钥失效时其余文件夹也会失败，等下一轮
                logger.error("轮询 \(target.key, privacy: .public) 失败：\(error.localizedDescription, privacy: .public)")
                break
            }
        }
        if changed {
            logger.info("轮询发现远端变化")
        }
        return changed
    }
}
