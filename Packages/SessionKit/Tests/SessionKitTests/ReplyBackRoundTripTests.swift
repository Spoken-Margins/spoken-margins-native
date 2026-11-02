import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

/// Sending replies back (#3221), the whole loop with real files and real SQLite: A shares a Margin, B imports it and
/// replies, B sends back only the reply, and A's review holds that reply with its parent link resolved.
final class ReplyBackRoundTripTests: XCTestCase {
    private var root: URL!
    private let digest = String(repeating: "ab", count: 32)
    private var episode: SharedItemIdentity {
        SharedItemIdentity(itemType: .other, title: "Harbour Lights", durationMs: 1_800_000, exactEditionSHA256: digest)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReplyBackRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBReplyTravelsBackAndAHearsItAfterItsParent() throws {
        let (ana, ben) = (try Person(name: "Ana", root: root, episode: episode), try Person(name: "Ben", root: root, episode: episode))

        // A shares a Margin at 12:34 with B.
        let first = try ana.record("a-1", madeAt: 10, atMs: 754_000)
        let (anaURL, anaManifest) = try ana.send([first], packageId: "package-a", in: root)
        XCTAssertEqual(anaManifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion])

        // B made a Margin before the packet arrived, imports it, then replies and adds two more.
        try ben.record("b-before", madeAt: 20, atMs: 100_000)
        guard case .imported = try ben.importPacket(anaURL, at: 100) else { return XCTFail("B should import A's packet") }
        let bensOffer = { try ReplyBackOffer.make(localMargins: ben.margins(), layers: ben.store.loadImportedCommentaryLayers(itemId: ben.itemId)) }
        XCTAssertNil(try bensOffer(), "B has made nothing since the import")
        let reply = try ben.record("b-reply", madeAt: 200, atMs: 755_000, replyingTo: "a-1")
        try ben.record("b-extra", madeAt: 210, atMs: 900_000)
        try ben.record("b-written", madeAt: 220, atMs: 910_000, written: true)

        // B's Share offers the reply (selected) and the other new Margins (not selected). Nothing of A's, nothing older.
        let offer = try XCTUnwrap(try bensOffer())
        XCTAssertEqual(offer.title, "Send replies to Ana")
        XCTAssertEqual(offer.candidates.map(\.id), ["b-reply", "b-extra", "b-written"])
        XCTAssertEqual(offer.candidates.filter(offer.isPreselected).map(\.id), ["b-reply"])
        let importedFromAna = try ben.importedMargins().map(\.id)
        XCTAssertFalse(offer.candidates.contains { importedFromAna.contains($0.id) })

        // B sends back only the pre-selected reply.
        let (benURL, benManifest) = try ben.send(offer.candidates.filter(offer.isPreselected), packageId: "package-b", in: root)
        XCTAssertEqual(benManifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion], "no new capability")
        XCTAssertEqual(
            Set(benManifest.artifacts.map(\.kind)),
            [SpokenMarginsArtifactKind.commentaryLayer, SpokenMarginsArtifactKind.conversation],
            "no new packet key: the reply's link rides the optional conversation artifact of #472"
        )
        let sent = try SpokenMarginsPackageArchive.read(from: benURL, extractingAssetsTo: root.appendingPathComponent("check-b"))
        XCTAssertEqual(sent.commentaryLayers.flatMap(\.interjections).map(\.packageScopedId), ["b-reply"])
        XCTAssertEqual(reply.replyTo?.parentPackageScopedId, "a-1")

