import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// The launch sweep of `IncomingPackages/` (#2154), on real folders and a real SQLite Library: a staged folder
/// that an app kill left behind goes, and a folder an imported Margin plays from stays.
final class IncomingPackageSweepTests: XCTestCase {
    private var root: URL!
    private var incoming: URL!
    private var databasePath: String!
    private var store: SQLiteSessionStore!
    private let date = Date(timeIntervalSince1970: 1_777_000_000)
    private let identity = SharedItemIdentity(itemType: .podcast, canonicalURL: "https://podcasts.example.com/episodes/harbour-lights", title: "Harbour Lights")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-sweep-\(UUID().uuidString)", isDirectory: true)
        incoming = root.appendingPathComponent("SpokenMargins/IncomingPackages", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        databasePath = root.appendingPathComponent("library.sqlite").path
        store = try SQLiteSessionStore(path: databasePath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnOrphanedStagedFolderIsRemovedWithItsFiles() throws {
        let orphan = try stagedFolder(files: ["package.spokenmargins", "assets/voice.m4a"])

        let outcome = IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: store)

        XCTAssertEqual(outcome.removed, [orphan])
        XCTAssertEqual(try folderNames(), [])
    }

    func testAFolderOutsideTheListedSetIsNeverACandidate() throws {
        let listed = try stagedFolder(files: ["package.spokenmargins"])
        let stagedMeanwhile = try stagedFolder(files: ["package.spokenmargins"])

        let outcome = IncomingPackageSweep.sweep(directory: incoming, keeping: [], only: [listed], store: store)

        XCTAssertEqual(outcome.removed, [listed])
        XCTAssertEqual(try folderNames(), [stagedMeanwhile], "a folder staged after the listing is left alone")
    }

    func testAFolderAnImportedMarginPlaysFromStays() throws {
        let used = try stagedFolder(files: ["package.spokenmargins", "assets/voice.m4a"])
        let orphan = try stagedFolder(files: ["package.spokenmargins"])
        try saveImportedMargin(audioPath: audioPath(in: used, file: "assets/voice.m4a"))

        let outcome = IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: store)

        XCTAssertEqual(outcome.removed, [orphan])
        XCTAssertEqual(outcome.kept, [used])
        XCTAssertEqual(try folderNames(), [used])
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("\(used)/assets/voice.m4a").path),
                      "the recording the Margin plays is still there")
    }

    func testAFolderStaysWhoseMarginWasSavedUnderAnotherContainerPath() throws {
        let used = try stagedFolder(files: ["assets/voice.m4a"])
        try saveImportedMargin(audioPath: "/private/var/mobile/Containers/Data/Application/OLD/Library/Application Support/SpokenMargins/IncomingPackages/\(used)/assets/voice.m4a")

        IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: store)

        XCTAssertEqual(try folderNames(), [used], "the moved container's path still names the folder")
    }

    func testAFolderStaysWhenOnlyTheLayerNamesIt() throws {
        let used = try stagedFolder(files: ["assets/map.bin"])
        try store.saveImportedCommentaryLayer(makeLayer(
            episodeMapEvidencePaths: ["signature-1": audioPath(in: used, file: "assets/map.bin")]))

        IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: store)

        XCTAssertEqual(try folderNames(), [used])
    }

    func testAFolderStaysWhenOnlyAQuarantinedMarginNamesIt() throws {
        let used = try stagedFolder(files: ["assets/voice.m4a"])
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            VALUES ('imported_commentary_interjection', 'held', ?, 'newer build', '2026-02-03 04:05:06');
            """, bindings: ["{\"audioPath\":\"\(audioPath(in: used, file: "assets/voice.m4a"))\"}"], at: databasePath)

        IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: store)

        XCTAssertEqual(try folderNames(), [used], "a row this build can't decode still uses its recording")
    }

    func testAFolderAReviewOwnsStaysUntilItIsDone() throws {
        let reviewing = try stagedFolder(files: ["package.spokenmargins"])
        let orphan = try stagedFolder(files: ["package.spokenmargins"])

        let outcome = IncomingPackageSweep.sweep(directory: incoming, keeping: [reviewing], store: store)

        XCTAssertEqual(outcome.removed, [orphan])
        XCTAssertEqual(try folderNames(), [reviewing])
    }

    func testKillAndRelaunchTwiceLeavesOneStagedCopy() throws {
        // Each launch sweeps, then stages the packet that waits in the Share inbox into a fresh folder.
        var latest = ""
        for _ in 1...2 {
            IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: store)
            latest = try stagedFolder(files: ["package.spokenmargins"])
        }
        XCTAssertEqual(try folderNames(), [latest])
    }

    func testOnlyUUIDFoldersAreTouched() throws {
        try FileManager.default.createDirectory(at: incoming.appendingPathComponent("notes", isDirectory: true), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: incoming.appendingPathComponent("\(UUID().uuidString)"))
        let orphan = try stagedFolder(files: ["package.spokenmargins"])

        let outcome = IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: store)

        XCTAssertEqual(outcome.removed, [orphan])
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("notes").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: incoming.path).count, 2, "a plain file and a non-UUID folder stay")
    }

    func testNothingIsRemovedWhenTheUseCheckFails() throws {
        let folder = try stagedFolder(files: ["package.spokenmargins"])
        struct Unreadable: Error {}

        let outcome = IncomingPackageSweep.sweep(directory: incoming, keeping: [], isUsed: { _ in throw Unreadable() })

        XCTAssertEqual(outcome.removed, [])
        XCTAssertEqual(outcome.kept, [folder])
        XCTAssertEqual(try folderNames(), [folder], "when the Library can't be read, no folder is guessed unused")
    }

    func testAMissingFolderIsNotAnError() {
        let outcome = IncomingPackageSweep.sweep(
            directory: root.appendingPathComponent("never-made"), keeping: [], store: store)
        XCTAssertEqual(outcome, IncomingPackageSweep.Outcome())
    }

    // MARK: Fixtures

    private func stagedFolder(files: [String]) throws -> String {
        let name = UUID().uuidString
        for file in files {
            let url = incoming.appendingPathComponent("\(name)/\(file)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bytes".utf8).write(to: url)
        }
        return name
    }

    private func folderNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: incoming.path).sorted()
    }

    private func audioPath(in folder: String, file: String) -> String {
        incoming.appendingPathComponent("\(folder)/\(file)").path
    }

    private func makeLayer(episodeMapEvidencePaths: [String: String]? = nil) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "packet-digest", packageId: "packet",
                                itemIdentity: identity, displayLabel: "Friend", importedAt: date,
                                sourceResolutionStatus: .contextOnly, isEnabled: true, isMuted: false,
                                episodeMapEvidencePaths: episodeMapEvidencePaths)
    }

    private func saveImportedMargin(audioPath: String) throws {
        try store.saveImportedCommentaryLayer(makeLayer())
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: "margin", layerId: "layer", packageScopedId: "margin-001", createdAt: date,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000),
            approvedTranscript: "Keep this thought", audioPath: audioPath, audioDurationMs: 500,
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 9_000)))
    }
}
