import FileProvider
import SyncCore
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let documentSize: NSNumber?
    let contentModificationDate: Date?

    /// CooperDrive 根目录：下面只有存储桶文件夹，不能直接放文件
    private static let rootCapabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsContentEnumerating]
    /// 存储桶文件夹：可以往里放东西，但不能在 Finder 里改名、移动或删除（到 App 里管理连接）
    private static let bucketCapabilities: NSFileProviderItemCapabilities = rootCapabilities.union(.allowsAddingSubItems)
    private static let folderCapabilities: NSFileProviderItemCapabilities = bucketCapabilities.union([.allowsRenaming, .allowsReparenting, .allowsDeleting])
    private static let fileCapabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]

    private init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        capabilities: NSFileProviderItemCapabilities,
        contentVersion: String,
        metadataVersion: String,
        size: Int64? = nil,
        modified: Date?
    ) {
        itemIdentifier = identifier
        parentItemIdentifier = parent
        self.filename = filename
        self.contentType = contentType
        self.capabilities = capabilities
        itemVersion = NSFileProviderItemVersion(contentVersion: Data(contentVersion.utf8), metadataVersion: Data(metadataVersion.utf8))
        documentSize = size.map { NSNumber(value: $0) }
        contentModificationDate = modified
        super.init()
    }

    static func root() -> FileProviderItem {
        FileProviderItem(
            identifier: .rootContainer,
            parent: .rootContainer,
            filename: CooperDrive.displayName,
            contentType: .folder,
            capabilities: rootCapabilities,
            contentVersion: "root",
            metadataVersion: "root",
            modified: nil
        )
    }

    /// 存储桶文件夹。改名（在 App 里改连接名）和日期变化都体现在元数据版本里
    static func bucket(identifier: NSFileProviderItemIdentifier, name: String, record: ItemRecord?) -> FileProviderItem {
        let modified = record.map { $0.modified ?? $0.firstSeen }
        let stamp = modified.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return FileProviderItem(
            identifier: identifier,
            parent: .rootContainer,
            filename: name,
            contentType: .folder,
            capabilities: bucketCapabilities,
            contentVersion: "bucket",
            metadataVersion: "bucket-\(name)-\(stamp)",
            modified: modified
        )
    }

    static func item(_ record: ItemRecord, identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier) -> FileProviderItem {
        // 文件夹在 S3 里没有时间，还不知道最新子项的时间时用首次见到的时间，不让 Finder 显示 1970 年
        let modified = record.modified ?? record.firstSeen
        if record.isFolder {
            // 文件夹没有内容版本，日期变化体现在元数据版本里
            let stamp = record.modified.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
            return FileProviderItem(
                identifier: identifier,
                parent: parent,
                filename: record.name,
                contentType: .folder,
                capabilities: folderCapabilities,
                contentVersion: "folder",
                metadataVersion: "folder-\(stamp)",
                modified: modified
            )
        }
        // S3 只提供 ETag 一个版本号，内容版本和元数据版本共用
        let version = record.etag ?? "\(record.size)-\(record.modified?.timeIntervalSince1970 ?? 0)"
        return FileProviderItem(
            identifier: identifier,
            parent: parent,
            filename: record.name,
            contentType: UTType(filenameExtension: (record.name as NSString).pathExtension) ?? .data,
            capabilities: fileCapabilities,
            contentVersion: version,
            metadataVersion: version,
            size: record.size,
            modified: modified
        )
    }
}
