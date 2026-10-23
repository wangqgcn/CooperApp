import AppKit
import CryptoKit
import Foundation
import QuickLookThumbnailing
import S3Kit
import UniformTypeIdentifiers

/// 预览和缩略图共用的本地缓存：同一个对象版本（ETag 相同）只下载一次。
enum PreviewCache {
    static func file(for item: BrowserItem, connectionID: String, client: S3Client) async throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Preview", isDirectory: true)
        let digest = SHA256.hash(data: Data("\(connectionID)|\(item.key)|\(item.etag ?? "")".utf8))
        let folder = caches.appendingPathComponent(digest.prefix(8).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
        let file = folder.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 下载先写临时文件，成功后才移到这里，所以存在的文件一定是完整的
        try await client.downloadFile(key: item.key, to: file, progress: Progress(totalUnitCount: max(item.size, 1)))
        return file
    }
}

/// 网格视图的缩略图。只给 20 MB 以内的图片和 PDF 生成（需要先下载），其余显示系统图标。
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    static let maxFileSize: Int64 = 20 * 1024 * 1024
    private static let maxConcurrent = 4

    private let cache = NSCache<NSString, NSImage>()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    static func supportsThumbnail(_ item: BrowserItem) -> Bool {
        guard !item.isFolder, item.size > 0, item.size <= maxFileSize,
              let type = UTType(filenameExtension: (item.name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    func thumbnail(for item: BrowserItem, connectionID: String, client: S3Client) async -> NSImage? {
        guard Self.supportsThumbnail(item) else { return nil }
        let key = "\(connectionID)|\(item.key)|\(item.etag ?? "")" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        await acquire()
        defer { release() }
        // 等待期间格子可能已经滚出屏幕
        guard !Task.isCancelled else { return nil }
        guard let rendered = try? await Self.render(item, connectionID: connectionID, client: client) else { return nil }
        cache.setObject(rendered.image, forKey: key)
        return rendered.image
    }

    /// 同时最多生成 maxConcurrent 张，避免一屏图片同时下载
    private func acquire() async {
        if running < Self.maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// NSImage 生成后不再修改，可以安全地交回主线程
    private struct RenderedImage: @unchecked Sendable {
        let image: NSImage
    }

    nonisolated private static func render(_ item: BrowserItem, connectionID: String, client: S3Client) async throws -> RenderedImage {
        let file = try await PreviewCache.file(for: item, connectionID: connectionID, client: client)
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 144, height: 144), scale: 2, representationTypes: .thumbnail)
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return RenderedImage(image: representation.nsImage)
    }
}
