import Foundation
import S3Kit
import UniformTypeIdentifiers

/// 按扩展名粗分的文件类型，用于存储占用统计。
public enum FileCategory: String, CaseIterable, Sendable {
    case image = "图片"
    case video = "视频"
    case audio = "音频"
    case document = "文档"
    case code = "代码"
    case archive = "压缩包"
    case other = "其他"

    public static func of(key: String) -> FileCategory {
        let ext = (S3Path.name(of: key) as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        // 源代码和 JSON、XML 也是文本，要先于文档判断
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .yaml) || type.conforms(to: .html) {
            return .code
        }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) {
            return .document
        }
        return .other
    }
}

/// 一个存储桶的占用统计。一页一页地加入列举结果，不需要一次拿到全部对象。
public struct StorageSummary: Equatable, Sendable {
    public struct Group: Identifiable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var bytes: Int64
        public var count: Int
    }

    public static let largestLimit = 10

    public private(set) var objectCount = 0
    public private(set) var totalBytes: Int64 = 0
    /// 从大到小，最多 largestLimit 个
    public private(set) var largest: [S3Object] = []
    /// 按顶层文件夹（"photos/"）汇总，根目录下的文件归在 ""
    private var folders: [String: Group] = [:]
    private var categories: [FileCategory: Group] = [:]

    public init() {}

    public mutating func add(_ objects: [S3Object]) {
        // 以 "/" 结尾的是文件夹占位对象，不算文件
        for object in objects where !object.key.hasSuffix("/") {
            objectCount += 1
            totalBytes += object.size

            let top = object.key.firstIndex(of: "/").map { String(object.key[...$0]) } ?? ""
            let folderLabel = top.isEmpty ? "根目录下的文件" : String(top.dropLast())
            folders[top, default: Group(id: top, label: folderLabel, bytes: 0, count: 0)].bytes += object.size
            folders[top]!.count += 1

            let category = FileCategory.of(key: object.key)
            categories[category, default: Group(id: category.rawValue, label: category.rawValue, bytes: 0, count: 0)].bytes += object.size
            categories[category]!.count += 1

            if largest.count < Self.largestLimit || object.size > largest.last!.size {
                let index = largest.firstIndex { $0.size < object.size } ?? largest.endIndex
                largest.insert(object, at: index)
                if largest.count > Self.largestLimit { largest.removeLast() }
            }
        }
    }

    public var topFolderCount: Int {
        folders.keys.filter { !$0.isEmpty }.count
    }

    /// 按占用从大到小的顶层文件夹，超过 limit 的部分合并成一项
    public func folderGroups(limit: Int = 8) -> [Group] {
        let sorted = folders.values.sorted { $0.bytes == $1.bytes ? $0.label < $1.label : $0.bytes > $1.bytes }
        guard sorted.count > limit else { return sorted }
        let rest = sorted.dropFirst(limit - 1)
        let merged = Group(
            id: "\u{0}rest",
            label: "其余 \(rest.count) 项",
            bytes: rest.reduce(0) { $0 + $1.bytes },
            count: rest.reduce(0) { $0 + $1.count }
        )
        return Array(sorted.prefix(limit - 1)) + [merged]
    }

    /// 按占用从大到小的文件类型，只包含有文件的类型
    public func categoryGroups() -> [Group] {
        categories.values.sorted { $0.bytes == $1.bytes ? $0.label < $1.label : $0.bytes > $1.bytes }
    }
}
