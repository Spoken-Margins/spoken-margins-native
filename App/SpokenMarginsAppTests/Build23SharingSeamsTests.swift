import XCTest
import Combine
import SessionKitSharing
import SessionKitPersistence
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Build23SharingSeamsTests: XCTestCase {
    func testSharingCoordinatorIgnoresPlaybackAndDiagnosticTicks() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let coordinator = Build23SharingCoordinator(model: model)
        // Start-up work (the coordinator's coalesced first model change, and
        // anything the new model schedules) can land well after a fixed number
        // of yields on a busy or just-erased simulator (#415). Wait until the
        // coordinator has been quiet for a while instead.
        try await waitUntilQuiet(coordinator)
        var notifications = 0
        let subscription = coordinator.objectWillChange.sink { notifications += 1 }
        // Names any sharing input that changed while ticking, so a failure
        // says whether a tick leaked or a sharing input really changed.
        var changedInputs: [String] = []
        let inputWatch = sharingInputs(of: model).map { name, input in
            input.dropFirst().sink { changedInputs.append(name) }
        }
        for index in 0..<100 {
            model.snapshot.currentMediaTimeMs = index * 500
            model.diagnostics["test-tick"] = String(index)
        }
        // A leaked tick reaches the coordinator through its coalescing task,
        // so give that task time to run before counting.
        try await Task.sleep(for: Self.quietWindow)
        XCTAssertEqual(
            notifications, 0,
            "Audio progress must not rebuild shared-Margin presentation; sharing inputs changed: \(changedInputs)"
        )
        coordinator.send(.setSenderDisplayLabel("A changed sharing input"))
        XCTAssertGreaterThan(notifications, 0)
        withExtendedLifetime((subscription, inputWatch)) {}
    }

    private static let quietWindow: Duration = .milliseconds(300)

    /// Returns once `coordinator` has sent no change notification for
    /// `quietWindow`; fails if it keeps changing for `timeout`.
    private func waitUntilQuiet(
        _ coordinator: Build23SharingCoordinator,
        timeout: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var lastChange = start
        let subscription = coordinator.objectWillChange.sink { lastChange = clock.now }
        defer { withExtendedLifetime(subscription) {} }
        while clock.now - lastChange < Self.quietWindow {
            guard clock.now - start < timeout else {
                XCTFail("The sharing coordinator never went quiet after start-up")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The model publishers the coordinator treats as sharing inputs
    /// (`Build23SharingCoordinator.init`).
    private func sharingInputs(of model: Gate1AppModel) -> [(String, AnyPublisher<Void, Never>)] {
        [
            ("sharingState", model.$sharingState.map { _ in () }.eraseToAnyPublisher()),
            ("selectedItem", model.$selectedItem.map { _ in () }.eraseToAnyPublisher()),
            ("importReview", model.$spokenMarginsPackageImportReview.map { _ in () }.eraseToAnyPublisher()),
            ("isImporting", model.$isImportingSpokenMarginsPackage.map { _ in () }.eraseToAnyPublisher()),
            ("importError", model.$spokenMarginsPackageImportError.map { _ in () }.eraseToAnyPublisher()),
            ("sharedPackageURL", model.$sharedSpokenMarginsPackageURL.map { _ in () }.eraseToAnyPublisher())
        ]
    }

    func testTwoMarginsWithLocalSkimReferencesProduceVerifiedShareFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: db.path)
        let itemID = model.selectedItem.id
        let proposal = PortableListeningMapProposalArtifact(
            id: "local-map", createdAt: Date(timeIntervalSince1970: 1), generator: "test",
            scenes: [PortableListeningMapScene(id: "scene", order: 0, title: "Opening",
                summaryText: "A summary to retain", summaryAssetId: "unselected-local-summary",
                summaryProvenance: .modelGenerated, eligibility: .eligible,
                startAnchor: PortableAnchorEvidence(anchorType: .text, roughPercent: 0),
                endAnchor: PortableAnchorEvidence(anchorType: .text, roughPercent: 100))]
        )
        try store.savePortableListeningMapProposal(proposal, itemId: itemID)
        model.selectedItem.interjections = (1...2).map { index in
            Interjection(id: "margin-\(index)", itemId: itemID, sessionId: "session-test",
                targetType: .item, targetId: itemID, createdAt: Date(), roughPercent: index * 20,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
                transcript: "Reviewed Margin \(index)", cleanedTranscript: nil, displayText: nil, status: "active")
        }
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.advanceToReview)
        coordinator.send(.buildRecipientPreview)
        try await waitForSharingPreview(coordinator) { $0.previewState != .building }
        XCTAssertEqual(coordinator.previewState, .ready)
        let url = try XCTUnwrap(coordinator.verifiedShareFileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(coordinator.verifiedPreview?.margins.count, 2)
        let exported = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appending(path: "verified-assets"))
        XCTAssertNil(exported.listeningMapProposals.first?.scenes.first?.summaryAssetId)
        // The seeded item is a local one with no public-source mark, so the model-written summary stays on the phone (#3449):
        // the packet carries the scene start and nothing the model wrote. A marked-public source keeps its text; that is
        // covered where the gate is (`ListeningMapExportTests`, `SharedMarginExportTests`).
        XCTAssertNil(exported.listeningMapProposals.first?.scenes.first?.summaryText)
        XCTAssertNil(exported.listeningMapProposals.first?.scenes.first?.title)
        XCTAssertEqual(try store.loadPortableListeningMapProposals(itemId: itemID).first, proposal, "Sharing must not mutate the local map or its usable Skim audio")
        coordinator.send(.presentSystemShare)
        XCTAssertEqual(coordinator.stage, .share)
    }

    /// #3839: the moment step reads the stored Margin and whether this item is playing each time, so it clears when the
    /// sample lands without the sheet reopening, says "Play the episode" while the item is paused or another one plays,
    /// and a flip of playback reaches the sheet.
    func testTheMomentStepFollowsTheStoredMarginAndPlaybackWithoutReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.isNativeAudio = true
        model.selectedItem.interjections = [Interjection(
            id: "margin-just-recorded", itemId: itemID, sessionId: "session-test", targetType: .item, targetId: itemID,
            createdAt: Date(), roughPercent: 40,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "Just recorded.",
            cleanedTranscript: nil, displayText: nil, status: "active",
            podcastAnchorEvidenceCaptureStatus: .pendingPostResumeSample
        )]
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.advanceToReview)
        try await waitUntilQuiet(coordinator)

        func firstStep() -> String? { coordinator.snapshot.margins.first?.steps.first?.text }
        XCTAssertEqual(coordinator.snapshot.margins.first?.steps.first?.icon, .clock)
        XCTAssertTrue(firstStep()?.hasPrefix("Play the episode for about 12 seconds") == true, "paused: \(String(describing: firstStep()))")
        XCTAssertTrue(coordinator.snapshot.pinnedStep?.text.hasPrefix("Play the episode") == true)

        // Another item playing does not count as this one.
        model.snapshot.itemId = "another-episode"
        model.snapshot.status = .playing
        XCTAssertTrue(firstStep()?.hasPrefix("Play the episode") == true, "another item plays: \(String(describing: firstStep()))")

        // This item playing changes the words, and the change reaches the sheet.
        var notifications = 0
        let subscription = coordinator.objectWillChange.sink { notifications += 1 }
        defer { withExtendedLifetime(subscription) {} }
        model.snapshot.itemId = itemID
        let clock = ContinuousClock()
        let start = clock.now
        while notifications == 0, clock.now - start < .seconds(10) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(notifications, 0, "playback of this item starting must reach the sheet")
        XCTAssertTrue(firstStep()?.hasPrefix("Finding the exact moment for this Margin") == true, String(describing: firstStep()))
        XCTAssertTrue(coordinator.snapshot.pinnedStep?.text.hasPrefix("Finding the exact moment for your new Margin") == true)

        // The sample lands in the stored Margin: no step, no pinned line, nothing reopened.
        model.selectedItem.interjections[0].podcastAnchorEvidence = [
            CapturedPodcastAnchorEvidence(id: "evidence", localPath: "/unused", durationMs: 12_000, anchorOffsetMs: 4_000)
        ]
        model.selectedItem.interjections[0].podcastAnchorEvidenceCaptureStatus = .ready
        XCTAssertEqual(coordinator.snapshot.margins.first?.steps, [])
        XCTAssertNil(coordinator.snapshot.margins.first?.placementNote)
        XCTAssertNil(coordinator.snapshot.pinnedStep)
    }

    /// A coordinator on review for one podcast Margin whose post-resume sample has not landed yet.
    private func coordinatorWithPendingEvidence() async throws -> (Build23SharingCoordinator, Gate1AppModel) {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = [Interjection(
            id: "margin-evidence-mid-build", itemId: itemID, sessionId: "session-test", targetType: .item, targetId: itemID,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 25,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "A reviewed Margin.",
            cleanedTranscript: nil, displayText: nil, status: "active",
            podcastAnchorEvidenceCaptureStatus: .pendingPostResumeSample
        )]
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.advanceToReview)
        try await waitUntilQuiet(coordinator)
        return (coordinator, model)
    }

    private func landEvidence(in model: Gate1AppModel) {
        model.selectedItem.interjections[0].podcastAnchorEvidence = [
            CapturedPodcastAnchorEvidence(id: "evidence", localPath: "/unused", durationMs: 12_000, anchorOffsetMs: 4_000)
        ]
        model.selectedItem.interjections[0].podcastAnchorEvidenceCaptureStatus = .ready
    }

    /// #3839 audit: the post-resume sample landing while the packet builds must not turn the preview stale; the sender
    /// changed nothing, so they must not be sent back with "Your selection changed".
    func testEvidenceLandingMidBuildDoesNotMakeThePreviewStale() async throws {
        let (coordinator, model) = try await coordinatorWithPendingEvidence()
        coordinator.send(.buildRecipientPreview)
        XCTAssertEqual(coordinator.snapshot.stage, .recipientPreview)
        landEvidence(in: model)

        try await waitForSharingPreview(coordinator)
        XCTAssertNotNil(coordinator.snapshot.verifiedPreview, "the preview must reach ready, not stale")
        XCTAssertEqual(coordinator.snapshot.stage, .recipientPreview)
        if let url = coordinator.snapshot.verifiedPreview?.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    /// #3839 second audit: the same landing after the system share sheet closed (stage back on review, packet kept) or
    /// after "Back to your Margins" (#4647) must not show "Your selection changed" or move the sender. The old packet is dropped
    /// quietly, so the next Share builds one that carries the evidence.
    func testEvidenceLandingAfterSharingOrGoingBackIsNotAChangedSelection() async throws {
        for returning in [Build23SenderAction.returnFromSystemShare, .returnToSelect] {
            let (coordinator, model) = try await coordinatorWithPendingEvidence()
            coordinator.send(.buildRecipientPreview)
            try await waitForSharingPreview(coordinator)
            let builtURL = coordinator.snapshot.verifiedPreview?.fileURL
            defer { if let builtURL { try? FileManager.default.removeItem(at: builtURL) } }
            if returning == .returnFromSystemShare { coordinator.send(.presentSystemShare) }
            coordinator.send(returning)
            let stageBefore = coordinator.snapshot.stage

            landEvidence(in: model)
            try await waitUntilQuiet(coordinator)

            XCTAssertNotEqual(coordinator.snapshot.previewState, .stale, "\(returning): evidence is not a changed selection")
            XCTAssertEqual(coordinator.snapshot.stage, stageBefore, "\(returning): the sender must stay where they are")
            XCTAssertNil(coordinator.snapshot.verifiedPreview, "\(returning): a packet built without the evidence is dropped")
        }
    }

    /// A coordinator on review for one voice Margin whose transcript is still pending (#3839).
    private func coordinatorWithPendingWords() async throws -> (Build23SharingCoordinator, Gate1AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "words-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appending(path: "voice.m4a")
        try Data([0]).write(to: audio)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = [Interjection(
            id: "margin-words-wait", itemId: itemID, sessionId: "session-test", targetType: .item, targetId: itemID,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 25,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: audio.path, audioStatus: "recorded", transcriptionStatus: "pending", transcript: nil,
            cleanedTranscript: nil, displayText: nil, status: "active"
        )]
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.advanceToReview)
        try await waitUntilQuiet(coordinator)
        return (coordinator, model, root)
    }

    private func wordsArrive(in model: Gate1AppModel, _ words: String = "Keep going.") {
        model.selectedItem.interjections[0].transcript = words
        model.selectedItem.interjections[0].displayText = words
        model.selectedItem.interjections[0].transcriptionStatus = "transcribed"
        model.selectedItem.interjections[0].alignedTranscript = AlignedInterjectionTranscript(text: words, segments: [
            .init(id: "keep", text: "Keep", startMs: 0, endMs: 300), .init(id: "going", text: "going.", startMs: 400, endMs: 800)
        ])
    }

    /// #3839: a Margin recorded seconds ago has no words yet. The card says so and the bar says so above Share link; when
    /// the words land the draft is rebuilt from the stored Margin, the step and the badge go, and nothing is reopened.
    func testAMarginWaitingOnItsWordsSaysSoAndIsRebuiltWhenTheyArrive() async throws {
        let (coordinator, model, root) = try await coordinatorWithPendingWords()
        defer { try? FileManager.default.removeItem(at: root) }
        let waiting = try XCTUnwrap(coordinator.snapshot.margins.first)
        XCTAssertEqual(waiting.waitingBadge, "Waiting for words")
        XCTAssertEqual(waiting.steps.first?.icon, .words)
        XCTAssertEqual(waiting.steps.first?.text, "Getting this Margin's words ready. It's added when they're ready.")
        XCTAssertTrue(waiting.isShowingPlaceholder, "a voice Margin goes with stand-in words while it waits (#3027)")
        XCTAssertEqual(coordinator.snapshot.pinnedStep?.text, "Getting the words ready for your new Margin. A few seconds.")
        XCTAssertTrue(coordinator.snapshot.canAdvance, "Share is never blocked by the wait")

        wordsArrive(in: model)
        try await pollUntil { coordinator.snapshot.margins.first?.reviewedText == "Keep going." }

        let arrived = try XCTUnwrap(coordinator.snapshot.margins.first)
        XCTAssertEqual(arrived.reviewedText, "Keep going.")
        XCTAssertFalse(arrived.isShowingPlaceholder)
        XCTAssertNil(arrived.waitingBadge)
        XCTAssertEqual(arrived.steps, [])
        XCTAssertNil(coordinator.snapshot.pinnedStep)
        XCTAssertTrue(arrived.isIncluded)
        XCTAssertEqual(coordinator.snapshot.stage, .review, "the sender stays where they are")
        XCTAssertNotEqual(coordinator.snapshot.previewState, .stale)
    }

    /// The sender's other choices never hold the words back, and words they typed stay (#3839 review).
    func testWordsArriveWhateverElseTheSenderChangedAndTypedWordsStay() async throws {
        let (coordinator, model, root) = try await coordinatorWithPendingWords()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.send(.setRepresentation(id: "margin-words-wait", choice: .textOnly))
        wordsArrive(in: model)
        try await pollUntil { coordinator.snapshot.margins.first?.reviewedText == "Keep going." }
        XCTAssertEqual(coordinator.snapshot.margins.first?.representation, .textOnly, "their choice stays")
        XCTAssertEqual(coordinator.snapshot.margins.first?.isShowingPlaceholder, false)

        let (typed, typedModel, typedRoot) = try await coordinatorWithPendingWords()
        defer { try? FileManager.default.removeItem(at: typedRoot) }
        typed.send(.setReviewedWords(id: "margin-words-wait", text: "My own words"))
        wordsArrive(in: typedModel)
        try await pollUntil { typed.snapshot.margins.first?.waitingBadge == nil }
        try await waitUntilQuiet(typed)
        XCTAssertEqual(typed.snapshot.margins.first?.reviewedText, "My own words")
        XCTAssertEqual(typed.snapshot.margins.first?.steps, [], "the step still clears: the stored Margin has its words")
        XCTAssertNil(typed.snapshot.pinnedStep)
    }

    /// A Margin the sender left out stays left out when its words arrive, and a Margin whose transcription failed shows
    /// no step: it goes with its stand-in words.
    func testRebuildKeepsALeftOutMarginOutAndAFailedTranscriptionShowsNoStep() async throws {
        let (coordinator, model, root) = try await coordinatorWithPendingWords()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.send(.setIncluded(id: "margin-words-wait", included: false))
        XCTAssertNil(coordinator.snapshot.pinnedStep, "a Margin that isn't going doesn't hold the bar")
        wordsArrive(in: model)
        try await pollUntil { coordinator.snapshot.margins.first?.reviewedText == "Keep going." }
        XCTAssertEqual(coordinator.snapshot.margins.first?.isIncluded, false)

        let (failed, failedModel, failedRoot) = try await coordinatorWithPendingWords()
        defer { try? FileManager.default.removeItem(at: failedRoot) }
        failedModel.selectedItem.interjections[0].transcriptionStatus = "failed"
        try await pollUntil { failedModel.sharingState.drafts.first?.interjection.transcriptionStatus == "failed" }
        XCTAssertEqual(failedModel.sharingState.drafts.first?.interjection.transcriptionStatus, "failed", "the draft took the stored Margin")
        XCTAssertEqual(failed.snapshot.margins.first?.steps, [])
        XCTAssertNil(failed.snapshot.pinnedStep)
        XCTAssertTrue(failed.snapshot.margins.first?.isShowingPlaceholder == true)
    }

    func testSenderStageVocabularyIsFrozenInReleaseOrder() {
        XCTAssertEqual(
            Build23SharingStage.allCases.map(\.rawValue),
            ["select", "review", "recipient_preview", "share"]
        )
    }

    func testRecipientPreviewComesFromVerifiedFileAndMutationInvalidatesIt() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = [Interjection(
            id: "margin-build-23-seam",
            itemId: itemID,
            sessionId: "session-build-23-seam",
            targetType: .item,
            targetId: itemID,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 25,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: 5,
                anchorBefore: "Before",
                anchorAfter: "After"
            ),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "A reviewed Margin.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )]
        let coordinator = Build23SharingCoordinator(model: model)

        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.stage, .review, "a sheet that isn't a reply opens the list (#4647)")
        XCTAssertEqual(coordinator.snapshot.margins.map(\.id), ["margin-build-23-seam"])
        coordinator.send(.advanceToReview)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        coordinator.send(.buildRecipientPreview)

        try await waitForSharingPreview(coordinator)
        let preview = try XCTUnwrap(coordinator.snapshot.verifiedPreview)
        XCTAssertEqual(coordinator.snapshot.stage, .recipientPreview)
        XCTAssertEqual(preview.margins.map(\.reviewedText), ["A reviewed Margin."])
        XCTAssertFalse(preview.contentDigest.isEmpty)
        XCTAssertEqual(coordinator.verifiedShareFileURL, preview.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.fileURL.path))
        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertFalse(model.isSharedSpokenMarginsPackagePresented)

        coordinator.send(.setSenderDisplayLabel("Changed after preview"))

        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertNil(coordinator.snapshot.verifiedPreview)
        XCTAssertNil(coordinator.verifiedShareFileURL)
        try? FileManager.default.removeItem(at: preview.fileURL)
    }
    func testAcousticOptOutOmitsStoredEditionSpineAndRetainsReviewedDisclosures() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "evidence-opt-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        let store = try SQLiteSessionStore(path: db.path)
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: "stored-spine", itemId: itemID, landmarks: [
                EpisodeFingerprintLandmark(id: "landmark", order: 0, sourceMediaStartMs: 0,
                    sourceMediaEndMs: 12_000, anchorMediaTimeMs: 6_000, continuityEpoch: 0,
                    trigger: .initialPlayback, provenance: .observedDecodedPlayback,
                    signatureAssetId: "signature-the-user-excluded")
            ]
        ))
        model.selectedItem.interjections = [Interjection(
            id: "margin-build-23-seam",
            itemId: itemID,
            sessionId: "session-build-23-seam",
            targetType: .item,
            targetId: itemID,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 25,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: 5,
                anchorBefore: "Before",
                anchorAfter: "After"
            ),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "A reviewed Margin.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )]
        let coordinator = Build23SharingCoordinator(model: model)

        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.stage, .review, "a sheet that isn't a reply opens the list (#4647)")
        XCTAssertEqual(coordinator.snapshot.margins.map(\.id), ["margin-build-23-seam"])
        coordinator.send(.advanceToReview)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        coordinator.send(.setIncludesAcousticEvidence(false))
        coordinator.send(.buildRecipientPreview)

        try await waitForSharingPreview(coordinator)
        let preview = try XCTUnwrap(coordinator.snapshot.verifiedPreview)
        XCTAssertEqual(coordinator.snapshot.stage, .recipientPreview)
        XCTAssertEqual(preview.margins.map(\.reviewedText), ["A reviewed Margin."])
        XCTAssertFalse(preview.contentDigest.isEmpty)
        let verified = try SpokenMarginsPackageArchive.read(from: preview.fileURL, extractingAssetsTo: root.appending(path: "assets"))
        XCTAssertTrue(verified.editionFingerprintSpines.isEmpty)
        XCTAssertFalse(verified.manifest.assets.contains { $0.role == SpokenMarginsAssetRole.acousticSignature })
        XCTAssertTrue(verified.commentaryLayers.flatMap(\.interjections).allSatisfy { $0.anchor.machineEvidenceAssetIds.isEmpty })
        XCTAssertTrue(preview.disclosures.contains(SharingRightsPresentation.rightsNotice))
        XCTAssertTrue(preview.disclosures.contains(SharingRightsPresentation.recipientCopiesNotice))
        XCTAssertTrue(preview.disclosures.contains { $0.contains("Context before: Before") })
        XCTAssertTrue(preview.disclosures.contains { $0.contains("Context after: After") })
        XCTAssertTrue(preview.disclosures.contains { $0.contains("text only; no recording") })
        XCTAssertNotNil(try store.loadEditionFingerprintSpine(itemId: itemID), "Opt-out must not delete locally useful evidence")
        XCTAssertEqual(coordinator.verifiedShareFileURL, preview.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.fileURL.path))
        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertFalse(model.isSharedSpokenMarginsPackagePresented)

        coordinator.send(.setSenderDisplayLabel("Changed after preview"))

        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertNil(coordinator.snapshot.verifiedPreview)
        XCTAssertNil(coordinator.verifiedShareFileURL)
        try? FileManager.default.removeItem(at: preview.fileURL)
    }

    /// "Tell Ben you got it" (#3902, Design E2): a friend's packet that answers the listener's own Margin puts the offer on
    /// its card and in the intro; a friend's first share on the same item gets neither, and the offer follows the item as
    /// it changes, the way a relaunch rebuilds it from the stored records.
    func testAReplyToMyMarginOffersTellReceivedOnItsCardAndInTheIntro() throws {
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        let mine = MarginPacketIdentity(packageDigest: String(repeating: "a", count: 64), packageScopedId: "a-1")
        let identity = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/harbour", title: "Harbour Lights")
        func layer(_ id: String, _ label: String, importedAt: Double) -> ImportedCommentaryLayer {
            ImportedCommentaryLayer(
                id: id, packageDigest: String(repeating: id.first.map(String.init) ?? "x", count: 64), packageId: id,
                itemIdentity: identity, displayLabel: label, importedAt: date.addingTimeInterval(importedAt))
        }
        func friendMargin(_ id: String, layer: String, replying: Bool) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(
                id: id, layerId: layer, packageScopedId: "\(id)-scoped", createdAt: date,
                anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Words",
                replyLinks: replying ? [MarginReplyLink.replying(to: mine, parentConversationId: nil)] : nil)
        }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        var item = ItemDetailState()
        item.id = "item"
        item.title = "Harbour Lights"
        item.interjections = [Interjection(
            id: "mine", itemId: "item", sessionId: "session", targetType: .item, targetId: "item", createdAt: date, roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
            displayText: "Words", status: "active", captureKind: .written
        ).recordingShare(as: mine)]
        item.importedCommentaryLayers = [layer("ben", "Ben", importedAt: 10), layer("cy", "Cy", importedAt: 20)]
        item.importedCommentaryInterjections = [
            "ben": [friendMargin("b1", layer: "ben", replying: true)],
            "cy": [friendMargin("c1", layer: "cy", replying: false)],
        ]
        model.selectedItem = item
        let coordinator = Build23SharingCoordinator(model: model)

        let ben = try XCTUnwrap(coordinator.importedLayers.first { $0.id == "ben" })
        XCTAssertEqual(ben.receipt?.replyCount, 1)
        XCTAssertNil(coordinator.importedLayers.first { $0.id == "cy" }?.receipt, "Cy's first share is not an answer")
        let intro = try XCTUnwrap(coordinator.introReceipt, "Cy's newer first share doesn't hide Ben's reply")
        XCTAssertEqual(intro.title, "Tell Ben you got it")
        XCTAssertEqual(intro.message, "Got your reply on \u{201C}Harbour Lights\u{201D} in Spoken Margins.")

        item.importedCommentaryInterjections["ben"] = [friendMargin("b1", layer: "ben", replying: false)]
        model.selectedItem = item
        XCTAssertNil(coordinator.introReceipt)
        XCTAssertTrue(coordinator.importedLayers.allSatisfy { $0.receipt == nil })
    }
}
