import SwiftUI
import Foundation
import XCTest
@testable import SessionKit
import SessionKitSharing
@testable import SpokenMarginsApp

@MainActor
final class Build23SenderSharingExperienceTests: XCTestCase {
    func testFirstShareChoiceIsRememberedAndControlsFutureDefault() {
        let defaults = UserDefaults.standard
        let priorDecision = defaults.object(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        let priorEnabled = defaults.object(forKey: ShareAutoCleanPreference.enabledKey)
        defer {
            restoreUserDefault(priorDecision, forKey: ShareAutoCleanPreference.decisionRecordedKey)
            restoreUserDefault(priorEnabled, forKey: ShareAutoCleanPreference.enabledKey)
        }
        defaults.removeObject(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        defaults.removeObject(forKey: ShareAutoCleanPreference.enabledKey)

        let firstShare = makeCoordinator()
        firstShare.send(.begin)
        XCTAssertTrue(firstShare.snapshot.needsAutoCleanDecision)
        XCTAssertFalse(firstShare.snapshot.autoCleanSelectedEnabled)

        firstShare.send(.setAutoCleanSelectedEnabled(true))
        XCTAssertFalse(firstShare.snapshot.needsAutoCleanDecision)
        XCTAssertTrue(firstShare.snapshot.autoCleanSelectedEnabled)

        let laterShare = makeCoordinator()
        laterShare.send(.begin)
        XCTAssertFalse(laterShare.snapshot.needsAutoCleanDecision)
        XCTAssertTrue(laterShare.snapshot.autoCleanSelectedEnabled)

        laterShare.send(.setAutoCleanSelectedEnabled(false))
        XCTAssertFalse(laterShare.snapshot.autoCleanSelectedEnabled)
        XCTAssertFalse(defaults.bool(forKey: ShareAutoCleanPreference.enabledKey))
    }

    func testBulkSelectionCanIncludeOrExcludeEveryVisibleMarginInOneAction() {
        let coordinator = makeCoordinator(marginCount: 3)
        coordinator.send(.begin)
        let visibleIDs = coordinator.snapshot.margins.map(\.id)

        coordinator.send(.setVisibleIncluded(ids: visibleIDs, included: false))
        XCTAssertTrue(coordinator.snapshot.margins.allSatisfy { !$0.isIncluded })

        coordinator.send(.setVisibleIncluded(ids: visibleIDs, included: true))
        XCTAssertTrue(coordinator.snapshot.margins.allSatisfy(\.isIncluded))
    }

    /// #4647: a sheet that isn't a reply opens the list even with nothing included; Share is disabled until a Margin is.
    func testASheetThatIsNotAReplyOpensTheListWithNothingIncludedAndShareDisabled() {
        let coordinator = makeCoordinator()
        coordinator.send(.begin)
        coordinator.send(.setPrivateSharingRightsConfirmed(true))
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertTrue(coordinator.snapshot.showsList)

        let marginID = coordinator.snapshot.margins[0].id
        coordinator.send(.setIncluded(id: marginID, included: false))

        XCTAssertEqual(coordinator.snapshot.stage, .review, "the list stays open with nothing included")
        XCTAssertFalse(coordinator.snapshot.canAdvance)
        XCTAssertEqual(coordinator.snapshot.readiness, .nothingToSend)

        coordinator.send(.setIncluded(id: marginID, included: true))
        XCTAssertTrue(coordinator.snapshot.canAdvance)
        XCTAssertEqual(coordinator.snapshot.readiness, .ready(count: 1))
    }

    /// #536: a failed share offers "Share without episode matching" while matching data is included.
    func testAFailedShareOffersSharingWithoutEpisodeMatching() {
        let failed = Build23SharingPreviewState.failed("episode fingerprint spine is out of bounds: canonical_url")
        XCTAssertTrue(Build23SenderPresentation.offersShareWithoutMatching(previewState: failed, includesAcousticEvidence: true))
        XCTAssertFalse(Build23SenderPresentation.offersShareWithoutMatching(previewState: failed, includesAcousticEvidence: false))
        XCTAssertFalse(Build23SenderPresentation.offersShareWithoutMatching(previewState: .ready, includesAcousticEvidence: true))
        XCTAssertFalse(Build23SenderPresentation.offersShareWithoutMatching(previewState: .notBuilt, includesAcousticEvidence: true))
        // Failures that turning matching off can't fix offer nothing.
        for unrelated in ["Select at least one Margin with reviewed text.", "Finish or cancel bulk preparation before sharing.", "The package could not be built."] {
            XCTAssertFalse(Build23SenderPresentation.offersShareWithoutMatching(previewState: .failed(unrelated), includesAcousticEvidence: true), unrelated)
        }
        XCTAssertTrue(Build23SenderPresentation.offersShareWithoutMatching(
            previewState: .failed("The package manifest is invalid: episode fingerprint landmark is invalid: signature_asset."), includesAcousticEvidence: true
        ))
        XCTAssertTrue(Build23SenderPresentation.offersShareWithoutMatching(
            previewState: .failed("A package asset is unreadable: assets/evidence/episode-signature-item-grid-3.shazamsignature."), includesAcousticEvidence: true
        ))
    }

    /// #3896 audit: the top "Back to selection" on the preview step was drawn in every preview state, so a listener
    /// could go back while the preview was still building and a failed build then pushed them off the selection
    /// screen. It is drawn only for a ready, verified preview, as the old in-actions button was.
    func testTheTopBackToSelectionOnThePreviewStepNeedsAReadyVerifiedPreview() {
        func id(_ stage: Build23SharingStage, _ state: Build23SharingPreviewState, verified: Bool) -> String? {
            Build23SenderPresentation.topBackToSelectionIdentifier(stage: stage, previewState: state, hasVerifiedPreview: verified)
        }
        XCTAssertEqual(id(.recipientPreview, .ready, verified: true), "build23.sender.preview.edit")
        for state in [Build23SharingPreviewState.building, .stale, .notBuilt, .failed("x"), .ready] {
            XCTAssertNil(id(.recipientPreview, state, verified: false), "\(state) without a verified preview")
        }
        for state in [Build23SharingPreviewState.building, .stale, .notBuilt, .failed("x")] {
            XCTAssertNil(id(.recipientPreview, state, verified: true), "\(state)")
        }
        for state in [Build23SharingPreviewState.building, .ready, .failed("x")] {
            XCTAssertEqual(id(.review, state, verified: false), "build23.sender.review.back")
            // The Share Margins list is the review step itself: it has no back (#4647).
            XCTAssertNil(Build23SenderPresentation.topBackToSelectionIdentifier(
                stage: .review, previewState: state, hasVerifiedPreview: false, showsList: true))
        }
        XCTAssertNil(id(.select, .ready, verified: true))
        XCTAssertNil(id(.share, .ready, verified: true))
    }

    func testPresentationReturnsExactlyOneExpandedEditorForTheSelectedMargin() {
        let coordinator = makeCoordinator(marginCount: 2)
        coordinator.send(.begin)

        // On the list no editor is open until a card's editor button is tapped (#4647).
        XCTAssertTrue(Build23SenderPresentation.expandedMargins(in: coordinator.snapshot).isEmpty)

        let secondMarginID = coordinator.snapshot.margins[1].id
        coordinator.send(.selectMargin(secondMarginID))
        XCTAssertEqual(
            Build23SenderPresentation.expandedMargins(in: coordinator.snapshot).map(\.id),
            [secondMarginID]
        )

        coordinator.send(.selectMargin(nil))
        XCTAssertTrue(Build23SenderPresentation.expandedMargins(in: coordinator.snapshot).isEmpty)
    }

    func testPackageMutationInvalidatesVerifiedRecipientPreviewAsStale() async throws {
        let coordinator = makeCoordinator()
        coordinator.send(.begin)
        coordinator.send(.setPrivateSharingRightsConfirmed(true))
        coordinator.send(.advanceToReview)
        coordinator.send(.buildRecipientPreview)

        let preview = try await waitForVerifiedPreview(from: coordinator)
        defer { try? FileManager.default.removeItem(at: preview.fileURL) }

        XCTAssertEqual(coordinator.snapshot.previewState, .ready)
        XCTAssertEqual(coordinator.verifiedShareFileURL, preview.fileURL)

        coordinator.send(.setAnchorBefore(id: coordinator.snapshot.margins[0].id, text: "Changed context"))

        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertNotEqual(coordinator.snapshot.previewState, .ready)
        XCTAssertNil(coordinator.snapshot.verifiedPreview)
        XCTAssertNil(coordinator.verifiedShareFileURL)
    }

    /// #3751 audit: a link asked for on review must not open its sheet after the listener went back to the selection
    /// and removed a Margin. Walks the real coordinator through those steps and asks the screen's rule at each.
    func testALinkIsDroppedOnceTheListenerGoesBackOrChangesTheSelection() async throws {
        let coordinator = makeCoordinator()
        coordinator.send(.begin)
        coordinator.send(.setPrivateSharingRightsConfirmed(true))
        coordinator.send(.advanceToReview)
        coordinator.send(.buildRecipientPreview)
        let preview = try await waitForVerifiedPreview(from: coordinator)
        defer { try? FileManager.default.removeItem(at: preview.fileURL) }

        func keepsLink() -> Bool {
            Build23ShareRequestPolicy.keepsLink(stage: coordinator.snapshot.stage, previewState: coordinator.snapshot.previewState)
        }
        XCTAssertTrue(keepsLink(), "the packet is ready on screen: a link for it may open")

        // On the list (#4647) the preview's back returns to the list, and the packet still matches what it shows.
        coordinator.send(.returnToSelect)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertTrue(keepsLink(), "nothing changed: the link is still for the Margins on screen")

        coordinator.send(.setAnchorBefore(id: coordinator.snapshot.margins[0].id, text: "Changed context"))
        XCTAssertNil(coordinator.verifiedShareFileURL)
        XCTAssertFalse(keepsLink(), "the packet the link was made from is gone")
    }

    func testAShareAskedForWhileThePacketBuildsWaitsOnlyForThatBuild() {
        typealias Policy = Build23ShareRequestPolicy
        XCTAssertTrue(Policy.keepsPendingShare(stage: .recipientPreview, previewState: .building))
        XCTAssertTrue(Policy.keepsPendingShare(stage: .recipientPreview, previewState: .ready))
        for state: Build23SharingPreviewState in [.notBuilt, .stale, .failed("no")] {
            XCTAssertFalse(Policy.keepsPendingShare(stage: .review, previewState: state), "\(state)")
        }
        XCTAssertFalse(Policy.keepsPendingShare(stage: .select, previewState: .building))
        XCTAssertFalse(Policy.keepsLink(stage: .recipientPreview, previewState: .building))
    }

    /// #3751 audit: "Making link…" showed on the preview while a file or a plain preview was being made.
    func testMakingLinkShowsOnlyForALink() {
        typealias Policy = Build23ShareRequestPolicy
        XCTAssertFalse(Policy.showsMakingLink(isMakingLink: false, pendingShare: .file))
        XCTAssertFalse(Policy.showsMakingLink(isMakingLink: false, pendingShare: nil))
        XCTAssertTrue(Policy.showsMakingLink(isMakingLink: false, pendingShare: .link))
        XCTAssertTrue(Policy.showsMakingLink(isMakingLink: true, pendingShare: nil))
    }

    func testShareURLIsAbsentAndShareStageIsGatedBeforeVerification() {
        let coordinator = makeCoordinator()
        coordinator.send(.begin)

        XCTAssertNil(coordinator.verifiedShareFileURL)
        coordinator.send(.presentSystemShare)
        XCTAssertEqual(coordinator.snapshot.stage, .review, "the list: no share stage without a verified packet")

        coordinator.send(.setPrivateSharingRightsConfirmed(true))
        XCTAssertNil(coordinator.verifiedShareFileURL)
        XCTAssertFalse(coordinator.snapshot.canShareVerifiedFile)

        coordinator.send(.presentSystemShare)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertNil(coordinator.verifiedShareFileURL)
    }

    func testSelectAndReviewOwnDistinctPresentationSurfaces() {
        XCTAssertFalse(Build23SenderPresentation.stageOwnsDetailedEditor(.select))
        XCTAssertTrue(Build23SenderPresentation.stageOwnsBatchPreparation(.select))
        XCTAssertTrue(Build23SenderPresentation.stageOwnsDetailedEditor(.review))
        XCTAssertFalse(Build23SenderPresentation.stageOwnsBatchPreparation(.review))

        let coordinator = makeCoordinator(marginCount: 2)
        coordinator.send(.begin)
        let selectedMarginID = coordinator.snapshot.margins[0].id
        coordinator.send(.setIncluded(id: selectedMarginID, included: false))

        let reviewEditors = Build23SenderPresentation.reviewExpandedMargins(in: coordinator.snapshot)
        XCTAssertEqual(reviewEditors.count, 1)
        XCTAssertTrue(reviewEditors[0].isIncluded)
        XCTAssertNotEqual(reviewEditors[0].id, selectedMarginID)
    }

    // MARK: The reply sheet (#3792)

    /// The reply sheet opens on its review as a receipt: the answers are included, no editor is open, and the
    /// first-run cleanup question stays away even with no decision recorded.
    func testTheReplySheetOpensOnItsReviewWithNoEditorOpen() {
        let (model, coordinator) = makeModelAndCoordinator(marginCount: 2)
        let offer = ReplyBackOffer(replies: model.selectedItem.interjections, others: [], friendLabels: ["Cole"])
        model.presentReplyBackShare(offer)
        coordinator.send(.begin)

        let snapshot = coordinator.snapshot
        XCTAssertTrue(snapshot.isReplyBack)
        XCTAssertEqual(coordinator.senderHeading, "Share replies with Cole")
        XCTAssertEqual(snapshot.stage, .review, "two taps from the player: Share, then Share link")
        XCTAssertEqual(snapshot.margins.filter(\.isIncluded).count, 2)
        XCTAssertNil(snapshot.selectedMarginID)
        XCTAssertTrue(Build23SenderPresentation.reviewExpandedMargins(in: snapshot).isEmpty, "a receipt: no editor until a row is tapped")
        XCTAssertFalse(snapshot.asksAutoCleanQuestion)
    }

    func testATappedReplyRowOpensItsEditorAndTappingItAgainClosesIt() {
        let (model, coordinator) = makeModelAndCoordinator(marginCount: 2)
        model.presentReplyBackShare(ReplyBackOffer(replies: model.selectedItem.interjections, others: [], friendLabels: ["Cole"]))
        coordinator.send(.begin)
        let first = coordinator.snapshot.margins[0].id

        coordinator.send(.selectMargin(first))
        XCTAssertEqual(Build23SenderPresentation.reviewExpandedMargins(in: coordinator.snapshot).map(\.id), [first])
        coordinator.send(.selectMargin(nil))
        XCTAssertTrue(Build23SenderPresentation.reviewExpandedMargins(in: coordinator.snapshot).isEmpty)
    }

    func testAnOrdinaryShareKeepsItsOpenEditorAndAsksTheCleanupQuestionOnlyWhenAMarginCanBeCleaned() {
        let defaults = UserDefaults.standard
        let priorDecision = defaults.object(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        defer { restoreUserDefault(priorDecision, forKey: ShareAutoCleanPreference.decisionRecordedKey) }
        defaults.removeObject(forKey: ShareAutoCleanPreference.decisionRecordedKey)

        let coordinator = makeCoordinator(marginCount: 1)
        coordinator.send(.begin)
        let snapshot = coordinator.snapshot
        XCTAssertFalse(snapshot.isReplyBack)
        XCTAssertTrue(snapshot.needsAutoCleanDecision)
        XCTAssertFalse(snapshot.margins[0].canPrepareCleanup, "these Margins have no word-level timing")
        XCTAssertFalse(snapshot.asksAutoCleanQuestion, "nothing could be cleaned, so the question has no job")
        XCTAssertEqual(Build23SenderPresentation.reviewExpandedMargins(in: snapshot).count, 1, "an ordinary review opens its first editor")
    }

    func testReferenceTransportNeverRequiresPayloadRightsAssertion() {
        XCTAssertFalse(Build23SenderPresentation.showsLinklessRightsControl(for: .reference))
        XCTAssertFalse(Build23SenderPresentation.requiresPayloadRightsAssertion(for: .reference))
        XCTAssertFalse(Build23SenderPresentation.requiresPayloadRightsAssertion(for: .recipientSupplied))
        XCTAssertTrue(Build23SenderPresentation.requiresPayloadRightsAssertion(for: .embeddedText))
    }

    /// #1185: a voice Margin with no transcript is "included" in the list but can't go in the
    /// packet, so the Review and Share buttons must not count it.
    func testTheShareButtonsCountOnlyMarginsThePacketCanCarry() {
        let coordinator = makeCoordinator(marginCount: 2, marginsWithoutTranscript: [0])
        coordinator.send(.begin)
        let snapshot = coordinator.snapshot

        XCTAssertEqual(snapshot.margins.filter(\.isIncluded).count, 2)
        XCTAssertEqual(snapshot.selectionSummary.packetCount, 1)
        XCTAssertEqual(snapshot.selectionSummary.notice, "1 Margin has no transcript and wasn't included.")
        let leftOut = snapshot.margins.filter(\.isLeftOutForMissingText)
        XCTAssertEqual(leftOut.count, 1)
        XCTAssertEqual(leftOut.first?.reviewedText, "")
    }

    /// #3027: a voice Margin with no words used to be left out. It now goes with placeholder words, marked as
    /// such, which the listener can replace; clearing their words brings the placeholder back.
    func testAVoiceMarginWithoutWordsIsSharedWithReplaceablePlaceholderWords() throws {
        let (model, coordinator) = makeModelAndCoordinator(marginCount: 2, voiceMarginsWithoutWords: [0])
        coordinator.send(.begin)
        let id = "session-build-23-sender::margin-build-23-sender-0"
        let placeholder = SharedMarginPlaceholder.words(
            mediaTimeMs: nil, itemTitle: model.selectedItem.title, recordedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(coordinator.snapshot.selectionSummary.packetCount, 2)
        XCTAssertNil(coordinator.snapshot.selectionSummary.notice)
        var voice = try XCTUnwrap(coordinator.snapshot.margins.first { $0.id == id })
        XCTAssertEqual(voice.reviewedText, placeholder)
        XCTAssertEqual(voice.placeholderText, placeholder)
        XCTAssertTrue(voice.isShowingPlaceholder)
        XCTAssertFalse(voice.isLeftOutForMissingText)
        XCTAssertNil(voice.warning)
        XCTAssertEqual(voice.spokenWordsDescription, "placeholder words: \(placeholder)")

        coordinator.send(.setReviewedWords(id: id, text: "My own words."))
        voice = try XCTUnwrap(coordinator.snapshot.margins.first { $0.id == id })
        XCTAssertEqual(voice.reviewedText, "My own words.")
        XCTAssertFalse(voice.isShowingPlaceholder)

        coordinator.send(.setReviewedWords(id: id, text: ""))
        voice = try XCTUnwrap(coordinator.snapshot.margins.first { $0.id == id })
        XCTAssertEqual(voice.reviewedText, placeholder)
        XCTAssertTrue(voice.isShowingPlaceholder)
    }

    /// #1185 audit: the export screen prepares drafts from the session picked there; opening the
    /// sheet must keep them, so the count on the Share Margins button is the count in the sheet.
    func testBeginKeepsDraftsTheExportScreenAlreadyPrepared() {
        let (model, coordinator) = makeModelAndCoordinator(marginCount: 2)
        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.margins.count, 2)

        model.sharingState.drafts.removeLast()
        model.sharingState.draftsPreparedForExport = true
        model.isSharingInterjectionsPresented = true
        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.margins.count, 1)
        XCTAssertFalse(model.sharingState.draftsPreparedForExport)

        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.margins.count, 2)
    }

    /// #1507, #4647: every entry that isn't a reply opens the one list, where Share is pinned, so the player's Share is
    /// still two taps. A reply sheet still opens on its receipt.
    func testEveryEntryThatIsNotAReplyOpensTheListAndAReplySheetStillOpensOnItsReceipt() {
        let (model, coordinator) = makeModelAndCoordinator(marginCount: 2)
        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.stage, .review, "opened from the Margins tab or Export: the list")
        // What `openMarginItemExport(entry:)` leaves behind: drafts prepared, the sheet up, the entry set after.
        model.sharingState.draftsPreparedForExport = true
        model.isSharingInterjectionsPresented = true
        model.sharingState.entry = .reviewDefaults
        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertEqual(coordinator.snapshot.margins.filter(\.isIncluded).count, 2)
        XCTAssertNil(coordinator.snapshot.selectedMarginID, "no editor is open on the list until one is asked for")
        XCTAssertEqual(model.sharingState.entry, .chooseMargins, "The entry applies once")

        coordinator.send(.returnToSelect)
        XCTAssertEqual(coordinator.snapshot.stage, .review, "there is no Choose stage to go back to")

        model.presentReplyBackShare(ReplyBackOffer(replies: model.selectedItem.interjections, others: [], friendLabels: ["Cole"]))
        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertFalse(coordinator.snapshot.showsList, "the reply sheet keeps its receipt")
        coordinator.send(.returnToSelect)
        XCTAssertEqual(coordinator.snapshot.stage, .select, "the reply sheet keeps Back to selection")
    }

