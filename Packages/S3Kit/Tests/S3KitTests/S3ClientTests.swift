import Foundation
import Testing
@testable import S3Kit

struct S3ClientURLTests {
    let credentials = S3Credentials(accessKeyId: "k", secretAccessKey: "s")

    @Test func pathStyleObjectURL() {
        let client = S3Client(
            config: S3Config(endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")!, bucket: "media"),
            credentials: credentials
        )
        #expect(client.url(forKey: "相册/a b.jpg").absoluteString
            == "https://acct.r2.cloudflarestorage.com/media/%E7%9B%B8%E5%86%8C/a%20b.jpg")
        #expect(client.url(forKey: nil, query: [("list-type", "2"), ("prefix", "a/")]).absoluteString
            == "https://acct.r2.cloudflarestorage.com/media?list-type=2&prefix=a%2F")
    }

    @Test func virtualHostedObjectURL() {
        let client = S3Client(
            config: S3Config(endpoint: URL(string: "https://s3.us-east-1.amazonaws.com")!, bucket: "media", region: "us-east-1", usePathStyle: false),
            credentials: credentials
        )
        #expect(client.url(forKey: "a/b.txt").absoluteString == "https://media.s3.us-east-1.amazonaws.com/a/b.txt")
        #expect(client.url(forKey: nil).absoluteString == "https://media.s3.us-east-1.amazonaws.com/")
    }
}

struct ListObjectsParserTests {
    @Test func parsesObjectsPrefixesAndToken() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>media</Name>
          <Prefix>photos/</Prefix>
          <KeyCount>3</KeyCount>
          <MaxKeys>1000</MaxKeys>
          <Delimiter>/</Delimiter>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
          <Contents>
            <Key>photos/</Key>
            <LastModified>2026-10-01T08:00:00.000Z</LastModified>
            <ETag>"d41d8cd98f00b204e9800998ecf8427e"</ETag>
            <Size>0</Size>
          </Contents>
          <Contents>
            <Key>photos/ cover &amp; logo.png</Key>
            <LastModified>2026-10-02T09:30:15Z</LastModified>
            <ETag>"9b2cf535f27731c974343645a3985328"</ETag>
            <Size>2048</Size>
          </Contents>
          <CommonPrefixes><Prefix>photos/2025/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = try ListObjectsParser.parse(Data(xml.utf8))

        #expect(page.objects.map(\.key) == ["photos/", "photos/ cover & logo.png"])
        #expect(page.objects[1].size == 2048)
        #expect(page.objects[1].etag == "9b2cf535f27731c974343645a3985328")
        #expect(page.objects[0].lastModified == Date(timeIntervalSince1970: 1_790_841_600))
        #expect(page.objects[1].lastModified != nil)
        #expect(page.commonPrefixes == ["photos/2025/"])
        #expect(page.isTruncated)
        #expect(page.nextContinuationToken == "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
    }

    @Test func parsesErrorBody() {
        let xml = "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>"
        let error = S3Error.from(status: 404, body: Data(xml.utf8))
        guard case .http(let status, let code, _) = error else {
            Issue.record("应为 http 错误")
            return
        }
        #expect(status == 404)
        #expect(code == "NoSuchKey")
    }
}
