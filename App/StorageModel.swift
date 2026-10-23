import Foundation
import Observation
import S3Kit
import SyncCore

/// 各存储桶的占用统计。统计要列出整个存储桶，只在用户打开或点「重新统计」时进行，结果保留到 App 退出。
@MainActor
@Observable
final class StorageModel {
    struct Scan {
        var summary = StorageSummary()
        var isRunning = true
        var finishedAt: Date?
        var error: String?
    }

    private(set) var scans: [String: Scan] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func scan(_ connectionID: String, client: S3Client) {
        tasks[connectionID]?.cancel()
        scans[connectionID] = Scan()
        tasks[connectionID] = Task {
            var summary = StorageSummary()
            var token: String?
            do {
                repeat {
                    let page = try await client.listObjects(prefix: "", delimiter: nil, continuationToken: token, maxKeys: 1000)
                    try Task.checkCancellation()
                    summary.add(page.objects)
                    // 每一页都更新界面，统计过程中就能看到对象数在增长
                    scans[connectionID]?.summary = summary
                    token = page.nextContinuationToken
                } while token != nil
                scans[connectionID]?.isRunning = false
                scans[connectionID]?.finishedAt = Date()
            } catch is CancellationError {
                scans[connectionID]?.isRunning = false
            } catch {
                scans[connectionID]?.isRunning = false
                scans[connectionID]?.error = error.localizedDescription
            }
        }
    }

    func cancel(_ connectionID: String) {
        tasks[connectionID]?.cancel()
    }
}
