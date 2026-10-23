import Foundation
import Testing
@testable import S3Kit

struct PartSizeTests {
    let mib: Int64 = 1024 * 1024

    @Test func smallFilesUseMinimumPartSize() {
        #expect(S3Client.partSize(for: 100 * mib, minimum: S3Client.minPartSize) == 8 * mib)
    }

    @Test func hugeFilesStayWithinTenThousandParts() {
        let size: Int64 = 100 * 1024 * mib  // 100 GiB
        let part = S3Client.partSize(for: size, minimum: S3Client.minPartSize)
        #expect(part % mib == 0)
        #expect((size + part - 1) / part <= 10_000)
        #expect(part == 11 * mib)
    }

    @Test func copyPartsAreAtLeast512MiB() {
        #expect(S3Client.partSize(for: 6 * 1024 * mib, minimum: S3Client.minCopyPartSize) == 512 * mib)
    }
}

struct S3XMLBuilderTests {
    @Test func completeMultipartUploadKeepsETagQuotes() {
        let xml = S3XMLBuilder.completeMultipartUpload([(1, "\"aaa\""), (2, "\"bbb\"")])
        #expect(xml.contains("<Part><PartNumber>1</PartNumber><ETag>&quot;aaa&quot;</ETag></Part>"))
        #expect(xml.contains("<PartNumber>2</PartNumber>"))
    }

    @Test func deleteObjectsEscapesKeys() {
        let xml = S3XMLBuilder.deleteObjects(["a&b/<c>.txt", "d"])
        #expect(xml.contains("<Quiet>true</Quiet>"))
        #expect(xml.contains("<Object><Key>a&amp;b/&lt;c&gt;.txt</Key></Object>"))
        #expect(xml.contains("<Object><Key>d</Key></Object>"))
    }
}

struct S3XMLResponseTests {
    @Test func parsesUploadID() throws {
        let xml = "<InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>abc-123</UploadId></InitiateMultipartUploadResult>"
        #expect(try S3XMLResponse.uploadID(from: Data(xml.utf8)) == "abc-123")
    }

    @Test func parsesCopyResultETag() throws {
        let xml = "<CopyObjectResult><LastModified>2026-10-19T08:00:00.000Z</LastModified><ETag>&quot;9b2c&quot;</ETag></CopyObjectResult>"
        #expect(try S3XMLResponse.etag(from: Data(xml.utf8), root: "CopyObjectResult") == "\"9b2c\"")
    }

    /// CompleteMultipartUpload 可能返回 200 但内容是错误
    @Test func errorBodyWithSuccessStatusThrows() {
        let xml = "<Error><Code>InternalError</Code><Message>We encountered an internal error.</Message></Error>"
        #expect(throws: S3Error.self) {
            try S3XMLResponse.etag(from: Data(xml.utf8), root: "CompleteMultipartUploadResult")
        }
    }

    @Test func parsesDeleteFailures() throws {
        let xml = """
        <DeleteResult><Error><Key>a.txt</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error></DeleteResult>
        """
        let failures = try S3XMLResponse.deleteFailures(from: Data(xml.utf8))
        #expect(failures.count == 1)
        guard case .batchFailed(let key, let code, _) = failures[0] else {
            Issue.record("应为 batchFailed")
            return
        }
        #expect(key == "a.txt")
        #expect(code == "AccessDenied")
        #expect(try S3XMLResponse.deleteFailures(from: Data()).isEmpty)
        #expect(try S3XMLResponse.deleteFailures(from: Data("<DeleteResult></DeleteResult>".utf8)).isEmpty)
    }
}

struct PublicURLTests {
    @Test func appendsEncodedKeyToBase() {
        #expect(S3Client.publicURL(base: URL(string: "https://pub-abc.r2.dev/")!, key: "相册/a b.jpg").absoluteString
            == "https://pub-abc.r2.dev/%E7%9B%B8%E5%86%8C/a%20b.jpg")
        #expect(S3Client.publicURL(base: URL(string: "https://cdn.example.com/files")!, key: "x+y.txt").absoluteString
            == "https://cdn.example.com/files/x%2By.txt")
    }
}

struct CopySourceTests {
    @Test func encodesBucketAndKey() {
        let client = S3Client(
            config: S3Config(endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")!, bucket: "media"),
            credentials: S3Credentials(accessKeyId: "k", secretAccessKey: "s")
        )
        #expect(client.copySource("相册/a b.jpg") == "media/%E7%9B%B8%E5%86%8C/a%20b.jpg")
    }
}
