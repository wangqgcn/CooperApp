import Foundation
import S3Kit
import Testing
@testable import SyncCore

struct FileCategoryTests {
    @Test func classifiesCommonExtensions() {
        #expect(FileCategory.of(key: "a/photo.JPG") == .image)
        #expect(FileCategory.of(key: "clip.mp4") == .video)
        #expect(FileCategory.of(key: "song.mp3") == .audio)
        #expect(FileCategory.of(key: "docs/report.pdf") == .document)
        #expect(FileCategory.of(key: "notes.md") == .document)
        #expect(FileCategory.of(key: "api/openapi.json") == .code)
        #expect(FileCategory.of(key: "main.swift") == .code)
        #expect(FileCategory.of(key: "deploy.sh") == .code)
        #expect(FileCategory.of(key: "backup.zip") == .archive)
        #expect(FileCategory.of(key: "data.zzunknown") == .other)
        #expect(FileCategory.of(key: "Makefile") == .other)
    }
}

struct StorageSummaryTests {
    private func object(_ key: String, _ size: Int64) -> S3Object {
        S3Object(key: key, size: size)
    }

    @Test func aggregatesByFolderAndCategoryAcrossPages() {
        var summary = StorageSummary()
        summary.add([object("photos/", 0), object("photos/a.jpg", 300), object("photos/2025/b.png", 200)])
        summary.add([object("readme.md", 50), object("backups/db.zip", 1000)])

        #expect(summary.objectCount == 4)
        #expect(summary.totalBytes == 1550)
        #expect(summary.topFolderCount == 2)

        let folders = summary.folderGroups()
        #expect(folders.map(\.label) == ["backups", "photos", "根目录下的文件"])
        #expect(folders.map(\.bytes) == [1000, 500, 50])
        #expect(folders[1].count == 2)

        let categories = summary.categoryGroups()
        #expect(categories.map(\.label) == ["压缩包", "图片", "文档"])
        #expect(categories.map(\.bytes) == [1000, 500, 50])
    }

    @Test func foldsSmallFoldersIntoOneGroup() {
        var summary = StorageSummary()
        summary.add((1...10).map { object("f\($0)/x.bin", Int64($0 * 100)) })
        let groups = summary.folderGroups(limit: 4)
        #expect(groups.count == 4)
        #expect(groups.prefix(3).map(\.label) == ["f10", "f9", "f8"])
        #expect(groups.last?.label == "其余 7 项")
        #expect(groups.last?.bytes == (1...7).reduce(0) { $0 + Int64($1 * 100) })
        #expect(groups.last?.count == 7)
    }

    @Test func keepsTenLargestInOrder() {
        var summary = StorageSummary()
        summary.add((1...25).shuffled().map { object("k\($0)", Int64($0)) })
        #expect(summary.largest.map(\.size) == Array((16...25).reversed()).map(Int64.init))
    }
}
