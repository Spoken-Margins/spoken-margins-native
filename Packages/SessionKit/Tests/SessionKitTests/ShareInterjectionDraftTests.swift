import Foundation
import SessionKit
import SessionKitSharing
import XCTest

final class ShareInterjectionDraftTests: XCTestCase {
    func testNewEditAfterUndoDropsRedoTail() {
        var draft = makeDraft()
        _ = draft.toggleWord(segmentID: "keep", hasOriginalAudio: true)
        _ = draft.toggleWord(segmentID: "last", hasOriginalAudio: true)
        _ = draft.undoEdit(hasOriginalAudio: true)
        _ = draft.recordEdit(hasOriginalAudio: true) { $0.automaticCleanupEnabled = true }
        XCTAssertEqual(draft.editHistory.count, 3)
        XCTAssertEqual(draft.editHistoryIndex, 2)
        XCTAssertFalse(draft.canRedoEdit)
        XCTAssertEqual(draft.currentEditState.manuallyDeletedSegmentIds, ["keep"])
        XCTAssertTrue(draft.currentEditState.automaticCleanupEnabled)
    }

    func testUnchangedEditAddsNoHistoryEntry() {
        var draft = makeDraft()
        _ = draft.toggleWord(segmentID: "keep", hasOriginalAudio: true)
        _ = draft.undoEdit(hasOriginalAudio: true)
        let history = draft.editHistory
        XCTAssertFalse(draft.recordEdit(hasOriginalAudio: true) { $0.automaticCleanupEnabled = false })
        XCTAssertEqual(draft.editHistory, history)
        XCTAssertEqual(draft.editHistoryIndex, 0)
        XCTAssertTrue(draft.canRedoEdit)
    }

    func testUndoAndRedoStopAtEnds() {
        var draft = makeDraft()
        XCTAssertFalse(draft.undoEdit(hasOriginalAudio: true))
        XCTAssertEqual(draft.editHistoryIndex, 0)
        _ = draft.toggleWord(segmentID: "keep", hasOriginalAudio: true)
        XCTAssertTrue(draft.isWordDeleted(segmentID: "keep"))
        _ = draft.undoEdit(hasOriginalAudio: true)
        XCTAssertFalse(draft.isWordDeleted(segmentID: "keep"))
        XCTAssertFalse(draft.canUndoEdit)
        XCTAssertFalse(draft.undoEdit(hasOriginalAudio: true))
        XCTAssertEqual(draft.editHistoryIndex, 0)
        XCTAssertTrue(draft.redoEdit(hasOriginalAudio: true))
        XCTAssertTrue(draft.isWordDeleted(segmentID: "keep"))
        XCTAssertFalse(draft.canRedoEdit)
        XCTAssertFalse(draft.redoEdit(hasOriginalAudio: true))
        XCTAssertEqual(draft.editHistoryIndex, 1)
    }

    func testAutomaticCleanupOffRestoresCoreAndAcousticDecisions() throws {
        for hasAcoustic in [false, true] {
            var draft = makeDraft()
            if hasAcoustic { draft.acousticPauseDecisions = [acousticPause] }
            _ = draft.toggleWord(segmentID: "last", hasOriginalAudio: false)
            let cleanup = try XCTUnwrap(draft.cleanup)
            XCTAssertTrue(cleanup.decisions.contains { $0.kind == .filler })
            XCTAssertTrue(cleanup.decisions.contains { $0.kind == .longPause })
            XCTAssertTrue(cleanup.decisions.filter { $0.kind != .manualWord }.allSatisfy { !$0.accepted })
            XCTAssertEqual(cleanup.cleanedTranscript, "Um Keep")
        }
    }

    func testAcousticPausesHideCoreLongPauses() throws {
        var draft = makeDraft()
        _ = draft.recordEdit(hasOriginalAudio: true) { $0.automaticCleanupEnabled = true }
        XCTAssertTrue(try XCTUnwrap(draft.cleanup).decisions.contains { $0.kind == .longPause })
        draft.acousticPauseDecisions = [acousticPause]
        XCTAssertTrue(draft.applyEditState(hasOriginalAudio: true))
        let pauses = try XCTUnwrap(draft.cleanup).decisions.filter { $0.kind == .longPause }
        XCTAssertEqual(pauses, [acousticPause])
    }

