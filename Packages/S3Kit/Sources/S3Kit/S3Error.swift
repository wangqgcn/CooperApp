import Foundation

public enum S3Error: Error, LocalizedError, Sendable {
    /// 服务端返回非 2xx。code 是 S3 错误码，如 NoSuchKey、AccessDenied
    case http(status: Int, code: String?, message: String?)
    case invalidResponse
    case invalidXML(String)
    /// 批量删除里有对象没删掉
    case batchFailed(key: String, code: String?, message: String?)

    public var statusCode: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .http(let status, let code, let message):
            return "HTTP \(status) \(code ?? "")\(message.map { ": \($0)" } ?? "")"
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case .invalidXML(let detail):
            return "XML 解析失败：\(detail)"
        case .batchFailed(let key, let code, let message):
            return "删除 \(key) 失败：\(code ?? "")\(message.map { " \($0)" } ?? "")"
        }
    }

    /// 从错误响应体（<Error><Code>…</Code><Message>…</Message></Error>）构造。
    static func from(status: Int, body: Data) -> S3Error {
        guard !body.isEmpty, let root = try? S3XMLElement.parse(body), root.name == "Error" else {
            return .http(status: status, code: nil, message: nil)
        }
        return .http(status: status, code: root.child("Code")?.text, message: root.child("Message")?.text)
    }
}
