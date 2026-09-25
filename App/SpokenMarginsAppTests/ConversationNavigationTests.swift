import XCTest
import AVFoundation
import ShazamKit
import MediaPlayer
import PDFKit
import UIKit
import SessionKit
import SessionKitAudio
import SessionKitSharing
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class ConversationNavigationTests: XCTestCase {
    func testForegroundKeepsLiveCaptureWhileColdStartReclassifiesIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveSession(Session(
            id: "session", itemId: "podcast", status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "podcast",
            position: Position(mediaTimeMs: 20_000), completionPercent: 20, playbackRate: 1
        ))
        let margin = Interjection(
            id: "ij-live", itemId: "podcast", sessionId: "session", targetType: .item,
            targetId: "podcast", createdAt: Date(), roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000),
            audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "pending",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active",
            podcastAnchorCaptureWindows: [
                .init(role: .preInterjection, state: .unavailable, attempt: 1, anchorMediaTimeMs: 20_000),
                .init(role: .postResume, state: .collecting, attempt: 1, anchorMediaTimeMs: 20_000)
            ]
        )
        try store.saveInterjection(margin)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        try model.reconcilePodcastAnchorEvidence(store: store, interruptedJobs: false)
        try model.reconcilePodcastAnchorEvidence(store: store, interruptedJobs: false)
        var restored = try XCTUnwrap(store.loadInterjections(sessionId: "session").first)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.last?.state, .collecting)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.last?.attempt, 1)
        try model.reconcilePodcastAnchorEvidence(store: store, interruptedJobs: true)
        restored = try XCTUnwrap(store.loadInterjections(sessionId: "session").first)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.last?.state, .retryableFailure)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.last?.attempt, 1)
    }

    func testExactLocalRecoveryRequiresOriginalProducingEdition() {
        XCTAssertFalse(Gate1AppModel.canRecoverOriginalPodcastEdition(
            storedProducingDigest: nil, candidateDigest: "downloaded-later"
        ))
        XCTAssertFalse(Gate1AppModel.canRecoverOriginalPodcastEdition(
            storedProducingDigest: "heard-edition", candidateDigest: "new-ad-edition"
        ))
        XCTAssertTrue(Gate1AppModel.canRecoverOriginalPodcastEdition(
            storedProducingDigest: "heard-edition", candidateDigest: "heard-edition"
        ))
    }

    func testPodcastRestartReconciliationPreservesValidSiblingAndInvalidatesMissingSignature() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "library.sqlite").path)
        let session = Session(
            id: "session", itemId: "podcast", status: "finished", phase: .finished,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "podcast",
            position: Position(mediaTimeMs: 20_000), completionPercent: 20, playbackRate: 1
        )
        try store.saveSession(session)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000))
        buffer.frameLength = 64_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<64_000 { samples[frame] = Float(0.2 * sin(2 * .pi * 220 * Double(frame) / 8_000)) }
        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        let data = generator.signature().dataRepresentation
        XCTAssertFalse(data.isEmpty)
        let validURL = root.appending(path: "pre.shazamsignature")
        try data.write(to: validURL)
        let missingURL = root.appending(path: "post.shazamsignature")
        let margin = Interjection(
            id: "ij-1", itemId: "podcast", sessionId: session.id,
            targetType: .item, targetId: "podcast", createdAt: Date(), roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000),
            audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "failed",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active",
            podcastAnchorEvidence: [
                .init(id: "pre", localPath: validURL.path, durationMs: 8_000,
                      anchorOffsetMs: 8_000, provenance: .observedDecodedPlayback, windowRole: .preInterjection),
                .init(id: "post", localPath: missingURL.path, durationMs: 8_000,
                      anchorOffsetMs: 0, provenance: .observedDecodedPlayback, windowRole: .postResume)
            ],
            sourceExactEditionSHA256: "known-edition",
            podcastAnchorCaptureWindows: [
                .init(role: .preInterjection, state: .committed, attempt: 1, anchorMediaTimeMs: 20_000),
                .init(role: .postResume, state: .committed, attempt: 1, anchorMediaTimeMs: 20_000)
            ]
        )
        try store.saveInterjection(margin)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        try model.reconcilePodcastAnchorEvidence(store: store, interruptedJobs: true)
        let restored = try XCTUnwrap(store.loadInterjections(sessionId: session.id).first)
        XCTAssertEqual(restored.podcastAnchorEvidence?.map(\.id), ["pre"])
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.first?.state, .committed)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.last?.state, .retryableFailure)
        XCTAssertEqual(restored.podcastAnchorEvidenceCaptureStatus, .pendingPostResumeSample)
        XCTAssertEqual(restored.sourceExactEditionSHA256, "known-edition")
        XCTAssertEqual(restored.transcriptionStatus, "failed", "ASR failure must not discard acoustic evidence")
    }

    func testPodcastEvidenceOmissionConsentTracksReviewedSelectionAndAssetState() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let evidenceURL = root.appending(path: "pre.shazamsignature")
        var margin = Interjection(
            id: "ij-001", itemId: "podcast", sessionId: "session-one",
            targetType: .item, targetId: "podcast", createdAt: Date(), roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000),
            audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "transcribed",
            transcript: "Review me", cleanedTranscript: nil, displayText: nil, status: "active",
            podcastAnchorEvidence: [.init(
                id: "pre", localPath: evidenceURL.path, durationMs: 12_000,
                anchorOffsetMs: 12_000, provenance: .observedDecodedPlayback,
                windowRole: .preInterjection
            )],
            podcastAnchorCaptureWindows: [
                .init(role: .preInterjection, state: .committed, attempt: 1, anchorMediaTimeMs: 20_000),
                .init(role: .postResume, state: .unavailable, attempt: 1, anchorMediaTimeMs: 20_000)
            ]
        )
        var draft = ShareInterjectionDraft(
            interjection: margin, approvedTranscript: "Review me",
            representationChoice: .original, anchorBefore: "", anchorAfter: ""
        )
        let missing = Gate1AppModel.podcastEvidenceExportDisposition([draft])
        let key = Gate1AppModel.podcastEvidenceAssetKey(
            try XCTUnwrap(margin.podcastAnchorEvidence?.first), sessionId: margin.sessionId, interjectionId: margin.id
        )
        XCTAssertTrue(missing.isDegraded)
        XCTAssertEqual(missing.omittedAssetKeys, [key])
        try Data("sample".utf8).write(to: evidenceURL)
        let present = Gate1AppModel.podcastEvidenceExportDisposition([draft])
        XCTAssertTrue(present.omittedAssetKeys.isEmpty)
        XCTAssertNotEqual(missing.fingerprint, present.fingerprint)
        let partial = Gate1AppModel.podcastEvidenceOutcome(
            for: margin, includedEvidence: try XCTUnwrap(margin.podcastAnchorEvidence),
            omittedAssetKeys: [], optedOut: false
        )
        XCTAssertEqual(partial.disposition, .partial)
        XCTAssertEqual(partial.reasonCategory, "capture_unavailable")
        XCTAssertEqual(partial.includedRoles, [.preInterjection])
        let optOut = Gate1AppModel.podcastEvidenceOutcome(
            for: margin, includedEvidence: [], omittedAssetKeys: [], optedOut: true
        )
        XCTAssertEqual(optOut.disposition, .intentionalOptOut)
        XCTAssertEqual(optOut.reasonCategory, "user_opt_out")
        draft.approvedTranscript = "Different reviewed text"
        XCTAssertNotEqual(present.fingerprint, Gate1AppModel.podcastEvidenceExportDisposition([draft]).fingerprint)
        margin.sessionId = "session-two"
        draft.interjection = margin
        XCTAssertNotEqual(present.fingerprint, Gate1AppModel.podcastEvidenceExportDisposition([draft]).fingerprint)
    }

    func testExportRejectsPersistedEvidenceChangeAfterDegradedReview() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: db.path)
        let item = Item(id: "changing-podcast", title: "Changing podcast", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 120_000))
        try store.saveItem(item)
        model.openItem(id: item.id)
        var margin = Interjection(
            id: "changing-margin", itemId: item.id, sessionId: "sharing-session",
            targetType: .item, targetId: item.id, createdAt: Date(), roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
            transcript: "Reviewed words", cleanedTranscript: nil, displayText: nil, status: "active",
            podcastAnchorCaptureWindows: [
                .init(role: .preInterjection, state: .unavailable, attempt: 1, anchorMediaTimeMs: 20_000),
                .init(role: .postResume, state: .unavailable, attempt: 1, anchorMediaTimeMs: 20_000)
            ]
        )
        try store.saveInterjection(margin)
        model.sharingState.drafts = [ShareInterjectionDraft(
            interjection: margin, approvedTranscript: "Reviewed words", representationChoice: .original,
            anchorBefore: "", anchorAfter: ""
        )]
        XCTAssertTrue(model.authorizeDegradedPodcastEvidenceForCurrentSelection())
        let consent = model.sharingState.degradedPodcastEvidenceConsentFingerprint
        let evidenceURL = root.appending(path: "new-evidence.shazamsignature")
        try Data("new persisted evidence".utf8).write(to: evidenceURL)
        margin.podcastAnchorEvidence = [.init(
            id: "new-pre", localPath: evidenceURL.path, durationMs: 10_000,
            anchorOffsetMs: 10_000, provenance: .observedDecodedPlayback,
            windowRole: .preInterjection
        )]
        try store.saveInterjection(margin)
        XCTAssertEqual(model.sharingState.drafts.first?.interjection.podcastAnchorEvidence?.count, nil,
                       "The reviewed draft must remain stale for this regression")
        model.exportSharedInterjections(presentsReadySheet: false)
        XCTAssertNotEqual(consent, Gate1AppModel.podcastEvidenceExportDisposition([
            ShareInterjectionDraft(interjection: margin, approvedTranscript: "Reviewed words",
                                  representationChoice: .original, anchorBefore: "", anchorAfter: "")
        ]).fingerprint)
        XCTAssertTrue(model.sharingState.errorMessage?.contains("podcast_positioning_evidence_pending") == true)
        XCTAssertNil(model.sharedSpokenMarginsPackageURL)
    }

    func testRecursiveWrittenRepliesKeepCaptureCoordinatesAndPlayExactParentChain() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.ttsVoiceSelection = .system
        model.resetAndSeed(); model.startItem(id: "item-pill")
        model.seekText(toCharOffset: 80)
        model.beginWrittenMargin(); model.saveWrittenMargin(text: "Original")
        let a = try XCTUnwrap(model.selectedItem.interjections.first)
        let aSnapshot = try model.ensureConversationSnapshot(a)
        model.seekText(toCharOffset: 170)
        model.beginReply(to: a, written: true)
        XCTAssertEqual(model.replyCaptureParent?.id, aSnapshot.id)
        model.saveWrittenMargin(text: "Reply")
        let b = try XCTUnwrap(model.selectedItem.interjections.first { $0.transcript == "Reply" })
        XCTAssertEqual(b.anchor.startChar, 170, "The reply link must not rewrite capture coordinates")
        XCTAssertEqual(b.conversation?.parent, aSnapshot.conversation.reference)
        let bSnapshot = try model.ensureConversationSnapshot(b)
        model.beginReply(to: b, written: true); model.saveWrittenMargin(text: "Reply to reply")
        let c = try XCTUnwrap(model.selectedItem.interjections.first { $0.transcript == "Reply to reply" })
        XCTAssertEqual(c.conversation?.parent, bSnapshot.conversation.reference)
        model.conversationContextSeconds = 0
        model.playConversationMargin(c, withContext: true)
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "Original")
        XCTAssertEqual(model.conversationThreadQueue.map(\.transcript), ["Reply", "Reply to reply"])
        model.skimForward()
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "Reply")
        model.skimForward()
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "Reply to reply")
        XCTAssertTrue(model.conversationThreadQueue.isEmpty)
        model.returnFromConversation()
        XCTAssertEqual(model.snapshot.currentTextStart, 170)
        model.beginReply(to: a, written: true); model.cancelWrittenMargin()
        XCTAssertNil(model.replyCaptureParent)
    }

    func testTwoTargetWrittenReplyKeepsCaptureAnchorAndPlaysSharedAncestorOnce() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.ttsVoiceSelection = .system
        model.resetAndSeed(); model.startItem(id: "item-pill")
        model.seekText(toCharOffset: 80)
        model.beginWrittenMargin(); model.saveWrittenMargin(text: "Cole")
        let cole = try XCTUnwrap(model.selectedItem.interjections.first { $0.transcript == "Cole" })
        model.beginReply(to: cole, written: true); model.saveWrittenMargin(text: "Alex")
        let alex = try XCTUnwrap(model.selectedItem.interjections.first { $0.transcript == "Alex" })
        model.beginReply(to: cole, written: true); model.saveWrittenMargin(text: "Blair")
        let blair = try XCTUnwrap(model.selectedItem.interjections.first { $0.transcript == "Blair" })
        let alexNode = try model.ensureConversationSnapshot(alex)
        let blairNode = try model.ensureConversationSnapshot(blair)
        model.seekText(toCharOffset: 170)
        try model.beginReply(to: [alexNode, blairNode], written: true)
        XCTAssertEqual(model.replyCaptureParents.map(\.id), [alexNode.id, blairNode.id])
        model.saveWrittenMargin(text: "Casey")
        let casey = try XCTUnwrap(model.selectedItem.interjections.first { $0.transcript == "Casey" })
        XCTAssertEqual(casey.anchor.startChar, 170)
        XCTAssertEqual(casey.conversation?.parents, [alexNode.conversation.reference, blairNode.conversation.reference])
        model.conversationContextSeconds = 0
        model.playConversationMargin(casey, withContext: true)
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "Cole")
        XCTAssertEqual(model.conversationThreadQueue.map(\.transcript), ["Alex", "Blair", "Casey"])
        model.returnFromConversation()
        XCTAssertEqual(model.snapshot.currentTextStart, 170)
        model.prepareShareInterjections()
        for draft in model.sharingState.drafts { model.setShareDraftIncluded(draft.id, included: draft.id == casey.id) }
        let coleNode = try model.ensureConversationSnapshot(cole)
        XCTAssertEqual(Set(model.forwardedReplyContext.map(\.id)), Set([alexNode.id, blairNode.id, coleNode.id]))
    }

    func testContextEditsPreserveAnchorRejectCyclesAndKeepPreviousRevision() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.ttsVoiceSelection = .system
        model.resetAndSeed(); model.startItem(id: "item-pill"); model.seekText(toCharOffset: 100)
        model.beginWrittenMargin(); model.saveWrittenMargin(text: "Root")
        let note = try XCTUnwrap(model.selectedItem.interjections.first)
        let original = try model.ensureConversationSnapshot(note)
        let quote = String(model.selectedItem.text.prefix(30))
        XCTAssertTrue(model.saveConversationContext(note: note, parent: nil,
            context: .init(kind: .sourceText, start: 0, end: 30, quote: quote)))
        let updated = model.conversationUpdatedNote(note)
        XCTAssertEqual(updated.anchor, note.anchor)
        XCTAssertNotEqual(updated.conversation?.reference, original.conversation.reference)
        XCTAssertEqual(model.conversationSnapshots.first { $0.id == original.id }, original)
        XCTAssertFalse(model.saveConversationContext(note: updated, parent: nil,
            context: .init(kind: .sourceText, start: 0, end: 30, quote: "Wrong passage")))
        model.beginReply(to: updated, written: true); model.saveWrittenMargin(text: "Child")
        let child = try XCTUnwrap(model.selectedItem.interjections.first { $0.transcript == "Child" })
        let childNode = try model.ensureConversationSnapshot(child)
        XCTAssertFalse(model.saveConversationContext(note: updated, parent: childNode.conversation.reference, context: nil))
        model.seekText(toCharOffset: 0)
        model.conversationContextSeconds = 0
        model.playConversationMargin(updated, withContext: true)
        XCTAssertEqual(model.conversationLeadIn?.contextEnd, 30, "An explicit selection applies even when the default context is off")
        model.skimForward()
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "Root")
    }

    func testReplyExportRequiresExplicitParentForwardingAndKeepsRevisionStable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.ttsVoiceSelection = .system
        model.resetAndSeed(); model.startItem(id: "item-pill"); model.seekText(toCharOffset: 100)
        model.beginWrittenMargin(); model.saveWrittenMargin(text: "Private parent")
        let parent = try XCTUnwrap(model.selectedItem.interjections.first)
        model.beginReply(to: parent, written: true); model.saveWrittenMargin(text: "Reviewed reply")
        let reply = try XCTUnwrap(model.selectedItem.interjections.first { $0.transcript == "Reviewed reply" })
        XCTAssertTrue(model.conversationSnapshots.contains { $0.conversation.reference == reply.conversation?.reference })
        model.prepareShareInterjections()
        for draft in model.sharingState.drafts { model.setShareDraftIncluded(draft.id, included: draft.id == reply.id) }
        model.exportSharedInterjections(presentsReadySheet: false)
        XCTAssertNil(model.sharingState.errorMessage)
        let firstURL = try XCTUnwrap(model.sharedSpokenMarginsPackageURL)
        let first = try SpokenMarginsPackageArchive.read(from: firstURL, extractingAssetsTo: root.appending(path: "first"))
        let sent = try XCTUnwrap(first.commentaryLayers.first?.interjections.first)
        XCTAssertEqual(first.commentaryLayers.first?.interjections.count, 1)
        XCTAssertNotNil(sent.conversation?.parent)
        model.sharingState.includesReplyContext = true
        model.exportSharedInterjections(presentsReadySheet: false)
        XCTAssertNil(model.sharingState.errorMessage)
        let secondURL = try XCTUnwrap(model.sharedSpokenMarginsPackageURL)
        defer { try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: secondURL) }
        let second = try SpokenMarginsPackageArchive.read(from: secondURL, extractingAssetsTo: root.appending(path: "second"))
        XCTAssertEqual(second.commentaryLayers.first?.interjections.count, 2)
        XCTAssertTrue(second.commentaryLayers.first?.interjections.contains { $0.conversation?.reference == sent.conversation?.reference } == true)
        XCTAssertTrue(second.commentaryLayers.first?.interjections.contains { $0.conversation?.reference == sent.conversation?.parent } == true)
    }

    func testNewSessionKeepsEarlierMarginsInTimelineAndSkimWithoutChangingTheirSession() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.ttsVoiceSelection = .system
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.seekText(toCharOffset: 80)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "An earlier observation")
        let originalSession = try XCTUnwrap(model.snapshot.sessionId)
        let note = try XCTUnwrap(model.selectedItem.interjections.first)
        model.startNewSession(id: "item-pill")
        let newSession = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(newSession, originalSession)
        XCTAssertTrue(model.selectedItem.interjections.isEmpty)
        XCTAssertEqual(model.selectedItem.itemInterjections.first?.sessionId, originalSession)
        let entries = ExperienceTimelineRailScreen.makeEntries(from: model.selectedItem, sessionID: newSession)
        XCTAssertTrue(entries.contains { if case .margin(let row) = $0.action { return row.interjection.id == note.id }; return false })
        model.conversationScope = .margins
        model.conversationContextSeconds = 120
        XCTAssertTrue(model.snapshot.canSkimForward)
        model.skimForward()
        XCTAssertNil(model.conversationLeadIn)
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "An earlier observation")
        XCTAssertEqual(model.snapshot.sessionId, newSession, "Listening to an old Margin must not reopen or rewrite its session")
        XCTAssertEqual(model.selectedItem.itemInterjections.first?.sessionId, originalSession)
        model.returnFromConversation()
        XCTAssertNil(model.conversationCurrentMargin)
        XCTAssertEqual(model.snapshot.currentTextStart, 0)
    }

    func testSecondSkimTapAdvancesDirectlyToNextMargin() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.ttsVoiceSelection = .system
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.seekText(toCharOffset: 100)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "First")
        model.seekText(toCharOffset: 180)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "Second")
        model.seekText(toCharOffset: 0)
        model.conversationScope = .margins
        model.skimForward()
        let target = try XCTUnwrap(model.conversationCurrentMargin)
        XCTAssertEqual(target.transcript, "First")
        XCTAssertNil(model.conversationLeadIn)
        model.skimForward()
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "Second")
        XCTAssertNotEqual(model.conversationCurrentMargin?.id, target.id)
    }

    func testManualSeekCancelsPinnedContextAndUnresolvedSharedPositionsAreNotSkimTargets() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.ttsVoiceSelection = .system
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.seekText(toCharOffset: 90)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "Pinned")
        model.seekText(toCharOffset: 0)
        model.conversationScope = .margins
        model.skimForward()
        XCTAssertNotNil(model.conversationCurrentMargin)
        model.seekText(toCharOffset: 40)
        XCTAssertNil(model.conversationLeadIn)
        XCTAssertNil(model.conversationCurrentMargin)
        let layer = ImportedCommentaryLayer(id: "unresolved", itemId: "item-pill", packageDigest: "digest", packageId: "package", itemIdentity: SharedItemIdentity(itemType: .pdf, title: "PDF"), importedAt: Date(), sourceResolutionStatus: .ambiguous, isEnabled: true)
        let note = ImportedCommentaryInterjection(id: "unresolved", layerId: layer.id, packageScopedId: "note", createdAt: Date(), anchorEvidence: PortableAnchorEvidence(anchorType: .text, roughPercent: 50), approvedTranscript: "Uncertain", resolution: ImportedAnchorResolution(evidenceClass: .ambiguous, localStartChar: 100, isAmbiguous: true))
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: [note]]
        XCTAssertFalse(model.conversationDestinations.contains { $0.id.hasPrefix("shared:") })
    }

    func testSamePositionContributionsAreStableAndNeitherIsSkipped() throws {
        let a = ConversationDestination(id: "a", position: 100, title: "A", content: .chapter)
        let b = ConversationDestination(id: "b", position: 100, title: "B", content: .chapter)
        let c = ConversationDestination(id: "c", position: 200, title: "C", content: .chapter)
        XCTAssertEqual(ConversationNavigation.next(in: [c, b, a], position: 0, currentID: nil, backward: false)?.id, "a")
        XCTAssertEqual(ConversationNavigation.next(in: [c, b, a], position: 100, currentID: "a", backward: false)?.id, "b")
        XCTAssertEqual(ConversationNavigation.next(in: [c, b, a], position: 100, currentID: "b", backward: false)?.id, "c")
        XCTAssertEqual(ConversationNavigation.next(in: [c, b, a], position: 200, currentID: "c", backward: true)?.id, "b")
    }

    func testPodcastAssetTargetUsesVerifiedRecipientPositionsAndNaturallyArrives() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.ttsVoiceSelection = .system
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: database.path)
        let item = Item(id: "podcast", title: "Conversation episode", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/audio.mp3", durationMs: 900_000))
        try store.saveItem(item)
        let layer = ImportedCommentaryLayer(id: "friends", itemId: item.id, packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: item.title), importedAt: Date(), sourceResolutionStatus: .resolved, isEnabled: true)
        let note = ImportedCommentaryInterjection(id: "response", layerId: layer.id, packageScopedId: "response", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 250_000), approvedTranscript: "The recipient edition is different.",
            resolution: ImportedAnchorResolution(evidenceClass: .transcriptVerified, localMediaTimeMs: 300_000, confidence: 1))
        try store.saveImportedCommentaryLayer(layer)
        try store.saveImportedCommentaryInterjection(note)
        model.startItem(id: item.id)
        XCTAssertNotEqual(model.snapshot.targetId, item.id, "The engine uses the media URL as target")
        XCTAssertEqual(model.selectedItem.id, item.id)
        model.conversationScope = .margins
        model.playConversationMargin(SharedMarginRow(interjection: note, layer: layer, itemTitle: item.title), withContext: true)
        XCTAssertEqual(model.conversationLeadIn?.destination.position, 300_000)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 180_000)
        XCTAssertEqual(model.skimForwardDestinationMs, 300_000)
        var reached = model.snapshot
        reached.currentMediaTimeMs = 300_100
        XCTAssertTrue(model.reconcileConversationLeadIn(current: reached))
        XCTAssertNil(model.conversationLeadIn)
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, note.approvedTranscript)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 300_000, "Context arrival must bookmark the Margin before its voice")
        XCTAssertNil(model.pendingImportedCommentary, "Explicit arrival must not also prompt")
        model.conversationScope = .newMargins
        XCTAssertTrue(model.conversationDestinations.isEmpty, "Displayed text is no longer new")
        model.returnFromConversation()
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 0)
        model.conversationScope = .margins
        model.setImportedCommentaryLayerMuted(layer.id, muted: true)
        XCTAssertFalse(model.snapshot.canSkimForward)
        XCTAssertTrue(model.conversationDestinations.isEmpty)

        model.setImportedCommentaryLayerMuted(layer.id, muted: false)
        model.playConversationMargin(SharedMarginRow(interjection: note, layer: layer, itemTitle: item.title), withContext: true)
        XCTAssertNotNil(model.conversationLeadIn)
        let stalled = model.snapshot
        XCTAssertTrue(model.reconcileConversationLeadIn(current: stalled, now: ProcessInfo.processInfo.systemUptime + 9))
        XCTAssertNil(model.conversationLeadIn, "A non-advancing source must not hold the Margin indefinitely")
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, note.approvedTranscript)
    }

    func testFinishingOneMarginResumesAtItsPositionAndSkimsToTheNext() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.ttsVoiceSelection = .system
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.seekText(toCharOffset: 100)
        model.beginWrittenMargin(); model.saveWrittenMargin(text: "First")
        model.seekText(toCharOffset: 180)
        model.beginWrittenMargin(); model.saveWrittenMargin(text: "Second")
        model.seekText(toCharOffset: 0)
        model.conversationScope = .margins
        model.conversationContextSeconds = 0
        model.skimForward()
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "First")

        model.resumeSourceFromConversation()
        XCTAssertNil(model.conversationCurrentMargin)
        XCTAssertEqual(model.snapshot.currentTextStart, 100, "Returning to source after a Margin must not rewind to the pre-Skim origin")
        XCTAssertTrue(model.snapshot.canSkimForward)
        model.skimForward()
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "Second", "The completed Margin must not be offered again")
    }

    func testExplicitSkimPlaysSharedVoiceEvenWhenPassiveAutoPlayIsOff() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appending(path: "shared-voice.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file.write(from: buffer)
        let database = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: database.path)
        let item = Item(id: "shared-episode", title: "Shared episode", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 900_000))
        try store.saveItem(item)
        let layer = ImportedCommentaryLayer(id: "friends", itemId: item.id, packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: item.title), displayLabel: "Shanti",
            importedAt: Date(), sourceResolutionStatus: .resolved, isEnabled: true, revealMode: .companion)
        try store.saveImportedCommentaryLayer(layer)
        for (id, position) in [("first", 300_000), ("second", 400_000)] {
            try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
                id: id, layerId: layer.id, packageScopedId: id, createdAt: Date(),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: position),
                approvedTranscript: id, audioPath: audioURL.path,
                resolution: ImportedAnchorResolution(evidenceClass: .transcriptVerified, localMediaTimeMs: position, confidence: 1)
            ))
        }
        model.startItem(id: item.id)
        model.conversationScope = .margins
        model.conversationContextSeconds = 0
        XCTAssertFalse(model.importedCommentaryAutoPlayEnabled)
        model.skimForward()
        XCTAssertEqual(model.playingImportedCommentary?.interjection.id, "first")
        XCTAssertNil(model.pendingImportedCommentary, "An explicit Skim tap requests playback")
        XCTAssertNil(model.conversationLeadIn)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 300_000, "Verified Skim must move the podcast bookmark")
        XCTAssertTrue(model.isRespondingToMargin)
        model.skimForward()
        XCTAssertEqual(model.playingImportedCommentary?.interjection.id, "second")
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 400_000)
    }

    func testExplicitPodcastSkimStartsLocalRecordingAtItsSourcePositionWithoutLeadIn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "library.sqlite")
        let audioURL = root.appending(path: "own-margin.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file.write(from: buffer)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: database.path)
        let item = Item(id: "local-episode", title: "Local episode", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 900_000))
        try store.saveItem(item)
        model.startItem(id: item.id)
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        let note = Interjection(id: "own-voice", itemId: item.id, sessionId: sessionID, targetType: .item,
            targetId: item.id, createdAt: Date(), roughPercent: 33,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 300_000),
            audioPath: audioURL.path, audioStatus: "recorded", transcriptionStatus: "transcribed",
            transcript: "My own recording", cleanedTranscript: nil, displayText: nil, status: "active")
        try store.saveInterjection(note)
        model.openItem(id: item.id)
        model.conversationScope = .newMargins
        XCTAssertTrue(model.conversationDestinations.isEmpty, "A capture made on this installation is already familiar")
        model.conversationScope = .margins
        model.conversationContextSeconds = 120
        model.skimForward()
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "My own recording")
        XCTAssertEqual(model.playingInterjectionAudioId, note.id)
        XCTAssertNil(model.conversationLeadIn)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 300_000, "Explicit Skim must bookmark the verified source position before voice starts")
        model.skipCurrentMarginToEnd()
        XCTAssertNil(model.conversationCurrentMargin)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 300_000, "Skipping voice must leave the podcast at the Margin")
        XCTAssertFalse(model.heardConversationMargins.contains("local:\(sessionID):own-voice"), "Skipping voice is not a listening completion")
    }

    func testUnmatchedImportsRemainReachableWithoutSeekingTheSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appending(path: "unmatched-voice.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file.write(from: buffer)
        let database = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: database.path)
        let item = Item(id: "unmatched-episode", title: "Unmatched episode", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/unmatched", status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/unmatched.mp3", durationMs: 900_000))
        try store.saveItem(item)
        let layer = ImportedCommentaryLayer(id: "friends", itemId: item.id, packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: item.title), displayLabel: "Cole",
            importedAt: Date(), sourceResolutionStatus: .contextOnly, isEnabled: true, revealMode: .companion)
        try store.saveImportedCommentaryLayer(layer)
        for (id, percent) in [("later", 57), ("earlier", 42)] {
            try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
                id: id, layerId: layer.id, packageScopedId: id, createdAt: Date(),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, roughPercent: percent),
                approvedTranscript: id, audioPath: audioURL.path,
                resolution: ImportedAnchorResolution(evidenceClass: .unresolved)
            ))
        }
        model.startItem(id: item.id)
        model.conversationScope = .margins
        XCTAssertTrue(model.snapshot.canSkimForward)
        XCTAssertEqual(model.skimForwardTitle, "Listen next unmatched · Cole")
        XCTAssertTrue(model.conversationDestinations.isEmpty)
        let sourcePosition = model.snapshot.currentMediaTimeMs
        model.skimForward()
        XCTAssertEqual(model.playingImportedCommentary?.interjection.id, "earlier")
        XCTAssertNil(model.pendingImportedCommentary)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, sourcePosition)
        XCTAssertTrue(model.snapshot.canSkimForward)
        model.skimForward()
        XCTAssertEqual(model.playingImportedCommentary?.interjection.id, "later")
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, sourcePosition)
    }

    func testLocalVoiceMarginOwnsPauseResumeAndManualSeekStopsRecordingPlayback() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "library.sqlite")
        let audioURL = root.appending(path: "margin.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000))
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file.write(from: buffer)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.ttsVoiceSelection = .system
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        let note = Interjection(id: "recorded-note", itemId: "item-pill", sessionId: sessionID, targetType: .item, targetId: "item-pill",
            createdAt: Date(), roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 10, anchorBefore: "", anchorAfter: ""),
            audioPath: audioURL.path, audioStatus: "recorded", transcriptionStatus: "transcribed", transcript: "My earlier recording", cleanedTranscript: nil, displayText: nil, status: "active")
        let store = try SQLiteSessionStore(path: database.path)
        try store.saveInterjection(note)
        model.openItem(id: "item-pill")
        model.playConversationMargin(note, withContext: false)
        XCTAssertTrue(model.isPlayingInterjectionAudio(note))
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "My Margin")
        XCTAssertFalse(model.heardConversationMargins.contains("local:\(sessionID):recorded-note"), "Starting audio is not completing it")
        model.pause()
        XCTAssertFalse(model.activePlaybackIsPlaying)
        XCTAssertEqual(model.snapshot.status, .paused)
        model.resumePlayback()
        XCTAssertTrue(model.activePlaybackIsPlaying)
        XCTAssertEqual(model.snapshot.status, .paused, "Resume must not restart the source under the Margin")
        model.seekText(toCharOffset: 40)
        XCTAssertFalse(model.isPlayingInterjectionAudio(note))
        XCTAssertNil(model.conversationCurrentMargin)
        XCTAssertEqual(model.snapshot.currentTextStart, 40)
        XCTAssertNotEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "My Margin")
    }

    func testTextContextStartsAtBoundaryAndHonorsNoContext() {
        let text = String(repeating: "A complete sentence with several words.\n", count: 100)
        let end = text.count - 10
        let start = ConversationNavigation.contextStart(text: text, destination: end, seconds: 30)
        XCTAssertGreaterThan(start, 0)
        XCTAssertLessThan(start, end)
        XCTAssertTrue(String(text.dropFirst(start)).hasPrefix("A complete"))
        XCTAssertEqual(ConversationNavigation.contextStart(text: text, destination: end, seconds: 0), end)
        XCTAssertEqual(ConversationNavigation.contextStart(text: text, destination: 10, seconds: 120), 0)
    }

    func testPDFDownloadDatesDoNotChangePreparedTextIdentityButBodyDatesDo() throws {
        func extracted(stamp: String, body: String) throws -> String {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let data = renderer.pdfData { context in
                context.beginPage()
                (stamp as NSString).draw(at: CGPoint(x: 30, y: 25), withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
                (body as NSString).draw(in: CGRect(x: 40, y: 200, width: 520, height: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
            return try PDFStructuredTextExtractor.markdown(from: XCTUnwrap(PDFDocument(data: data)))
        }
        let body = "Research findings. The experiment began on 2026-09-01. Its results are meaningful."
        let first = try extracted(stamp: "Downloaded on 2026-09-21", body: body)
        let second = try extracted(stamp: "Downloaded on 2026-09-22", body: body)
        XCTAssertFalse(first.contains("Downloaded"))
        XCTAssertEqual(PortableArticleAnchorResolver.normalizedContentSHA256(first), PortableArticleAnchorResolver.normalizedContentSHA256(second))
        let changed = try extracted(stamp: "Downloaded on 2026-09-22", body: body.replacingOccurrences(of: "2026-09-01", with: "2026-09-02"))
        XCTAssertNotEqual(PortableArticleAnchorResolver.normalizedContentSHA256(first), PortableArticleAnchorResolver.normalizedContentSHA256(changed))
        let quote = "Its results are meaningful."
        let anchor = PortableAnchorEvidence(anchorType: .text, exactText: quote)
        let resolution = PortableArticleAnchorResolver.resolve(anchor: anchor, in: second, expectedExactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(first))
        XCTAssertEqual(resolution.evidenceClass, .articleTextVerified)
        XCTAssertNotNil(resolution.localStartChar)
        XCTAssertFalse(PDFStructuredTextExtractor.isDownloadStamp("The dataset was downloaded on 2026-09-22 for our experiment."))
    }
}