    /// #4647: opened from the player with nothing selected, the list opens anyway with Share disabled.
    func testPlaybackShareWithNothingSelectedOpensTheListWithShareDisabled() {
        let (model, coordinator) = makeModelAndCoordinator(marginCount: 2)
        coordinator.send(.begin)
        for draft in model.sharingState.drafts { model.setShareDraftIncluded(draft.id, included: false) }
        model.sharingState.entry = .reviewDefaults
        model.sharingState.draftsPreparedForExport = true
        model.isSharingInterjectionsPresented = true
        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertFalse(coordinator.snapshot.canAdvance)
    }

    /// #4647: the list is the Choose step for VoiceOver, so coming back from the preview says "Choose Margins" and
    /// opening says nothing; the reply sheet keeps its Review step.
    func testTheListAnnouncesAsChooseMargins() {
        XCTAssertEqual(Build23SenderSharingExperience.step(for: .review, showsList: true), .select)
        XCTAssertEqual(Build23SenderSharingExperience.step(for: .review, showsList: false), .review)
        XCTAssertNil(VoiceOverAnnouncements.sharingStage(from: .select, to: Build23SenderSharingExperience.step(for: .review, showsList: true)))
        XCTAssertEqual(
            VoiceOverAnnouncements.sharingStage(
                from: Build23SenderSharingExperience.step(for: .recipientPreview, showsList: true),
                to: Build23SenderSharingExperience.step(for: .review, showsList: true)),
            "Choose Margins")
    }

