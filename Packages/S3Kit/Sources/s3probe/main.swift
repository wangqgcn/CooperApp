import Foundation
import S3Kit

// 不依赖 Xcode 的联调工具，直接对真实存储桶验证 S3Kit。
// 连接参数从环境变量读取：S3_ENDPOINT、S3_BUCKET、S3_ACCESS_KEY_ID、S3_SECRET_ACCESS_KEY，可选 S3_REGION（默认 auto）。
//
//   swift run s3probe ls [PREFIX]
//   swift run s3probe head KEY
//   swift run s3probe get KEY LOCAL_FILE
//   swift run s3probe put LOCAL_FILE KEY      超过 32 MB 自动分片上传
//   swift run s3probe cp SRC_KEY DST_KEY      服务端复制
//   swift run s3probe rm KEY
//   swift run s3probe rmr PREFIX              递归删除前缀下所有对象（批量删除）

let env = ProcessInfo.processInfo.environment
func required(_ name: String) -> String {
    guard let value = env[name], !value.isEmpty else {
        FileHandle.standardError.write(Data("缺少环境变量 \(name)\n".utf8))
        exit(2)
    }
    return value
}

guard let endpoint = URL(string: required("S3_ENDPOINT")) else {
    FileHandle.standardError.write(Data("S3_ENDPOINT 不是合法地址\n".utf8))
    exit(2)
}
let client = S3Client(
    config: S3Config(endpoint: endpoint, bucket: required("S3_BUCKET"), region: env["S3_REGION"] ?? "auto"),
    credentials: S3Credentials(accessKeyId: required("S3_ACCESS_KEY_ID"), secretAccessKey: required("S3_SECRET_ACCESS_KEY"))
)

/// 把回调式的传输任务包成 async。
func run<T: Sendable>(_ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> URLSessionTask) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        start { continuation.resume(with: $0) }.resume()
    }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch (args.first, args.count) {
    case ("ls", 1), ("ls", 2):
        var token: String?
        repeat {
            let page = try await client.listObjects(prefix: args.count == 2 ? args[1] : "", continuationToken: token)
            page.commonPrefixes.forEach { print("DIR   \($0)") }
            page.objects.forEach { print(String(format: "%12lld  ", $0.size) + $0.key) }
            token = page.nextContinuationToken
        } while token != nil
    case ("head", 2):
        let object = try await client.headObject(key: args[1])
        print("size=\(object.size) etag=\(object.etag ?? "-") type=\(object.contentType ?? "-") modified=\(object.lastModified.map { "\($0)" } ?? "-")")
    case ("get", 3):
        let destination = URL(fileURLWithPath: args[2])
        let response = try await run { client.downloadTask(key: args[1], to: destination, completion: $0) }
        print("已下载 \(response.expectedContentLength) 字节到 \(destination.path)")
    case ("put", 3):
        let progress = Progress()
        let etag = try await client.uploadFile(key: args[2], fileURL: URL(fileURLWithPath: args[1]), contentType: nil, progress: progress)
        let mode = progress.totalUnitCount > S3Client.multipartThreshold ? "分片上传" : "单次上传"
        print("已\(mode) \(progress.totalUnitCount) 字节，ETag=\(etag ?? "-")")
    case ("cp", 3):
        let source = try await client.headObject(key: args[1])
        let etag = try await client.copyObject(from: args[1], to: args[2], size: source.size)
        print("已复制到 \(args[2])，ETag=\(etag ?? "-")")
    case ("rm", 2):
        try await client.deleteObject(key: args[1])
        print("已删除 \(args[1])")
    case ("rmr", 2):
        let keys = try await client.listAllObjects(prefix: args[1]).map(\.key)
        try await client.deleteObjects(keys: keys)
        print("已删除 \(keys.count) 个对象")
    default:
        print("用法：s3probe ls [PREFIX] | head KEY | get KEY FILE | put FILE KEY | cp SRC DST | rm KEY | rmr PREFIX")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
