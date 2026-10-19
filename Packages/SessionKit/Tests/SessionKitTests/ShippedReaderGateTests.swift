import Foundation
@testable import SessionKit
import SessionKitSharing
import ShippedPacketReader
import XCTest
import SessionKitTestInputs

/// The Build 29 compatibility gate is itself under test (PKT-01 of the #1039 audit). `exportPacket` is what every
/// exporter test calls, and AGENTS.md's rule that a new build's packets must import into the last shipped build rests
/// on it. Before these tests it could be emptied (the `importPacket` line deleted, or its result ignored) and
/// every exporter test stayed green.
final class ShippedReaderGateTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShippedReaderGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let item = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")

    private func selection(_ id: String, replyTo: MarginReplyLink? = nil) -> ReviewedInterjectionSelection {
        .init(
            packageScopedId: id,
            revision: InterjectionShareRevision(
                id: "revision-\(id)", interjectionId: "private-\(id)", itemId: "private-item", sessionId: "private-session",
                createdAt: created, approvedTranscript: "Thought \(id).",
                anchorBefore: "Before.", anchorAfter: "After.", status: .senderApproved
            ),
            anchor: .init(anchorType: .text, exactText: "The durable idea."),
            representation: .textOnly,
            replyTo: replyTo
        )
    }

    private func prepare(_ selections: [ReviewedInterjectionSelection]) throws -> PreparedSpokenMarginsPackage {
        try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-gate", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: selections, senderDisplayLabel: "A Friend", suggestedRevealMode: .companion
        )
    }

    /// A packet the current writer and reader both accept, but that Build 29 refuses: its reply links are a required
    /// artifact, and Build 29's `decodeKnownArtifacts` does not know the kind (the current build marks it optional so
    /// that Build 29 can open packets with replies).
    private func packetWithRequiredReplyLinks() throws -> PreparedSpokenMarginsPackage {
        let parent = MarginReplyLink(
            conversationId: "conversation-1", parentPackageDigest: String(repeating: "a", count: 64),
            parentPackageScopedId: "parent-001"
        )
        let optional = try prepare([selection("margin-001", replyTo: parent)])
        var manifest = optional.manifest
        XCTAssertTrue(manifest.artifacts.contains { $0.kind == SpokenMarginsArtifactKind.conversation && !$0.required })
        manifest.artifacts = manifest.artifacts.map {
            $0.kind == SpokenMarginsArtifactKind.conversation
                ? SpokenMarginsArtifactDescriptor(id: $0.id, kind: $0.kind, schemaVersion: $0.schemaVersion, path: $0.path, required: true)
                : $0
        }
        return PreparedSpokenMarginsPackage(manifest: manifest, artifactData: optional.artifactData, assetFiles: optional.assetFiles)
    }

    func testTheGateRefusesAPacketTheShippedBuildRefusesEvenThoughTheNewReaderAcceptsIt() throws {
        let prepared = try packetWithRequiredReplyLinks()
        let url = root.appendingPathComponent("required-replies.spokenmargins")
        XCTAssertThrowsError(try exportPacket(prepared, to: url)) {
            let description = String(describing: $0)
            XCTAssertTrue(description.contains("Build 29"), "the refusal names the shipped build: \(description)")
            XCTAssertTrue(description.contains("unsupportedRequiredCapability"), description)
        }
        // The packet was written, and this build's reader is happy with it: only the gate stood in the way.
        XCTAssertNoThrow(try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets")))
    }

    func testTheShippedBuildReadsEveryMarginTheGateSent() throws {
        let prepared = try prepare([selection("margin-001"), selection("margin-002"), selection("margin-003")])
        let url = root.appendingPathComponent("three.spokenmargins")
        try exportPacket(prepared, to: url)
        XCTAssertEqual(try ShippedPacketReader.importPacket(at: url).sorted(), ["margin-001", "margin-002", "margin-003"])
    }

    // MARK: The Margin comparison (#1898)

    func testTheComparisonNamesEveryWayTheShippedBuildCanDisagree() {
        XCTAssertNil(shippedMarginsMismatch(sent: ["a", "b"], shippedBuildRead: ["b", "a"]), "order does not matter")
        XCTAssertNil(shippedMarginsMismatch(sent: [], shippedBuildRead: []))
        XCTAssertNil(shippedMarginsMismatch(sent: nil, shippedBuildRead: ["a"]), "no commentary layer, nothing to compare")

        XCTAssertEqual(shippedMarginsMismatch(sent: ["a", "b", "c"], shippedBuildRead: ["c", "a"]),
                       .marginsDiffer(sent: ["a", "b", "c"], shippedBuildRead: ["a", "c"]), "a dropped Margin")
        XCTAssertEqual(shippedMarginsMismatch(sent: ["a"], shippedBuildRead: ["a", "x"]),
                       .marginsDiffer(sent: ["a"], shippedBuildRead: ["a", "x"]), "a Margin that was never sent")
        XCTAssertEqual(shippedMarginsMismatch(sent: ["a", "b"], shippedBuildRead: ["a", "z"]),
                       .marginsDiffer(sent: ["a", "b"], shippedBuildRead: ["a", "z"]), "a different Margin")
        XCTAssertEqual(shippedMarginsMismatch(sent: ["a", "b"], shippedBuildRead: ["a", "a"]),
                       .marginsDiffer(sent: ["a", "b"], shippedBuildRead: ["a", "a"]), "the same Margin twice")
        XCTAssertEqual(shippedMarginsMismatch(sent: ["a"], shippedBuildRead: []),
                       .marginsDiffer(sent: ["a"], shippedBuildRead: []), "everything dropped")
    }

    func testTheGateRefusesAPacketWhoseMarginTheShippedBuildDrops() throws {
        let prepared = try prepare([selection("margin-001"), selection("margin-002"), selection("margin-003")])
        let url = root.appendingPathComponent("dropped.spokenmargins")
        // A reader that decodes the zip but loses the last Margin, which is what a Margin kind Build 29 can't read looks like.
        let dropsOne: (URL) throws -> [String] = { try ShippedPacketReader.importPacket(at: $0).sorted().dropLast().map { $0 } }
        XCTAssertThrowsError(try exportPacket(prepared, to: url, shippedBuildReader: dropsOne)) {
            XCTAssertEqual($0 as? ShippedReaderGateError,
                           .marginsDiffer(sent: ["margin-001", "margin-002", "margin-003"], shippedBuildRead: ["margin-001", "margin-002"]))
        }
    }

    func testTheGateAcceptsAPacketWhoseMarginsTheShippedBuildReadsInAnyOrder() throws {
        let prepared = try prepare([selection("margin-001"), selection("margin-002")])
        let url = root.appendingPathComponent("reordered.spokenmargins")
        let reversed: (URL) throws -> [String] = { try ShippedPacketReader.importPacket(at: $0).sorted().reversed().map { $0 } }
        XCTAssertNoThrow(try exportPacket(prepared, to: url, shippedBuildReader: reversed))
    }

    // MARK: Nothing writes a packet around the gate

    private func swiftFiles(under folder: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testNoTestWritesAPacketAcrossTwoLinesToGetAroundTheGate() throws {
        // ShippedReaderRoundTripTests searches the sources line by line for the archive type's `write` call; a call split after the
        // type name (`SpokenMarginsPackageArchive` newline `.write(`) was invisible to it.
        let folder = TestInputs.packageURL("Tests/SessionKitTests")
        let pattern = try NSRegularExpression(pattern: #"SpokenMarginsPackageArchive\s*\n\s*\.write\("#)
        var split: [String] = []
        for file in try swiftFiles(under: folder) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if matches > 0 { split.append("\(file.lastPathComponent) x\(matches)") }
        }
        XCTAssertEqual(split, [], "export with exportPacket(_:to:) so the shipped build reads the packet")
    }

    func testTheAppTestsThatWritePacketsDirectlyAreTheOnesWeKnowAbout() throws {
        // App tests cannot call exportPacket (the frozen reader is not linked into the app test target), so these
        // writes there are not read by Build 29. EpisodeMapStoredNamesTests writes one only to drive an import and
        // check the names the app saves; it asserts nothing about what Build 29 can read. SpokenMarginsPackageImportCoordinatorTests
        // writes embedded-text packets only to drive the import coordinator's stage and confirm paths; the same
        // packet shape is exported through exportPacket in SharingTests. Its map packet (#1471) is the same shape
        // TextListeningMapPacketTests exports through exportMapOnlyPacket, which asserts the shipped build refuses it. SourceLinkImportTests
        // writes a private-feed packet only to drive the #454 recovery; PrivateFeedRecoveryTests exports the same
        // kind of linkless packet through exportPacket. This pins that list: a new
        // direct write fails here until someone either routes it through a packet the Mac package tests also read
        // with Build 29, or adds it below on purpose.
        let appTests = try TestInputs.directory(.appTests)
        guard FileManager.default.fileExists(atPath: appTests.path) else {
            throw XCTSkip("the app tests are not in this checkout")
        }
        let call = try NSRegularExpression(pattern: #"SpokenMarginsPackageArchive\s*\.write\("#)
        var counts: [String: Int] = [:]
        for file in try swiftFiles(under: appTests) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = call.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if matches > 0 { counts[file.lastPathComponent] = matches }
        }
        XCTAssertEqual(counts, ["EpisodeMapStoredNamesTests.swift": 1, "LocalAudioListeningPackageTests.swift": 3,
                                "SourceLinkImportTests.swift": 1, "SpokenMarginsPackageHandoffTests.swift": 1,
                                "SpokenMarginsPackageImportCoordinatorTests.swift": 2])
    }
}