        // A imports it and reviews.
        guard case .imported = try ana.importPacket(benURL, at: 300) else { return XCTFail("A should import B's packet") }
        let own = try ana.margins()
        let entries = try SharedMarginReview.entries(itemId: ana.itemId, in: ana.store, ownMargins: own)
        XCTAssertEqual(entries.map(\.interjection.packageScopedId), ["b-reply"], "the review holds the reply and nothing else")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.mediaTimeMs, 755_000)
        XCTAssertEqual(entry.replyContext?.parent, .yours(interjectionId: "a-1", mediaTimeMs: 754_000))
        XCTAssertEqual(entry.replyContext?.caption, "Reply to your Margin at 12:34")

        // The parent link resolves to A's own Margin.
        let graph = MarginReplyGraph.build(
            localMargins: own, layers: try ana.store.loadImportedCommentaryLayers(itemId: ana.itemId), importedMargins: try ana.importedMargins()
        )
        guard case .linked(let link)? = graph.states[.imported(entry.interjection.id)] else {
            return XCTFail("the reply should link to its parent: \(String(describing: graph.states))")
        }
        XCTAssertEqual(link.parent, .local("a-1"))

        // One tap plays the lead-in, then A's own Margin, then the reply.
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: own)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].ownParent?.id, "a-1")
        XCTAssertEqual(steps[0].anchor.caption, "Your Margin at 12:34")
        XCTAssertEqual(steps[1].entry?.interjection.packageScopedId, "b-reply")
        XCTAssertEqual(try ana.store.quarantinedRecordCount(), 0)
        XCTAssertEqual(try ben.store.quarantinedRecordCount(), 0)
    }

    func testTheListenerCanAddAnotherNewMarginAndItTravelsToo() throws {
        let (ana, ben) = (try Person(name: "Ana", root: root, episode: episode), try Person(name: "Ben", root: root, episode: episode))
        let (anaURL, _) = try ana.send([try ana.record("a-1", madeAt: 10, atMs: 754_000)], packageId: "package-a", in: root)
        try ben.importPacket(anaURL, at: 100)
        try ben.record("b-reply", madeAt: 200, atMs: 755_000, replyingTo: "a-1")
        try ben.record("b-extra", madeAt: 210, atMs: 900_000)
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: ben.margins(), layers: ben.store.loadImportedCommentaryLayers(itemId: ben.itemId)))

        // The extra Margin is ticked by hand: the packet carries both, and A hears the reply with its parent and the
        // extra one as an ordinary Margin.
        let (benURL, _) = try ben.send(offer.candidates, packageId: "package-b", in: root)
        try ana.importPacket(benURL, at: 300)
        let own = try ana.margins()
        let entries = try SharedMarginReview.entries(itemId: ana.itemId, in: ana.store, ownMargins: own)
        XCTAssertEqual(entries.map(\.interjection.packageScopedId), ["b-reply", "b-extra"])
        XCTAssertNotNil(entries[0].replyContext)
        XCTAssertNil(entries[1].replyContext)
        XCTAssertEqual(SharedMarginReview.playlist(for: entries, ownMargins: own).count, 3)
    }

    func testTwoPacketsFromTheSameFriendNameThemOnceAndOfferTheReplyToTheSecond() throws {
        // Ben imports two packets from Ana and answers the second: the offer holds the reply and names Ana once.
        let (ana, ben) = (try Person(name: "Ana", root: root, episode: episode), try Person(name: "Ben", root: root, episode: episode))
        let (one, _) = try ana.send([try ana.record("a-1", madeAt: 10, atMs: 754_000)], packageId: "package-a1", in: root)
        let (two, _) = try ana.send([try ana.record("a-2", madeAt: 11, atMs: 800_000)], packageId: "package-a2", in: root)
        try ben.importPacket(one, at: 100)
        try ben.importPacket(two, at: 110)
        try ben.record("b-reply", madeAt: 200, atMs: 801_000, replyingTo: "a-2")
        let offer = try XCTUnwrap(ReplyBackOffer.make(localMargins: ben.margins(), layers: ben.store.loadImportedCommentaryLayers(itemId: ben.itemId)))
        XCTAssertEqual(offer.replies.map(\.id), ["b-reply"])
        XCTAssertEqual(offer.title, "Send replies to Ana")
    }
}

/// One listener with their own SQLite Library, and a local copy of the same recording.
private final class Person {
    let name: String
    let store: SQLiteSessionStore
    let itemId = "episode"
    var sessionId: String { "session-\(name)" }
    private let folder: URL
    private let episode: SharedItemIdentity
    private var imports = 0

