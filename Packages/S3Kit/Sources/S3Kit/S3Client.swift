import CryptoKit
import Foundation

/// 一个前缀下的直接子项（所有分页合并后）。
public struct FolderListing: Sendable {
    public var objects: [S3Object]
    /// 以 "/" 结尾的子前缀，即子文件夹
    public var folderPrefixes: [String]
}

/// 精简的 S3 客户端，只覆盖挂载需要的操作。
public final class S3Client: Sendable {
    public let config: S3Config
    private let signer: SigV4Signer
    private let session: URLSession

    /// 超过这个大小走分片上传
    public static let multipartThreshold: Int64 = 32 * 1024 * 1024
    /// 单次 CopyObject 的上限，超过要分片复制
    public static let maxSingleCopySize: Int64 = 5 * 1024 * 1024 * 1024
    static let minPartSize: Int64 = 8 * 1024 * 1024
    static let minCopyPartSize: Int64 = 512 * 1024 * 1024
    static let maxParts: Int64 = 10_000
    static let partConcurrency = 4
    /// 移动文件夹时同时复制的对象数
    static let copyConcurrency = 8

    public init(config: S3Config, credentials: S3Credentials, session: URLSession = S3Client.makeSession()) {
        self.config = config
        self.signer = SigV4Signer(credentials: credentials, region: config.region)
        self.session = session
    }

    /// 不缓存、不存 Cookie 的会话。签名请求不能命中本地缓存。
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    // MARK: - 列举

    /// 列举一页对象。delimiter 为 "/" 时，子目录以 commonPrefixes 返回。
    public func listObjects(
        prefix: String,
        delimiter: String? = "/",
        continuationToken: String? = nil,
        maxKeys: Int? = nil
    ) async throws -> ListPage {
        var query: [(String, String)] = [("list-type", "2"), ("prefix", prefix)]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        if let maxKeys { query.append(("max-keys", String(maxKeys))) }

        let request = makeRequest(method: "GET", url: url(forKey: nil, query: query), payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, _) = try await send(request)
        return try ListObjectsParser.parse(data)
    }

    /// 列出一个前缀下的直接子项，自动翻完所有分页。
    public func listFolder(prefix: String) async throws -> FolderListing {
        var listing = FolderListing(objects: [], folderPrefixes: [])
        var token: String?
        repeat {
            let page = try await listObjects(prefix: prefix, continuationToken: token, maxKeys: 1000)
            listing.objects += page.objects
            listing.folderPrefixes += page.commonPrefixes
            token = page.nextContinuationToken
        } while token != nil
        return listing
    }

    /// 递归列出前缀下的所有对象（包括文件夹占位对象）。
    public func listAllObjects(prefix: String) async throws -> [S3Object] {
        var objects: [S3Object] = []
        var token: String?
        repeat {
            let page = try await listObjects(prefix: prefix, delimiter: nil, continuationToken: token, maxKeys: 1000)
            objects += page.objects
            token = page.nextContinuationToken
        } while token != nil
        return objects
    }

    // MARK: - 单个对象

    public func headObject(key: String) async throws -> S3Object {
        let request = makeRequest(method: "HEAD", url: url(forKey: key), payloadHash: SigV4Signer.emptyPayloadHash)
        let (_, response) = try await send(request)
        return S3Object(key: key, response: response)
    }

    /// 上传小块数据（如文件夹占位对象），返回 ETag。
    @discardableResult
    public func putObject(key: String, data: Data, contentType: String? = nil) async throws -> String? {
        var headers: [String: String] = [:]
        if let contentType { headers["content-type"] = contentType }
        let payloadHash = SigV4Signer.hex(SHA256.hash(data: data))
        let request = makeRequest(method: "PUT", url: url(forKey: key), headers: headers, payloadHash: payloadHash)
        let (_, response) = try await send(request, body: data)
        return response.value(forHTTPHeaderField: "ETag").map(S3Object.unquote)
    }

