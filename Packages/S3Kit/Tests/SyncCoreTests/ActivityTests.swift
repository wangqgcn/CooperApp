import Foundation
import Testing
@testable import SyncCore

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let bucket = "B1"

private func at(_ seconds: TimeInterval) -> Date {
    t0.addingTimeInterval(seconds)
}

/// 一条已完成的记录
private func done(
    _ action: ActivityAction,
    _ key: String,
    at seconds: TimeInterval,
    source: ActivitySource = .finder,
    connectionID: String = bucket,
    size: Int64? = nil
) -> ActivityEvent {
    var event = ActivityEvent(source: source, draft: ActivityDraft(action, connectionID: connectionID, key: key, size: size), date: at(seconds))
    event.status = .done
    event.finishedAt = at(seconds + 1)
    return event
}

struct ActivityLogTests {
    @Test func beginAndFinishFillInResult() {
        var log = ActivityLog(source: .finder)
        let id = log.begin(ActivityDraft(.upload, connectionID: bucket, key: "docs/a.txt"), now: t0)
        #expect(log.events.first?.status == .running)

        log.finish(id, status: .done, itemID: "docs/a.txt", size: 42, now: at(3))
        let event = log.events.first
        #expect(event?.status == .done)
        #expect(event?.itemID == "docs/a.txt")
        #expect(event?.size == 42)
        #expect(event?.finishedAt == at(3))
        #expect(event?.attempts == 1)
    }

    @Test func retryAfterFailureReusesRecord() {
        var log = ActivityLog(source: .finder)
        let first = log.begin(ActivityDraft(.update, connectionID: bucket, key: "a.txt", itemID: "id-a"), now: t0)
        log.finish(first, status: .failed("无法连接到服务器"), now: at(1))
        log.begin(ActivityDraft(.upload, connectionID: bucket, key: "b.txt"), now: at(2))

        // 改名后再重试同一个条目：按标识认出来
        let retry = log.begin(ActivityDraft(.update, connectionID: bucket, key: "renamed.txt", itemID: "id-a"), now: at(5))
        #expect(retry == first)
        #expect(log.events.count == 2)
        #expect(log.events.last?.id == first)
        #expect(log.events.last?.attempts == 2)
        #expect(log.events.last?.status == .running)
        #expect(log.events.last?.key == "renamed.txt")
        #expect(log.events.last?.finishedAt == nil)
    }

    @Test func finishedRecordIsNotReused() {
        var log = ActivityLog(source: .app)
        let first = log.begin(ActivityDraft(.upload, connectionID: bucket, key: "a.txt"), now: t0)
        log.finish(first, status: .done, now: at(1))
        let second = log.begin(ActivityDraft(.upload, connectionID: bucket, key: "a.txt"), now: at(2))
        #expect(second != first)
        #expect(log.events.count == 2)
    }

    @Test func discardRemovesRecord() {
        var log = ActivityLog(source: .finder)
        let id = log.begin(ActivityDraft(.upload, connectionID: bucket, key: "a.txt"), now: t0)
        log.discard(id)
        #expect(log.events.isEmpty)
    }

    @Test func leftoverRunningRecordsBecomeInterrupted() {
        var log = ActivityLog(source: .finder)
        let running = log.begin(ActivityDraft(.upload, connectionID: bucket, key: "a.txt"), now: t0)
        let finished = log.begin(ActivityDraft(.delete, connectionID: bucket, key: "b.txt"), now: t0)
        log.finish(finished, status: .done, now: at(1))

        let changed = log.markRunningInterrupted(now: at(10))
        #expect(changed)
        #expect(log.events.first { $0.id == running }?.status == .interrupted)
        #expect(log.events.first { $0.id == finished }?.status == .done)
        let changedAgain = log.markRunningInterrupted(now: at(11))
        #expect(!changedAgain)
    }

    @Test func trimDropsOldAndExcessRecords() {
        let old = done(.upload, "old.txt", at: -ActivityLog.maxAge - 100)
        var events = [old]
        for index in 0..<(ActivityLog.maxCount + 5) {
            events.append(done(.upload, "f\(index).txt", at: TimeInterval(index)))
        }
        var log = ActivityLog(source: .finder, events: events)
        log.trim(now: at(10_000))
        #expect(log.events.count == ActivityLog.maxCount)
        #expect(!log.events.contains { $0.id == old.id })
        #expect(log.events.first?.key == "f5.txt")
    }
}

