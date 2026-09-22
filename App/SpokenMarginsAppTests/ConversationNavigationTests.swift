import XCTest
import AVFoundation
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
        XCTAssertNotNil(model.conversationLeadIn)
        model.skimForward()
        XCTAssertNil(model.conversationLeadIn)
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, "An earlier observation")
        XCTAssertEqual(model.snapshot.sessionId, newSession, "Listening to an old Margin must not reopen or rewrite its session")
        XCTAssertEqual(model.selectedItem.itemInterjections.first?.sessionId, originalSession)
        model.returnFromConversation()
        XCTAssertNil(model.conversationCurrentMargin)
        XCTAssertEqual(model.snapshot.currentTextStart, 0)
    }

    func testSecondTapKeepsDestinationEvenIfContextPassesAnotherMargin() throws {
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
        let target = try XCTUnwrap(model.conversationLeadIn?.destination)
        model.skimForward()
        XCTAssertEqual(model.conversationCurrentMargin?.id, target.id)
        model.skimForward()
        XCTAssertNotEqual(model.conversationLeadIn?.destination.id ?? model.conversationCurrentMargin?.id, target.id)
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
        XCTAssertNotNil(model.conversationLeadIn)
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
        model.skimForward()
        XCTAssertEqual(model.conversationLeadIn?.destination.position, 300_000)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 180_000)
        XCTAssertEqual(model.skimForwardDestinationMs, 300_000)
        var reached = model.snapshot
        reached.currentMediaTimeMs = 300_100
        XCTAssertTrue(model.reconcileConversationLeadIn(current: reached))
        XCTAssertNil(model.conversationLeadIn)
        XCTAssertEqual(model.conversationCurrentMargin?.transcript, note.approvedTranscript)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 300_000)
        XCTAssertNil(model.pendingImportedCommentary, "Explicit arrival must not also prompt")
        model.conversationScope = .newMargins
        XCTAssertTrue(model.conversationDestinations.isEmpty, "Displayed text is no longer new")
        model.returnFromConversation()
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 0)
        model.conversationScope = .margins
        model.setImportedCommentaryLayerMuted(layer.id, muted: true)
        XCTAssertFalse(model.snapshot.canSkimForward)
        XCTAssertTrue(model.conversationDestinations.isEmpty)
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
