#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitTestInputs
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
        catalogURL: URL? = URL(string: "https://voices.example/voices/v1/catalog.json")!,
        snapshot: [VoiceModelEntry]? = nil,
        snapshotData: Data? = nil,
        served: [String: Data]? = nil,
        playable: Set<String> = ["neural-1"],
        transport: VoiceModelTransport? = nil,
        decompressor: any VoiceModelArchiveDecompressor = BZip2ArchiveDecompressor(),
        memory: Int = 8_192,
        availableBytes: Int64? = nil
    ) throws -> VoiceCatalogCoordinator {
        let served = served ?? Dictionary(uniqueKeysWithValues: files.map { ("https://voices.example/neural-1/\($0.key)", $0.value) })
        return VoiceCatalogCoordinator(
            supportDirectory: root,
            configuration: .init(
                catalogURL: catalogURL,
                trustedKeys: [VoiceCatalogTrustedKey(keyId: "test", publicKey: key.publicKey.rawRepresentation)],
                playableVoiceIds: playable,
                physicalMemoryMegabytes: memory,
                bundledSnapshot: try snapshotData ?? snapshot.map { try catalogData(voices: $0) }
            ),
            fetcher: fetcher,
            transport: transport ?? MemoryTransport(files: served),
            installerConfiguration: .init(marginBytes: 0, attemptsPerSource: 1, retryDelay: .zero, availableCapacity: { _ in availableBytes }, decompressor: decompressor),
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

    func testWithNoCatalogURLRefreshFetchesNothingAndTheSnapshotStays() async throws {
        // The app has no catalog home off the owner's server yet (#2055 audit 2), so it never asks one.
        let fetcher = FixedFetcher(try envelope(version: 3, voices: [entry(memory: 2_048)]))
        let voices = try coordinator(fetcher: fetcher, catalogURL: nil, snapshot: [entry(), kitten])
        let failure = await voices.refresh()
        XCTAssertNil(failure)
        XCTAssertEqual(fetcher.calls, 0)
        let source = await voices.catalogSource
        XCTAssertEqual(source, .bundledSnapshot)
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

    func testAFourGigabyteIPhoneIsOfferedAVoiceThatNeedsFourGigabytes() async throws {
        // An iPhone 12 or 13 has 4 GB on the box but iOS reports about 3,700 MB (#2055 audit 3).
        for (reported, offered) in [(3_662, true), (3_750, true), (4_096, true), (2_867, false), (3_000, false), (5_700, true)] {
            let voices = try coordinator(snapshot: [entry(memory: 4_096), kitten], memory: reported)
            let rows = await voices.rows()
            XCTAssertEqual(rows.contains { $0.id == "neural-1" }, offered, "a phone reporting \(reported) MB")
        }
        XCTAssertEqual(VoiceCatalogCoordinator.nominalMemoryMegabytes(reported: 7_400), 7_168)
        XCTAssertEqual(VoiceCatalogCoordinator.nominalMemoryMegabytes(reported: 0), 0)
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

    /// A file whose text the catalog carries itself (a notice we wrote) has no download source. The
    /// coordinator must hand that text to the installer, not an empty source list (#2055 audit on 2c27e97).
    func testAFileTheCatalogCarriesAsTextIsWrittenWithoutADownload() async throws {
        let notice = "Notice of modification\n"
        var withNotice = entry(restricted: false)
        withNotice.files.append(VoiceModelFile(path: "onnx/MODIFIED.txt", byteCount: notice.utf8.count, sha256: Self.sha256(Data(notice.utf8)),
                                               sources: [], licenseId: "model", content: notice))
        let voices = try coordinator(snapshot: [withNotice])
        let folder = try await voices.install(voiceId: "neural-1")
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "onnx/MODIFIED.txt"), encoding: .utf8), notice)
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "onnx/model.onnx")), files["onnx/model.onnx"])
    }

    /// The sibling of the carried-text case: a file the publisher ships only inside an archive. The
    /// coordinator must pass the archive along with the member, or the install refuses before downloading.
    func testAFileTakenFromAnArchiveIsInstalledFromThatArchive() async throws {
        let graph = Data(repeating: 9, count: 1_500)
        let tar = Self.tar(name: "pkg/vocoder.int8.onnx", data: graph)
        var packed = entry(restricted: false)
        packed.archives = [VoiceModelArchive(id: "int8", byteCount: tar.count, sha256: Self.sha256(tar), sources: ["https://voices.example/int8.tar.bz2"])]
        packed.files.append(VoiceModelFile(path: "onnx/vocoder.onnx", byteCount: graph.count, sha256: Self.sha256(graph), sources: [],
                                           licenseId: "model", archiveMember: VoiceModelArchiveMember(archive: "int8", member: "pkg/vocoder.int8.onnx")))
        var served = Dictionary(uniqueKeysWithValues: files.map { ("https://voices.example/neural-1/\($0.key)", $0.value) })
        served["https://voices.example/int8.tar.bz2"] = tar
        let voices = try coordinator(snapshot: [packed], served: served, decompressor: PlainTar())
        let folder = try await voices.install(voiceId: "neural-1")
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "onnx/vocoder.onnx")), graph)
    }

    /// The Supertonic entry exactly as the app ships it in its snapshot: every source URL and every carried
    /// text as they are. Only the downloaded bytes are stand-ins (their real size and hash are swapped for
    /// the stand-in's), served at the entry's own pinned addresses. Carried text keeps its real hash.
    func testTheShippedSnapshotsSupertonicEntryInstallsFromItsOwnSources() async throws {
        let snapshot = try TestInputs.data(.voiceCatalogSnapshot, "catalog-snapshot.json")
        var catalog = try JSONDecoder().decode(VoiceModelCatalog.self, from: snapshot)
        let id = "supertonic-3-int8"
        let index = try XCTUnwrap(catalog.voices.firstIndex { $0.id == id })
        XCTAssertTrue(catalog.voices[index].files.contains { $0.content != nil }, "the snapshot no longer carries any text; this test lost its point")

        var served: [String: Data] = [:]
        for fileIndex in catalog.voices[index].files.indices where catalog.voices[index].files[fileIndex].content == nil {
            let file = catalog.voices[index].files[fileIndex]
            XCTAssertNil(file.archiveMember)
            let standIn = Data("stand-in for \(file.path)".utf8)
            catalog.voices[index].files[fileIndex].byteCount = standIn.count
            catalog.voices[index].files[fileIndex].sha256 = Self.sha256(standIn)
            let source = try XCTUnwrap(file.sources.first, "\(file.path) has nothing to download from")
            served[source] = standIn
        }
        let transport = RecordingTransport(files: served)
        let voices = try coordinator(snapshotData: try JSONEncoder().encode(catalog), playable: [id], transport: transport)
        let rows = await voices.rows()
        let row = try XCTUnwrap(rows.first { $0.id == id })
        XCTAssertTrue(row.isOffered)
        try await voices.agree(to: row.entry.licenses)

        let folder = try await voices.install(voiceId: id)

        for file in catalog.voices[index].files {
            let placed = try Data(contentsOf: folder.appending(path: file.path))
            XCTAssertEqual(Self.sha256(placed), file.sha256, file.path)
            if let content = file.content { XCTAssertEqual(placed, Data(content.utf8), file.path) }
        }
        XCTAssertEqual(Set(transport.requested), Set(served.keys), "every source asked for, and nothing else")
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

    // MARK: Diagnostics log (#2224)

    private func logged(_ voices: VoiceCatalogCoordinator) -> [VoiceDownloadLog.Event] { voices.log.snapshot }

    func testTheCatalogPathIsLoggedFromTheSnapshotThroughASignedFetch() async throws {
        let voices = try coordinator(fetcher: FixedFetcher(try envelope(version: 3, voices: [entry()])), snapshot: [entry(), kitten])
        _ = await voices.rows()
        _ = await voices.refresh()
        let events = logged(voices)
        XCTAssertEqual(events.map(\.kind), ["catalog.loaded", "catalog.fetch", "catalog.fetched", "catalog.signature_verified"])
        XCTAssertEqual(events[0].fields["source"], "bundled snapshot")
        XCTAssertEqual(events[0].fields["voices"], "2")
        XCTAssertEqual(events[1].fields["host"], "voices.example", "the address is reduced to its host")
        XCTAssertNotNil(events[2].fields["bytes"].flatMap(Int.init))
        XCTAssertEqual(events[3].fields, ["keyId": "test", "catalogVersion": "3", "voices": "1"])
    }

    func testAKeptCatalogIsLoggedWithItsKeyAndVersionOnTheNextLaunch() async throws {
        let first = try coordinator(fetcher: FixedFetcher(try envelope(version: 4, voices: [entry()])))
        _ = await first.refresh()
        let next = try coordinator(snapshot: [kitten])
        _ = await next.rows()
        let loaded = try XCTUnwrap(logged(next).last { $0.kind == "catalog.loaded" })
        XCTAssertEqual(loaded.fields, ["source": "signed catalog kept", "keyId": "test", "catalogVersion": "4", "voices": "1"])
        XCTAssertEqual(logged(next).first?.kind, "catalog.loaded", "the earlier launch's events are still ahead of it")
    }

    func testASkippedFetchSaysWhy() async throws {
        let voices = try coordinator(catalogURL: nil, snapshot: [entry()])
        _ = await voices.refresh()
        let skipped = try XCTUnwrap(logged(voices).first { $0.kind == "catalog.fetch_skipped" })
        XCTAssertEqual(skipped.fields, ["reason": "no catalog address", "source": "bundled snapshot"])
        XCTAssertFalse(logged(voices).contains { $0.kind == "catalog.fetch" })
    }

    func testAFailedFetchAndARejectedCatalogAreLoggedAndSayWhichCatalogStayed() async throws {
        let good = try coordinator(fetcher: FixedFetcher(try envelope(version: 5, voices: [entry()])))
        _ = await good.refresh()

        let offline = try coordinator(fetcher: FixedFetcher(nil))
        _ = await offline.refresh()
        let failedFetch = try XCTUnwrap(logged(offline).last { $0.kind == "catalog.fetch_failed" })
        XCTAssertEqual(failedFetch.fields["reason"], "network error \(URLError.notConnectedToInternet.rawValue)")
        XCTAssertEqual(failedFetch.fields["source"], "signed catalog 5")

        let replayed = try coordinator(fetcher: FixedFetcher(try envelope(version: 4, voices: [])))
        _ = await replayed.refresh()
        let rolledBack = try XCTUnwrap(logged(replayed).last { $0.kind == "catalog.signature_rejected" })
        XCTAssertEqual(rolledBack.fields, ["reason": "rollback: offered 4, already accepted 5", "kept": "signed catalog 5"])

        let tampered = try coordinator(fetcher: FixedFetcher(Data("not a catalog".utf8)))
        _ = await tampered.refresh()
        let malformed = try XCTUnwrap(logged(tampered).last { $0.kind == "catalog.signature_rejected" })
        XCTAssertEqual(malformed.fields["reason"], "malformed envelope")
    }

    func testAnInstallIsLoggedFromStartToFinishAndARemoveSaysWhatItFreed() async throws {
        let voices = try coordinator(snapshot: [entry(), kitten])
        try await voices.agree(to: entry().licenses)
        try await voices.install(voiceId: "neural-1")
        let total = files.values.reduce(0) { $0 + $1.count }
        try await voices.remove(voiceId: "neural-1")

        let events = logged(voices)
        let kinds = events.map(\.kind)
        XCTAssertEqual(kinds.first, "catalog.loaded")
        XCTAssertEqual(kinds.filter { $0 == "install.started" }.count, 1)
        let started = try XCTUnwrap(events.first { $0.kind == "install.started" })
        XCTAssertEqual(started.fields["voice"], "neural-1")
        XCTAssertEqual(started.fields["version"], "3cadd1e+int8-2026-05-11")
        XCTAssertEqual(started.fields["bytesToDownload"], String(total))
        let downloaded = events.filter { $0.kind == "file.download" }.compactMap { $0.fields["file"] }
        XCTAssertEqual(downloaded.sorted(), files.keys.sorted(), "each file's start is logged, by its catalog path and host")
        XCTAssertTrue(events.filter { $0.kind == "file.done" }.allSatisfy { $0.fields["host"] == "voices.example" })
        let finished = try XCTUnwrap(events.first { $0.kind == "install.finished" })
        XCTAssertEqual(finished.fields["bytesOnDisk"], String(total))
        let removed = try XCTUnwrap(events.last)
        XCTAssertEqual(removed.kind, "remove.done")
        XCTAssertEqual(removed.fields["bytesFreed"], String(total))
        let order = ["install.started", "file.download", "file.done", "install.finished", "remove.done"]
        XCTAssertEqual(kinds.filter(order.contains).first, "install.started")
        XCTAssertEqual(kinds.last, "remove.done")
    }

    func testARefusedInstallIsLoggedBeforeAnyByteMoves() async throws {
        let voices = try coordinator(snapshot: [entry(), kitten])
        do {
            try await voices.install(voiceId: "neural-1")
            XCTFail("installed without agreeing to the licence")
        } catch VoiceCatalogCoordinatorError.agreementNeeded {}
        do {
            try await voices.install(voiceId: "nope")
            XCTFail("installed a voice the catalog doesn't have")
        } catch VoiceCatalogCoordinatorError.voiceNotOffered {}
        let refused = logged(voices).filter { $0.kind == "install.refused" }
        XCTAssertEqual(refused.map { $0.fields["reason"] }, ["licence not agreed", "not offered"])
        XCTAssertEqual(refused.first?.fields["licenses"], "model")
        XCTAssertFalse(logged(voices).contains { $0.kind == "install.started" || $0.kind == "file.download" })
    }

    func testAFailedInstallLogsItsReasonAndNoAddress() async throws {
        let voices = try coordinator(snapshot: [entry(restricted: false)], served: [:])
        do {
            try await voices.install(voiceId: "neural-1")
            XCTFail("installed from a server with nothing on it")
        } catch VoiceCatalogCoordinatorError.install {}
        let failed = try XCTUnwrap(logged(voices).last { $0.kind == "install.failed" })
        XCTAssertEqual(failed.fields["kind"], "download failed")
        XCTAssertEqual(failed.fields["voice"], "neural-1")
        XCTAssertEqual(failed.fields["reason"], "the server answered HTTP 404")
        let all = try String(contentsOf: VoiceCatalogCoordinator.downloadLogURL(supportDirectory: root), encoding: .utf8)
        XCTAssertFalse(all.contains("https://"), "only hosts are logged, never a whole address")
        XCTAssertFalse(all.contains(root.path), "no file-system path is logged")
    }

    func testNotEnoughSpaceIsLoggedWithTheNumbers() async throws {
        let voices = try coordinator(snapshot: [entry(restricted: false)], availableBytes: 10)
        _ = try? await voices.install(voiceId: "neural-1")
        let failed = try XCTUnwrap(logged(voices).last { $0.kind == "install.failed" })
        XCTAssertEqual(failed.fields["kind"], "not enough space")
        XCTAssertEqual(failed.fields["availableBytes"], "10")
    }

    func testACancelledInstallIsLoggedAsCancelled() async throws {
        let voices = try coordinator(snapshot: [entry(restricted: false)], transport: StallingTransport())
        let task = Task { try await voices.install(voiceId: "neural-1") }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = try? await task.value
        XCTAssertTrue(logged(voices).contains { $0.kind == "install.cancelled" }, logged(voices).map(\.kind).joined(separator: ","))
    }

    func testVersionFolderNames() {
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: "0.8 fp32, revision 7a1db64"), "0.8_fp32__revision_7a1db64")
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: "..hidden"), "v..hidden")
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: ""), "v")
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: String(repeating: "x", count: 80)).count, 64)
        XCTAssertEqual(VoiceCatalogCoordinator.folderName(forVersion: "voix-é"), "voix-_")
    }

    /// One regular file in a ustar archive, then the two empty blocks that end it.
    private static func tar(name: String, data: Data) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) { for (i, byte) in text.utf8.enumerated() { header[offset + i] = byte } }
        put(name, at: 0)
        put("0000644", at: 100)
        put("0000000", at: 108)
        put("0000000", at: 116)
        put(String(format: "%011o", data.count), at: 124)
        put("00000000000", at: 136)
        header[156] = UInt8(ascii: "0")
        put("ustar", at: 257)
        put("00", at: 263)
        for i in 148..<156 { header[i] = UInt8(ascii: " ") }
        put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", at: 148)
        var out = Data(header) + data
        out += Data(count: (512 - data.count % 512) % 512)
        return out + Data(count: 1_024)
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

/// Hands the tar over unchanged under the tar.bz2 label, so the test needs no bzip2.
private struct PlainTar: VoiceModelArchiveDecompressor {
    var formats: Set<String> { ["tar.bz2"] }
    func tarBytes(of url: URL, format: String, onChunk: (Data) throws -> Void) throws {
        try onChunk(Data(contentsOf: url))
    }
}

/// A `MemoryTransport` that remembers every address it was asked for.
private final class RecordingTransport: VoiceModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: MemoryTransport
    private var urls: [String] = []

    init(files: [String: Data]) { inner = MemoryTransport(files: files) }

    var requested: [String] { lock.withLock { urls } }

    func fetch(
        _ url: URL,
        from offset: Int,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        lock.withLock { urls.append(url.absoluteString) }
        try await inner.fetch(url, from: offset, onHead: onHead, onChunk: onChunk)
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

/// Never delivers a byte, until the task is cancelled.
private struct StallingTransport: VoiceModelTransport {
    func fetch(
        _ url: URL,
        from offset: Int,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        _ = try onHead(VoiceModelResponseHead(statusCode: 200))
        try await Task.sleep(for: .seconds(60))
    }
}
