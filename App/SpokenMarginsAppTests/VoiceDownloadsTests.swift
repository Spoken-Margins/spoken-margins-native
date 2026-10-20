import CryptoKit
import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// Settings › Voices in the app (#1819 point 7): a voice installs from a local fixture catalog, Storage grows by
/// its size, and Remove gives the space back. Real SQLite, the app's Storage ledger and the real installer;
/// the network is a fixture served from memory.
@MainActor
final class VoiceDownloadsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testInstallingAVoiceGrowsStorageAndRemoveShrinksItAgain() async throws {
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: root)
        let bytes = Data(repeating: 3, count: 250_000)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let entry = VoiceModelEntry(
            id: "supertonic-3-int8", displayName: "Supertonic 3", publisher: "Fixture", version: "1+test",
            runtime: VoiceModelRuntime(name: "onnxruntime", version: "1.24.2"), minimumIOSVersion: "26.0", minimumMemoryMegabytes: 1,
            files: [VoiceModelFile(path: "onnx/fixture.onnx", byteCount: bytes.count, sha256: digest, sources: ["https://fixture.invalid/onnx/fixture.onnx"])],
            licenses: [VoiceModelLicense(id: "model", name: "Fixture licence", textURL: "https://fixture.invalid/licence",
                                         textSHA256: digest, requiresAcceptance: true, restrictionsSummary: "No harm.")]
        )
        let snapshot = try JSONEncoder().encode(VoiceModelCatalog(catalogVersion: 1, issuedAt: "2026-10-18T00:00:00Z", voices: [entry]))
        let coordinator = VoiceCatalogCoordinator(
            supportDirectory: root,
            configuration: .init(catalogURL: URL(string: "https://fixture.invalid/catalog.json")!, trustedKeys: [],
                                 playableVoiceIds: VoiceDownloadsModel.playableVoiceIds, bundledSnapshot: snapshot),
            transport: FixtureTransport(files: ["https://fixture.invalid/onnx/fixture.onnx": bytes]),
            installerConfiguration: .init(marginBytes: 0, attemptsPerSource: 1, retryDelay: .zero, availableCapacity: { _ in nil }),
            repository: store
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voice-downloads-\(UUID().uuidString)"))
        let voices = VoiceDownloadsModel(coordinator: coordinator, defaults: defaults)
        var changes = 0
        voices.onInstalledVoicesChanged = { changes += 1 }

        await voices.reload()
        let before = try await ledger.presentationSnapshot().usedBytes
        let row = try XCTUnwrap(voices.rows.first)
        XCTAssertEqual(row.licensesNeedingAgreement.map(\.id), ["model"], "the restricted licence comes before the download")

        voices.agreeAndDownload(row)
        try await waitUntil { voices.rows.first?.state != .notInstalled && voices.activity[row.id] == .idle }
        let afterInstall = try await ledger.presentationSnapshot()
        XCTAssertEqual(afterInstall.usedBytes - before, Int64(bytes.count), "Storage grows by the voice's size")
        XCTAssertEqual(afterInstall.categories.map(\.title), ["Downloaded voices"])
        XCTAssertNotNil(VoiceCatalogCoordinator.installedFolder(voiceId: row.id, supportDirectory: root))

        voices.remove(row.id)
        try await waitUntil { voices.rows.first?.state == .notInstalled && voices.activity[row.id] == .idle }
        let afterRemove = try await ledger.presentationSnapshot()
        XCTAssertEqual(afterRemove.usedBytes, before, "Remove gives the space back")
        XCTAssertNil(VoiceCatalogCoordinator.installedFolder(voiceId: row.id, supportDirectory: root))
        XCTAssertEqual(changes, 2)
    }

    func testTheBundledSnapshotOffersSupertonicWithItsLicenceAndKittenAsIncluded() async throws {
        let voices = VoiceDownloadsModel.make(supportDirectory: root, repository: nil)
        await voices.reload()
        XCTAssertEqual(voices.source, .bundledSnapshot)
        let supertonic = try XCTUnwrap(voices.rows.first { $0.id == SupertonicAssetResolver.catalogVoiceId })
        XCTAssertEqual(supertonic.state, .notInstalled)
        XCTAssertGreaterThan(supertonic.entry.downloadByteCount, 140_000_000)
        let restricted = try XCTUnwrap(supertonic.licensesNeedingAgreement.first)
        XCTAssertNotNil(VoiceLicenseView.bundledText(sha256: restricted.textSHA256), "the Open RAIL-M text opens offline")
        XCTAssertEqual(voices.rows.first { $0.entry.bundled }?.state, .bundled)
        XCTAssertFalse(voices.rows.contains { $0.id.hasPrefix("pocket") }, "no player for Pocket TTS in this build")
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct FixtureTransport: VoiceModelTransport {
    let files: [String: Data]

    func fetch(
        _ url: URL,
        from offset: Int,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        guard let data = files[url.absoluteString] else {
            _ = try onHead(VoiceModelResponseHead(statusCode: 404))
            return
        }
        guard try onHead(offset > 0 ? VoiceModelResponseHead(statusCode: 206, contentRangeStart: offset) : VoiceModelResponseHead(statusCode: 200)) else { return }
        try onChunk(data.subdata(in: offset..<data.count))
    }
}