    func testTogglingAcceptedAutomaticWordRestoresInsteadOfDeleting() throws {
        var draft = makeDraft()
        _ = draft.recordEdit(hasOriginalAudio: true) { $0.automaticCleanupEnabled = true }
        let filler = try XCTUnwrap(draft.cleanup?.decisions.first { $0.kind == .filler })
        XCTAssertTrue(draft.isWordDeleted(segmentID: "filler"))
        _ = draft.toggleWord(segmentID: "filler", hasOriginalAudio: true)
        XCTAssertEqual(draft.currentEditState.restoredAutomaticDecisionIds, [filler.id])
        XCTAssertTrue(draft.currentEditState.manuallyDeletedSegmentIds.isEmpty)
        XCTAssertFalse(draft.isWordDeleted(segmentID: "filler"))
        XCTAssertEqual(draft.approvedTranscript, "Um Keep going.")
    }

    func testAnchorBeforeKeepsSuffixAndAfterKeepsPrefixWithoutNormalization() {
        var draft = makeDraft()
        // The draft's comment is 14 characters, so the rule gives 280 before and 120 after (ExcerptCapRule, #2237).
        XCTAssertEqual(ExcerptCapRule.beforeCap(commentLength: 14), 280)
        XCTAssertEqual(ExcerptCapRule.afterMaximum, 120)
        let middle = String(repeating: "é👩", count: 250)
        let value = " \nBEFORE" + middle + "AFTER\t "
        draft.setAnchorBefore(value)
        draft.setAnchorAfter(value)
        XCTAssertTrue(draft.anchorBefore == String(value.suffix(280)), "Before must retain the last 280 characters")
        XCTAssertTrue(draft.anchorAfter == String(value.prefix(120)), "After must retain the first 120 characters")
        // Combining marks and ZWJ emoji take several scalars each: the cap also holds in code points, which is what the share page counts.
        let heavy = String(repeating: "e\u{301}👩🏽‍💻", count: 250)
        draft.setAnchorBefore(heavy)
        draft.setAnchorAfter(heavy)
        XCTAssertLessThanOrEqual(draft.anchorBefore.unicodeScalars.count, 280)
        XCTAssertLessThanOrEqual(draft.anchorAfter.unicodeScalars.count, 120)
        XCTAssertTrue(heavy.hasSuffix(draft.anchorBefore) && heavy.hasPrefix(draft.anchorAfter))
        for short in ["", " \n café\t "] {
            draft.setAnchorBefore(short)
            draft.setAnchorAfter(short)
            XCTAssertEqual(draft.anchorBefore, short)
            XCTAssertEqual(draft.anchorAfter, short)
        }
    }

    func testRepresentationsRequireTheirAudio() {
        var draft = makeDraft()
        draft.setRepresentation(.cleaned, hasOriginalAudio: true)
        XCTAssertEqual(draft.representationChoice, .textOnly)
        draft.setRepresentation(.original, hasOriginalAudio: false)
        XCTAssertEqual(draft.representationChoice, .textOnly)
        draft.setRepresentation(.original, hasOriginalAudio: true)
        XCTAssertEqual(draft.representationChoice, .original)
        draft.cleanedAudioURL = URL(fileURLWithPath: "/test/cleaned.m4a")
        draft.setRepresentation(.cleaned, hasOriginalAudio: false)
        XCTAssertEqual(draft.representationChoice, .cleaned)
        draft.setRepresentation(.textOnly, hasOriginalAudio: true)
        XCTAssertEqual(draft.representationChoice, .textOnly)
    }

    func testRestoreOriginalResetsEditsAndUsesOriginalTranscriptFallbacks() {
        let cases: [(String?, String?, String)] = [
            ("Original", "Display", "Original"), (nil, "Display", "Display"),
            (nil, nil, ""), ("", "Display", "")
        ]
        for (transcript, display, expected) in cases {
            for hasAudio in [false, true] {
                var draft = makeDraft()
                _ = draft.recordEdit(hasOriginalAudio: true) { $0.automaticCleanupEnabled = true }
                draft.interjection.transcript = transcript
                draft.interjection.displayText = display
                draft.interjection.cleanedTranscript = "Must not restore this"
                draft.cleanedAudioURL = URL(fileURLWithPath: "/test/cleaned.m4a")
                draft.cleanedAudioDurationMs = 900
                draft.acousticPauseDecisions = [acousticPause]
                draft.isAnalyzingPauses = true
                draft.isPreparingCleanup = true
                draft.preparationMessage = "Preparing"
                draft.renderGeneration = 7
                draft.restoreOriginal(hasOriginalAudio: hasAudio, anchorWarning: "Anchor warning")
                XCTAssertEqual(draft.editHistory, [.original])
                XCTAssertEqual(draft.editHistoryIndex, 0)
                XCTAssertNil(draft.cleanup)
                XCTAssertNil(draft.cleanedAudioURL)
                XCTAssertNil(draft.cleanedAudioDurationMs)
                XCTAssertFalse(draft.isAnalyzingPauses)
                XCTAssertFalse(draft.isPreparingCleanup)
                XCTAssertNil(draft.preparationMessage)
                XCTAssertEqual(draft.approvedTranscript, expected)
                XCTAssertEqual(draft.representationChoice, hasAudio ? .original : .textOnly)
                XCTAssertEqual(draft.warning, expected.isEmpty
                    ? "No transcript yet, so this Margin can't be shared. Retry its transcription in Margin detail."
                    : "Anchor warning")
                XCTAssertEqual(draft.acousticPauseDecisions, [acousticPause])
                XCTAssertEqual(draft.renderGeneration, 7)
            }
        }
    }

