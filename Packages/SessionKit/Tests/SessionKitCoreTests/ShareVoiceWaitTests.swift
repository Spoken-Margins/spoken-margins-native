import Foundation
import XCTest
import SessionKit
import SessionKitSharing

/// #4647: what the Share Margins list waits on while voices without ums are made. Every row of the rules, so a change
/// to one of them is a deliberate edit.
final class ShareVoiceWaitTests: XCTestCase {
    private func margin(
        included: Bool = true, words: Bool = true, recording: Bool = true, edits: Bool = false, file: Bool = false,
        inProgress: Bool = false, goes: ShareMarginRepresentationChoice = .original, pick: ShareMarginRepresentationChoice? = nil
    ) -> ShareVoiceWait.Margin {
        ShareVoiceWait.Margin(
            isIncluded: included, hasWords: words, hasRecording: recording, hasCleanupEdits: edits, hasCleanedFile: file,
            voiceInProgress: inProgress, representation: goes, senderPick: pick)
    }

    func testWhoWaits() {
        struct Row { let name: String; let margin: ShareVoiceWait.Margin; let waits: Bool }
        let rows = [
            Row(name: "queued, no pick", margin: margin(edits: true, inProgress: true), waits: true),
            Row(name: "queued, nothing found yet (no edits)", margin: margin(inProgress: true), waits: true),
            Row(name: "queued, picked Without ums", margin: margin(edits: true, inProgress: true, pick: .cleaned), waits: true),
            Row(name: "queued, picked As recorded", margin: margin(edits: true, inProgress: true, pick: .original), waits: false),
            Row(name: "queued, picked Words only", margin: margin(edits: true, inProgress: true, goes: .textOnly, pick: .textOnly), waits: false),
            Row(name: "queued, left out", margin: margin(included: false, edits: true, inProgress: true), waits: false),
            Row(name: "queued, no recording", margin: margin(recording: false, edits: true, inProgress: true, goes: .textOnly), waits: false),
            Row(name: "not in progress", margin: margin(edits: true, file: true, goes: .cleaned), waits: false),
        ]
        for row in rows {
            XCTAssertEqual(row.margin.waits, row.waits, row.name)
        }
    }

    func testTheShownVersionIsWithoutUmsOnlyWhileThatVoiceIsComingForEditedWords() {
        XCTAssertEqual(margin(edits: true, inProgress: true).displayedVersion, .cleaned)
        XCTAssertEqual(margin(inProgress: true).displayedVersion, .original, "nothing found yet: shows what goes")
        XCTAssertEqual(margin(edits: true, inProgress: true, pick: .original).displayedVersion, .original)
        XCTAssertEqual(margin(edits: true, inProgress: true, goes: .textOnly, pick: .textOnly).displayedVersion, .textOnly)
        XCTAssertEqual(margin(edits: true, file: true, goes: .cleaned).displayedVersion, .cleaned)
        XCTAssertEqual(margin(edits: true).displayedVersion, .original, "failed earlier: shows what goes")
    }

    func testTheMenuOffersWithoutUmsWhileItsVoiceIsBeingMade() {
        XCTAssertEqual(margin().menuOptions, [.original, .textOnly])
        XCTAssertEqual(margin(edits: true, inProgress: true).menuOptions, [.original, .cleaned, .textOnly])
        XCTAssertEqual(margin(file: true).menuOptions, [.original, .cleaned, .textOnly])
        XCTAssertEqual(margin(recording: false, edits: true, file: true, goes: .textOnly).menuOptions, [.textOnly])
    }

    func testWhatCountsAsAFailedWait() {
        XCTAssertTrue(margin(edits: true).failedAfterWait, "edits, no voice, no pick: the render failed")
        XCTAssertFalse(margin().failedAfterWait, "the analysis found nothing (no edits), render done, still As recorded: not failed")
        XCTAssertFalse(margin(edits: true, file: true, goes: .cleaned).failedAfterWait)
        XCTAssertFalse(margin(edits: true, inProgress: true).failedAfterWait, "still being made")
        XCTAssertFalse(margin(edits: true, pick: .original).failedAfterWait, "the sender chose As recorded")
        XCTAssertFalse(margin(edits: true, goes: .textOnly, pick: .textOnly).failedAfterWait)
        XCTAssertFalse(margin(included: false, edits: true).failedAfterWait)
        XCTAssertTrue(margin(edits: true, pick: .cleaned).failedAfterWait, "picked Without ums and it didn't come")
    }

    func testReadiness() {
        XCTAssertEqual(ShareSendReadiness([]), .nothingToSend)
        XCTAssertEqual(ShareSendReadiness([margin(included: false)]), .nothingToSend)
        XCTAssertEqual(ShareSendReadiness([margin(words: false)]), .nothingToSend)
        XCTAssertEqual(ShareSendReadiness([margin(), margin(included: false)]), .ready(count: 1))
        XCTAssertEqual(ShareSendReadiness([margin(), margin(edits: true, inProgress: true), margin(inProgress: true)]),
                       .waiting(count: 2))
        XCTAssertEqual(ShareSendReadiness([margin(), margin(edits: true, inProgress: true, pick: .original)]), .ready(count: 2))
        XCTAssertTrue(ShareSendReadiness([margin(inProgress: true)]).isWaiting)
        XCTAssertFalse(ShareSendReadiness([margin()]).isWaiting)
    }

