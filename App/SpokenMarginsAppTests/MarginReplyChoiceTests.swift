import SessionKit
import XCTest
@testable import SpokenMarginsApp
#if canImport(UIKit)
import UIKit
#endif

/// The "Make independent" switch is honoured wherever it is shown (#473): before the microphone is running, and
/// in what a written draft journals for a closed app. Each fails when the line that implements it is removed.
@MainActor
final class MarginReplyChoiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private var priorTerms: [Any?] = []
    private let termsKeys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]

    override func setUp() async throws {
        priorTerms = termsKeys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDown() async throws {
        for (key, value) in zip(termsKeys, priorTerms) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func replyDraft() -> MarginReplyDraft {
        var layer = ImportedCommentaryLayer(
            id: "layer", itemId: "item", packageDigest: String(repeating: "a", count: 64), packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.com/a", title: "A"),
            displayLabel: "Ana", importedAt: now
        )
        layer.isEnabled = true
        let margin = ImportedCommentaryInterjection(
            id: "m1", layerId: "layer", packageScopedId: "m1-scoped", createdAt: now,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 1_000)
        )
        return MarginReplyDraft(parent: margin, in: layer)
    }

    func testTheSwitchWorksWhileTheMicrophoneIsStillBeingAskedFor() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.marginCapture.setPendingReply(replyDraft())
        model.marginCapture.beginCompactRequest()
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(model.isRequestingRecordingPermission)

        model.toggleReplyOfCurrentMargin()
        XCTAssertNil(model.marginCapture.pendingReply, "the start will read independent")
        model.toggleReplyOfCurrentMargin()
        XCTAssertNotNil(model.marginCapture.pendingReply, "and the way back works too")
    }

    func testAClosedAppKeepsWhatTheListenerChose() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "reply-choice-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = WrittenMarginDraftJournal(directory: WrittenMarginDraftJournal.standardDirectory(applicationSupport: directory))
        let reply = replyDraft()
        var draft = WrittenMarginDraft(
            capture: WrittenInterjectionCapture(
                id: "c", sessionId: "s", itemId: "item", targetType: .item, targetId: "item",
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
                roughPercent: 5, wasPlaying: false, replyTo: reply.link
            ),
            text: "typed", itemTitle: "A", targetDescription: "Source", progressPercent: 5,
            replyChoice: MarginReplyChoice(suggested: reply)
        )
        let keeper = WrittenMarginDraftKeeper(journal: journal, currentDraft: { draft }, onFailure: { XCTFail($0) })
        _ = keeper

        draft.replyChoice.toggle()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertNil(try journal.load().drafts.first?.replyTo, "independent is what the next launch restores")

        draft.replyChoice.toggle()
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertEqual(try journal.load().drafts.first?.replyTo, reply.link)
    }

    func testARestoredLinkWhoseMarginCannotBeShownIsDroppedNotHidden() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        XCTAssertFalse(model.restoredReplyChoice(for: nil).canToggle)
        let choice = model.restoredReplyChoice(for: replyDraft().link)
        XCTAssertNil(choice.effective, "a reply the screen cannot show would be saved unseen")
        XCTAssertEqual(model.diagnostics["writtenMarginDraftReply"], "dropped:parent_not_found")
    }
}