    private func makeCoordinator(marginCount: Int = 1, marginsWithoutTranscript: Set<Int> = []) -> Build23SharingCoordinator {
        makeModelAndCoordinator(marginCount: marginCount, marginsWithoutTranscript: marginsWithoutTranscript).coordinator
    }

    private func makeModelAndCoordinator(
        marginCount: Int = 1,
        marginsWithoutTranscript: Set<Int> = [],
        voiceMarginsWithoutWords: Set<Int> = []
    ) -> (model: Gate1AppModel, coordinator: Build23SharingCoordinator) {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        var interjections: [Interjection] = []
        interjections.reserveCapacity(marginCount)

        for index in 0..<marginCount {
            let marginID: String = "margin-build-23-sender-\(index)"
            let sessionID: String = "session-build-23-sender"
            let createdAt = Date(timeIntervalSince1970: TimeInterval(index + 1))
            let roughPercent: Int = (index + 1) * 20
            let startCharacter = index * 5
            let endCharacter = startCharacter + 5
            let anchor = Anchor(
                anchorType: .text,
                startChar: startCharacter,
                endChar: endCharacter,
                anchorBefore: "Before \(index)",
                anchorAfter: "After \(index)"
            )
            let isWordlessVoice = voiceMarginsWithoutWords.contains(index)
            let transcript: String = marginsWithoutTranscript.contains(index) || isWordlessVoice ? "" : "Reviewed Margin \(index)."
            var audioPath: String?
            if isWordlessVoice {
                let audio = FileManager.default.temporaryDirectory.appending(path: "build23-voice-\(UUID().uuidString).m4a")
                FileManager.default.createFile(atPath: audio.path, contents: Data([0, 0, 0, 0x18]))
                addTeardownBlock { try? FileManager.default.removeItem(at: audio) }
                audioPath = audio.path
            }
            let interjection = Interjection(
                id: marginID,
                itemId: itemID,
                sessionId: sessionID,
                targetType: .item,
                targetId: itemID,
                createdAt: createdAt,
                roughPercent: roughPercent,
                anchor: anchor,
                audioPath: audioPath,
                audioStatus: isWordlessVoice ? "saved" : "none",
                transcriptionStatus: isWordlessVoice ? "failed" : "transcribed",
                transcript: transcript,
                cleanedTranscript: nil,
                displayText: nil,
                status: "active"
            )
            interjections.append(interjection)
        }
        model.selectedItem.interjections = interjections
        return (model, Build23SharingCoordinator(model: model))
    }

