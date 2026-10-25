import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// A saved Margin is switched between reply and independent in the real Library (#473, owner 2026-10-25).
/// Only the link changes, and the stored Margin stays the shape Build 32 and Build 34 read.
final class SavedMarginReplySwitchTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor"]
        ]
    )
    private let parent = MarginPacketIdentity(packageDigest: String(repeating: "a", count: 64), packageScopedId: "a-1")
    private var directory: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "reply-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        try store.saveItem(Item(id: "item", title: "Article", mediaType: "text", text: "First sentence. Second sentence.", externalReference: nil, status: "ready"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func savedMargin(replyingTo link: MarginReplyLink?, text: String) throws -> (sessionId: String, margin: Interjection) {
        let engine = SessionEngine(profile: profile, repository: store)
        _ = try engine.startSession(itemId: "item")
        let capture = try engine.beginWrittenInterjection(replyTo: link)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: text)
        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        return (sessionId, try XCTUnwrap(store.loadInterjections(sessionId: sessionId).first { $0.displayText == text }))
    }

    func testAReplyBecomesIndependentAndAnswersAgainWithEverythingElseKept() throws {
        let link = MarginReplyLink.replying(to: parent, parentConversationId: nil)
        let (sessionId, original) = try savedMargin(replyingTo: link, text: "I disagree.")
        XCTAssertEqual(original.replyTo, link)

        XCTAssertTrue(try store.updateReply(ofInterjection: original.id, sessionId: sessionId, to: nil))
        var changed = try XCTUnwrap(store.loadInterjections(sessionId: sessionId).first)
        XCTAssertNil(changed.replyTo)
        changed.replyTo = link
        XCTAssertEqual(changed, original, "only the link differed")

        XCTAssertTrue(try store.updateReply(ofInterjection: original.id, sessionId: sessionId, to: link))
        XCTAssertEqual(try store.loadInterjections(sessionId: sessionId).first, original)
    }

    func testOnlyTheNamedMarginChanges() throws {
        let link = MarginReplyLink.replying(to: parent, parentConversationId: nil)
        let (sessionId, first) = try savedMargin(replyingTo: link, text: "First reply.")
        let engine = SessionEngine(profile: profile, repository: store)
        _ = try engine.inspectSession(sessionId: sessionId)
        let capture = try engine.beginWrittenInterjection(replyTo: link)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Second reply.")

        XCTAssertTrue(try store.updateReply(ofInterjection: first.id, sessionId: sessionId, to: nil))
        let saved = try store.loadInterjections(sessionId: sessionId)
        XCTAssertNil(try XCTUnwrap(saved.first { $0.displayText == "First reply." }).replyTo)
        XCTAssertEqual(try XCTUnwrap(saved.first { $0.displayText == "Second reply." }).replyTo, link)
    }

    func testAMarginThatIsNotThereIsReportedNotInvented() throws {
        let (sessionId, _) = try savedMargin(replyingTo: nil, text: "Plain.")
        XCTAssertFalse(try store.updateReply(ofInterjection: "nope", sessionId: sessionId, to: nil))
        XCTAssertEqual(try store.loadInterjections(sessionId: sessionId).count, 1)
    }
}
