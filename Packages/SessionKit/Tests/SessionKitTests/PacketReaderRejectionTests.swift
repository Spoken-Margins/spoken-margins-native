import Foundation
import SessionKit
import SessionKitSharing
import XCTest
import ZIPFoundation

/// The read side of the packet trust boundary: every file that arrives from another person's phone goes through
/// `SpokenMarginsPackageArchive.read` (PKT-03 of the #1039 audit). SharingTests covers an unsupported schema, a
/// tampered artifact and an unknown required capability; PacketCompressionRatioTests covers a runaway
/// compression ratio; SharingTests (#913) covers a repeated descriptor. This file covers the rest of
/// `SpokenMarginsPackageArchiveError`: each case builds a good packet, damages the raw zip in one way, and expects
/// that exact error.
final class PacketReaderRejectionTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PacketReaderRejectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private func goodPacketEntries() throws -> [(path: String, data: Data)] {
        let item = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
        let revision = InterjectionShareRevision(
            id: "revision-approved", interjectionId: "private-note", itemId: "private-item",
            sessionId: "private-session", createdAt: created, approvedTranscript: "A sender-reviewed thought.",
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-article-001", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: revision,
                anchor: .init(anchorType: .text, exactText: "The durable idea that prompted this note."),
                representation: .textOnly
            )],
            senderDisplayLabel: "A Friend", suggestedRevealMode: .companion
        )
        let url = root.appendingPathComponent("good-\(UUID().uuidString).spokenmargins")
        try exportPacket(prepared, to: url)
        let archive = try Archive(url: url, accessMode: .read)
        return try archive.map { entry in
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            return (entry.path, data)
        }
    }

    /// Writes entries in the order given (so a path can appear twice), each stored or deflated as asked.
    private func writeArchive(
        _ entries: [(path: String, data: Data)], stored: Set<String> = [], to url: URL
    ) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                modificationDate: Date(timeIntervalSince1970: 315_532_800), permissions: 0o644,
                compressionMethod: stored.contains(path) || path.hasPrefix("assets/") ? .none : .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
    }

    private func assertReadFails(
        _ entries: [(path: String, data: Data)], stored: Set<String> = [],
        with expected: SpokenMarginsPackageArchiveError, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = root.appendingPathComponent("damaged-\(UUID().uuidString).spokenmargins")
        try writeArchive(entries, stored: stored, to: url)
        XCTAssertThrowsError(
            try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("out-\(UUID().uuidString)")),
            message, file: file, line: line
        ) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, expected, message, file: file, line: line)
        }
    }

    func testTheGoodPacketReadsSoTheDamagedOnesFailForTheDamage() throws {
        let entries = try goodPacketEntries()
        let url = root.appendingPathComponent("rewritten.spokenmargins")
        try writeArchive(entries, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("rewritten-assets"))
        XCTAssertEqual(verified.manifest.packageId, "package-article-001")
        XCTAssertTrue(entries.map(\.path).contains("manifest.json"))
        XCTAssertTrue(entries.map(\.path).contains("preview.md"))
        XCTAssertTrue(entries.contains { $0.path.hasPrefix("artifacts/") })
    }

    // MARK: Which entries are allowed

    /// Traversal is refused three times over in `validNestedPath` (the `..`, `\\` and `//` checks, the ban on `/` in
    /// the file name, and the character allow-list), so deleting any one of those checks alone changes nothing a
    /// listener could see. What this pins is the outcome: none of these names gets in.
    func testEntriesOutsideTheAllowedPathsAreRefusedByName() throws {
        let good = try goodPacketEntries()
        let hostile = [
            "artifacts/../escape.json",
            "../escape.json",
            "/absolute.json",
            "artifacts/nested/deeper.json",
            "artifacts\\backslash.json",
            "artifacts//double.json",
            "artifacts/extension.txt",
            "artifacts/space in name.json",
            "assets/audio/voice.mp3",
            "assets/audio/nested/voice.m4a",
            "assets/evidence/signature.m4a",
            "assets/other/thing.m4a",
            "scripts/run.sh",
            "README.md",
        ]
        for path in hostile {
            try assertReadFails(good + [(path, Data("x".utf8))], with: .invalidEntry(path), "\(path) must be refused")
        }
    }

    func testADirectoryEntryIsRefusedEvenAtAnAllowedName() throws {
        let good = try goodPacketEntries()
        let url = root.appendingPathComponent("directory.spokenmargins")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in good {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                modificationDate: Date(timeIntervalSince1970: 315_532_800), permissions: 0o644, compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
        try archive.addEntry(
            with: "artifacts/folder.json", type: .directory, uncompressedSize: 0,
            modificationDate: Date(timeIntervalSince1970: 315_532_800), permissions: 0o755,
            provider: { (_: Int64, _: Int) in Data() }
        )
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("dir-out"))) {
            // The zip library may or may not add the trailing slash a directory entry carries.
            guard case .invalidEntry(let path) = $0 as? SpokenMarginsPackageArchiveError else {
                return XCTFail("expected invalidEntry, got \($0)")
            }
            XCTAssertTrue(path.hasPrefix("artifacts/folder.json"), path)
        }
    }

    func testTheSameEntryTwiceIsRefusedNotSilentlyReplaced() throws {
        let good = try goodPacketEntries()
        let artifact = try XCTUnwrap(good.first { $0.path.hasPrefix("artifacts/") })
        // The second copy is the one whose bytes the digest would otherwise be computed over.
        let doctored = (artifact.path, Data("{}".utf8))
        try assertReadFails(good + [doctored], with: .duplicateEntry(artifact.path), "a repeated artifact")
        try assertReadFails(good + [("manifest.json", Data("{}".utf8))], with: .duplicateEntry("manifest.json"), "a repeated manifest")
    }

    // MARK: What the manifest declares must be what the archive holds

    func testAnEntryTheManifestDoesNotDeclareIsRefused() throws {
        let good = try goodPacketEntries()
        try assertReadFails(
            good + [("artifacts/undeclared.json", Data("{}".utf8))],
            with: .invalidManifest("declared entries do not match archive"), "an extra artifact"
        )
        try assertReadFails(
            good + [("assets/audio/undeclared.m4a", Data(count: 16))],
            with: .invalidManifest("declared entries do not match archive"), "an extra voice file"
        )
    }

    func testADeclaredEntryThatIsMissingFromTheArchiveIsRefused() throws {
        let good = try goodPacketEntries()
        let artifact = try XCTUnwrap(good.first { $0.path.hasPrefix("artifacts/") })
        try assertReadFails(
            good.filter { $0.path != artifact.path },
            with: .invalidManifest("declared entries do not match archive"), "a missing artifact"
        )
    }

    func testAPacketWithoutAManifestOrWithAnUnreadableOneIsRefused() throws {
        let good = try goodPacketEntries()
        try assertReadFails(good.filter { $0.path != "manifest.json" }, with: .manifestMissing, "no manifest")
        let withoutManifest = good.filter { $0.path != "manifest.json" } + [("manifest.json", Data("not json at all".utf8))]
        let url = root.appendingPathComponent("garbage-manifest.spokenmargins")
        try writeArchive(withoutManifest, to: url)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("gm-out"))) {
            guard case .invalidManifest = $0 as? SpokenMarginsPackageArchiveError else {
                return XCTFail("expected invalidManifest, got \($0)")
            }
        }
    }

    // MARK: Size limits

    func testAFileThatIsNotAZipIsMalformed() throws {
        let url = root.appendingPathComponent("notazip.spokenmargins")
        try Data("This is a text file someone renamed.".utf8).write(to: url)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("nz-out"))) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .malformedArchive)
        }
    }

    func testEachKindOfEntryHasItsOwnSizeLimit() throws {
        let good = try goodPacketEntries()
        let megabyte = 1_024 * 1_024
        // Stored, not deflated, so only the size limit can be what refuses them (the ratio check has its own tests).
        try assertReadFails(
            good.filter { $0.path != "manifest.json" } + [("manifest.json", Data(count: megabyte + 1))],
            stored: ["manifest.json"], with: .manifestTooLarge, "manifest over 1 MB"
        )
        try assertReadFails(
            good + [("artifacts/huge.json", Data(count: 5 * megabyte + 1))],
            stored: ["artifacts/huge.json"], with: .invalidAsset("artifacts/huge.json"), "artifact over 5 MB"
        )
        try assertReadFails(
            good + [("assets/evidence/huge.shazamsignature", Data(count: megabyte + 1))],
            with: .invalidAsset("assets/evidence/huge.shazamsignature"), "evidence over 1 MB"
        )
        try assertReadFails(
            good + [("assets/audio/huge.m4a", Data(count: 20 * megabyte + 1))],
            with: .audioTooLarge("assets/audio/huge.m4a"), "voice over 20 MB"
        )
    }

    func testAFileOverTheWholePacketLimitIsRefusedBeforeItIsOpened() throws {
        let url = root.appendingPathComponent("enormous.spokenmargins")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(100 * 1_024 * 1_024 + 1))
        try handle.close()
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("big-out"))) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .packageTooLarge)
        }
    }
}
