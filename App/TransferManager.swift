import Foundation
import Observation
import S3Kit
import SyncCore
import UniformTypeIdentifiers

/// 一次上传或下载（一个文件或一整个文件夹）。
@MainActor
@Observable
final class Transfer: Identifiable {
    enum Direction: Sendable {
        case upload, download
    }

    enum State: Equatable {
        case running, completed, cancelled
        case failed(String)
    }

    let id = UUID()
    let direction: Direction
    let name: String
    /// 存储桶和所在文件夹，如「R2 / photos/」
    let location: String
    /// 单位是字节
    let progress = Progress(totalUnitCount: 1)
    var state: State = .running
    /// 下载完成后的本地位置
    var localURL: URL?
    @ObservationIgnored var task: Task<Void, Never>?

    init(direction: Direction, name: String, location: String) {
        self.direction = direction
        self.name = name
        self.location = location
    }

    func cancel() {
        task?.cancel()
    }
}

/// 管理所有上传、下载任务。下载默认存到「下载」文件夹。
@MainActor
@Observable
final class TransferManager {
    private(set) var transfers: [Transfer] = []
    /// 上传结束（无论成败）后调用，参数是连接 id
    @ObservationIgnored var onUploadFinished: ((String) -> Void)?
    /// 上传记进菜单栏的操作记录；下载不改变存储桶，不记录
    @ObservationIgnored var activity: ActivityRecorder?

    private static let fileConcurrency = 4

    var activeCount: Int {
        transfers.filter { $0.state == .running }.count
    }

    var hasFinished: Bool {
        transfers.contains { $0.state != .running }
    }

    func clearFinished() {
        transfers.removeAll { $0.state != .running }
    }

    func upload(_ urls: [URL], to prefix: String, connectionID: String, folderName: String, client: S3Client) {
        for url in urls {
            let transfer = Transfer(direction: .upload, name: url.lastPathComponent, location: "\(folderName) / \(prefix)")
            let progress = transfer.progress
            let recorder = activity
            start(transfer) {
                // 通过「上传」面板选择的文件带安全作用域，读取前要申请访问
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let key = prefix + url.lastPathComponent + (isFolder ? "/" : "")
                let eventID = await recorder?.begin(ActivityDraft(.upload, connectionID: connectionID, key: key))
                do {
                    let uploaded = try await Self.upload(url, to: prefix, client: client, progress: progress)
                    if let eventID {
                        await recorder?.finish(eventID, status: .done, size: uploaded.size, fileCount: isFolder ? uploaded.files : nil)
                    }
                } catch {
                    if let eventID {
                        let message = ActivityFailure.message(for: error)
                        await recorder?.finish(eventID, status: message.map { .failed($0) } ?? .cancelled)
                    }
                    throw error
                }
                return nil
            } finished: { [weak self] in
                self?.onUploadFinished?(connectionID)
            }
        }
    }

    func download(_ items: [BrowserItem], folderName: String, client: S3Client) {
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        for item in items {
            let transfer = Transfer(direction: .download, name: item.name, location: "\(folderName) / \(S3Path.parent(of: item.key))")
            let progress = transfer.progress
            start(transfer) {
                try await Self.download(item, to: directory, client: client, progress: progress)
            } finished: {}
        }
    }

