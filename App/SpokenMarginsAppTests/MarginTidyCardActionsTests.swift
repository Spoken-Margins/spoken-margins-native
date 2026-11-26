import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #4339 PR 4: the Tidy version card's three taps reach the right Margin, including one of another session (the Margins
/// tab lists every session), and a proposal for words that changed since saves nothing.
@MainActor
final class MarginTidyCardActionsTests: XCTestCase {
    private static let spoken = "um so the the result was not 12 percent"

    private func makeModel() throws -> (Gate1AppModel, SQLiteSessionStore, Interjection, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-tidy-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let store = try SQLiteSessionStore(path: url.path)
        var session = try XCTUnwrap(store.loadSession(id: try XCTUnwrap(model.snapshot.sessionId)))
        session.id = "other-session"
        try store.saveSession(session)
        let margin = Interjection(
            id: "tidy-margin", itemId: "item-pill", sessionId: session.id, targetType: .item, targetId: "item-pill",
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 50,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before.", anchorAfter: "After."),
            audioPath: "interjections/tidy-margin.m4a", audioStatus: "saved", transcriptionStatus: "transcribed",
            transcript: Self.spoken, cleanedTranscript: nil, displayText: Self.spoken, status: "active"
        )
        try store.saveInterjection(margin)
        return (model, store, margin, root)
    }

    private func saved(_ store: SQLiteSessionStore, _ margin: Interjection) throws -> Interjection {
        try XCTUnwrap(store.loadInterjections(sessionId: margin.sessionId).first { $0.id == margin.id })
    }

    func testUseTidyThenUseMyOriginalWordsOnAMarginOfAnotherSession() throws {
        let (model, store, margin, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = MarginTidyProposal(text: "The result was not 12 percent", source: .fillers)

        model.useTidyVersion(margin, proposal: proposal, basedOn: Self.spoken)
        let used = try saved(store, margin)
        XCTAssertEqual(used.displayText, proposal.text)
        XCTAssertEqual(used.cleanedTranscript, proposal.text)
        XCTAssertEqual(used.transcript, Self.spoken)
        XCTAssertEqual(used.tidyDecision?.choice, .usedTidy)
        XCTAssertEqual(MarginTidyCardState.state(for: used), .used)

        model.useOriginalWords(of: margin)
        let back = try saved(store, margin)
        XCTAssertNil(back.cleanedTranscript)
        XCTAssertNil(back.tidyDecision)
        XCTAssertEqual(back.displayText, Self.spoken)
        XCTAssertEqual(MarginTidyCardState.state(for: back), .candidate(transcript: Self.spoken))
    }

    func testKeepMineIsRemembered() throws {
        let (model, store, margin, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.keepMarginAsSpoken(margin)
        let kept = try saved(store, margin)
        XCTAssertEqual(kept.tidyDecision?.choice, .keptOriginal)
        XCTAssertEqual(kept.displayText, Self.spoken)
        XCTAssertEqual(MarginTidyCardState.state(for: kept), .hidden)
    }

    func testAProposalForOtherWordsSavesNothing() throws {
        let (model, store, margin, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.useTidyVersion(margin, proposal: MarginTidyProposal(text: "Old words tidied", source: .onDeviceAI), basedOn: "some older words")
        XCTAssertEqual(try saved(store, margin), margin)
    }
}