    init(name: String, root: URL, episode: SharedItemIdentity) throws {
        self.name = name
        self.episode = episode
        folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_777_000_000 + seconds) }

    @discardableResult
    func record(_ id: String, madeAt: Double, atMs: Int, replyingTo parentScopedId: String? = nil, written: Bool = false) throws -> Interjection {
        var audioPath: String?
        if !written {
            let clip = folder.appendingPathComponent("\(id).m4a")
            try Self.writeClip(to: clip)
            audioPath = clip.path
        }
        let margin = Interjection(
            id: id, itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId, createdAt: date(madeAt),
            roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: atMs),
            audioPath: audioPath, audioStatus: written ? "none" : "ready", transcriptionStatus: "complete",
            transcript: "Words from \(name).", cleanedTranscript: nil, displayText: "Words from \(name).", status: "active",
            captureKind: written ? .written : nil, replyTo: try parentScopedId.map(replyLink(to:))
        )
        try store.saveInterjection(margin)
        return margin
    }

    func margins() throws -> [Interjection] { try store.loadInterjections(sessionId: sessionId) }

    func importedMargins() throws -> [ImportedCommentaryInterjection] {
        try store.loadImportedCommentaryLayers(itemId: itemId).flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }
    }

    private func replyLink(to parentScopedId: String) throws -> MarginReplyLink {
        for layer in try store.loadImportedCommentaryLayers(itemId: itemId) {
            if let parent = try store.loadImportedCommentaryInterjections(layerId: layer.id).first(where: { $0.packageScopedId == parentScopedId }) {
                return parent.replyLink(in: layer)
            }
        }
        throw SessionKitError.persistenceFailed("\(name) has no imported Margin \(parentScopedId)")
    }

    /// Writes a packet that the last shipped build's reader also opens (`exportPacket`), and records what went out.
    func send(_ margins: [Interjection], packageId: String, in directory: URL) throws -> (URL, SpokenMarginsPackageManifest) {
        let selections = margins.map { margin in
            ReviewedInterjectionSelection(
                packageScopedId: margin.id,
                revision: InterjectionShareRevision(
                    id: "revision-\(margin.id)", interjectionId: margin.id, itemId: margin.itemId, sessionId: margin.sessionId,
                    createdAt: margin.createdAt, approvedTranscript: margin.displayText ?? "", anchorBefore: "", anchorAfter: "",
                    status: .senderApproved
                ),
                anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: margin.anchor.mediaTimeMs),
                representation: margin.audioPath.map { .originalAudio(sourceURL: URL(fileURLWithPath: $0), durationMs: 600) } ?? .textOnly,
                replyTo: margin.replyTo
            )
        }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: packageId, createdAt: date(5), item: episode, itemTransportSelection: .recipientSupplied,
            selections: selections, senderDisplayLabel: name, suggestedRevealMode: .companion
        )
        let url = directory.appendingPathComponent("\(packageId).spokenmargins")
        let manifest = try exportPacket(prepared, to: url)
        try SpokenMarginsPackageExportRecord.recordExport(manifest: manifest, selections: selections, repository: store)
        return (url, manifest)
    }

    @discardableResult
    func importPacket(_ url: URL, at seconds: Double) throws -> ImportedCommentaryImportDisposition {
        imports += 1
        let contents = try SpokenMarginsPackageArchive.read(
            from: url, extractingAssetsTo: folder.appendingPathComponent("import-\(imports)", isDirectory: true))
        return try SpokenMarginsPackageImporter.importPackage(
            contents, itemId: itemId, localItem: episode, importedAt: date(seconds), repository: store)
    }

    /// A short voice clip: real AAC on a Mac (the reader decodes it), an `ftyp` header elsewhere.
    static func writeClip(to url: URL) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate / 10) * 6
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try audioFile.write(from: buffer)
        #else
        let header: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0, 0, 0, 0]
        try (Data(header) + Data(repeating: 6, count: 600)).write(to: url)
        #endif
    }
}
