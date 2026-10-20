#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// Settings › Voices (#1819): the catalog the listener sees, the licence agreement, install and remove,
/// and the Storage row. Real files, real SQLite and the real installer; only the network is in memory.
final class VoiceCatalogCoordinatorTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private let key = Curve25519.Signing.PrivateKey()
    private let files: [String: Data] = [
        "onnx/model.onnx": Data(repeating: 7, count: 40_000),
        "voice_styles/F1.json": Data("{\"style\":1}".utf8),
    ]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private func entry(id: String = "neural-1", version: String = "3cadd1e+int8-2026-05-11", status: VoiceModelStatus = .available,
                       memory: Int = 1_024, restricted: Bool = true, licenseText: String = "a") -> VoiceModelEntry {
        VoiceModelEntry(
            id: id, displayName: "Neural One", publisher: "Example Voices", version: version,
            runtime: VoiceModelRuntime(name: "onnxruntime", version: "1.24.2"), minimumIOSVersion: "26.0",
            minimumMemoryMegabytes: memory, status: status, supersededBy: status == .superseded ? "neural-2" : nil,
            files: files.keys.sorted().map { path in
                VoiceModelFile(path: path, byteCount: files[path]!.count, sha256: Self.sha256(files[path]!),
                               sources: ["https://voices.example/\(id)/\(path)"], licenseId: "model")
            },
            licenses: [VoiceModelLicense(
                id: "model", name: "Model licence", textURL: "https://voices.example/licence",
                textSHA256: Self.sha256(Data(licenseText.utf8)), requiresAcceptance: restricted,
                restrictionsSummary: restricted ? "Don't use it to harm people." : nil
            )]
        )
    }

    private let kitten = VoiceModelEntry(
        id: "kitten", displayName: "Kitten", publisher: "KittenML", version: "0.8",
        runtime: VoiceModelRuntime(name: "onnxruntime", version: "1.24.2"), minimumIOSVersion: "26.0",
        minimumMemoryMegabytes: 1, bundled: true, files: [],
        licenses: [VoiceModelLicense(id: "apache", name: "Apache 2.0", spdxId: "Apache-2.0", textURL: "https://voices.example/apache",
                                     textSHA256: String(repeating: "a", count: 64), requiresAcceptance: false)]
    )

    private func catalogData(version: Int = 1, voices: [VoiceModelEntry]) throws -> Data {
        try JSONEncoder().encode(VoiceModelCatalog(catalogVersion: version, issuedAt: "2026-10-18T00:00:00Z", voices: voices))
    }

    private func envelope(version: Int = 1, voices: [VoiceModelEntry]) throws -> Data {
        let payload = try catalogData(version: version, voices: voices)
        let signature = try key.signature(for: VoiceModelCatalogVerifier.signingContext + payload)
        return try JSONEncoder().encode(VoiceModelCatalogEnvelope(keyId: "test", payload: payload.base64EncodedString(), signature: signature.base64EncodedString()))
    }

    private func coordinator(
        fetcher: FixedFetcher = FixedFetcher(nil),
        snapshot: [VoiceModelEntry]? = nil,
        memory: Int = 8_192,
        availableBytes: Int64? = nil
    ) throws -> VoiceCatalogCoordinator {
        let served = Dictionary(uniqueKeysWithValues: files.map { ("https://voices.example/neural-1/\($0.key)", $0.value) })
        return VoiceCatalogCoordinator(
            supportDirectory: root,
            configuration: .init(
                catalogURL: URL(string: "https://voices.example/voices/v1/catalog.json")!,
                trustedKeys: [VoiceCatalogTrustedKey(keyId: "test", publicKey: key.publicKey.rawRepresentation)],
                playableVoiceIds: ["neural-1"],
                physicalMemoryMegabytes: memory,
                bundledSnapshot: try snapshot.map { try catalogData(voices: $0) }
            ),
            fetcher: fetcher,
            transport: MemoryTransport(files: served),
            installerConfiguration: .init(marginBytes: 0, attemptsPerSource: 1, retryDelay: .zero, availableCapacity: { _ in availableBytes }),
            repository: store,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    // MARK: Where the catalog comes from

    func testWithNothingVerifiedTheBundledSnapshotIsOfferedWithoutTouchingTheNetwork() async throws {
        let fetcher = FixedFetcher(nil)
        let voices = try coordinator(fetcher: fetcher, snapshot: [entry(), kitten])
        let rows = await voices.rows()
        XCTAssertEqual(rows.map(\.id), ["neural-1", "kitten"])
        XCTAssertEqual(rows.first?.state, .notInstalled)
        XCTAssertEqual(rows.last?.state, .bundled)
        let source = await voices.catalogSource
        XCTAssertEqual(source, .bundledSnapshot)
        XCTAssertEqual(fetcher.calls, 0, "opening the rows must not fetch: the catalog is fetched only on refresh")
    }

    func testAVerifiedCatalogReplacesTheSnapshotAndIsKeptForTheNextLaunch() async throws {
        let signed = try envelope(version: 3, voices: [entry(memory: 2_048)])
        let first = try coordinator(fetcher: FixedFetcher(signed), snapshot: [entry(), kitten])
        let failure = await first.refresh()
        XCTAssertNil(failure)
        let source = await first.catalogSource
        XCTAssertEqual(source, .verified(catalogVersion: 3))

        // Next launch, offline: the kept catalog, not the snapshot.
        let offline = try coordinator(fetcher: FixedFetcher(nil), snapshot: [entry(), kitten])
        let rows = await offline.rows()
        XCTAssertEqual(rows.map(\.entry.minimumMemoryMegabytes), [2_048])
        let offlineSource = await offline.catalogSource
        XCTAssertEqual(offlineSource, .verified(catalogVersion: 3))
    }

    func testABadOrOlderCatalogLeavesTheLastGoodOneInPlace() async throws {
        let voices = try coordinator(fetcher: FixedFetcher(try envelope(version: 5, voices: [entry()])), snapshot: [kitten])
        _ = await voices.refresh()

        let tampered = try coordinator(fetcher: FixedFetcher(Data("not a catalog".utf8)))
        let tamperedFailure = await tampered.refresh()
        XCTAssertEqual(tamperedFailure, .malformedEnvelope)
        let afterTamper = await tampered.catalogSource
        XCTAssertEqual(afterTamper, .verified(catalogVersion: 5))

        let replayed = try coordinator(fetcher: FixedFetcher(try envelope(version: 4, voices: [])))
        let replayFailure = await replayed.refresh()
        XCTAssertEqual(replayFailure, .rollback(lastAccepted: 5, offered: 4))
        let rows = await replayed.rows()
        XCTAssertEqual(rows.map(\.id), ["neural-1"])
    }

    func testVoicesThisBuildCannotPlayOrThisPhoneCannotRunAreNotShown() async throws {
        let voices = try coordinator(snapshot: [entry(memory: 16_384), entry(id: "unknown-engine"), kitten], memory: 8_192)
        let rows = await voices.rows()
        XCTAssertEqual(rows.map(\.id), ["kitten"])
    }

    // MARK: Agreement

    func testARestrictedLicenceMustBeAgreedBeforeAnyByteDownloads() async throws {
        let voices = try coordinator(snapshot: [entry()])
        do {
            try await voices.install(voiceId: "neural-1")
            XCTFail("installed without an agreement")
        } catch VoiceCatalogCoordinatorError.agreementNeeded(let ids) {
            XCTAssertEqual(ids, ["model"])
        }
        XCTAssertNil(VoiceCatalogCoordinator.installedFolder(voiceId: "neural-1", supportDirectory: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Voices/.staging").path), "nothing was staged")

        let licence = try XCTUnwrap(entry().licenses.first)
        try await voices.agree(to: [licence])
        let rows = await voices.rows()
        XCTAssertEqual(rows.first?.licensesNeedingAgreement, [])
        let agreements = await voices.agreements()
        XCTAssertEqual(agreements, [VoiceLicenseAgreement(licenseId: "model", textSHA256: licence.textSHA256, agreedAt: Date(timeIntervalSince1970: 1_800_000_000))])
    }

    func testAChangedLicenceTextNeedsANewAgreement() async throws {
        let voices = try coordinator(snapshot: [entry(licenseText: "first wording")])
        try await voices.agree(to: entry(licenseText: "first wording").licenses)
        let reworded = try coordinator(snapshot: [entry(licenseText: "second wording")])
        let rows = await reworded.rows()
        XCTAssertEqual(rows.first?.licensesNeedingAgreement.map(\.id), ["model"])
    }

    func testAnUnrestrictedLicenceNeedsNoAgreement() async throws {
        let voices = try coordinator(snapshot: [entry(restricted: false)])
        try await voices.install(voiceId: "neural-1")
        XCTAssertNotNil(VoiceCatalogCoordinator.installedFolder(voiceId: "neural-1", supportDirectory: root))
    }

    // MARK: Install, Storage and remove

    func testInstallPutsTheFilesInPlaceAndStorageCountsThemUntilRemove() async throws {
        let voices = try coordinator(snapshot: [entry(), kitten])
        try await voices.agree(to: entry().licenses)
        let folder = try await voices.install(voiceId: "neural-1")

        XCTAssertEqual(folder.lastPathComponent, "3cadd1e_int8-2026-05-11", "the + in the catalog version can't be a folder name")
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "onnx/model.onnx")), files["onnx/model.onnx"])
        XCTAssertEqual(VoiceCatalogCoordinator.installedFolder(voiceId: "neural-1", supportDirectory: root)?.standardizedFileURL, folder.standardizedFileURL)
        let total = Int64(files.values.reduce(0) { $0 + $1.count })
        let rows = await voices.rows()
        XCTAssertEqual(rows.first?.state, .installed(version: "3cadd1e_int8-2026-05-11", byteCount: total))

        let assets = try store.loadOwnedOfflineAssets()
        XCTAssertEqual(assets.map(\.id), ["voice-model-neural-1"])
        XCTAssertEqual(assets.first?.relativePath, "Voices/neural-1")
        XCTAssertEqual(assets.first?.isReproducible, false)
        XCTAssertEqual(assets.first?.isAutomaticallyEvictable, false, "Storage must never clear a voice on its own")
        let snapshot = OfflineStorageSnapshot.make(budget: OfflineStorageBudget(), assets: assets, reservations: [])
        XCTAssertEqual(snapshot.usedBytes, total)
        XCTAssertEqual(snapshot.categories.map(\.title), ["Downloaded voices"])

        // Reconciliation leaves a row that names a folder alone (#259), so the voice keeps counting.
        let plan = OfflineLedgerReconciliation.plan(assets: assets) { _ in .other }
        XCTAssertTrue(plan.isEmpty)

        try await voices.remove(voiceId: "neural-1")
        XCTAssertNil(VoiceCatalogCoordinator.installedFolder(voiceId: "neural-1", supportDirectory: root))
        XCTAssertEqual(try store.loadOwnedOfflineAssets(), [])
        let afterRemove = await voices.rows()
        XCTAssertEqual(afterRemove.first?.state, .notInstalled)
    }

    func testRemoveDeletesOnlyThatVoice() async throws {
        let neighbour = root.appending(path: "Voices/other-voice/1/file.bin")
        try FileManager.default.createDirectory(at: neighbour.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: neighbour)
        let voices = try coordinator(snapshot: [entry(restricted: false)])
        try await voices.install(voiceId: "neural-1")
        try await voices.remove(voiceId: "neural-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
    }

    func testNotEnoughSpaceSaysHowMuchInPlainWords() async throws {
        let voices = try coordinator(snapshot: [entry(restricted: false)], availableBytes: 10)
        do {
            try await voices.install(voiceId: "neural-1")
            XCTFail("installed with no room")
        } catch let error as VoiceCatalogCoordinatorError {
            XCTAssertEqual(error.errorDescription, "Not enough space: needs 1 MB.")
        }
        XCTAssertEqual(VoiceCatalogCoordinator.plainWords(for: .insufficientSpace(neededBytes: 159_400_001, availableBytes: 0)), "Not enough space: needs 160 MB.")
    }

    func testAWithdrawnVoiceIsNotOfferedButAnInstalledCopyStaysAndCanBeRemoved() async throws {
        let voices = try coordinator(fetcher: FixedFetcher(try envelope(version: 1, voices: [entry(restricted: false)])))
        _ = await voices.refresh()
        try await voices.install(voiceId: "neural-1")

        let withdrawn = try coordinator(fetcher: FixedFetcher(try envelope(version: 2, voices: [entry(status: .withdrawn, restricted: false)])))
        _ = await withdrawn.refresh()
        let rows = await withdrawn.rows()
        XCTAssertEqual(rows.map(\.isOffered), [false])
        XCTAssertNotNil(VoiceCatalogCoordinator.installedFolder(voiceId: "neural-1", supportDirectory: root), "the installed copy keeps working")
        do {
            try await withdrawn.install(voiceId: "neural-1")
            XCTFail("a withdrawn voice downloaded again")
        } catch VoiceCatalogCoordinatorError.voiceNotOffered {}
        try await withdrawn.remove(voiceId: "neural-1")
        let afterRemove = await withdrawn.rows()
        XCTAssertEqual(afterRemove, [], "withdrawn and not installed: nothing to show")
    }

    func testVersionFolderNames() {
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: "0.8 fp32, revision 7a1db64"), "0.8_fp32__revision_7a1db64")
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: "..hidden"), "v..hidden")
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: ""), "v")
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: String(repeating: "x", count: 80)).count, 64)
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: "voix-é"), "voix-_")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class FixedFetcher: VoiceCatalogFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data?
    private var count = 0

    init(_ data: Data?) { self.data = data }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func fetchEnvelope(from url: URL) async throws -> Data {
        lock.withLock { count += 1 }
        guard let data else { throw URLError(.notConnectedToInternet) }
        return data
    }
}

/// Serves whole files from memory, honouring a resume offset with a 206.
private struct MemoryTransport: VoiceModelTransport {
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
        let head = offset > 0 ? VoiceModelResponseHead(statusCode: 206, contentRangeStart: offset) : VoiceModelResponseHead(statusCode: 200)
        guard try onHead(head) else { return }
        try onChunk(data.subdata(in: offset..<data.count))
    }
}
