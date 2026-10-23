import Foundation
import S3Kit
import Testing
@testable import SyncCore

private let root = "ROOT"
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func file(_ key: String, etag: String = "e1", size: Int64 = 10, at date: Date = t0) -> S3Object {
    S3Object(key: key, size: size, lastModified: date, etag: etag)
}

private func makeStore(fileURL: URL? = nil, scope: String = "r2|media") -> SyncStore {
    SyncStore(fileURL: fileURL, rootID: root, scope: scope, now: t0)
}

/// 枚举根目录并完成，让根目录进入轮询。
private func listRoot(_ store: SyncStore, objects: [S3Object], prefixes: [String], at date: Date = t0) async {
    _ = await store.recordListed(folderKey: "", objects: objects, folderPrefixes: prefixes, now: date)
    await store.finishListing(
        folderID: root,
        seenKeys: Set(objects.map(\.key) + prefixes),
        newestModified: objects.compactMap(\.lastModified).max(),
        startedAt: date,
        now: date
    )
}

struct SyncStoreIdentityTests {
    @Test func defaultIDsAreKeysAndParentsResolve() async {
        let store = makeStore()
        let items = await store.recordListed(folderKey: "", objects: [file("a.txt")], folderPrefixes: ["docs/"], now: t0)
        #expect(items.map(\.record.id).sorted() == ["a.txt", "docs/"])
        #expect(items.allSatisfy { $0.parentID == root })

        let nested = await store.recordListed(folderKey: "docs/", objects: [file("docs/b.txt")], folderPrefixes: [], now: t0)
        #expect(nested.first?.parentID == "docs/")
        #expect(await store.key(forID: root) == "")
        #expect(await store.key(forID: "unknown/x.txt") == "unknown/x.txt")
    }

    @Test func folderRenameKeepsIDsAndMovesDescendants() async {
        let store = makeStore()
        _ = await store.recordListed(folderKey: "", objects: [], folderPrefixes: ["old/"], now: t0)
        _ = await store.recordListed(folderKey: "old/", objects: [file("old/a.txt")], folderPrefixes: ["old/sub/"], now: t0)
        _ = await store.recordListed(folderKey: "old/sub/", objects: [file("old/sub/b.txt")], folderPrefixes: [], now: t0)

        let moved = await store.recordLocalMove(id: "old/", toKey: "new/", now: t0)
        #expect(moved?.record.id == "old/")
        #expect(moved?.record.key == "new/")
        #expect(await store.key(forID: "old/a.txt") == "new/a.txt")
        #expect(await store.key(forID: "old/sub/b.txt") == "new/sub/b.txt")
        #expect(await store.liveItem(forKey: "new/sub/b.txt")?.parentID == "old/sub/")

        // 旧路径上又出现同名文件夹时，不能和改名后的条目共用标识
        let reused = await store.recordListed(folderKey: "", objects: [], folderPrefixes: ["old/"], now: t0)
        #expect(reused.first?.record.id != "old/")
        #expect(reused.first?.record.key == "old/")
    }
}

struct SyncStorePollTests {
    @Test func reportsAddedChangedAndDeletedItems() async {
        let store = makeStore()
        await listRoot(store, objects: [file("a.txt"), file("b.txt")], prefixes: ["docs/"])
        let anchor = await store.currentAnchor()

        let poll = t0.addingTimeInterval(120)
        let changed = await store.applyPoll(
            folderID: root, listedKey: "",
            objects: [file("a.txt", etag: "e2", size: 20, at: poll), file("c.txt", at: poll)],
            folderPrefixes: [],
            startedAt: poll, now: poll
        )
        #expect(changed)

        guard case .changes(let updated, let deleted, let newAnchor) = await store.changes(since: anchor) else {
            Issue.record("锚点不应失效")
            return
        }
        // 根目录日期也变了
        #expect(Set(updated.map(\.record.id)) == [root, "a.txt", "c.txt"])
        #expect(updated.first { $0.record.id == "a.txt" }?.record.etag == "e2")
        #expect(Set(deleted) == ["b.txt", "docs/"])

        guard case .changes(let none, let noDeletes, _) = await store.changes(since: newAnchor) else {
            Issue.record("锚点不应失效")
            return
        }
        #expect(none.isEmpty && noDeletes.isEmpty)
    }

    @Test func unchangedFolderBacksOffPolling() async {
        let store = makeStore()
        await listRoot(store, objects: [file("a.txt")], prefixes: [])
        #expect(await store.foldersDueForPoll(now: t0.addingTimeInterval(30), force: false).isEmpty)

        var now = t0.addingTimeInterval(SyncStore.minPollInterval)
        #expect(await store.foldersDueForPoll(now: now, force: false).map(\.id) == [root])
        await store.applyPoll(folderID: root, listedKey: "", objects: [file("a.txt")], folderPrefixes: [], startedAt: now, now: now)

        // 没变化：间隔翻倍到 2 分钟
        now = now.addingTimeInterval(SyncStore.minPollInterval)
        #expect(await store.foldersDueForPoll(now: now, force: false).isEmpty)
        #expect(await store.foldersDueForPoll(now: now, force: true).map(\.id) == [root])
    }