    public func deleteObject(key: String) async throws {
        let request = makeRequest(method: "DELETE", url: url(forKey: key), payloadHash: SigV4Signer.emptyPayloadHash)
        _ = try await send(request)
    }

    /// 批量删除，每 1000 个一批。有对象删除失败时抛出第一个失败。
    public func deleteObjects(keys: [String]) async throws {
        for start in stride(from: 0, to: keys.count, by: 1000) {
            let batch = Array(keys[start..<min(start + 1000, keys.count)])
            let body = Data(S3XMLBuilder.deleteObjects(batch).utf8)
            // DeleteObjects 要求带 Content-MD5
            let headers = [
                "content-md5": Data(Insecure.MD5.hash(data: body)).base64EncodedString(),
                "content-type": "application/xml",
            ]
            let payloadHash = SigV4Signer.hex(SHA256.hash(data: body))
            let request = makeRequest(method: "POST", url: url(forKey: nil, query: [("delete", "")]), headers: headers, payloadHash: payloadHash)
            let (data, _) = try await send(request, body: body)
            if let failure = try S3XMLResponse.deleteFailures(from: data).first {
                throw failure
            }
        }
    }

    /// 在存储桶内复制对象，返回新对象的 ETag。超过 5 GB 自动改用分片复制。
    @discardableResult
    public func copyObject(from sourceKey: String, to destinationKey: String, size: Int64) async throws -> String? {
        if size > Self.maxSingleCopySize {
            return try await multipartCopy(from: sourceKey, to: destinationKey, size: size)
        }
        let request = makeRequest(
            method: "PUT",
            url: url(forKey: destinationKey),
            headers: ["x-amz-copy-source": copySource(sourceKey)],
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        let (data, _) = try await send(request, body: Data())
        return S3Object.unquote(try S3XMLResponse.etag(from: data, root: "CopyObjectResult"))
    }

    // MARK: - 组合操作（S3 没有改名和目录，用复制、批量删除拼出来）

    /// 移动单个对象：复制到新 key 再删除旧的，返回新对象的 ETag。
    @discardableResult
    public func moveObject(from sourceKey: String, to destinationKey: String, size: Int64) async throws -> String? {
        let etag = try await copyObject(from: sourceKey, to: destinationKey, size: size)
        try await deleteObject(key: sourceKey)
        return etag
    }

    /// 移动文件夹：把前缀下的所有对象复制到新前缀，全部成功后再删除旧的。
    /// 复制到一半失败时删掉已复制过去的对象，原文件夹保持不动。
    public func moveFolder(from oldPrefix: String, to newPrefix: String, progress: Progress? = nil) async throws {
        let objects = try await listAllObjects(prefix: oldPrefix)
        guard !objects.isEmpty else {
            // 远端什么都没有（连占位对象都没有），在新位置建一个占位对象
            try await putObject(key: newPrefix, data: Data())
            return
        }

        progress?.totalUnitCount = Int64(objects.count) + 1
        var copied: [String] = []
        do {
            try await forEachConcurrently(objects, limit: Self.copyConcurrency) { object in
                let target = newPrefix + object.key.dropFirst(oldPrefix.count)
                try await self.copyObject(from: object.key, to: target, size: object.size)
                return target
            } onResult: { target in
                copied.append(target)
                progress?.completedUnitCount += 1
            }
        } catch {
            try? await deleteObjects(keys: copied)
            throw error
        }
        try await deleteObjects(keys: objects.map(\.key))
        progress?.completedUnitCount = progress?.totalUnitCount ?? 0
    }

    /// 删除前缀下的所有对象（包括文件夹占位对象），返回删除的个数。
    @discardableResult
    public func deleteFolder(prefix: String) async throws -> Int {
        let keys = try await listAllObjects(prefix: prefix).map(\.key)
        try await deleteObjects(keys: keys)
        return keys.count
    }

    /// 公开访问地址：公开域名（如 R2 的 https://pub-xxx.r2.dev 或自定义域名）加上按 S3 规则编码的 key。
    /// 只有存储桶允许公开读取时才能访问，没有有效期。
    public static func publicURL(base: URL, key: String) -> URL {
        var string = base.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        return URL(string: string + "/" + SigV4Signer.uriEncode(key, encodeSlash: false))!
    }

    /// 生成限时下载链接，expires 为有效秒数（1…604800）。
    public func presignedURL(forKey key: String, expiresIn expires: Int, date: Date = Date()) -> URL {
        signer.presign(method: "GET", url: url(forKey: key), expires: min(max(expires, 1), 604_800), date: date)
    }

    // MARK: - 文件传输

    /// 下载对象到 destination（已存在会被覆盖），返回对象信息。
    /// 传输进度挂到 progress 上；取消调用方的 Task 会中止下载。
    @discardableResult
    public func downloadFile(key: String, to destination: URL, progress: Progress) async throws -> S3Object {
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = downloadTask(key: key, to: destination) { result in
                    continuation.resume(with: result.map { S3Object(key: key, response: $0) })
                }
                progress.addChild(task.progress, withPendingUnitCount: max(progress.totalUnitCount, 1))
                holder.start(task)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    /// 下载对象到 destination（已存在会被覆盖），完成后回调响应头。
    /// 返回尚未 resume 的任务，调用方可以先把 task.progress 接到自己的 Progress 上再启动。
    public func downloadTask(
        key: String,
        to destination: URL,
        completion: @escaping @Sendable (Result<HTTPURLResponse, Error>) -> Void
    ) -> URLSessionDownloadTask {
        let request = makeRequest(method: "GET", url: url(forKey: key), payloadHash: SigV4Signer.emptyPayloadHash)
        return session.downloadTask(with: request) { location, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse, let location else {
                completion(.failure(S3Error.invalidResponse))
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                let body = (try? Data(contentsOf: location)) ?? Data()
                completion(.failure(S3Error.from(status: response.statusCode, body: body)))
                return
            }
            // location 在回调返回后就会被删除，必须在这里移走
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                completion(.success(response))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// 上传本地文件，返回 ETag。不超过 multipartThreshold 用单个 PUT，否则分片上传。
    /// progress 的 totalUnitCount 会被设为文件字节数；取消调用方的 Task 会中止上传。
    @discardableResult
    public func uploadFile(key: String, fileURL: URL, contentType: String?, progress: Progress) async throws -> String? {
        let size = Int64(try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        progress.totalUnitCount = max(size, 1)
        guard size > Self.multipartThreshold else {
            var headers: [String: String] = [:]
            if let contentType { headers["content-type"] = contentType }
            let request = makeRequest(method: "PUT", url: url(forKey: key), headers: headers, payloadHash: SigV4Signer.unsignedPayload)
            let (_, response) = try await sendTracked(request, body: .file(fileURL), progress: progress, pendingUnitCount: max(size, 1))
            return response.value(forHTTPHeaderField: "ETag").map(S3Object.unquote)
        }
        return try await multipartUpload(key: key, fileURL: fileURL, size: size, contentType: contentType, progress: progress)
    }

    // MARK: - 分片

    /// 分片大小：至少 minimum，并保证总片数不超过 10000。按 MiB 取整，除最后一片外大小相同（R2 的要求）。
    static func partSize(for size: Int64, minimum: Int64) -> Int64 {
        let mib: Int64 = 1024 * 1024
        let needed = (size + maxParts - 1) / maxParts
        let rounded = (needed + mib - 1) / mib * mib
        return max(minimum, rounded)
    }

    private func multipartUpload(key: String, fileURL: URL, size: Int64, contentType: String?, progress: Progress) async throws -> String? {
        let partSize = Self.partSize(for: size, minimum: Self.minPartSize)
        let partCount = Int((size + partSize - 1) / partSize)
        let uploadID = try await createMultipartUpload(key: key, contentType: contentType)
        do {
            let parts = try await forEachPart(count: partCount) { number in
                let offset = Int64(number - 1) * partSize
                let length = min(partSize, size - offset)
                let data = try Self.readChunk(of: fileURL, offset: offset, length: length)
                let request = self.makeRequest(
                    method: "PUT",
                    url: self.url(forKey: key, query: [("partNumber", String(number)), ("uploadId", uploadID)]),
                    payloadHash: SigV4Signer.unsignedPayload
                )
                let (_, response) = try await self.sendTracked(request, body: .data(data), progress: progress, pendingUnitCount: length)
                guard let etag = response.value(forHTTPHeaderField: "ETag") else { throw S3Error.invalidResponse }
                return etag
            }
            return try await completeMultipartUpload(key: key, uploadID: uploadID, parts: parts)
        } catch {
            abortInBackground(key: key, uploadID: uploadID)
            throw error
        }
    }

    private func multipartCopy(from sourceKey: String, to destinationKey: String, size: Int64) async throws -> String? {
        let partSize = Self.partSize(for: size, minimum: Self.minCopyPartSize)
        let partCount = Int((size + partSize - 1) / partSize)
        // 分片复制不会带上源对象的 Content-Type，要自己设置
        let source = try await headObject(key: sourceKey)
        let uploadID = try await createMultipartUpload(key: destinationKey, contentType: source.contentType)
        do {
            let parts = try await forEachPart(count: partCount) { number in
                let start = Int64(number - 1) * partSize
                let end = min(start + partSize, size) - 1
                let request = self.makeRequest(
                    method: "PUT",
                    url: self.url(forKey: destinationKey, query: [("partNumber", String(number)), ("uploadId", uploadID)]),
                    headers: ["x-amz-copy-source": self.copySource(sourceKey), "x-amz-copy-source-range": "bytes=\(start)-\(end)"],
                    payloadHash: SigV4Signer.emptyPayloadHash
                )
                let (data, _) = try await self.send(request, body: Data())
                return try S3XMLResponse.etag(from: data, root: "CopyPartResult")
            }
            return try await completeMultipartUpload(key: destinationKey, uploadID: uploadID, parts: parts)
        } catch {
            abortInBackground(key: destinationKey, uploadID: uploadID)
            throw error
        }
    }

    private func createMultipartUpload(key: String, contentType: String?) async throws -> String {
        var headers: [String: String] = [:]
        if let contentType { headers["content-type"] = contentType }
        let request = makeRequest(method: "POST", url: url(forKey: key, query: [("uploads", "")]), headers: headers, payloadHash: SigV4Signer.emptyPayloadHash)
        let (data, _) = try await send(request, body: Data())
        return try S3XMLResponse.uploadID(from: data)
    }

    private func completeMultipartUpload(key: String, uploadID: String, parts: [(number: Int, etag: String)]) async throws -> String? {
        let body = Data(S3XMLBuilder.completeMultipartUpload(parts).utf8)
        let request = makeRequest(
            method: "POST",
            url: url(forKey: key, query: [("uploadId", uploadID)]),
            headers: ["content-type": "application/xml"],
            payloadHash: SigV4Signer.hex(SHA256.hash(data: body))
        )
        let (data, _) = try await send(request, body: body)
        return S3Object.unquote(try S3XMLResponse.etag(from: data, root: "CompleteMultipartUploadResult"))
    }

    /// 失败或取消后放弃分片上传，否则已传的分片会一直占用存储。
    /// 放到独立任务里执行，不受调用方 Task 取消的影响。
    private func abortInBackground(key: String, uploadID: String) {
        let request = makeRequest(method: "DELETE", url: url(forKey: key, query: [("uploadId", uploadID)]), payloadHash: SigV4Signer.emptyPayloadHash)
        Task.detached { [self] in
            _ = try? await send(request)
        }
    }

    /// 以有限并发处理第 1…count 片，返回按片号排好的 ETag。任一片失败会取消其余分片。
    private func forEachPart(
        count: Int,
        _ body: @escaping @Sendable (Int) async throws -> String
    ) async throws -> [(number: Int, etag: String)] {
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 1
            func addNext() {
                let number = next
                group.addTask { (number, try await body(number)) }
                next += 1
            }
            while next <= min(count, Self.partConcurrency) { addNext() }

            var results: [(number: Int, etag: String)] = []
            while let (number, etag) = try await group.next() {
                results.append((number, etag))
                if next <= count { addNext() }
            }
            return results.sorted { $0.number < $1.number }
        }
    }

    static func readChunk(of fileURL: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)), data.count == Int(length) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "读取分片时文件大小发生了变化"])
        }
        return data
    }

    // MARK: - 请求构造

    /// key 为 nil 时返回存储桶本身的地址（用于列举和批量删除）。
    func url(forKey key: String?, query: [(String, String)] = []) -> URL {
        var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)!
        var basePath = components.percentEncodedPath
        if basePath.hasSuffix("/") { basePath.removeLast() }
        let keyPath = key.map { "/" + SigV4Signer.uriEncode($0, encodeSlash: false) } ?? ""

        if config.usePathStyle {
            components.percentEncodedPath = basePath + "/" + SigV4Signer.uriEncode(config.bucket, encodeSlash: true) + keyPath
        } else {
            components.host = config.bucket + "." + (components.host ?? "")
            components.percentEncodedPath = basePath + (keyPath.isEmpty ? "/" : keyPath)
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { SigV4Signer.uriEncode($0.0, encodeSlash: true) + "=" + SigV4Signer.uriEncode($0.1, encodeSlash: true) }
                .joined(separator: "&")
        }
        return components.url!
    }

    /// x-amz-copy-source 的值：bucket/key，按 URL 编码
    func copySource(_ key: String) -> String {
        SigV4Signer.uriEncode(config.bucket, encodeSlash: true) + "/" + SigV4Signer.uriEncode(key, encodeSlash: false)
    }

    private func makeRequest(method: String, url: URL, headers: [String: String] = [:], payloadHash: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let signedHeaders = signer.sign(method: method, url: url, headers: headers, payloadHash: payloadHash)
        for (name, value) in headers.merging(signedHeaders, uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// body 不为 nil 时用 upload 发送，保证带上 Content-Length（PUT/POST 空请求体也需要）。
    private func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = if let body {
            try await session.upload(for: request, from: body)
        } else {
            try await session.data(for: request)
        }
        return try Self.check(data, response)
    }

    private enum UploadBody {
        case data(Data)
        case file(URL)
    }

    /// 和 send 一样，但把传输进度挂到 progress 上。
    private func sendTracked(_ request: URLRequest, body: UploadBody, progress: Progress, pendingUnitCount: Int64) async throws -> (Data, HTTPURLResponse) {
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(with: Result { try Self.check(data ?? Data(), response) })
                }
                let task = switch body {
                case .data(let data): session.uploadTask(with: request, from: data, completionHandler: completion)
                case .file(let fileURL): session.uploadTask(with: request, fromFile: fileURL, completionHandler: completion)
                }
                progress.addChild(task.progress, withPendingUnitCount: pendingUnitCount)
                holder.start(task)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private static func check(_ data: Data, _ response: URLResponse?) throws -> (Data, HTTPURLResponse) {
        guard let response = response as? HTTPURLResponse else {
            throw S3Error.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw S3Error.from(status: response.statusCode, body: data)
        }
        return (data, response)
    }
}

/// 以有限并发处理每个元素，结果在调用方任务里逐个交给 onResult。任一失败会取消其余任务并抛出。
public func forEachConcurrently<Element: Sendable, Result: Sendable>(
    _ elements: [Element],
    limit: Int,
    _ body: @escaping @Sendable (Element) async throws -> Result,
    onResult: (Result) -> Void
) async throws {
    try await withThrowingTaskGroup(of: Result.self) { group in
        var iterator = elements.makeIterator()
        for _ in 0..<limit {
            guard let element = iterator.next() else { break }
            group.addTask { try await body(element) }
        }
        while let result = try await group.next() {
            onResult(result)
            if let element = iterator.next() {
                group.addTask { try await body(element) }
            }
        }
    }
}

/// 让 Swift 并发的取消能传到 URLSessionTask，即使取消发生在任务创建之前。
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func start(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = isCancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
