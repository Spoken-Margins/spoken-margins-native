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
                // From As recorded; a Words only draft stays Words only (#4647, ShareVoiceWaitTests and
                // BulkShareDraftPreparationTests on Linux).
                draft.representationChoice = .original
                draft.restoreOriginal(hasOriginalAudio: hasAudio)
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
                // The placement wait is no longer a warning on the draft (#3839): it is a live step on the card.
                XCTAssertEqual(draft.warning, expected.isEmpty
                    ? "No transcript yet, so this Margin can't be shared. Retry its transcription in Margin detail."
                    : nil)
                XCTAssertEqual(draft.acousticPauseDecisions, [acousticPause])
                XCTAssertEqual(draft.renderGeneration, 8, "Undo all edits makes a render still out stale (#4647)")
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
            draft.representationChoice = .original // a Words only draft would stay Words only (#4647)
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

    /// #3839: the review's step reads the stored Margin, so the packet must be built from it too. Evidence the stored
    /// Margin gains while the sheet is open reaches the draft; the sender's words and edits never change.
    func testTheDraftTakesEvidenceTheStoredMarginGainsAndNothingElse() {
        var draft = makeDraft()
        draft.approvedTranscript = "The sender's own words"
        XCTAssertFalse(draft.refreshAnchorEvidence(from: draft.interjection), "an unchanged Margin is no change")
        var stored = draft.interjection
        stored.transcript = "Different stored words"
        stored.podcastAnchorEvidence = [CapturedPodcastAnchorEvidence(id: "e", localPath: "/unused", durationMs: 12_000, anchorOffsetMs: 4_000)]
        stored.podcastAnchorEvidenceCaptureStatus = .ready
        stored.sourceExactEditionSHA256 = "sha"
        XCTAssertTrue(draft.refreshAnchorEvidence(from: stored))
        XCTAssertEqual(draft.interjection.podcastAnchorEvidence?.map(\.id), ["e"])
        XCTAssertEqual(draft.interjection.podcastAnchorEvidenceCaptureStatus, .ready)
        XCTAssertEqual(draft.interjection.sourceExactEditionSHA256, "sha")
        XCTAssertEqual(draft.approvedTranscript, "The sender's own words")
        XCTAssertNotEqual(draft.interjection.transcript, "Different stored words")
        XCTAssertFalse(draft.refreshAnchorEvidence(from: stored), "the second read changes nothing")
        var other = stored
        other.id = "another"
        other.podcastAnchorEvidence = nil
        XCTAssertFalse(draft.refreshAnchorEvidence(from: other), "another Margin's evidence is never taken")
    }

    // MARK: Words arriving (#3839)

    private func pendingVoiceMargin() -> Interjection {
        Interjection(
            id: "voice", itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "Before", anchorAfter: "After", mediaTimeMs: 61_000),
            audioPath: "voice.m4a", audioStatus: "recorded", transcriptionStatus: "pending", transcript: nil,
            cleanedTranscript: nil, displayText: nil, status: "active")
    }

    private func arrived(_ margin: Interjection, status: String = "transcribed", words: String = "Keep going.") -> Interjection {
        var stored = margin
        stored.transcriptionStatus = status
        stored.transcript = status == "transcribed" ? words : nil
        stored.displayText = status == "transcribed" ? words : nil
        stored.alignedTranscript = status == "transcribed" ? AlignedInterjectionTranscript(text: words, segments: [
            .init(id: "keep", text: "Keep", startMs: 0, endMs: 300), .init(id: "going", text: "going.", startMs: 400, endMs: 800)
        ]) : nil
        return stored
    }

    private func pendingDraft(isIncluded: Bool = true) -> ShareInterjectionDraft {
        ShareInterjectionDraft.initial(for: pendingVoiceMargin(), isIncluded: isIncluded, hasVoice: true, itemTitle: "Episode")
    }

    func testTheWordsThatArriveReplaceTheStandInWordsAndBringTheTiming() throws {
        var draft = pendingDraft()
        XCTAssertTrue(draft.isShowingPlaceholder, "a pending voice Margin starts with the stand-in words")
        XCTAssertTrue(draft.adoptArrivedWords(from: arrived(draft.interjection), hasVoice: true, itemTitle: "Episode"))
        XCTAssertEqual(draft.approvedTranscript, "Keep going.")
        XCTAssertFalse(draft.isShowingPlaceholder)
        XCTAssertNil(draft.placeholderText)
        XCTAssertNil(draft.warning)
        XCTAssertEqual(draft.interjection.transcriptionStatus, "transcribed")
        XCTAssertNotNil(draft.interjection.alignedTranscript, "the timing arrives with the words, so ums can be removed")
        XCTAssertEqual(draft.representationChoice, .original)
        XCTAssertFalse(draft.adoptArrivedWords(from: arrived(draft.interjection), hasVoice: true, itemTitle: "Episode"), "once taken, nothing is pending")
    }

    func testTheWordsArriveWhateverElseTheSenderChangedAndTheirChoicesStay() {
        let choices: [(String, (inout ShareInterjectionDraft) -> Void)] = [
            ("words only", { $0.setRepresentation(.textOnly, hasOriginalAudio: true) }),
            ("read aloud off", { $0.readAloud = false }),
            ("run-up changed", { $0.leadInMs += 1_000 }),
            ("left out", { $0.setIncluded(false) })
        ]
        for (name, choose) in choices {
            var draft = pendingDraft()
            choose(&draft)
            let (representation, readAloud, leadIn, included) = (draft.representationChoice, draft.readAloud, draft.leadInMs, draft.isIncluded)
            XCTAssertTrue(draft.adoptArrivedWords(from: arrived(draft.interjection), hasVoice: true, itemTitle: "Episode"), name)
            XCTAssertEqual(draft.approvedTranscript, "Keep going.", "\(name): the words still arrive")
            XCTAssertEqual(draft.representationChoice, representation, name)
            XCTAssertEqual(draft.readAloud, readAloud, name)
            XCTAssertEqual(draft.leadInMs, leadIn, name)
            XCTAssertEqual(draft.isIncluded, included, name)
        }
    }

    func testPlacementWordsTheSenderEditedStayAndUntouchedOnesFollowTheNewWords() {
        var edited = pendingDraft()
        edited.setAnchorBefore("Something else")
        edited.setAnchorAfter("Another thing")
        let (before, after) = (edited.anchorBefore, edited.anchorAfter)
        XCTAssertNotEqual(before, "Before")
        XCTAssertTrue(edited.adoptArrivedWords(from: arrived(edited.interjection), hasVoice: true, itemTitle: "Episode"))
        XCTAssertEqual(edited.anchorBefore, before)
        XCTAssertEqual(edited.anchorAfter, after)
        var untouched = pendingDraft()
        let expected = ShareInterjectionDraft.initial(
            for: arrived(untouched.interjection), isIncluded: true, hasVoice: true, itemTitle: "Episode")
        XCTAssertTrue(untouched.adoptArrivedWords(from: arrived(untouched.interjection), hasVoice: true, itemTitle: "Episode"))
        XCTAssertEqual(untouched.anchorBefore, expected.anchorBefore)
        XCTAssertEqual(untouched.anchorAfter, expected.anchorAfter)
    }

    func testRebuildKeepsTheLastSentChoicesTheDraftStartedWith() {
        var draft = ShareInterjectionDraft.initial(
            for: pendingVoiceMargin(), isIncluded: true, hasVoice: true, itemTitle: "Episode",
            lastSentReadAloud: false, lastSentLeadInMs: 8_000)
        XCTAssertTrue(draft.adoptArrivedWords(from: arrived(draft.interjection), hasVoice: true, itemTitle: "Episode"))
        XCTAssertFalse(draft.readAloud)
        XCTAssertEqual(draft.previousReadAloud, false)
        XCTAssertEqual(draft.leadInMs, SenderLeadIn.startingMs(lastSent: 8_000))
        XCTAssertEqual(draft.previousLeadInMs, 8_000)
    }

    /// Words the sender wrote over the stand-in are theirs: the arriving words take none of it and bring no timing.
    func testWordsTheSenderTypedStayAndClearingThemLetTheArrivingWordsIn() {
        var draft = pendingDraft()
        draft.setReviewedWords("My own words")
        XCTAssertFalse(draft.adoptArrivedWords(from: arrived(draft.interjection), hasVoice: true, itemTitle: "Episode"))
        XCTAssertEqual(draft.approvedTranscript, "My own words")
        XCTAssertEqual(draft.interjection.transcriptionStatus, "pending")
        XCTAssertNil(draft.interjection.alignedTranscript)
        draft.setReviewedWords("")
        XCTAssertTrue(draft.isShowingPlaceholder, "clearing their words brings the stand-in back")
        XCTAssertTrue(draft.adoptArrivedWords(from: arrived(draft.interjection), hasVoice: true, itemTitle: "Episode"))
        XCTAssertEqual(draft.approvedTranscript, "Keep going.")
    }

    func testOnlyAPendingOrFailedDraftForTheSameMarginTakesWords() {
        var done = pendingDraft()
        done.interjection.transcriptionStatus = "transcribed"
        XCTAssertFalse(done.adoptArrivedWords(from: arrived(done.interjection), hasVoice: true, itemTitle: "Episode"))
        var draft = pendingDraft()
        var other = arrived(draft.interjection)
        other.id = "another"
        XCTAssertFalse(draft.adoptArrivedWords(from: other, hasVoice: true, itemTitle: "Episode"))
        XCTAssertFalse(draft.adoptArrivedWords(from: draft.interjection, hasVoice: true, itemTitle: "Episode"), "still pending")
    }

    /// Failed first, then a retry in Margin detail lands while the sheet is still open.
    func testAFailedTranscriptionKeepsTheStandInWordsAndALaterRetryStillLandsTheWords() {
        var draft = pendingDraft()
        let placeholder = draft.approvedTranscript
        XCTAssertTrue(draft.adoptArrivedWords(from: arrived(draft.interjection, status: "failed"), hasVoice: true, itemTitle: "Episode"))
        XCTAssertEqual(draft.approvedTranscript, placeholder, "a voice Margin still goes, with its stand-in words (#3027)")
        XCTAssertEqual(draft.interjection.transcriptionStatus, "failed")
        XCTAssertNil(draft.warning)
        XCTAssertTrue(draft.adoptArrivedWords(from: arrived(draft.interjection), hasVoice: true, itemTitle: "Episode"))
        XCTAssertEqual(draft.approvedTranscript, "Keep going.")
        XCTAssertEqual(draft.interjection.transcriptionStatus, "transcribed")
    }

    func testCleanupInFlightHoldsTheWordsBack() {
        for hold in [{ (d: inout ShareInterjectionDraft) in d.isPreparingCleanup = true },
                     { (d: inout ShareInterjectionDraft) in d.editHistory.append(ShareMarginEditState(automaticCleanupEnabled: true)); d.editHistoryIndex = 1 }] {
            var draft = pendingDraft()
            hold(&draft)
            XCTAssertFalse(draft.adoptArrivedWords(from: arrived(draft.interjection), hasVoice: true, itemTitle: "Episode"))
            XCTAssertTrue(draft.isShowingPlaceholder)
        }
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
