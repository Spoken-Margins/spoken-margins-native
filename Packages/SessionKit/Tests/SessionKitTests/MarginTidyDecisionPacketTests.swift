import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest
import ZIPFoundation

/// #4339: the author's answer about a tidy version stays on their phone. A packet is built from a reviewed share
/// revision, not from the Margin row, so a Margin that carries an answer must produce the very same packet as one
/// that doesn't, and the last shipped build's reader (`exportPacket`) must still import it.
final class MarginTidyDecisionPacketTests: XCTestCase {
    private var root: URL!
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MarginTidyDecisionPacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAMarginWithAnAnswerMakesTheSamePacketAsOneWithoutAndTheShippedReaderImportsIt() throws {
        let plain = margin()
        var decided = margin()
        decided.cleanedTranscript = "The result was not 12 percent."
        decided.displayText = "The result was not 12 percent."
        decided.tidyDecision = MarginTidyDecision(choice: .usedTidy, source: .onDeviceAI, decidedAt: createdAt)

        let plainPacket = try rawArchive(packet(for: plain, name: "plain"))
        let decidedPacket = try rawArchive(packet(for: decided, name: "decided"))

        XCTAssertEqual(decidedPacket, plainPacket, "the answer changes nothing in what a friend receives")
        for (path, data) in decidedPacket {
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("tidyDecision"), path)
            XCTAssertFalse(text.contains("usedTidy"), path)
            XCTAssertFalse(text.contains("onDeviceAI"), path)
        }
    }

    /// Writes the packet through `exportPacket`, which has the last shipped build's reader import it.
    private func packet(for margin: Interjection, name: String) throws -> URL {
        // The share flow starts from the transcript, never from an approved tidy (the Design's "Around it").
        let selection = ReviewedInterjectionSelection(
            packageScopedId: "margin-001",
            revision: InterjectionShareRevision(
                id: "revision-\(margin.id)", interjectionId: margin.id, itemId: margin.itemId,
                sessionId: margin.sessionId, createdAt: createdAt, approvedTranscript: margin.transcript ?? "",
                anchorBefore: "", anchorAfter: "", status: .senderApproved
            ),
            anchor: PortableAnchorEvidence(anchorType: .text, exactText: "durable idea"),
            representation: .textOnly,
            replyTo: nil
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-a", createdAt: createdAt,
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article"),
            itemTransportSelection: .reference, selections: [selection],
            senderDisplayLabel: "A", suggestedRevealMode: .companion
        )
        let url = root.appendingPathComponent("\(name).spokenmargins")
        try exportPacket(prepared, to: url)
        return url
    }

    private func rawArchive(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: Data] = [:]
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            result[entry.path] = data
        }
        return result
    }

    private func margin() -> Interjection {
        Interjection(
            id: "m1", itemId: "item-text", sessionId: "session-A", targetType: .item, targetId: "item-text",
            createdAt: createdAt, roughPercent: 40,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed",
            transcript: "um so the the result was not 12 percent", cleanedTranscript: nil,
            displayText: "um so the the result was not 12 percent", status: "active"
        )
    }
}
