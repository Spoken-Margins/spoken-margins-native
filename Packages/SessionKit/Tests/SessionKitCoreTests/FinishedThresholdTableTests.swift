import Foundation
import XCTest
@testable import SessionKit

/// #4106: "finished" is two named numbers on `ItemFinishedRule`, and every reader in SessionKit agrees with them.
/// A session's `completionPercent` is a whole number, so the rows step through it; the engine rows go through a
/// text item at fractional places, to see how the percent it saves rounds.
final class FinishedThresholdTableTests: XCTestCase {
    private let rows = [0, 50, 97, 98, 99, 100]

    func testTheNumbersAreWhatTheOwnerSettled() {
        XCTAssertEqual(ItemFinishedRule.listenedPercent, 99)
        XCTAssertEqual(ItemFinishedRule.atEndPercent, 100)
        XCTAssertEqual(PreparationChunkGate.listenedCutoffPercent, ItemFinishedRule.listenedPercent)
    }

    private func session(percent: Int) -> Session {
        Session(
            id: "s", itemId: "item", updatedAt: Date(timeIntervalSince1970: 1), status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: "item",
            position: Position(charOffset: 0, mediaTimeMs: 1_000), completionPercent: percent, playbackRate: 1)
    }

    func testPreparationAndLibraryHearItAtTheListenedPercent() {
        for percent in rows {
            let heard = percent >= ItemFinishedRule.listenedPercent
            XCTAssertEqual(PreparationChunkGate.itemAlreadyListened([session(percent: percent)]), heard, "\(percent)%")
        }
    }

    /// At the end percent Play starts again, so the saved place is the end only from the listened percent up to it.
    func testPlaySavedPlaceIsAtTheEndFromTheListenedPercentUpToTheEndPercent() {
        for percent in rows {
            XCTAssertEqual(
                PlayRule.savedPlaceIsAtEnd(sessions: [session(percent: percent)], addedAgainAt: nil),
                percent >= ItemFinishedRule.listenedPercent && percent < ItemFinishedRule.atEndPercent, "\(percent)%")
        }
    }

    func testContinueStartsOverOnlyAtTheEndPercent() {
        for percent in rows {
            let one = session(percent: percent)
            let atEnd = percent >= ItemFinishedRule.atEndPercent
            XCTAssertEqual(SessionContinuation.continueResumes(one), !atEnd, "\(percent)%")
            XCTAssertEqual(
                SessionContinuation.continuePlaceMs(hasContinuationSession: true, progressPercent: percent),
                atEnd ? 0 : nil, "\(percent)% from the row")
            XCTAssertEqual(SessionContinuation.continuePlaceMs(sessions: [one]), atEnd ? 0 : 1_000, "\(percent)%")
            var closed = one
            closed.status = "finished"
            XCTAssertEqual(
                SessionContinuation.preferredContinuationSession(in: [closed])?.id,
                atEnd ? "s" : nil, "\(percent)% finished session")
        }
    }

    func testCarPlayFinishedAtTheEndPercent() {
        for percent in rows {
            let entry = CarPlayLibraryEntry(id: "i", title: "T", kind: .text, progressPercent: percent)
            XCTAssertEqual(entry.isFinished, percent >= ItemFinishedRule.atEndPercent, "\(percent)%")
        }
    }

    /// The engine stamps the item finished when a session it saves is at the listened percent, at whatever place the
    /// text reaches. The saved percent is a whole number, so the engine's old `> 98` and the Library's `>= 99` agreed
    /// in practice; this pins them to one constant so they can't drift (a `> 97` makes the 98% rows fail).
    func testEngineStampsTheItemFinishedAtTheListenedPercent() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online", displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"]])
        for tenth in [0, 500, 979, 980, 985, 989, 990, 995, 1000] {
            let item = Item(
                id: "item", title: "Own", mediaType: "text", text: String(repeating: "x", count: 1000),
                externalReference: nil, status: "ready")
            let session = Session(
                id: "s", itemId: item.id, status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(),
                completionPercent: 0, playbackRate: 1)
            let note = Interjection(
                id: "ij", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
                createdAt: Date(), roughPercent: tenth / 10,
                anchor: Anchor(anchorType: .text, startChar: tenth, endChar: tenth, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note",
                cleanedTranscript: nil, displayText: "Note", status: "active")
            let repository = InMemorySessionRepository(
                items: [item.id: item], sessions: [session.id: session], interjections: [note.id: note])
            let engine = SessionEngine(profile: profile, repository: repository)

            _ = try engine.playInterjectionAnchor(note)

            let saved = try XCTUnwrap(repository.loadSession(id: "s"))
            let stamped = try repository.loadItem(id: item.id).sourceCompletedAt != nil
            XCTAssertEqual(stamped, saved.completionPercent >= ItemFinishedRule.listenedPercent,
                           "place \(Double(tenth) / 10)% saved as \(saved.completionPercent)%")
        }
    }
}
