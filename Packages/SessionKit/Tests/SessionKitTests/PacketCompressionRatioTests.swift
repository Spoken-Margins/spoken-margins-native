import Foundation
@testable import SessionKit
import SessionKitSharing
import ShippedPacketReader
import XCTest
import ZIPFoundation

/// A packet the writer accepts must be one the reader accepts, in this build and in Build 29 (#946).
/// The reader refuses any entry that shrinks by more than 100 to 1; repetitive text deflates past that.
final class PacketCompressionRatioTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_777_000_000)

    private static let inspectionLine = "Inspection complete. The equipment is operating within specification.\n"

    /// Neighbouring inputs: the issue's log, the same line either side of the ratio threshold,
    /// whitespace runs, one repeated character, repeated non-ASCII, and ordinary prose.
    private var texts: [(name: String, text: String)] {
        let prose = (1...120).map {
            "Paragraph \($0) argues that listening changes what a reader notices, because pace is set by the voice and not the eye."
        }.joined(separator: "\n\n")
        return [
            ("issue log x4000", String(repeating: Self.inspectionLine, count: 4_000)),
            ("log x1000", String(repeating: Self.inspectionLine, count: 1_000)),
            ("log x400", String(repeating: Self.inspectionLine, count: 400)),
            ("log x150", String(repeating: Self.inspectionLine, count: 150)),
            ("log x50", String(repeating: Self.inspectionLine, count: 50)),
            ("whitespace-heavy", (1...3_000).map { "word\($0)" + String(repeating: " ", count: 80) + "\n\n\n" }.joined()),
            ("one repeated character", "Intro. " + String(repeating: "a", count: 300_000)),
            ("repeated non-ASCII", String(repeating: "Café déjà vu — naïve façade.\n", count: 6_000)),
            ("ordinary prose", prose)
        ]
    }

    func testEmbeddedTextPacketsAlwaysImportWhateverTheTextCompressesTo() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, sample) in texts.enumerated() {
            let url = root.appendingPathComponent("packet-\(index).spokenmargins")
            // exportPacket also reads the packet with the Build 29 reader, which has the same limit.
            _ = try exportPacket(try embeddedPackage(text: sample.text, id: "package-\(index)"), to: url)
            let verified = try SpokenMarginsPackageArchive.read(
                from: url, extractingAssetsTo: root.appendingPathComponent("assets-\(index)")
            )
            XCTAssertEqual(verified.embeddedTextItems.first?.text, sample.text, sample.name)
            let archive = try Archive(url: url, accessMode: .read)
            for entry in archive where entry.compressedSize > 0 {
                XCTAssertLessThanOrEqual(
                    entry.uncompressedSize / entry.compressedSize, 100, "\(sample.name): \(entry.path)"
                )
            }
        }
    }

    func testOrdinaryTextStaysDeflatedAndOnlyRunawayEntriesAreStored() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prose = try XCTUnwrap(texts.first { $0.name == "ordinary prose" }).text
        let proseURL = root.appendingPathComponent("prose.spokenmargins")
        _ = try exportPacket(try embeddedPackage(text: prose, id: "package-prose"), to: proseURL)
        let proseArtifacts = try Archive(url: proseURL, accessMode: .read).filter { $0.path.hasPrefix("artifacts/") }
        XCTAssertFalse(proseArtifacts.isEmpty)
        XCTAssertTrue(proseArtifacts.allSatisfy { $0.compressedSize < $0.uncompressedSize }, "ordinary text should still be compressed")

        let log = String(repeating: Self.inspectionLine, count: 4_000)
        let logURL = root.appendingPathComponent("log.spokenmargins")
        _ = try exportPacket(try embeddedPackage(text: log, id: "package-log"), to: logURL)
        let logArtifacts = try Archive(url: logURL, accessMode: .read).filter { $0.path.hasPrefix("artifacts/") }
        XCTAssertTrue(
            logArtifacts.contains { $0.compressedSize == $0.uncompressedSize },
            "the runaway-ratio artifact should be stored"
        )
    }

    func testReaderStillRejectsAnOutsidePacketWithARunawayRatio() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let goodURL = root.appendingPathComponent("good.spokenmargins")
        _ = try exportPacket(try embeddedPackage(text: "A short linkless reading.", id: "package-good"), to: goodURL)

        var entries: [String: Data] = [:]
        let good = try Archive(url: goodURL, accessMode: .read)
        for entry in good {
            var data = Data()
            _ = try good.extract(entry) { data.append($0) }
            entries[entry.path] = data
        }
        let artifactPath = try XCTUnwrap(entries.keys.sorted().first { $0.hasPrefix("artifacts/") })
        entries[artifactPath] = Data(count: 600_000)

        let bombURL = root.appendingPathComponent("bomb.spokenmargins")
        let bomb = try Archive(url: bombURL, accessMode: .create)
        for path in entries.keys.sorted() {
            let data = try XCTUnwrap(entries[path])
            try bomb.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                modificationDate: fixedDate, permissions: 0o644, compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(
            from: bombURL, extractingAssetsTo: root.appendingPathComponent("bomb-assets")
        )) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .excessiveCompression(artifactPath))
        }
    }

    private func embeddedPackage(text: String, id: String) throws -> PreparedSpokenMarginsPackage {
        let item = SharedItemIdentity(
            itemType: .pdf,
            title: "Linkless Reading",
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text),
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text)
        )
        let revision = InterjectionShareRevision(
            id: "revision-approved", interjectionId: "private-note", itemId: "private-item",
            sessionId: "private-session", createdAt: fixedDate, approvedTranscript: "A sender-reviewed thought.",
            cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: id,
            createdAt: fixedDate,
            item: item,
            itemTransportSelection: .embeddedText(
                text: text, originalMediaType: "pdf", rightsBasis: .senderConfirmedPrivateRights
            ),
            selections: [.init(
                packageScopedId: "margin-001", revision: revision,
                anchor: .init(anchorType: .text), representation: .textOnly
            )]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PacketCompressionRatioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
