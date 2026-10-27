import Foundation
import XCTest
import SessionKitTestInputs
@testable import SessionKit

/// #2704: the host-testable half of the Phonon voice: what a usable bundle holds, its saved-audio identity, and
/// the one-time compile after download.
final class PhononVoiceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "phonon-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeBundle(voices: [String] = [PhononVoice.defaultVoiceName]) throws {
        for name in PhononModelLocation.requiredFiles { try Data("x".utf8).write(to: folder.appending(path: name)) }
        for package in PhononModelLocation.modelPackages {
            let manifest = folder.appending(path: "\(package)/Manifest.json")
            try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: manifest)
        }
        try FileManager.default.createDirectory(at: folder.appending(path: "voices"), withIntermediateDirectories: true)
        for voice in voices { try Data("v".utf8).write(to: folder.appending(path: "voices/\(voice).safetensors")) }
    }

    private func snapshotEntry() throws -> VoiceModelEntry {
        let snapshot = try TestInputs.data(.voiceCatalogSnapshot, "catalog-snapshot.json")
        let catalog = try JSONDecoder().decode(VoiceModelCatalog.self, from: snapshot)
        return try XCTUnwrap(catalog.voices.first { $0.id == PhononVoice.catalogId })
    }

    // MARK: The bundle

    func testAValidBundleNeedsEveryModelFileAndTheChosenVoice() throws {
        try makeBundle()
        let location = PhononModelLocation(rootURL: folder)
        XCTAssertNoThrow(try location.validate())
        XCTAssertThrowsError(try location.validate(voice: "Pippa")) { XCTAssertEqual($0 as? PhononModelError, .unknownVoice("Pippa")) }
        try FileManager.default.removeItem(at: folder.appending(path: "mimi-c266.mlpackage"))
        XCTAssertThrowsError(try location.validate()) { XCTAssertEqual($0 as? PhononModelError, .missingAsset("mimi-c266.mlpackage")) }
    }

    func testTheDefaultVoiceIsOneOfTheCatalogueVoicesTheSnapshotDownloads() throws {
        let entry = try snapshotEntry()
        XCTAssertTrue(PhononVoice.isKnownVoice(PhononVoice.defaultVoiceName))
        let downloaded = entry.files.map(\.path).filter { $0.hasPrefix("voices/") }.sorted()
        XCTAssertEqual(downloaded, PhononVoice.voiceNames.map { "voices/\($0).safetensors" }.sorted(),
                       "the app's voice list and the catalog's files are the same set")
    }

    // MARK: The saved-audio identity (#64)

    func testEachVoiceHasItsOwnIdentityAndTheEngineIsPhonons() throws {
        let entry = try snapshotEntry()
        let alfie = try XCTUnwrap(PhononRenderSignature.make(entry: entry, voice: "Alfie"))
        let pippa = try XCTUnwrap(PhononRenderSignature.make(entry: entry, voice: "Pippa"))
        XCTAssertEqual(alfie.engine, PhononVoice.engine)
        XCTAssertNotEqual(alfie.digest, pippa.digest, "two voices' audio must never be filed together")
        XCTAssertNotEqual(alfie.voiceStyleHash, pippa.voiceStyleHash)
        XCTAssertEqual(alfie.assetManifestHash, pippa.assetManifestHash)
        XCTAssertEqual(alfie, PhononRenderSignature.make(entry: entry, voice: "Alfie"), "the same bytes give the same identity every time")
        XCTAssertNil(PhononRenderSignature.make(entry: entry, voice: "Grub the Ogre"), "a voice the catalog doesn't download has no identity")
    }

    func testAChangedModelFileChangesTheIdentityButALicenceTextDoesNot() throws {
        let entry = try snapshotEntry()
        let before = try XCTUnwrap(PhononRenderSignature.make(entry: entry, voice: "Alfie"))
        var model = entry
        let weight = try XCTUnwrap(model.files.firstIndex { $0.path.hasSuffix("weight.bin") })
        model.files[weight].sha256 = String(repeating: "a", count: 64)
        XCTAssertNotEqual(PhononRenderSignature.make(entry: model, voice: "Alfie")?.digest, before.digest)
        var licence = entry
        let notice = try XCTUnwrap(licence.files.firstIndex { $0.path == "licenses/NOTICE.txt" })
        licence.files[notice].sha256 = String(repeating: "b", count: 64)
        XCTAssertEqual(PhononRenderSignature.make(entry: licence, voice: "Alfie")?.digest, before.digest)
        var newer = entry
        newer.version = "0.4.3-0000000"
        XCTAssertNotEqual(PhononRenderSignature.make(entry: newer, voice: "Alfie")?.digest, before.digest)
    }

    func testAnotherVoicesEntryHasNoPhononIdentity() throws {
        var entry = try snapshotEntry()
        entry.id = "kokoro-82m"
        XCTAssertNil(PhononRenderSignature.make(entry: entry, voice: "Alfie"))
    }

    // MARK: Preparation

    func testPreparationCompilesEveryPackageInsideTheStagedFolder() async throws {
        try makeBundle()
        let calls = Counter()
        let preparation = PhononVoicePreparation { location in
            calls.add()
            for package in PhononModelLocation.modelPackages {
                try FileManager.default.createDirectory(at: location.compiledURL(of: package), withIntermediateDirectories: true)
            }
        }
        XCTAssertTrue(preparation.needsPreparation, "Settings shows Preparing voice")
        XCTAssertEqual(PhononModelLocation(rootURL: folder).uncompiledPackages().count, 3)
        try await preparation.prepare(stagedFolder: folder, entry: try snapshotEntry())
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(PhononModelLocation(rootURL: folder).uncompiledPackages(), [])
    }

    func testAPartialCompileFromAnEarlierTryIsRemovedFirst() async throws {
        try makeBundle()
        let stale = PhononModelLocation(rootURL: folder).compiledURL(of: "mimi-c266.mlpackage")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: stale.appending(path: "partial.bin"))
        let preparation = PhononVoicePreparation { location in
            XCTAssertEqual(location.uncompiledPackages().count, 3, "the compile starts with no compiled copy")
            for package in PhononModelLocation.modelPackages {
                try FileManager.default.createDirectory(at: location.compiledURL(of: package), withIntermediateDirectories: true)
            }
        }
        try await preparation.prepare(stagedFolder: folder, entry: try snapshotEntry())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.appending(path: "partial.bin").path))
    }

    func testACompileThatLeavesAPackageUncompiledFailsTheInstall() async throws {
        try makeBundle()
        let preparation = PhononVoicePreparation { _ in }
        do {
            try await preparation.prepare(stagedFolder: folder, entry: try snapshotEntry())
            XCTFail("an uncompiled package must leave the voice uninstalled")
        } catch {
            XCTAssertEqual(error as? PhononModelError, .notCompiled("flow-c414-t1.mlpackage"))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