    func testRepresentationRawValuesAndDraftPublicContract() {
        XCTAssertEqual(ShareMarginRepresentationChoice.allCases.map(\.rawValue), ["original", "cleaned", "textOnly"])
        XCTAssertEqual(ShareMarginRepresentationChoice.allCases.map(\.id), ["original", "cleaned", "textOnly"])
        let original = makeDraft()
        // These typed key paths pin the field names/types used by the sender fingerprint.
        let _: WritableKeyPath<ShareInterjectionDraft, Interjection> = \.interjection
        let _: WritableKeyPath<ShareInterjectionDraft, InterjectionCleanupResult?> = \.cleanup
        let _: WritableKeyPath<ShareInterjectionDraft, String?> = \.warning
        let _: WritableKeyPath<ShareInterjectionDraft, [InterjectionCleanupDecision]> = \.acousticPauseDecisions
        let _: WritableKeyPath<ShareInterjectionDraft, [ShareMarginEditState]> = \.editHistory
        let _: WritableKeyPath<ShareInterjectionDraft, Int> = \.editHistoryIndex
        let _: WritableKeyPath<ShareInterjectionDraft, Bool> = \.isAnalyzingPauses
        let _: WritableKeyPath<ShareInterjectionDraft, Bool> = \.isPreparingCleanup
        let _: WritableKeyPath<ShareInterjectionDraft, String?> = \.preparationMessage
        let _: KeyPath<ShareInterjectionDraft, String> = \.id
        let _: WritableKeyPath<ShareInterjectionDraft, Bool> = \.isIncluded
        let _: WritableKeyPath<ShareInterjectionDraft, String> = \.approvedTranscript
        let _: WritableKeyPath<ShareInterjectionDraft, ShareMarginRepresentationChoice> = \.representationChoice
        let _: WritableKeyPath<ShareInterjectionDraft, String> = \.anchorBefore
        let _: WritableKeyPath<ShareInterjectionDraft, String> = \.anchorAfter
        let _: WritableKeyPath<ShareInterjectionDraft, URL?> = \.cleanedAudioURL
        let _: WritableKeyPath<ShareInterjectionDraft, Int?> = \.cleanedAudioDurationMs
        let _: WritableKeyPath<ShareInterjectionDraft, Int> = \.renderGeneration
        let _: KeyPath<ShareInterjectionDraft, [InterjectionCleanupDecision]?> = \.cleanup?.decisions
        XCTAssertEqual(original.id, "margin")
        XCTAssertTrue(original.isIncluded)
        XCTAssertEqual(original.approvedTranscript, "um Keep going.")
        XCTAssertNil(original.cleanup)
        XCTAssertNil(original.cleanedAudioURL)
        XCTAssertNil(original.cleanedAudioDurationMs)
        XCTAssertNil(original.warning)
        XCTAssertEqual(original.anchorBefore, "Before")
        XCTAssertEqual(original.anchorAfter, "After")
        XCTAssertEqual(original.acousticPauseDecisions, [])
        XCTAssertEqual(original.editHistory, [.original])
        XCTAssertEqual(original.editHistoryIndex, 0)
        XCTAssertFalse(original.isAnalyzingPauses)
        XCTAssertFalse(original.isPreparingCleanup)
        XCTAssertNil(original.preparationMessage)
        XCTAssertEqual(original.renderGeneration, 0)
        XCTAssertEqual(ShareMarginEditState.original, ShareMarginEditState())
        // Same ordered labels used by prepareShareInterjections, across a non-testable import.
        let draft = ShareInterjectionDraft(
            interjection: original.interjection, isIncluded: false,
            approvedTranscript: "Reviewed", representationChoice: .original,
            warning: "Warning", anchorBefore: "Left", anchorAfter: "Right"
        )
        XCTAssertFalse(draft.isIncluded)
        XCTAssertEqual(draft.approvedTranscript, "Reviewed")
        XCTAssertEqual(draft.representationChoice, .original)
        XCTAssertEqual(draft.warning, "Warning")
        XCTAssertEqual(draft.anchorBefore, "Left")
        XCTAssertEqual(draft.anchorAfter, "Right")
    }

