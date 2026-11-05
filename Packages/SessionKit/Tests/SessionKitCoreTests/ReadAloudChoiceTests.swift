import Foundation
@testable import SessionKit
import SessionKitPersistence
import XCTest

/// A sender and a listener choose whether a written Margin is read aloud, and Skim follows the choice (owner, 2026-11-05,
/// #3427). The model side, which also runs on Linux; the packet side is `ReadAloudPacketTests` (Mac).
final class ReadAloudChoiceTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)

    private func written(
        id: String = "m", sender: Bool?, listener: Bool?, words: String = "Lovely harbour.", audioPath: String? = nil, at ms: Int = 60_000
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "ana", packageScopedId: id, createdAt: created,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: words, audioPath: audioPath,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: ms, confidence: 1),
            senderReadAloud: sender, listenerReadAloud: listener
        )
    }

    private let layer = ImportedCommentaryLayer(
        id: "ana", itemId: "item", packageDigest: "d", packageId: "p",
        itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
        displayLabel: "Ana", importedAt: Date(timeIntervalSince1970: 1_777_000_000), sourceResolutionStatus: .resolved,
        isEnabled: true, isMuted: false, deletedAt: nil
    )

    func testTheListenerBeatsTheSenderAndTheSenderBeatsTheDefault() {
        XCTAssertTrue(written(sender: nil, listener: nil).readsAloud, "nobody chose: read aloud, as before")
        XCTAssertFalse(written(sender: false, listener: nil).readsAloud)
        XCTAssertTrue(written(sender: false, listener: true).readsAloud, "the listener turns reading on")
        XCTAssertFalse(written(sender: nil, listener: false).readsAloud, "the listener turns reading off")
        XCTAssertFalse(written(sender: true, listener: false).readsAloud)
        XCTAssertTrue(written(sender: true, listener: true).readsAloud)
    }

    func testTheControlSaysWhetherTheListenerChangedWhatTheSenderAsked() {
        XCTAssertFalse(written(sender: false, listener: nil).listenerOverridesSender)
        XCTAssertTrue(written(sender: false, listener: true).listenerOverridesSender)
        XCTAssertTrue(written(sender: nil, listener: false).listenerOverridesSender)
        XCTAssertFalse(written(sender: nil, listener: true).listenerOverridesSender, "the default already reads aloud")
        XCTAssertTrue(written(sender: false, listener: true).readAloudChoice)
        XCTAssertFalse(written(sender: false, listener: nil).readAloudChoice)
    }

    /// Neighbouring Margins: a recording, and words the voice has nothing to say for, are never read whatever was chosen.
    func testTheChoiceNeverMakesAnUnreadableOrRecordedMarginRead() {
        XCTAssertFalse(written(sender: nil, listener: true, words: "🎧🔥").readsAloud)
        XCTAssertFalse(written(sender: nil, listener: true, words: "").readsAloud)
        XCTAssertFalse(written(sender: nil, listener: true, words: "Voice Margin at 1:02").readsAloud)
        let recorded = written(sender: false, listener: nil, audioPath: "a.m4a")
        XCTAssertFalse(recorded.readsAloud, "the voice does not read a recording")
        XCTAssertTrue(SharedMarginAudio.canOffer(recorded), "a recording is offered whatever either of them chose")
        XCTAssertTrue(SharedMarginAudio.canOffer(written(sender: true, listener: true, audioPath: "a.m4a")))
    }

    func testAMutedWrittenMarginResolvesToNothingToPlayAndOfferingAgrees() {
        func resolve(_ margin: ImportedCommentaryInterjection) -> SharedMarginAudio {
            SharedMarginAudio.resolve(margin, in: layer, voiceFile: { _ in nil }, reading: { _ in (URL(fileURLWithPath: "/tmp/r.caf"), true) })
        }
        XCTAssertEqual(resolve(written(sender: false, listener: nil)), .cannotBeRead)
        XCTAssertNotEqual(resolve(written(sender: false, listener: true)), .cannotBeRead)
        XCTAssertNotEqual(resolve(written(sender: nil, listener: nil)), .cannotBeRead)
        let all = [(false, nil), (false, true), (nil, false), (nil, nil), (true, false)].map { written(sender: $0.0, listener: $0.1) }
        for margin in all {
            XCTAssertEqual(SharedMarginAudio.canOffer(margin), resolve(margin) != .cannotBeRead, "offering agrees with what can play")
        }
        XCTAssertEqual(
            SharedMarginAudio.unavailableWords(for: written(sender: false, listener: nil)),
            "This Margin is set not to be read aloud. Turn reading on for it to hear it.")
        XCTAssertEqual(SharedMarginAudio.unavailableWords(for: written(sender: nil, listener: nil, words: "🎧")),
                       "This Margin can't be read aloud on this iPhone.", "words the voice can't read keep their own line")
    }

    func testTheControlSaysWhoDecidedAndWhatSkimDoes() {
        func words(_ sender: Bool?, _ listener: Bool?, name: String? = "Ana") -> String {
            ReadAloudWords.footer(for: written(sender: sender, listener: listener), senderName: name)
        }
        XCTAssertEqual(words(nil, nil), "Your phone reads this Margin aloud where it comes up, and Skim stops at it.")
        XCTAssertEqual(words(nil, true), words(nil, nil), "the listener turning on what was already on says nothing new")
        XCTAssertEqual(words(false, true), "Ana asked that this one not be read aloud. You turned reading on, so Skim stops at it.")
        XCTAssertEqual(words(false, nil), "Ana asked that this one not be read aloud. Skim passes it. Turn this on to hear it. You can always read it here and on the Timeline.")
        XCTAssertEqual(words(nil, false), "You turned reading off for this one. Skim passes it. You can always read it here and on the Timeline.")
        XCTAssertEqual(words(false, false), words(nil, false), "once the listener has chosen, it is their choice that is spoken of")
        XCTAssertTrue(words(false, nil, name: nil).hasPrefix("Your friend asked"), "a file that names nobody is not given a stand-in name")
    }

    // MARK: Skim

    func testSkimStopsAtAWrittenMarginThatWillBeReadAndPassesOneThatWillNot() {
        func stops(_ margins: [ImportedCommentaryInterjection]) -> [String] {
            SkimStopRouting.stops(textChapters: [], mediaChapters: [], ownMargins: [], sharedMargins: margins, unit: .milliseconds).stops.map(\.id)
        }
        XCTAssertEqual(stops([written(id: "read", sender: nil, listener: nil, at: 10_000)]), ["read"], "a written Margin that will be read is a stop")
        XCTAssertEqual(stops([written(id: "sender-no", sender: false, listener: nil, at: 10_000)]), [], "the sender said no: Skim passes it")
        XCTAssertEqual(stops([written(id: "listener-no", sender: nil, listener: false, at: 10_000)]), [], "the listener said no: Skim passes it")
        XCTAssertEqual(
            stops([written(id: "a", sender: false, listener: nil, at: 10_000), written(id: "b", sender: false, listener: true, at: 20_000),
                   written(id: "c", sender: nil, listener: nil, at: 30_000)]),
            ["b", "c"], "the listener turning reading back on makes it a stop again")
        XCTAssertEqual(stops([written(id: "voice", sender: false, listener: nil, audioPath: "a.m4a", at: 10_000)]), ["voice"],
                       "a recording is a stop whatever was chosen")
    }

    // MARK: Stored records

    func testARecordStoredBeforeTheSettingReadsAloud() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(written(sender: nil, listener: nil))) as? [String: Any])
        XCTAssertNil(object["senderReadAloud"], "unset choices are not written, so an older build's row is the row this build writes")
        XCTAssertNil(object["listenerReadAloud"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertTrue(try decoder.decode(ImportedCommentaryInterjection.self, from: JSONSerialization.data(withJSONObject: object)).readsAloud)
    }

    // MARK: The listener's choice is kept

    private func assertAStaleCopyCannotUndoTheListenersChoice(_ store: some ListeningSessionRepository, file: StaticString = #filePath, line: UInt = #line) throws {
        try store.saveImportedCommentaryLayer(layer)
        let stale = written(sender: false, listener: nil)
        try store.saveImportedCommentaryInterjection(stale)
        var chosen = stale
        chosen.listenerReadAloud = true
        try store.saveImportedCommentaryInterjection(chosen)
        try store.saveImportedCommentaryInterjection(stale) // a slow placement pass saving the copy it loaded earlier
        var stored = try XCTUnwrap(try store.loadImportedCommentaryInterjections(layerId: "ana").first, file: file, line: line)
        XCTAssertEqual(stored.listenerReadAloud, true, "the stale copy kept the listener's choice", file: file, line: line)
        XCTAssertEqual(stored.senderReadAloud, false, file: file, line: line)
        XCTAssertTrue(stored.readsAloud, file: file, line: line)
        stored.listenerReadAloud = false // and the listener can change their mind
        try store.saveImportedCommentaryInterjection(stored)
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "ana").first?.listenerReadAloud, false, file: file, line: line)
        // Hearing the Margin writes the same row and keeps the choice.
        _ = try store.markImportedCommentaryInterjectionHeard(id: "m", at: created)
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "ana").first?.listenerReadAloud, false, file: file, line: line)
    }

    func testAStaleCopyCannotUndoTheListenersChoiceInMemory() throws {
        try assertAStaleCopyCannotUndoTheListenersChoice(InMemorySessionRepository())
    }

    func testAStaleCopyCannotUndoTheListenersChoiceInTheLibrary() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ReadAloudChoice-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try assertAStaleCopyCannotUndoTheListenersChoice(try SQLiteSessionStore(path: path))
    }
}
