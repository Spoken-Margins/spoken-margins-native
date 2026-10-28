import XCTest
import SessionKit
import SessionKitSharing
@testable import SpokenMarginsApp

/// #1983: a shared-Margins file that needs a newer app stays in the handoff inbox, so the listener can open it
/// after updating. A damaged file is still removed once it has been tried.
@MainActor
final class KeptPackageHandoffTests: XCTestCase {
    private var temporaryURLs: [URL] = []
    private var suiteNames: [String] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        temporaryURLs.removeAll()
        suiteNames.removeAll()
        try super.tearDownWithError()
    }

    private let launch = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFileThatNeedsANewerAppStaysInTheInboxAndADamagedOneIsRemoved() async throws {
        let h = try makeHarness()
        let newer = try h.store.savePackage(from: try writePacket(manifestSchema: "spoken-margins.package.v99"))
        let damaged = try h.store.savePackage(from: try writeFile(Data("not a zip".utf8)))

        try await h.model.consumePendingSpokenMarginsPackageHandoffs(from: h.store, keptNotices: h.notices, appVersion: "v1", now: launch)

        XCTAssertEqual(try h.store.pendingPayloadIDs(), [newer], "the newer-app file is kept, the damaged one is removed")
        XCTAssertEqual(h.model.diagnostics["pendingSpokenMarginsPackage:\(newer)"], "kept_needs_newer_app")
        XCTAssertEqual(h.model.diagnostics["pendingSpokenMarginsPackage:\(damaged)"], "rejected")
    }

    func testTheMessageComesOncePerAppVersionAndTheFileStaysForTheNextOne() async throws {
        let h = try makeHarness()
        let newer = try h.store.savePackage(from: try writePacket(manifestSchema: "spoken-margins.package.v99"))

        try await h.model.consumePendingSpokenMarginsPackageHandoffs(from: h.store, keptNotices: h.notices, appVersion: "v1", now: launch)
        XCTAssertEqual(h.model.feedbackEvent?.message, "These Margins need a newer Spoken Margins. Update the app, then open them again.")

        h.model.dismissFeedback()
        try await h.model.consumePendingSpokenMarginsPackageHandoffs(from: h.store, keptNotices: h.notices, appVersion: "v1", now: launch.addingTimeInterval(3_600))
        XCTAssertNil(h.model.feedbackEvent, "the same build doesn't repeat the banner")
        XCTAssertEqual(try h.store.pendingPayloadIDs(), [newer], "and the file is still there")

        try await h.model.consumePendingSpokenMarginsPackageHandoffs(from: h.store, keptNotices: h.notices, appVersion: "v2", now: launch.addingTimeInterval(7_200))
        XCTAssertNotNil(h.model.feedbackEvent, "a new build tells again")
    }

    func testAKeptFileIsRemovedAfterThirtyDays() async throws {
        let h = try makeHarness()
        _ = try h.store.savePackage(from: try writePacket(manifestSchema: "spoken-margins.package.v99"))
        try await h.model.consumePendingSpokenMarginsPackageHandoffs(from: h.store, keptNotices: h.notices, appVersion: "v1", now: launch)
        XCTAssertEqual(try h.store.pendingPayloadIDs().count, 1)

        try await h.model.consumePendingSpokenMarginsPackageHandoffs(
            from: h.store, keptNotices: h.notices, appVersion: "v1", now: launch.addingTimeInterval(31 * 24 * 3_600))

        XCTAssertEqual(try h.store.pendingPayloadIDs(), [])
    }

    // MARK: Harness

    private struct Harness {
        let model: Gate1AppModel
        let store: SpokenMarginsPackageHandoffStore
        let notices: KeptPackageNotices
    }

    private func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-kept-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryURLs.append(root)
        let suite = "kept-package-handoff-\(UUID().uuidString)"
        suiteNames.append(suite)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: root.appendingPathComponent("Library.sqlite")
        )
        model.dismissFeedback()
        return Harness(
            model: model,
            store: SpokenMarginsPackageHandoffStore(baseDirectory: root.appendingPathComponent("inbox", isDirectory: true)),
            notices: KeptPackageNotices(defaults: UserDefaults(suiteName: suite)!)
        )
    }

    private func writeFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kept-package-\(UUID().uuidString).spokenmargins")
        try data.write(to: url)
        temporaryURLs.append(url)
        return url
    }

    /// A packet whose manifest names a schema this build doesn't know, as a future app would write.
    private func writePacket(manifestSchema: String) throws -> URL {
        let manifest = Data(#"{"schemaVersion":"\#(manifestSchema)"}"#.utf8)
        return try writeFile(StoredZip.data(entries: [("manifest.json", manifest), ("preview.md", Data())]))
    }
}

/// A minimal ZIP with stored (uncompressed) entries, so a test can write a packet the app's writer would refuse to.
private enum StoredZip {
    static func data(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(out.count)
            out.append(le32(0x0403_4b50)); out.append(le16(20)); out.append(le16(0)); out.append(le16(0))
            out.append(le16(0)); out.append(le16(33)) // 1980-01-01, so the file is reproducible
            out.append(le32(crc)); out.append(le32(UInt32(entry.data.count))); out.append(le32(UInt32(entry.data.count)))
            out.append(le16(UInt16(name.count))); out.append(le16(0)); out.append(name); out.append(entry.data)

            central.append(le32(0x0201_4b50)); central.append(le16(0x031E)); central.append(le16(20))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0)); central.append(le16(33))
            central.append(le32(crc)); central.append(le32(UInt32(entry.data.count))); central.append(le32(UInt32(entry.data.count)))
            central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(UInt32(0o100644) << 16))
            central.append(le32(offset)); central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x0605_4b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(centralOffset)); out.append(le16(0))
        return out
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