    func testCleanupDecisionCanBeRestoredAndAcceptedAgain() throws {
        var draft = makeDraft()
        _ = draft.recordEdit(hasOriginalAudio: true) { $0.automaticCleanupEnabled = true }
        let fillerID = try XCTUnwrap(draft.cleanup?.decisions.first { $0.kind == .filler }?.id)
        _ = draft.setCleanupDecision(decisionID: fillerID, accepted: false, hasOriginalAudio: true)
        XCTAssertFalse(draft.isWordDeleted(segmentID: "filler"))
        _ = draft.setCleanupDecision(decisionID: fillerID, accepted: true, hasOriginalAudio: true)
        XCTAssertTrue(draft.isWordDeleted(segmentID: "filler"))
        XCTAssertFalse(draft.isWordDeleted(segmentID: "missing"))
    }

    func testBulkUndoSuppressesRenderAndClearsCleanedAudio() {
        for hasAudio in [false, true] {
            var draft = makeDraft()
            _ = draft.toggleWord(segmentID: "keep", hasOriginalAudio: hasAudio)
            _ = draft.recordEdit(hasOriginalAudio: hasAudio) { $0.automaticCleanupEnabled = true }
            draft.cleanedAudioURL = URL(fileURLWithPath: "/test/cleaned.m4a")
            draft.cleanedAudioDurationMs = 500
            draft.isPreparingCleanup = true
            XCTAssertFalse(draft.undoEdit(hasOriginalAudio: hasAudio, renderCleanedAudio: false))
            XCTAssertEqual(draft.editHistoryIndex, 1)
            XCTAssertTrue(draft.isWordDeleted(segmentID: "keep"))
            XCTAssertNil(draft.cleanedAudioURL)
            XCTAssertNil(draft.cleanedAudioDurationMs)
            XCTAssertFalse(draft.isPreparingCleanup)
            XCTAssertEqual(draft.representationChoice, hasAudio ? .original : .textOnly)
        }
    }

    func testDisablingAutomaticCleanupPreservesManualEdits() {
        var draft = makeDraft()
        _ = draft.recordEdit(hasOriginalAudio: true) {
            $0.automaticCleanupEnabled = true
            $0.restoredAutomaticDecisionIds = ["restored"]
            $0.manuallyDeletedSegmentIds = ["keep"]
        }
        XCTAssertFalse(draft.recordEdit(hasOriginalAudio: true, renderCleanedAudio: false) {
            $0.disableAutomaticCleanup()
        })
        XCTAssertFalse(draft.currentEditState.automaticCleanupEnabled)
        XCTAssertEqual(draft.currentEditState.restoredAutomaticDecisionIds, [])
        XCTAssertEqual(draft.currentEditState.manuallyDeletedSegmentIds, ["keep"])
        XCTAssertEqual(draft.approvedTranscript, "Um going.")
    }

    func testInclusionAndUnalignedDraftNoOpEdits() {
        var draft = makeDraft()
        draft.setIncluded(false)
        XCTAssertFalse(draft.isIncluded)
        draft.setIncluded(true)
        XCTAssertTrue(draft.isIncluded)
        draft.interjection.alignedTranscript = nil
        var mutationRan = false
        XCTAssertFalse(draft.recordEdit(hasOriginalAudio: true) { _ in mutationRan = true })
        XCTAssertFalse(mutationRan)
        XCTAssertFalse(draft.toggleWord(segmentID: "keep", hasOriginalAudio: true))
        XCTAssertFalse(draft.applyEditState(hasOriginalAudio: true))
        XCTAssertFalse(draft.isWordDeleted(segmentID: "keep"))
        XCTAssertEqual(draft.editHistory, [.original])
        XCTAssertEqual(draft.approvedTranscript, "um Keep going.")
    }

    private var acousticPause: InterjectionCleanupDecision {
        .init(id: "acoustic", kind: .longPause, startMs: 700, endMs: 1_500)
    }

    private func makeDraft() -> ShareInterjectionDraft {
        let text = "um Keep going."
        var interjection = Interjection(
            id: "margin", itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0,
                           anchorBefore: "Before", anchorAfter: "After", mediaTimeMs: 1_000),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: text,
            cleanedTranscript: "Keep going.", displayText: "Display", status: "active"
        )
        interjection.alignedTranscript = AlignedInterjectionTranscript(text: text, segments: [
            .init(id: "filler", text: "um", startMs: 0, endMs: 200),
            .init(id: "keep", text: "Keep", startMs: 300, endMs: 500),
            .init(id: "last", text: "going.", startMs: 1_600, endMs: 2_000)
        ])
        return ShareInterjectionDraft(interjection: interjection, approvedTranscript: text,
                                      representationChoice: .textOnly, anchorBefore: "Before", anchorAfter: "After")
    }
}