    @Test func pollStartedBeforeLocalUploadDoesNotDeleteIt() async {
        let store = makeStore()
        await listRoot(store, objects: [], prefixes: [])
        let anchor = await store.currentAnchor()

        let pollStart = t0.addingTimeInterval(100)
        await store.recordLocalUpsert(key: "new.txt", size: 5, etag: "x", modified: nil, now: pollStart.addingTimeInterval(1))
        await store.applyPoll(folderID: root, listedKey: "", objects: [], folderPrefixes: [], startedAt: pollStart, now: pollStart.addingTimeInterval(2))

        #expect(await store.liveItem(forKey: "new.txt") != nil)
        guard case .changes(_, let deleted, _) = await store.changes(since: anchor) else {
            Issue.record("锚点不应失效")
            return
        }
        #expect(deleted.isEmpty)
    }

    @Test func pollStartedBeforeLocalDeleteDoesNotReviveIt() async {
        let store = makeStore()
        await listRoot(store, objects: [file("a.txt")], prefixes: [])

        let pollStart = t0.addingTimeInterval(100)
        await store.recordLocalDelete(id: "a.txt", now: pollStart.addingTimeInterval(1))
        let changed = await store.applyPoll(
            folderID: root, listedKey: "", objects: [file("a.txt")], folderPrefixes: [],
            startedAt: pollStart, now: pollStart.addingTimeInterval(2)
        )
        #expect(!changed)
        #expect(await store.liveItem(forKey: "a.txt") == nil)
    }

    @Test func pollResultIsIgnoredIfFolderWasRenamedMeanwhile() async {
        let store = makeStore()
        _ = await store.recordListed(folderKey: "", objects: [], folderPrefixes: ["old/"], now: t0)
        _ = await store.recordListed(folderKey: "old/", objects: [file("old/a.txt")], folderPrefixes: [], now: t0)
        await store.recordLocalMove(id: "old/", toKey: "new/", now: t0.addingTimeInterval(5))

        let changed = await store.applyPoll(
            folderID: "old/", listedKey: "old/", objects: [], folderPrefixes: [],
            startedAt: t0.addingTimeInterval(1), now: t0.addingTimeInterval(6)
        )
        #expect(!changed)
        #expect(await store.liveItem(forKey: "new/a.txt") != nil)
    }

    @Test func folderDateComesFromNewestChild() async {
        let store = makeStore()
        let newest = t0.addingTimeInterval(3600)
        _ = await store.recordListed(folderKey: "", objects: [], folderPrefixes: ["docs/"], now: t0)
        #expect(await store.item(id: "docs/")?.record.modified == nil)
        #expect(await store.item(id: "docs/")?.record.firstSeen == t0)

        let anchor = await store.currentAnchor()
        let children = [file("docs/a.txt", at: t0), file("docs/b.txt", at: newest)]
        _ = await store.recordListed(folderKey: "docs/", objects: children, folderPrefixes: [], now: t0)
        await store.finishListing(folderID: "docs/", seenKeys: Set(children.map(\.key)), newestModified: newest, startedAt: t0, now: t0)

        #expect(await store.item(id: "docs/")?.record.modified == newest)
        guard case .changes(let updated, _, _) = await store.changes(since: anchor) else {
            Issue.record("锚点不应失效")
            return
        }
        #expect(updated.map(\.record.id) == ["docs/"])
    }
}

struct SyncStoreAnchorTests {
    @Test func anchorFromAnotherGenerationExpires() async {
        let store = makeStore()
        guard case .expired = await store.changes(since: "someone-else:0") else {
            Issue.record("其他代的锚点应失效")
            return
        }
        guard case .changes = await store.changes(since: await store.currentAnchor()) else {
            Issue.record("当前锚点应有效")
            return
        }
    }

    @Test func stateSurvivesReloadButNotScopeChange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("syncstore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeStore(fileURL: url)
        _ = await first.recordListed(folderKey: "", objects: [], folderPrefixes: ["old/"], now: t0)
        await first.recordLocalMove(id: "old/", toKey: "new/", now: t0)
        let anchor = await first.currentAnchor()

        let reloaded = makeStore(fileURL: url)
        #expect(await reloaded.key(forID: "old/") == "new/")
        #expect(await reloaded.currentAnchor() == anchor)

        let otherBucket = makeStore(fileURL: url, scope: "r2|other")
        #expect(await otherBucket.key(forID: "old/") == "old/")
        #expect(await otherBucket.currentAnchor() != anchor)
    }
}
