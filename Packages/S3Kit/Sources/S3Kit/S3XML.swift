import Foundation

/// 极简 XML 树，只用于解析 S3 的响应。
final class S3XMLElement {
    let name: String
    var text = ""
    var children: [S3XMLElement] = []

    init(name: String) {
        self.name = name
    }

    func child(_ name: String) -> S3XMLElement? {
        children.first { $0.name == name }
    }

    func children(_ name: String) -> [S3XMLElement] {
        children.filter { $0.name == name }
    }

    static func parse(_ data: Data) throws -> S3XMLElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            throw S3Error.invalidXML(parser.parserError?.localizedDescription ?? preview)
        }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: S3XMLElement?
        private var stack: [S3XMLElement] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let element = S3XMLElement(name: elementName)
            stack.last?.children.append(element)
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let element = stack.removeLast()
            if stack.isEmpty {
                root = element
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

enum ListObjectsParser {
    static func parse(_ data: Data) throws -> ListPage {
        let root = try S3XMLElement.parse(data)
        guard root.name == "ListBucketResult" else {
            throw S3Error.invalidXML("意外的根节点 \(root.name)")
        }
        let objects = root.children("Contents").compactMap { node -> S3Object? in
            // key 不能 trim，S3 允许首尾有空格
            guard let key = node.child("Key")?.text else { return nil }
            return S3Object(
                key: key,
                size: Int64(node.child("Size")?.text.trimmed ?? "") ?? 0,
                lastModified: node.child("LastModified").flatMap { HTTPDate.parseISO8601($0.text.trimmed) },
                etag: node.child("ETag").map { S3Object.unquote($0.text.trimmed) }
            )
        }
        let prefixes = root.children("CommonPrefixes").compactMap { $0.child("Prefix")?.text }
        let token = root.child("NextContinuationToken")?.text.trimmed
        return ListPage(
            objects: objects,
            commonPrefixes: prefixes,
            nextContinuationToken: token?.isEmpty == false ? token : nil,
            isTruncated: root.child("IsTruncated")?.text.trimmed == "true"
        )
    }
}

/// 解析分片上传、复制、批量删除的响应。
enum S3XMLResponse {
    /// CompleteMultipartUpload、CopyObject、UploadPartCopy 可能返回 200 但响应体是 <Error>，必须检查根节点
    static func root(of data: Data, expected name: String) throws -> S3XMLElement {
        let root = try S3XMLElement.parse(data)
        if root.name == "Error" {
            throw S3Error.http(status: 200, code: root.child("Code")?.text, message: root.child("Message")?.text)
        }
        guard root.name == name else {
            throw S3Error.invalidXML("意外的根节点 \(root.name)，应为 \(name)")
        }
        return root
    }

    static func uploadID(from data: Data) throws -> String {
        guard let id = try root(of: data, expected: "InitiateMultipartUploadResult").child("UploadId")?.text.trimmed, !id.isEmpty else {
            throw S3Error.invalidXML("缺少 UploadId")
        }
        return id
    }

    /// 返回原样的 ETag（带引号），分片 ETag 要原样填回 CompleteMultipartUpload
    static func etag(from data: Data, root name: String) throws -> String {
        guard let etag = try root(of: data, expected: name).child("ETag")?.text.trimmed, !etag.isEmpty else {
            throw S3Error.invalidXML("\(name) 缺少 ETag")
        }
        return etag
    }

    /// Quiet 模式下只返回失败项，响应体为空表示全部成功
    static func deleteFailures(from data: Data) throws -> [S3Error] {
        guard !data.isEmpty else { return [] }
        return try root(of: data, expected: "DeleteResult").children("Error").map {
            .batchFailed(key: $0.child("Key")?.text ?? "?", code: $0.child("Code")?.text, message: $0.child("Message")?.text)
        }
    }
}

enum S3XMLBuilder {
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func completeMultipartUpload(_ parts: [(number: Int, etag: String)]) -> String {
        let body = parts.map { "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(escape($0.etag))</ETag></Part>" }.joined()
        return "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(body)</CompleteMultipartUpload>"
    }

    static func deleteObjects(_ keys: [String]) -> String {
        let body = keys.map { "<Object><Key>\(escape($0))</Key></Object>" }.joined()
        return "<Delete xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Quiet>true</Quiet>\(body)</Delete>"
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
