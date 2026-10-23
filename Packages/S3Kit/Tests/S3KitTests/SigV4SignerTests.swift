import Foundation
import Testing
@testable import S3Kit

/// 用 AWS 文档里公开的签名示例校验算法。
struct SigV4SignerTests {
    let signer = SigV4Signer(
        credentials: S3Credentials(
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        ),
        region: "us-east-1"
    )
    /// 2013-05-24T00:00:00Z
    let date = Date(timeIntervalSince1970: 1_369_353_600)

    @Test func getObjectWithRangeHeader() {
        let headers = signer.sign(
            method: "GET",
            url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
            headers: ["Range": "bytes=0-9"],
            payloadHash: SigV4Signer.emptyPayloadHash,
            date: date
        )
        #expect(headers["x-amz-date"] == "20130524T000000Z")
        #expect(headers["Authorization"] ==
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
            + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func listObjectsWithQuery() {
        let headers = signer.sign(
            method: "GET",
            url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!,
            payloadHash: SigV4Signer.emptyPayloadHash,
            date: date
        )
        #expect(headers["Authorization"]?.hasSuffix(
            "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    /// AWS 文档里的预签名示例：有效期 86400 秒
    @Test func presignedGetURL() {
        let url = signer.presign(
            method: "GET",
            url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
            expires: 86400,
            date: date
        )
        #expect(url.absoluteString ==
            "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    @Test func uriEncodeFollowsS3Rules() {
        #expect(SigV4Signer.uriEncode("照片/a b+c~.jpg", encodeSlash: false) == "%E7%85%A7%E7%89%87/a%20b%2Bc~.jpg")
        #expect(SigV4Signer.uriEncode("a/b", encodeSlash: true) == "a%2Fb")
    }

    @Test func canonicalQueryIsSortedAndEncoded() {
        let url = URL(string: "https://h/b?prefix=a%2Fb%20c&list-type=2&delimiter=%2F")!
        #expect(SigV4Signer.canonicalQuery(for: url) == "delimiter=%2F&list-type=2&prefix=a%2Fb%20c")
    }

    @Test func hostHeaderKeepsNonDefaultPort() {
        #expect(SigV4Signer.hostHeader(for: URL(string: "http://localhost:9000/b")!) == "localhost:9000")
        #expect(SigV4Signer.hostHeader(for: URL(string: "https://x.r2.cloudflarestorage.com:443/b")!) == "x.r2.cloudflarestorage.com")
    }
}
