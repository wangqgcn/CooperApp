import Foundation
import Testing
@testable import SyncCore

struct DriveIdentifierTests {
    let connection = "6F1C2D3E-0000-4000-8000-000000000001"

    @Test func bucketAndItemRoundTrip() {
        #expect(DriveIdentifier(rawValue: connection) == .bucket(connectionID: connection))
        let item = DriveIdentifier(rawValue: "\(connection)/docs/a b.txt")
        #expect(item == .item(connectionID: connection, storeID: "docs/a b.txt"))
        #expect(item?.rawValue == "\(connection)/docs/a b.txt")
        #expect(item?.connectionID == connection)
    }

    @Test func storeRootMapsToBucketFolder() {
        let bucket = DriveIdentifier.forStoreID(DriveIdentifier.storeRootID, connectionID: connection)
        #expect(bucket == .bucket(connectionID: connection))
        #expect(bucket.storeID == DriveIdentifier.storeRootID)
        #expect(DriveIdentifier.forStoreID("docs/", connectionID: connection).rawValue == "\(connection)/docs/")
    }

    @Test func rejectsMalformedIdentifiers() {
        #expect(DriveIdentifier(rawValue: "") == nil)
        #expect(DriveIdentifier(rawValue: "/a.txt") == nil)
        #expect(DriveIdentifier(rawValue: "\(connection)/") == nil)
    }
}

struct DriveNamingTests {
    @Test func duplicatesGetNumberedIgnoringCase() {
        let names = DriveNaming.folderNames([("a", "R2"), ("b", "r2"), ("c", "R2"), ("d", "Backup")])
        #expect(names == ["a": "R2", "b": "r2 2", "c": "R2 3", "d": "Backup"])
    }

    @Test func invalidCharactersAndHiddenNamesAreCleaned() {
        let names = DriveNaming.folderNames([("a", "media/2026:raw"), ("b", ".secret"), ("c", "   ")])
        #expect(names["a"] == "media-2026-raw")
        #expect(names["b"] == "secret")
        #expect(names["c"] == "存储桶")
    }
}

struct WorkingSetAnchorTests {
    @Test func encodesDeterministicallyAndDecodes() {
        let anchor = WorkingSetAnchor(buckets: [
            "b": .init(storeAnchor: "g2:5", folderName: "Backup"),
            "a": .init(storeAnchor: "g1:3", folderName: "R2"),
        ])
        #expect(anchor.data == WorkingSetAnchor(buckets: anchor.buckets).data)
        #expect(WorkingSetAnchor(data: anchor.data) == anchor)
    }

    @Test func legacyAnchorIsRejected() {
        #expect(WorkingSetAnchor(data: Data("empty".utf8)) == nil)
        #expect(WorkingSetAnchor(data: Data("g1:3".utf8)) == nil)
    }
}
