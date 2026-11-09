import Foundation
import XCTest
import SessionKit
import SessionKitPersistence
import SessionKitSharing

/// #3664: a Margin added while a spoken note plays is stored like any Margin on audio, so a packet that carries one is
/// the packet the last shipped builds already read. The note's item keeps the identity it had before it had audio
/// (#3662), so the packet names no episode and no new capability. `exportPacket` imports each packet with the frozen
/// Build 29 reader here and keeps it for scripts/check-build29-database.sh, which imports it again with Build 32's and
/// Build 34's own code.
final class SpokenNoteMarginPacketTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-margin-packet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testAMarginOnASpokenNoteExportsInAPacketTheShippedBuildsImport() throws {
        let noteId = "note-1"
        let itemId = SpokenNoteItem.itemId(forNoteId: noteId)
        var note = SpokenNote(id: noteId)
        note.appendTake(SpokenNoteTake(
            id: "a", audioFileName: "take-a.m4a", durationMs: 4_000, createdAt: stamp,
            sentences: [SpokenNoteSentence(text: "First thought.", startMs: 0, endMs: 900), SpokenNoteSentence(text: "Second thought.", startMs: 1_000, endMs: 1_900)]))
        let timeline = SpokenNoteWholeTimeline(note: note, layout: SpokenNoteWholeAudioLayout(
            requested: [], placed: [.init(takeId: "a", startMs: 0, durationMs: 4_000)], durationMs: 4_000))
        let item = Item(
            id: itemId, title: "Spoken note", mediaType: SpokenNoteItem.mediaType, text: timeline.text,
            externalReference: SpokenNoteItem.reference(forNoteId: noteId), status: "ready", externalReferenceType: SpokenNoteItem.referenceType,
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/whole-note.m4a", durationMs: 4_000, nativeMediaId: "spoken-note-audio-\(itemId)"))
        try store.saveItem(item)
        try store.saveTranscriptTimeline(SourceTranscriptTimeline(id: "transcript-\(itemId)", itemId: itemId, createdAt: stamp, timeline: timeline.mediaTimeline))
        try store.saveSession(Session(
            id: "session-note", itemId: itemId, createdAt: stamp, updatedAt: stamp, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "spoken-note-audio-\(itemId)",
            position: Position(charOffset: 0, mediaTimeMs: 1_200), completionPercent: 30, playbackRate: 1
        ))
        // A Margin placed at the playhead, written through the same engine a Margin added during playback uses.
        let margin = try PlayerItemMargin.placeMark(
            atMediaTimeMs: 1_200, markedAt: Date(timeIntervalSince1970: 1_793_805_600), itemId: itemId, repository: store,
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(margin.anchor.transcriptSegmentId, SpokenNoteMargins.segmentId(takeId: "a", sentenceIndex: 1), "the Margin names its sentence")

        let words = SharedMarginTextRequirement.initialReviewedText(for: margin)
        XCTAssertTrue(SharedMarginTextRequirement.hasReviewedText(words), "a Margin carries words, so every reader since Build 29 takes it (#304)")
        let anchor = SharedMarginExport.anchor(
            for: margin, item: try store.loadItem(id: itemId), isNativeAudio: true, mediaChapters: [], machineEvidenceAssetIds: []
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "spoken-note-margin", createdAt: stamp,
            item: SharedItemIdentityBuilder.exportIdentity(for: try store.loadItem(id: itemId), draftEditionDigests: [nil]),
            itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001",
                revision: InterjectionShareRevision(
                    id: "revision-\(margin.id)", interjectionId: margin.id, itemId: itemId, sessionId: margin.sessionId,
                    createdAt: margin.createdAt, approvedTranscript: words, cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
                    anchorBefore: margin.anchor.anchorBefore, anchorAfter: margin.anchor.anchorAfter, status: .senderApproved
                ),
                anchor: anchor, representation: .textOnly
            )],
            senderDisplayLabel: "A Friend", suggestedRevealMode: .companion
        )

        let manifest = try exportPacket(prepared, to: root.appendingPathComponent("spoken-note.spokenmargins"))

        XCTAssertEqual(manifest.requiredCapabilities.filter { $0.lowercased().contains("note") }, [], "no new capability: \(manifest.requiredCapabilities)")
    }
}