    private func start(_ transfer: Transfer, _ work: @escaping @Sendable () async throws -> URL?, finished: @escaping () -> Void) {
        transfers.insert(transfer, at: 0)
        transfer.task = Task {
            do {
                transfer.localURL = try await work()
                transfer.state = .completed
            } catch {
                transfer.state = Task.isCancelled || Self.isCancellation(error) ? .cancelled : .failed(error.localizedDescription)
            }
            finished()
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || (error as? CocoaError)?.code == .userCancelled
    }

    // MARK: - 上传

    /// 返回上传的总大小和文件数
    nonisolated private static func upload(_ url: URL, to prefix: String, client: S3Client, progress: Progress) async throws -> (size: Int64, files: Int) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory == true else {
            try await client.uploadFile(key: prefix + url.lastPathComponent, fileURL: url, contentType: mimeType(url.lastPathComponent), progress: progress)
            return (Int64(values.fileSize ?? 0), 1)
        }

        // 文件夹：保留目录结构，每个子文件夹都建占位对象，空文件夹也能保留
        let scan = try scanFolder(url, rootKey: prefix + url.lastPathComponent + "/")
        progress.totalUnitCount = max(scan.files.reduce(0) { $0 + $1.size }, 1)
        try await forEachConcurrently(scan.folders, limit: fileConcurrency) { key in
            try await client.putObject(key: key, data: Data())
        } onResult: { _ in }
        try await forEachConcurrently(scan.files, limit: fileConcurrency) { file in
            let child = Progress(totalUnitCount: max(file.size, 1))
            progress.addChild(child, withPendingUnitCount: file.size)
            try await client.uploadFile(key: file.key, fileURL: file.url, contentType: mimeType(file.url.lastPathComponent), progress: child)
        } onResult: { _ in }
        return (scan.files.reduce(0) { $0 + $1.size }, scan.files.count)
    }

    private struct FolderScan {
        var folders: [String]
        var files: [(url: URL, key: String, size: Int64)]
    }

    /// 列出本地文件夹里要上传的内容。跳过符号链接和 Finder 的系统文件。
    nonisolated private static func scanFolder(_ url: URL, rootKey: String) throws -> FolderScan {
        var scan = FolderScan(folders: [rootKey], files: [])
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            throw CocoaError(.fileReadUnknown)
        }
        var basePath = url.path(percentEncoded: false)
        if !basePath.hasSuffix("/") { basePath += "/" }

        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            let isDirectory = values.isDirectory == true
            if SyncExclusion.isExcluded(item.lastPathComponent) || values.isSymbolicLink == true {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            var path = item.path(percentEncoded: false)
            guard path.hasPrefix(basePath) else { continue }
            if path.hasSuffix("/") { path.removeLast() }
            let relative = String(path.dropFirst(basePath.count))
            if isDirectory {
                scan.folders.append(rootKey + relative + "/")
            } else {
                scan.files.append((item, rootKey + relative, Int64(values.fileSize ?? 0)))
            }
        }
        return scan
    }

    // MARK: - 下载

    nonisolated private static func download(_ item: BrowserItem, to directory: URL, client: S3Client, progress: Progress) async throws -> URL {
        if !item.isFolder {
            let destination = uniqueURL(directory.appendingPathComponent(item.name))
            progress.totalUnitCount = max(item.size, 1)
            try await client.downloadFile(key: item.key, to: destination, progress: progress)
            return destination
        }

        let root = uniqueURL(directory.appendingPathComponent(item.name, isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        var jobs: [(key: String, target: URL, size: Int64)] = []
        for object in try await client.listAllObjects(prefix: item.key) {
            let relative = String(object.key.dropFirst(item.key.count))
            guard !relative.isEmpty else { continue }
            let target = root.appendingPathComponent(relative).standardizedFileURL
            // key 里带「..」时可能跳出目标文件夹，跳过这种对象
            guard target.path(percentEncoded: false).hasPrefix(rootPath) else { continue }
            if relative.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                jobs.append((object.key, target, object.size))
            }
        }

        progress.totalUnitCount = max(jobs.reduce(0) { $0 + $1.size }, 1)
        try await forEachConcurrently(jobs, limit: fileConcurrency) { job in
            try FileManager.default.createDirectory(at: job.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let child = Progress(totalUnitCount: max(job.size, 1))
            progress.addChild(child, withPendingUnitCount: job.size)
            try await client.downloadFile(key: job.key, to: job.target, progress: child)
        } onResult: { _ in }
        return root
    }

    /// 同名文件已存在时加序号：「a.txt」→「a 2.txt」
    nonisolated private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            number += 1
        }
    }

    nonisolated private static func mimeType(_ name: String) -> String? {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
    }
}