    private func waitForVerifiedPreview(
        from coordinator: Build23SharingCoordinator
    ) async throws -> Build23VerifiedRecipientPreview {
        try await waitForSharingPreview(coordinator)
        return try XCTUnwrap(coordinator.snapshot.verifiedPreview)
    }

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// #3839: the step above "Share link" is limited to two lines from the first accessibility size, with a "More" button for
/// the rest, so the pinned bar never covers more than half the screen. This renders the step line, the part of the bar
/// that grows with its text, at the largest size and holds it to a third of the shortest iPhone screen, leaving the
/// other sixth of the half for the link status lines (#4134, which sets their own two-line limit) and the buttons.
/// The bound was set from the type sizes, not yet from a run on a device: if it fails, measure before moving it.
@MainActor
final class Build23PinnedStepLineTests: XCTestCase {
    private static let short = "Finding the exact moment for your new Margin. Keep the episode playing a few more seconds."
    private static let longest = "Play the episode for about 12 seconds so your friend hears 2 of these Margins at the exact moment. Sharing now may put them a few seconds off."
    private static let screenHeight: CGFloat = 667 // the shortest screen iOS 26 runs on (iPhone SE)

    private func height(_ text: String, _ size: DynamicTypeSize) -> CGFloat {
        let line = Build23PinnedStepLine(step: ShareReviewSteps.Step(icon: .clock, text: text))
        return UIHostingController(rootView: AnyView(line.environment(\.dynamicTypeSize, size)))
            .sizeThatFits(in: CGSize(width: 343, height: 10_000)).height
    }

    func testTheLongestStepAtTheLargestSizeStaysWithinAThirdOfTheScreen() {
        let atFive = height(Self.longest, .accessibility5)
        XCTAssertLessThanOrEqual(atFive, Self.screenHeight / 3, "the step line is \(atFive) pt high at AX5")
    }

    func testFromTheFirstAccessibilitySizeTheHeightDoesNotGrowWithTheText() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let long = height(Self.longest, size)
            let twiceAsLong = height(Self.longest + " " + Self.longest, size)
            let oneLine = height("Play.", size)
            XCTAssertEqual(long, twiceAsLong, accuracy: 2, "\(size): a longer step made the bar taller")
            XCTAssertGreaterThan(long, oneLine + 2, "\(size): the step shows its two lines, not one")
        }
    }

    func testAtOrdinarySizesTheWholeStepShowsAndGrowsWithItsText() {
        let short = height(Self.short, .large)
        let long = height(Self.longest + " " + Self.longest, .large)
        XCTAssertGreaterThan(long, short, "at ordinary sizes the whole step shows")
    }
}
