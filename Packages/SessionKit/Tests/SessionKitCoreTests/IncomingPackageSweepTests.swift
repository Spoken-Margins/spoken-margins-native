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

    /// #2246: imported folders are kept for good, so a long-time listener has many of them on every cold launch. The
    /// sweep read every imported payload once per folder; it now reads them once, whatever the folder count.
    func testTheImportedPayloadsAreReadOncePerLaunchHoweverManyFoldersThereAre() throws {
        let used = try stagedFolder(files: ["assets/voice.m4a"])
        try saveImportedMargin(audioPath: audioPath(in: used, file: "assets/voice.m4a"))
        let meter = StoreReadMeter()
        let metered = try SQLiteSessionStore(path: databasePath, readMeter: meter)
        var reads: [Int: Int] = [:]
        for orphans in [1, 40] {
            let created = try (0..<orphans).map { _ in try stagedFolder(files: ["package.spokenmargins"]) }
            meter.reset()

            let outcome = IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: metered)

            XCTAssertEqual(Set(outcome.removed), Set(created))
            XCTAssertEqual(outcome.kept, [used])
            reads[orphans] = meter.samples.count
            XCTAssertEqual(meter.totals(for: "imported_commentary_mentions").calls, 0, "no scan of the payloads per folder")
        }
        XCTAssertEqual(reads[1], reads[40], "the number of payload reads does not grow with the number of folders")
        XCTAssertLessThanOrEqual(try XCTUnwrap(reads[40]), 2, "one pass over the live rows and one over the quarantined ones")
    }

    func testTheBatchCheckFindsAFolderNamedInAnyCaseOrBesideOtherText() throws {
        let lower = UUID().uuidString.lowercased(), upper = UUID().uuidString, unmentioned = UUID().uuidString
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            VALUES ('imported_commentary_interjection', 'held', ?, 'newer build', '2026-02-03 04:05:06');
            """, bindings: ["{\"audioPath\":\"\\/var\\/IncomingPackages\\/\(lower)\\/a.m4a\",\"other\":\"x\(upper)y\"}"], at: databasePath)

        let found = try store.importedCommentaryRecordsMentioning(among: [lower, upper, unmentioned])

        XCTAssertEqual(found, [lower, upper], "a name inside escaped slashes or between letters still counts; another UUID does not")
        XCTAssertEqual(try store.importedCommentaryRecordsMentioning(among: [lower.uppercased()]), [],
                       "the match is case-sensitive, as the single-name check is")
    }

    func testAFolderNameThatIsNotUUIDShapedIsReportedUsedSoItIsKept() throws {
        XCTAssertEqual(try store.importedCommentaryRecordsMentioning(among: ["not-a-uuid"]), ["not-a-uuid"])
        XCTAssertEqual(try store.importedCommentaryRecordsMentioning(among: []), [])
    }

    func testTheBatchCheckAgreesWithTheSingleNameCheckOnEveryFolder() throws {
        let names = try (0..<6).map { _ in try stagedFolder(files: ["package.spokenmargins"]) }
        try saveImportedMargin(audioPath: audioPath(in: names[2], file: "assets/voice.m4a"))
        try store.saveImportedCommentaryLayer(makeLayer(episodeMapEvidencePaths: ["s": audioPath(in: names[4], file: "m.bin")]))

        let batch = try store.importedCommentaryRecordsMentioning(among: Set(names))

        XCTAssertEqual(batch, Set(try names.filter { try store.importedCommentaryRecordsMention($0) }))
        XCTAssertEqual(batch, [names[2], names[4]])
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