struct ActivityFeedTests {
    @Test func mergeSortsNewestFirstAndHonoursClear() {
        let finder = [done(.upload, "a.txt", at: 0), done(.delete, "b.txt", at: 100)]
        var running = ActivityEvent(source: .app, draft: ActivityDraft(.upload, connectionID: bucket, key: "c.txt"), date: at(10))
        running.status = .running
        let app = [running, done(.rename, "d.txt", at: 50, source: .app)]

        let all = ActivityFeed.merge([finder, app])
        #expect(all.map(\.key) == ["b.txt", "d.txt", "c.txt", "a.txt"])

        // 清除之后只剩之后结束的和进行中的
        let cleared = ActivityFeed.merge([finder, app], clearedBefore: at(60))
        #expect(cleared.map(\.key) == ["b.txt", "c.txt"])
    }

    @Test func folderUploadCollapsesIntoOneRow() {
        let events = [
            done(.createFolder, "photos/", at: 0),
            done(.upload, "photos/a.jpg", at: 5, size: 100),
            done(.createFolder, "photos/sub/", at: 6),
            done(.upload, "photos/sub/b.jpg", at: 30, size: 200),
            // 别的文件夹、主窗口发起的不算
            done(.upload, "docs/x.pdf", at: 10),
            done(.upload, "photos/c.jpg", at: 12, source: .app),
        ]
        let rows = ActivityFeed.rows(from: events)
        let folder = rows.first { $0.kind == .folder }
        #expect(folder?.primary.key == "photos/")
        #expect(folder?.events.count == 4)
        #expect(folder?.fileCount == 2)
        #expect(folder?.totalSize == 300)
        #expect(rows.count == 3)
    }

    @Test func emptyNewFolderStaysSingle() {
        let rows = ActivityFeed.rows(from: [done(.createFolder, "empty/", at: 0), done(.upload, "other.txt", at: 1)])
        #expect(rows.allSatisfy { $0.kind == .single })
    }

    @Test func sameFolderBatchesAndGapSplits() {
        let events = [
            done(.upload, "docs/a.txt", at: 0),
            done(.upload, "docs/b.txt", at: 20),
            done(.upload, "docs/c.txt", at: 40),
            done(.upload, "docs/d.txt", at: 40 + ActivityFeed.batchGap + 1),
            done(.upload, "misc/e.txt", at: 30),
            done(.delete, "docs/f.txt", at: 25),
        ]
        let rows = ActivityFeed.rows(from: events)
        let batch = rows.first { $0.kind == .batch }
        #expect(batch?.events.map(\.key) == ["docs/c.txt", "docs/b.txt", "docs/a.txt"])
        #expect(batch?.primary.key == "docs/c.txt")
        #expect(batch?.id == events[0].id)
        #expect(rows.count == 4)
        // 新的在前
        #expect(rows.first?.primary.key == "docs/d.txt")
    }

    @Test func repeatedSavesOfOneFileMerge() {
        let events = [done(.update, "notes.md", at: 0), done(.update, "notes.md", at: 60), done(.update, "notes.md", at: 120)]
        let rows = ActivityFeed.rows(from: events)
        #expect(rows.count == 1)
        #expect(rows.first?.isRepeatedUpdate == true)
    }

    @Test func runningAndFailedStayOnTheirOwn() {
        var failed = done(.upload, "docs/b.txt", at: 10)
        failed.status = .failed("无法连接到服务器")
        var running = done(.upload, "docs/c.txt", at: 20)
        running.status = .running
        running.finishedAt = nil
        let events = [done(.upload, "docs/a.txt", at: 0), failed, running, done(.upload, "docs/d.txt", at: 30)]

        let rows = ActivityFeed.rows(from: events)
        #expect(rows.count == 3)
        #expect(rows.first { $0.kind == .batch }?.events.count == 2)
        #expect(rows.contains { $0.kind == .single && $0.primary.id == failed.id })
        #expect(rows.contains { $0.kind == .single && $0.primary.id == running.id })
    }

    @Test func sectionsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-10-20 15:00 北京时间
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!
        func row(_ date: Date) -> ActivityRow {
            var event = ActivityEvent(source: .finder, draft: ActivityDraft(.upload, connectionID: bucket, key: "a"), date: date)
            event.status = .done
            event.finishedAt = date
            return ActivityRow(kind: .single, events: [event])
        }
        let rows = [
            row(now.addingTimeInterval(-3600)),
            row(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 0, minute: 5))!),
            row(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23))!),
            row(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 1))!),
            row(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 23))!),
        ]
        let sections = ActivityFeed.sections(from: rows, now: now, calendar: calendar)
        #expect(sections.map(\.period) == [.today, .yesterday, .pastWeek, .earlier])
        #expect(sections.map(\.rows.count) == [2, 1, 1, 1])
    }
}