    func testASendWaitEndsReadyOrFailedOnlyWhenEveryWaitedVoiceIsDone() {
        let wait = ShareSendWait(waitingIDs: ["a", "b"])
        XCTAssertEqual(wait.verdict(["a": margin(edits: true, inProgress: true), "b": margin(edits: true, inProgress: true)]),
                       .waiting(count: 2))
        XCTAssertEqual(wait.verdict(["a": margin(edits: true, file: true, goes: .cleaned), "b": margin(edits: true, inProgress: true)]),
                       .waiting(count: 1))
        XCTAssertEqual(wait.verdict(["a": margin(edits: true, file: true, goes: .cleaned), "b": margin()]), .ready,
                       "b's analysis found nothing: not a failure")
        XCTAssertEqual(wait.verdict(["a": margin(edits: true), "b": margin(edits: true, file: true, goes: .cleaned)]),
                       .failed(count: 1))
        XCTAssertEqual(wait.verdict(["a": margin(edits: true, inProgress: true, pick: .original), "b": margin(edits: true)]),
                       .failed(count: 1), "a stopped waiting when the sender picked As recorded; b failed")
        XCTAssertEqual(wait.verdict([:]), .ready, "Margins gone from the sheet neither wait nor fail")
    }

    func testAMarginReadsItsDraft() {
        var draft = ShareInterjectionDraft(
            interjection: Interjection(
                id: "a", itemId: "item", sessionId: "s", targetType: .item, targetId: "item",
                createdAt: Date(timeIntervalSince1970: 0), roughPercent: 0,
                anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 0),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "Words",
                cleanedTranscript: nil, displayText: nil, status: "active"),
            approvedTranscript: "Words", representationChoice: .original, anchorBefore: "", anchorAfter: "")
        draft.isPreparingCleanup = true
        let read = ShareVoiceWait.Margin(draft, hasRecording: true, isQueued: false)
        XCTAssertTrue(read.voiceInProgress)
        XCTAssertTrue(read.hasWords)
        XCTAssertFalse(read.hasCleanupEdits)
        draft.isPreparingCleanup = false
        XCTAssertTrue(ShareVoiceWait.Margin(draft, hasRecording: true, isQueued: true).voiceInProgress)
        XCTAssertFalse(ShareVoiceWait.Margin(draft, hasRecording: true, isQueued: false).voiceInProgress)
    }

    // MARK: The packet's fingerprint

    func testAVoiceLandingOnAMarginThatDoesNotGoCleanedLeavesThePacketCurrent() {
        let base = [draft("a", goes: .original), draft("b", included: false)]
        let before = ShareDraftFingerprint.fields(for: base)

        var rendered = base
        rendered[0].cleanedAudioURL = URL(fileURLWithPath: "/tmp/a.m4a")
        rendered[0].cleanedAudioDurationMs = 900
        rendered[0].renderGeneration += 3
        rendered[1].approvedTranscript = "left out, changed"
        XCTAssertEqual(ShareDraftFingerprint.fields(for: rendered), before,
                       "a render on an As recorded Margin and a change to a left-out one don't change the packet")

        var included = base
        included[1].isIncluded = true
        XCTAssertNotEqual(ShareDraftFingerprint.fields(for: included), before)

        var words = base
        words[0].approvedTranscript = "Other words"
        XCTAssertNotEqual(ShareDraftFingerprint.fields(for: words), before)

        var cleaned = base
        cleaned[0].representationChoice = .cleaned
        cleaned[0].cleanedAudioURL = URL(fileURLWithPath: "/tmp/a.m4a")
        let goingCleaned = ShareDraftFingerprint.fields(for: cleaned)
        XCTAssertNotEqual(goingCleaned, before)
        cleaned[0].renderGeneration += 1
        XCTAssertNotEqual(ShareDraftFingerprint.fields(for: cleaned), goingCleaned, "a Margin that goes cleaned counts its render")
    }

    private func draft(_ id: String, included: Bool = true, goes: ShareMarginRepresentationChoice = .original) -> ShareInterjectionDraft {
        var draft = ShareInterjectionDraft(
            interjection: Interjection(
                id: id, itemId: "item", sessionId: "s", targetType: .item, targetId: "item",
                createdAt: Date(timeIntervalSince1970: 0), roughPercent: 0,
                anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 0),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "Words",
                cleanedTranscript: nil, displayText: nil, status: "active"),
            approvedTranscript: "Words \(id)", representationChoice: goes, anchorBefore: "", anchorAfter: "")
        draft.isIncluded = included
        return draft
    }
}
