import AppKit
import FileProvider
import SyncCore

/// 管理唯一的 CooperDrive 挂载：Finder 侧栏「位置」里的一个入口，每个存储桶是其中一个子文件夹。
enum MountManager {
    static func makeDomain() -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: CooperDrive.domainID), displayName: CooperDrive.displayName)
    }

    private static func manager() throws -> NSFileProviderManager {
        guard let manager = NSFileProviderManager(for: makeDomain()) else {
            throw NSFileProviderError(.providerNotFound)
        }
        return manager
    }

    static func isMounted() async -> Bool {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return domains.contains { $0.identifier.rawValue == CooperDrive.domainID }
    }

    /// 旧版本每个存储桶单独挂载（标识是连接 id）。全部移除，返回移除的个数。
    /// 本机缓存的文件会被清掉，存储桶里的数据不受影响。
    @discardableResult
    static func removeLegacyDomains() async throws -> Int {
        let legacy = try await NSFileProviderManager.domains().filter { $0.identifier.rawValue != CooperDrive.domainID }
        for domain in legacy {
            try await NSFileProviderManager.remove(domain)
        }
        if !legacy.isEmpty {
            SyncStateLocation.removeAll()
        }
        return legacy.count
    }

    /// 已经挂载时什么也不做。
    static func mount() async throws {
        guard await !isMounted() else { return }
        // 新挂载从头开始，旧的同步记录作废
        SyncStateLocation.removeAll()
        try await NSFileProviderManager.add(makeDomain())
    }

    static func unmount() async throws {
        try await NSFileProviderManager.remove(makeDomain())
        SyncStateLocation.removeAll()
    }

    /// 打开 CooperDrive；给了连接 id 就直接打开那个存储桶的文件夹，系统还不认识它时退回根目录
    static func openInFinder(connectionID: String? = nil) async throws {
        let manager = try manager()
        var url = try await manager.getUserVisibleURL(for: .rootContainer)
        if let connectionID, let bucketURL = try? await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(connectionID)) {
            url = bucketURL
        }
        // 返回的地址带安全作用域：沙盒里的主程序要先申请访问，否则系统会提示没有权限打开。
        // 等 Finder 接手之后再释放
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 在 Finder 里选中一个条目。itemID 是扩展 SyncStore 里的标识；主窗口里的操作没有，用 key 代替（默认标识就是 key）。
    /// 找不到时（比如后来被改名或删除了）退回打开上级文件夹，再不行打开存储桶文件夹
    static func reveal(connectionID: String, itemID: String?, key: String) async throws {
        let manager = try manager()
        var candidates: [(DriveIdentifier, select: Bool)] = []
        if !key.isEmpty {
            candidates.append((.forStoreID(itemID ?? key, connectionID: connectionID), true))
            let parent = S3Path.parent(of: key)
            if !parent.isEmpty {
                candidates.append((.forStoreID(parent, connectionID: connectionID), false))
            }
        }
        candidates.append((.bucket(connectionID: connectionID), key.isEmpty))

        for candidate in candidates {
            let identifier = NSFileProviderItemIdentifier(candidate.0.rawValue)
            guard let url = try? await manager.getUserVisibleURL(for: identifier) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            if candidate.select {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        throw NSFileProviderError(.noSuchItem)
    }

    /// Finder 一侧进行中的上传或下载的总进度。系统在主线程更新它，调用方要一直持有
    static func globalProgress(for kind: Progress.FileOperationKind) -> Progress? {
        NSFileProviderManager(for: makeDomain())?.globalProgress(for: kind)
    }

    /// 立即检查这些存储桶里所有打开过的文件夹，不等各自的轮询间隔。
    static func refresh(connectionIDs: [String]) async throws {
        for id in connectionIDs {
            RefreshRequest.request(connectionID: id)
        }
        try await signalChanges()
    }

    /// 通知系统查询工作集变化。扩展会被唤醒，重新读取连接配置，并顺带轮询到期的文件夹。
    static func signalChanges() async throws {
        try await manager().signalEnumerator(for: .workingSet)
    }
}
