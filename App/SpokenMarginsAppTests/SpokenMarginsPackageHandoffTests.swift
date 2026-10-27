import XCTest
@testable import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
@testable import SpokenMarginsApp

final class SpokenMarginsPackageHandoffTests: XCTestCase {
    func testPackageHandoffPreservesExactBytesUntilConsumed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-handoff-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Shared Session.spokenmargins")
        let expected = Data([0x50, 0x4b, 0x03, 0x04, 0x00, 0xff, 0x10])
        try expected.write(to: source)
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)

        let payloadID = try store.savePackage(from: source)

        XCTAssertEqual(try store.pendingPayloadIDs(), [payloadID])
        XCTAssertEqual(try Data(contentsOf: store.packageURL(payloadID: payloadID)), expected)
        try store.deletePackage(payloadID: payloadID)
        XCTAssertTrue(try store.pendingPayloadIDs().isEmpty)
    }

    func testPackageHandoffRejectsAFileWithoutTheOwnedExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-handoff-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: source)
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)

        XCTAssertThrowsError(try store.savePackage(from: source)) { error in
            XCTAssertEqual(
                error as? SpokenMarginsPackageHandoffStoreError,
                .invalidPackage("the file extension is not .spokenmargins")
            )
        }
    }

    @MainActor
    func testSystemShareDeclaresTheOwnedPackageType() {
        let url = URL(fileURLWithPath: "/tmp/shared-session.spokenmargins")
        let item = SpokenMarginsPackageActivityItem(packageURL: url)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)

        XCTAssertEqual(
            item.activityViewController(controller, dataTypeIdentifierForActivityType: nil),
            SpokenMarginsPackageHandoffStore.uniformTypeIdentifier
        )
        XCTAssertEqual(
            item.activityViewController(controller, itemForActivityType: nil) as? URL,
            url
        )
    }

    @MainActor
    func testAppConsumesShareExtensionPackageIntoRecipientImportFlow() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = [Interjection(
            id: "margin-package-handoff",
            itemId: itemID,
            sessionId: "session-package-handoff",
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
            transcript: "A shared Margin.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )]
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.advanceToReview)
        coordinator.send(.buildRecipientPreview)
        for _ in 0..<100 where coordinator.snapshot.previewState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        let packageURL = try XCTUnwrap(coordinator.verifiedShareFileURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-consumption-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)
        _ = try store.savePackage(from: packageURL)

        try model.consumePendingSpokenMarginsPackageHandoffs(from: store)

        let review = try XCTUnwrap(model.spokenMarginsPackageImportReview)
        XCTAssertEqual(try store.pendingPayloadIDs().count, 1, "the shared copy waits until Import or Cancel (#2123)")
        XCTAssertTrue(model.diagnostics.values.contains("opened"))

        // Coming back to the foreground while the review shows stages nothing again.
        try model.consumePendingSpokenMarginsPackageHandoffs(from: store)
        XCTAssertEqual(model.spokenMarginsPackageImportReview?.id, review.id)

        // The app is killed before Import: the next launch reopens the review once, not on every foreground.
        let relaunched = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        try relaunched.consumePendingSpokenMarginsPackageHandoffs(from: store)
        let reopened = try XCTUnwrap(relaunched.spokenMarginsPackageImportReview, "the packet survived the relaunch")
        try relaunched.consumePendingSpokenMarginsPackageHandoffs(from: store)
        XCTAssertEqual(relaunched.spokenMarginsPackageImportReview?.id, reopened.id, "reopened once, not on a loop")
        XCTAssertEqual(try store.pendingPayloadIDs().count, 1)

        relaunched.cancelSpokenMarginsPackageImport()
        XCTAssertNil(relaunched.spokenMarginsPackageImportReview)
        XCTAssertTrue(try store.pendingPayloadIDs().isEmpty, "Cancel removes the shared copy")
        model.cancelSpokenMarginsPackageImport()
    }

    // MARK: Share links (#488)

    private static let shareLinkID = "0123456789abcdef0123456789abcdef"

    @MainActor
    private func shareLinkModel(root: URL, fetch: @escaping ShareLinkPacketDownloader.Fetch) -> Gate1AppModel {
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: root.appendingPathComponent("recipient.sqlite")
        )
        model.resetAndSeed()
        model.shareLinkOpener.downloader = ShareLinkPacketDownloader(fetch: fetch)
        return model
    }

    @MainActor
    private func waitForShareLink(_ model: Gate1AppModel, until done: @MainActor () -> Bool) async throws {
        for _ in 0..<250 where !done() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(done(), "Timed out waiting for the share link: \(model.diagnostics["lastShareLink"] ?? "no state")")
    }

    @MainActor
    func testTappingAShareLinkDownloadsTheSealedPacketAndShowsTheImportReview() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-share-link-open")
        let packageURL = root.appendingPathComponent("link.spokenmargins")
        _ = try writePodcastPackage(to: packageURL, packageID: "package-share-link")
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(
            packet: try Data(contentsOf: packageURL), preview: Data(#"{"schema":"spokenmargins.link-preview.v1"}"#.utf8), key: key
        )
        let requested = ShareLinkRequestLog()
        let model = shareLinkModel(root: root) { url, _ in
            requested.record(url)
            return (200, sealed.packet)
        }
        let link = try XCTUnwrap(ShareLinkSealing.linkURL(
            base: URL(string: "https://spokenmargins.proximitytoprogress.com/l/\(Self.shareLinkID)")!, key: key
        ))

        model.handleIncomingURL(link)
        try await waitForShareLink(model) { model.spokenMarginsPackageImportReview != nil }

        XCTAssertEqual(model.spokenMarginsPackageImportReview?.contents.manifest.item.title, Self.podcastTitle)
        XCTAssertEqual(requested.urls.map(\.absoluteString), ["https://spokenmargins.proximitytoprogress.com/l/\(Self.shareLinkID)/packet"])
        XCTAssertEqual(model.diagnostics["lastShareLink"], "opened")
        XCTAssertFalse(model.diagnostics.values.contains { $0.contains(key.fragment) }, "the key must never reach diagnostics")
        model.cancelSpokenMarginsPackageImport()
    }

    /// #1967: no connection is not an expired link, and the banner offers Retry.
    @MainActor
    func testAShareLinkOpenedOfflineSaysSoAndOffersARetry() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-share-link-offline")
        let model = shareLinkModel(root: root) { _, _ in throw URLError(.notConnectedToInternet) }
        let link = try XCTUnwrap(ShareLinkSealing.linkURL(
            base: URL(string: "https://spokenmargins.proximitytoprogress.com/l/\(Self.shareLinkID)")!, key: .random()
        ))

        model.handleIncomingURL(link)
        try await waitForShareLink(model) { model.lastError != nil }

        XCTAssertEqual(model.lastError, "You're offline. Reconnect, then tap the link again.")
        XCTAssertNotNil(model.feedbackEvent?.retry, "an offline link is worth another try")
        XCTAssertNil(model.spokenMarginsPackageImportReview)
    }

    @MainActor
    func testAnExpiredShareLinkSaysSoAndOpensNoReview() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-share-link-expired")
        let model = shareLinkModel(root: root) { _, _ in (410, Data()) }
        let link = try XCTUnwrap(ShareLinkSealing.linkURL(
            base: URL(string: "https://spokenmargins.proximitytoprogress.com/l/\(Self.shareLinkID)")!, key: .random()
        ))

        model.handleIncomingURL(link)
        try await waitForShareLink(model) { model.lastError != nil }

        XCTAssertEqual(model.lastError, "This link has expired. Ask your friend to share it again.")
        XCTAssertNil(model.spokenMarginsPackageImportReview)
    }

    @MainActor
    func testAShareLinkWithoutItsKeySaysItIsDamagedWithoutAskingTheServer() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-share-link-keyless")
        let requested = ShareLinkRequestLog()
        let model = shareLinkModel(root: root) { url, _ in
            requested.record(url)
            return (200, Data())
        }

        model.handleIncomingURL(URL(string: "https://spokenmargins.proximitytoprogress.com/l/\(Self.shareLinkID)")!)
        try await waitForShareLink(model) { model.lastError != nil }

        XCTAssertEqual(model.lastError, "This link is incomplete or damaged.")
        XCTAssertTrue(requested.urls.isEmpty)
        XCTAssertNil(model.spokenMarginsPackageImportReview)
    }

    /// Audit on 39b55b5: a replaced link whose server answered "gone" after the listener tapped a second link
    /// still showed "This link has expired", because only the generic catch checked for cancellation.
    @MainActor
    func testAReplacedLinkThatFailsLateShowsNoErrorForTheLinkThatReplacedIt() async throws {
        let firstAnswer = ShareLinkAnswerGate()
        let firstID = Self.shareLinkID
        let secondID = "fedcba9876543210fedcba9876543210"
        let opener = ShareLinkOpener(downloader: ShareLinkPacketDownloader { url, _ in
            if url.absoluteString.contains(firstID) {
                await firstAnswer.wait()
            }
            return (410, Data())
        })
        let failures = ShareLinkFailureLog()
        let base = "https://spokenmargins.proximitytoprogress.com/l/"
        let first = try XCTUnwrap(ShareLinkURL(url: try XCTUnwrap(ShareLinkSealing.linkURL(base: URL(string: base + firstID)!, key: .random()))))
        let second = try XCTUnwrap(ShareLinkURL(url: try XCTUnwrap(ShareLinkSealing.linkURL(base: URL(string: base + secondID)!, key: .random()))))

        opener.open(first, stage: { _ in XCTFail("the first link has no packet") }, fail: { message, _ in failures.first.append(message) })
        for _ in 0..<250 where !firstAnswer.isWaiting {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(firstAnswer.isWaiting, "the first link's download never started")
        opener.open(second, stage: { _ in XCTFail("the second link has no packet") }, fail: { message, _ in failures.second.append(message) })
        firstAnswer.answer()
        for _ in 0..<250 where failures.second.isEmpty || !firstAnswer.answered {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Give the replaced task time to reach its catch on the main actor.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(failures.second, ["This link has expired. Ask your friend to share it again."])
        XCTAssertEqual(failures.first, [], "the replaced link must not show an error over the link the listener tapped next")
    }

    @MainActor
    func testALinkOnTheShareHostThatIsNotAShareLinkIsRefusedWithoutADownload() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-share-link-foreign-path")
        let requested = ShareLinkRequestLog()
        let model = shareLinkModel(root: root) { url, _ in
            requested.record(url)
            return (200, Data())
        }

        model.handleIncomingURL(URL(string: "https://spokenmargins.proximitytoprogress.com/l/\(Self.shareLinkID)/packet")!)

        XCTAssertEqual(model.lastError, "This isn't a Spoken Margins share link.")
        XCTAssertTrue(requested.urls.isEmpty)
        XCTAssertNil(model.spokenMarginsPackageImportReview)
    }

    @MainActor
    func testPodcastPackageImportBindsToImportedItemInsteadOfStaleSelection() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-podcast-binding")
        // Background model work can retain SQLite; let the process close it before cleanup.
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("different-episode.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-different-episode")
        // Opening a store migrates/writes metadata. Prepare the inspection connection
        // before asynchronous model work, then read the actual persisted import below.
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let previouslySelectedItemID = model.selectedItem.id

        model.handleIncomingURL(packageURL)

        XCTAssertEqual(model.spokenMarginsPackageImportReview?.contents.manifest.item.title, Self.podcastTitle)
        XCTAssertNil(model.spokenMarginsPackageImportReview?.matchingItemId)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let importedItem = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)))
        XCTAssertNotEqual(importedItem.id, previouslySelectedItemID)
        XCTAssertEqual(layer.itemId, importedItem.id)
        XCTAssertNotEqual(layer.sourceResolutionStatus, .wrongSource)
        XCTAssertEqual(model.selectedItem.id, importedItem.id)
        XCTAssertEqual(model.selectedItem.title, Self.podcastTitle)
        XCTAssertEqual(model.screen, .item)
        XCTAssertNil(model.snapshot.sessionId, "Import must not start playback")

        model.handleIncomingURL(packageURL)

        XCTAssertNil(model.spokenMarginsPackageImportReview)
        XCTAssertEqual(model.selectedItem.id, importedItem.id)

        model.moveItemToTrash(id: importedItem.id)
        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == importedItem.id }))
        model.handleIncomingURL(packageURL)
        XCTAssertNotNil(model.spokenMarginsPackageImportReview, "Reopening must restore a deleted target instead of routing elsewhere")
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == importedItem.id }))
        XCTAssertEqual(model.selectedItem.id, importedItem.id)
        XCTAssertEqual(
            try store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest))?.itemId,
            importedItem.id
        )

        // On a fresh simulator the first-use voice choice is still pending, and startItem waits for it
        // silently; earlier classes that decline it hide this in a full run (#528). Make the choice here.
        model.declineCurrentTerms()
        model.startItem(id: importedItem.id)
        XCTAssertEqual(model.snapshot.itemId, importedItem.id)
    }

    @MainActor
    func testPodcastPackageCreatesReferencedEpisodeWithoutPublisherPageFetch() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-offline-publisher-page")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("referenced-episode.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-reference-with-enclosure")
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let model = Gate1AppModel(
            sourceLinkResolver: FailingPackagePodcastLinkResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()

        model.handleIncomingURL(packageURL)
        XCTAssertNil(model.spokenMarginsPackageImportReview?.matchingItemId)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let imported = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let item = try store.loadItem(id: imported.id)
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)))
        XCTAssertEqual(item.externalReference, Self.podcastURL)
        XCTAssertEqual(item.media?.url, Self.podcastAudioURL)
        XCTAssertEqual(layer.itemId, item.id)
        XCTAssertNotEqual(layer.sourceResolutionStatus, .wrongSource)
        XCTAssertNil(model.spokenMarginsPackageImportError)
        XCTAssertEqual(model.diagnostics["lastSharedPodcastAcquisition"], "package_reference_after_resolution_failure")
    }

    @MainActor
    func testPodcastPackageUsesItsOwnEnclosureWhenThePageLookupFindsNoAudio() async throws {
        // Omny-style: the page resolves, but only to a title with no audio (#157).
        let (model, store, manifest) = try makePackageImport(
            named: "lookup-without-audio",
            resolver: reviewResolver(candidates: [LinkResolutionCandidate(
                sourceLink: SourceLink(url: Self.podcastURL, provider: "podcasts.example.com", role: "discovery"),
                title: "Can you spot the imported story&#x27; - Example Show",
                confidence: 0.3
            )])
        )
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let imported = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        XCTAssertEqual(try store.loadItem(id: imported.id).media?.url, Self.podcastAudioURL)
        XCTAssertNotNil(try store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)))
        XCTAssertNil(model.spokenMarginsPackageImportError)
        XCTAssertEqual(model.diagnostics["lastSharedPodcastAcquisition"], "package_reference_after_lookup_without_audio")
    }

    @MainActor
    func testPodcastPackageMatchesATrackingWrappedEnclosureDespiteAdLengthDifference() async throws {
        let wrapped = "https://dts.podtrac.com/redirect.mp3/chtbl.com/track/ABC/cdn.example.com/imported-story.mp3?utm_source=feed"
        let (model, store, _) = try makePackageImport(
            named: "wrapped-enclosure",
            resolver: reviewResolver(candidates: [
                LinkResolutionCandidate(
                    sourceLink: SourceLink(url: "https://podcasts.example.com/feed.xml", provider: "rss", role: "canonical_feed"),
                    title: "Can you spot the imported story? (rerun)",
                    durationMs: 420_000,
                    audioURL: wrapped,
                    confidence: 0.8
                ),
                LinkResolutionCandidate(
                    sourceLink: SourceLink(url: "https://podcasts.example.com/feed.xml", provider: "rss", role: "canonical_feed"),
                    title: "A different episode",
                    durationMs: 300_000,
                    audioURL: "https://cdn.example.com/different-story.mp3",
                    confidence: 0.8
                )
            ])
        )
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let imported = try XCTUnwrap(model.libraryItems.first(where: { $0.title.hasPrefix("Can you spot the imported story") }))
        XCTAssertEqual(try store.loadItem(id: imported.id).media?.url, wrapped)
        XCTAssertNil(model.spokenMarginsPackageImportError)
    }

    @MainActor
    func testAmbiguousPodcastPackageShowsASentenceNotAnInternalCode() async throws {
        let (model, _, _) = try makePackageImport(
            named: "ambiguous",
            resolver: reviewResolver(candidates: ["one", "two"].map { name in
                LinkResolutionCandidate(
                    sourceLink: SourceLink(url: "https://podcasts.example.com/feed.xml", provider: "rss", role: "canonical_feed"),
                    title: "Episode \(name)",
                    audioURL: "https://cdn.example.com/\(name).mp3",
                    confidence: 0.5
                )
            })
        )
        model.confirmSpokenMarginsPackageImport()
        for _ in 0..<250 where model.spokenMarginsPackageImportError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let message = try XCTUnwrap(model.spokenMarginsPackageImportError)
        XCTAssertEqual(message, SharedMarginsImportMessage.userFacing(SessionKitError.persistenceFailed("shared_podcast_item_is_ambiguous")))
        XCTAssertFalse(message.contains("_"), message)
        XCTAssertEqual(model.diagnostics["lastSpokenMarginsPackageImport"], "failed:persistence_failed:shared_podcast_item_is_ambiguous")
    }

    func testUnreadablePacketSaysWhichVersionAndLogsTheFailingField() throws {
        // The parked co-op build wrote representation kinds this build doesn't know, e.g. forwarded_audio_and_text.
        struct Representation: Decodable { let kind: SharedInterjectionRepresentationKind }
        struct Record: Decodable { let representations: [Representation] }
        let json = Data(#"{"representations":[{"kind":"forwarded_audio_and_text"}]}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Record.self, from: json)
            XCTFail("expected a decoding error")
        } catch {
            XCTAssertEqual(SharedMarginsImportMessage.userFacing(error), SharedMarginsImportMessage.unreadablePackageMessage)
            let detail = SharedMarginsImportMessage.diagnosticDetail(error)
            XCTAssertTrue(detail.hasPrefix("decoding:representations.0.kind:"), detail)
            XCTAssertTrue(detail.contains("forwarded_audio_and_text"), detail)
        }
    }

    /// Co-op (#468): three friends' packets on one episode, the podcast not yet in the Library, opened in
    /// the order 2, 3, 1 through the model's import path, leave exactly one podcast item carrying all three.
    @MainActor
    func testThreeSendersPacketsOnOneEpisodeAddThePodcastOnce() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-coop-three-packets")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let senders: [(name: String, digest: String?)] = [
            ("Ana", String(repeating: "a1", count: 32)), ("Ben", nil), ("Cleo", nil),
        ]
        let packets = try senders.map { sender -> (URL, SpokenMarginsPackageManifest) in
            let url = root.appendingPathComponent("\(sender.name).spokenmargins")
            let manifest = try writePodcastPackage(
                to: url, packageID: "package-coop-\(sender.name.lowercased())",
                sender: sender.name, exactEditionSHA256: sender.digest
            )
            return (url, manifest)
        }
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        XCTAssertFalse(try store.listItems().contains { $0.media?.url == Self.podcastAudioURL })

        var podcastId: String?
        for index in [1, 2, 0] {
            model.handleIncomingURL(packets[index].0)
            // The second and third packets find the podcast the first one added, rather than adding it again.
            XCTAssertEqual(model.spokenMarginsPackageImportReview?.matchingItemId, podcastId, senders[index].name)
            model.confirmSpokenMarginsPackageImport()
            try await waitForImportToFinish(model)
            XCTAssertNil(model.spokenMarginsPackageImportError, senders[index].name)
            podcastId = try store.listItems().first { $0.media?.url == Self.podcastAudioURL }?.id
            XCTAssertNotNil(podcastId, senders[index].name)
        }

        let podcasts = try store.listItems().filter { $0.media?.url == Self.podcastAudioURL }
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(model.libraryItems.filter { $0.title == Self.podcastTitle }.count, 1)
        let layers = try store.loadImportedCommentaryLayers(itemId: try XCTUnwrap(podcasts.first?.id))
        XCTAssertEqual(Set(layers.compactMap(\.displayLabel)), ["Ana", "Ben", "Cleo"])
        XCTAssertEqual(Set(layers.map(\.packageDigest)), Set(packets.compactMap { $0.1.contentDigest }))

        // Opening one again adds nothing.
        model.handleIncomingURL(packets[0].0)
        XCTAssertNil(model.spokenMarginsPackageImportReview)
        XCTAssertEqual(
            model.diagnostics["lastSpokenMarginsPackageImport"],
            "duplicate:\(try XCTUnwrap(packets[0].1.contentDigest))"
        )
        XCTAssertEqual(try store.listItems().filter { $0.media?.url == Self.podcastAudioURL }.count, 1)
        XCTAssertEqual(try store.loadImportedCommentaryLayers().count, 3)
    }

    @MainActor
    private func makePackageImport(
        named name: String,
        resolver: LinkResolutionClient
    ) throws -> (Gate1AppModel, SQLiteSessionStore, SpokenMarginsPackageManifest) {
        let root = try temporaryDirectory(named: "spoken-margins-\(name)")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("\(name).spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-\(name)")
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        model.handleIncomingURL(packageURL)
        XCTAssertNil(model.spokenMarginsPackageImportReview?.matchingItemId)
        return (model, store, manifest)
    }

    private func reviewResolver(candidates: [LinkResolutionCandidate]) -> PackagePodcastLinkResolver {
        PackagePodcastLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .needsReview,
            originalLink: SourceLink(url: Self.podcastURL, provider: "podcasts.example.com", role: "discovery"),
            selectedCandidate: nil,
            candidates: candidates,
            failureReason: "audio_enclosure_not_found"
        ))
    }

    @MainActor
    func testReopeningCorruptedWrongSourcePackageRepairsItsItemAssociation() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-package-repair")
        // Background model work can retain SQLite; let the process close it before cleanup.
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("repair-episode.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-repair-episode")
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let wrongItemID = model.selectedItem.id
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let extracted = root.appendingPathComponent("corrupt-import-assets", isDirectory: true)
        let contents = try SpokenMarginsPackageArchive.read(from: packageURL, extractingAssetsTo: extracted)
        _ = try SpokenMarginsPackageImporter.importPackage(
            contents,
            itemId: wrongItemID,
            localItem: SharedItemIdentity(
                itemType: .text,
                canonicalURL: "https://example.com/wrong-item",
                title: "Wrong item"
            ),
            itemText: "Wrong item text",
            repository: store
        )
        let digest = try XCTUnwrap(manifest.contentDigest)
        XCTAssertEqual(try store.loadImportedCommentaryLayer(packageDigest: digest)?.sourceResolutionStatus, .wrongSource)

        model.handleIncomingURL(packageURL)

        XCTAssertNotNil(model.spokenMarginsPackageImportReview)
        XCTAssertTrue(model.diagnostics["lastSpokenMarginsPackageImport"]?.hasPrefix("repair_previewed:") == true)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let importedItem = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let repairedLayer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: digest))
        XCTAssertNotEqual(repairedLayer.itemId, wrongItemID)
        XCTAssertEqual(repairedLayer.itemId, importedItem.id)
        XCTAssertNotEqual(repairedLayer.sourceResolutionStatus, .wrongSource)
        XCTAssertEqual(model.selectedItem.id, importedItem.id)
        XCTAssertEqual(model.diagnostics["lastSpokenMarginsPackageRepair"], "reassociated:\(repairedLayer.id):\(importedItem.id)")
    }

    func testImportedAssetPathRebasesAfterApplicationContainerRelocation() throws {
        let root = try temporaryDirectory(named: "spoken-margins-relocated-assets")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let relativePath = "SpokenMargins/IncomingPackages/package/assets/margin.m4a"
        let relocated = support.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: relocated.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("voice".utf8).write(to: relocated)
        let stalePath = "/old/container/Library/Application Support/\(relativePath)"

        XCTAssertEqual(
            Gate1AppModel.resolvedApplicationSupportAssetURL(
                for: stalePath,
                applicationSupportDirectory: support
            ),
            relocated
        )
        XCTAssertEqual(
            Gate1AppModel.resolvedInterjectionAudioURL(
                for: stalePath,
                applicationSupportDirectory: support
            ),
            relocated,
            "The Margin voice player must use the relocated file, not the stale container path."
        )
        XCTAssertNil(Gate1AppModel.resolvedInterjectionAudioURL(
            for: "/old/container/Library/Application Support/SpokenMargins/IncomingPackages/package/assets/missing.m4a",
            applicationSupportDirectory: support
        ))
    }

    func testWeakerPodcastEvidenceRetainsPositionOnlyForSameKnownAudioEdition() throws {
        let previous = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 45_000)
        let absent = ImportedAnchorResolution(evidenceClass: .unresolved)
        for (old, current) in [("old", "new"), (nil, "new"), (nil, nil)] as [(String?, String?)] {
            let result = PodcastAnchorFusionResolver.preservingVerifiedPlacement(previous: previous, proposed: absent,
                previousEdition: old, currentEdition: current, hasTranscript: false)
            XCTAssertEqual(result.evidenceClass, .unresolved)
            XCTAssertNil(result.localMediaTimeMs)
        }
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(previous: previous, proposed: absent,
            previousEdition: "same", currentEdition: "same", hasTranscript: false), previous)
        let moved = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 65_000)
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(previous: previous, proposed: moved,
            previousEdition: "old", currentEdition: "new", hasTranscript: true), moved)
    }

    func testReplacingRecipientEditionInvalidatesDurablePlacementsAndProjection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let layer = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "package-digest",
            packageId: "package", itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            importedAt: Date(), sourceResolutionStatus: .resolved, isEnabled: true,
            resolvedRecipientEditionSHA256: "old")
        try store.saveImportedCommentaryLayer(layer)
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(id: "note", layerId: layer.id,
            packageScopedId: "note", createdAt: Date(), anchorEvidence: PortableAnchorEvidence(anchorType: .media),
            approvedTranscript: "Preserve my words", resolution: ImportedAnchorResolution(
                evidenceClass: .acousticVerified, localMediaTimeMs: 45_000)))
        try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(id: "projection", itemId: "item",
            recipientEditionSHA256: "old", algorithmVersion: "episode-projection.exact-edition.v1", points: [], intervals: []))
        try store.invalidateImportedPodcastPlacements(itemId: "item", editionSHA256: "old")
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: layer.id).first?.resolution.localMediaTimeMs, 45_000)
        try store.invalidateImportedPodcastPlacements(itemId: "item", editionSHA256: "new")
        let reopened = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let note = try XCTUnwrap(reopened.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertEqual(note.approvedTranscript, "Preserve my words")
        XCTAssertNil(note.resolution.localMediaTimeMs)
        XCTAssertEqual(note.resolution.evidenceClass, .unresolved)
        XCTAssertEqual(try reopened.loadImportedCommentaryLayers(itemId: "item").first?.sourceResolutionStatus, .pending)
        XCTAssertNil(try reopened.loadResolvedListeningMapProjection(itemId: "item")?.projectedRecipientTime(for: 45_000))
        let encoded = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(ImportedCommentaryLayer.self, from: encoded).resolvedRecipientEditionSHA256, "old")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "resolvedRecipientEditionSHA256")
        XCTAssertNil(try JSONDecoder().decode(ImportedCommentaryLayer.self, from: JSONSerialization.data(withJSONObject: legacy)).resolvedRecipientEditionSHA256)
    }

    func testMixedImportedLayerKeepsItsVerifiedMarginsPlaybackEligible() {
        let layer = ImportedCommentaryLayer(
            id: "layer",
            itemId: "item",
            packageDigest: "digest",
            packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            importedAt: Date(),
            sourceResolutionStatus: .ambiguous,
            isEnabled: true
        )
        let resolved = ImportedCommentaryInterjection(
            id: "resolved",
            layerId: layer.id,
            packageScopedId: "margin-1",
            createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000),
            approvedTranscript: "Resolved",
            resolution: ImportedAnchorResolution(
                evidenceClass: .acousticVerified,
                localMediaTimeMs: 1_050,
                confidence: 0.9
            )
        )
        let absent = ImportedCommentaryInterjection(
            id: "absent",
            layerId: layer.id,
            packageScopedId: "margin-2",
            createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 2_000),
            approvedTranscript: "Absent",
            resolution: ImportedAnchorResolution(evidenceClass: .absentFromRecipientEdition)
        )

        XCTAssertTrue(Gate1AppModel.isImportedCommentaryLayerPlaybackEligible(
            layer,
            records: [resolved, absent]
        ))
        XCTAssertFalse(Gate1AppModel.isImportedCommentaryLayerPlaybackEligible(
            layer,
            records: [absent]
        ))
    }

    @MainActor
    func testImportedPodcastRequestsTranscriptFallbackAndResolvesFuzzyContext() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-transcript-fallback")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("transcript-fallback.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-transcript-fallback")
        let transcriber = PackageAnchorTranscriptionClient()
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber,
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        model.handleIncomingURL(packageURL)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let item = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let localURL = root.appendingPathComponent("recipient.mp3")
        try Data("recipient-edition".utf8).write(to: localURL)
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Startup work may outlive this case. Never unlink an open SQLite/WAL
            // file; any retained UUID fixture remains in the test host's temp area.
            if model == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
        let digest = try XCTUnwrap(manifest.contentDigest)
        let importedLayer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: digest))
        let importedMargin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: importedLayer.id).first)
        XCTAssertTrue(PodcastTranscriptAnchorResolver.hasUsableContext(importedMargin.anchorEvidence))
        model.podcastLocalAssetDidBecomeReady(itemId: item.id, url: localURL)
        for _ in 0..<250 {
            if await transcriber.fullRequestCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let fullRequestCount = await transcriber.fullRequestCount()
        XCTAssertEqual(fullRequestCount, 1)

        for _ in 0..<250 {
            if try store.loadImportedCommentaryLayer(packageDigest: digest)?.sourceResolutionStatus == .resolved {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: digest))
        let margin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertEqual(model.diagnostics["sourceTranscriptionAfterDownload:\(item.id)"], "requested_for_imported_commentary")
        XCTAssertEqual(layer.sourceResolutionStatus, .resolved)
        XCTAssertEqual(margin.resolution.evidenceClass, .transcriptVerified)
        XCTAssertEqual(margin.resolution.localMediaTimeMs, 5_500)
        XCTAssertNil(try store.loadTranscriptTimeline(itemId: item.id))
        XCTAssertEqual(model.diagnostics["recipientAlignmentTranscript:\(item.id)"], "consumed_and_deleted")
    }

    /// #916: a packet shared by link for a web article the recipient hasn't added fetches the article and
    /// attaches the Margins to it, instead of saving a layer with no item and reporting success.
    @MainActor
    func testArticlePackageFetchesTheArticleAndAttachesItsMargins() async throws {
        let (model, store, manifest, extractor) = try makeArticlePackageImport(named: "article-fetch", extraction: .success(
            BrowserTextHandoff(
                captureMode: .readablePage,
                source: BrowserTextSource(url: Self.articleURL, title: Self.articleTitle),
                text: "# \(Self.articleTitle)\n\nBefore it the durable prefix has exactly enough unique words here and then the following suffix is also uniquely present right now.",
                contentFormat: .markdown
            )
        ))
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        XCTAssertEqual(extractor.requested.map(\.absoluteString), [Self.articleURL])
        let imported = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.articleTitle }))
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)))
        XCTAssertEqual(layer.itemId, imported.id)
        XCTAssertNotEqual(layer.sourceResolutionStatus, .wrongSource)
        XCTAssertNil(model.spokenMarginsPackageImportError)
        XCTAssertEqual(model.selectedItem.id, imported.id)
        XCTAssertNil(model.snapshot.sessionId, "Import must not start playback")
    }

    @MainActor
    func testArticlePackageThatCannotBeFetchedFailsInsteadOfSavingMarginsWithNoSource() async throws {
        let (model, store, manifest, _) = try makeArticlePackageImport(
            named: "article-unreadable",
            extraction: .failure(ReadablePageExtractionError.httpStatus(403))
        )
        model.confirmSpokenMarginsPackageImport()
        for _ in 0..<250 where model.spokenMarginsPackageImportError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(
            model.spokenMarginsPackageImportError,
            SharedMarginsImportMessage.userFacing(SessionKitError.persistenceFailed("shared_article_unreadable")),
            "diagnostic: \(model.diagnostics["lastSpokenMarginsPackageImport"] ?? "none")"
        )
        XCTAssertNil(try store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)), "no layer without a source")
        // Not the whole id list: a background fetch (the guided tour) can add its own row mid-test (#878).
        XCTAssertFalse(model.libraryItems.contains { $0.title == Self.articleTitle }, "the article was not added")
        XCTAssertNotNil(model.spokenMarginsPackageImportReview, "the sheet stays open so the listener can retry")
        model.cancelSpokenMarginsPackageImport()
    }

    /// The link redirects to a consent wall that answers 200: the wall must not be saved as the article.
    @MainActor
    func testArticlePackageWhoseLinkLandsOnAnotherPageFailsInsteadOfSavingItAsTheArticle() async throws {
        let (model, store, manifest, _) = try makeArticlePackageImport(named: "article-consent-wall", extraction: .success(
            BrowserTextHandoff(
                captureMode: .readablePage,
                source: BrowserTextSource(url: "https://consent.example.com/collect?next=story", title: "Before you continue"),
                text: "# Before you continue\n\nWe value your privacy.",
                contentFormat: .markdown
            )
        ))
        model.confirmSpokenMarginsPackageImport()
        for _ in 0..<250 where model.spokenMarginsPackageImportError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(
            model.spokenMarginsPackageImportError,
            SharedMarginsImportMessage.userFacing(SessionKitError.persistenceFailed("shared_article_unreadable")),
            "diagnostic: \(model.diagnostics["lastSharedArticleAcquisition"] ?? "none")"
        )
        XCTAssertNil(try store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)))
        XCTAssertFalse(model.libraryItems.contains { $0.title == "Before you continue" }, "the wall was not added")
        model.cancelSpokenMarginsPackageImport()
    }

    private static let articleTitle = "A shared essay on slow listening"
    private static let articleURL = "https://essays.example.com/slow-listening"

    @MainActor
    private func makeArticlePackageImport(
        named name: String,
        extraction: Result<BrowserTextHandoff, Error>
    ) throws -> (Gate1AppModel, SQLiteSessionStore, SpokenMarginsPackageManifest, ArticlePackageExtractor) {
        let root = try temporaryDirectory(named: "spoken-margins-\(name)")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("\(name).spokenmargins")
        let manifest = try writePodcastPackage(
            to: packageURL,
            packageID: "package-\(name)",
            item: SharedItemIdentity(
                itemType: .text,
                canonicalURL: Self.articleURL,
                originalURL: Self.articleURL,
                title: Self.articleTitle
            ),
            anchor: PortableAnchorEvidence(
                anchorType: .text,
                prefix: "the durable prefix has exactly enough unique words here",
                suffix: "the following suffix is also uniquely present right now"
            )
        )
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let extractor = ArticlePackageExtractor(extraction)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        model.readablePageExtractor = extractor
        model.handleIncomingURL(packageURL)
        XCTAssertNotNil(model.spokenMarginsPackageImportReview)
        XCTAssertNil(model.spokenMarginsPackageImportReview?.matchingItemId)
        return (model, store, manifest, extractor)
    }

    /// #914: the download finishing mid-session must not move the Margins onto a file the listener isn't hearing.
    /// Placement waits for the session that kept the stream to end, then runs against the download.
    @MainActor
    func testDownloadFinishingDuringAStreamingSessionDefersPlacementUntilTheSessionEnds() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-stream-then-download")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("stream-then-download.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-stream-then-download")
        let transcriber = PackageAnchorTranscriptionClient()
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber,
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        model.handleIncomingURL(packageURL)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let item = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let store = try model.libraryStoreForTesting()
        let digest = try XCTUnwrap(manifest.contentDigest)
        model.declineCurrentTerms()
        model.startItem(id: item.id)
        XCTAssertEqual(model.snapshot.itemId, item.id)
        XCTAssertNotNil(model.snapshot.sessionId, "the listener is streaming")

        let localURL = root.appendingPathComponent("recipient.mp3")
        try Data("recipient-edition".utf8).write(to: localURL)
        model.podcastLocalAssetDidBecomeReady(itemId: item.id, url: localURL)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(model.diagnostics["podcastPlacementDeferred:\(item.id)"], "session_keeps_its_edition")
        // The caller decides this before the background placement pass has recorded its own deferral (#2507).
        XCTAssertEqual(model.diagnostics["sourceTranscriptionAfterDownload:\(item.id)"], "not_requested",
                       "a download the session does not play gets no transcript, and the episode-map branch still runs")
        let requestsWhileStreaming = await transcriber.fullRequestCount()
        XCTAssertEqual(requestsWhileStreaming, 0, "nothing is placed against the download while the stream plays")
        XCTAssertNotEqual(try store.loadImportedCommentaryLayer(packageDigest: digest)?.sourceResolutionStatus, .resolved)

        model.endSession()
        for _ in 0..<250 {
            if try store.loadImportedCommentaryLayer(packageDigest: digest)?.sourceResolutionStatus == .resolved { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.diagnostics["podcastPlacementDeferred:\(item.id)"], "resumed_after_session_change")
        XCTAssertEqual(try store.loadImportedCommentaryLayer(packageDigest: digest)?.sourceResolutionStatus, .resolved)
    }

    /// #915, #1255: a placement pass copies each layer when it starts and publishes minutes later. What the
    /// listener changes in between must stand: the pass writes only its own placement fields, and a layer
    /// deleted meanwhile stays deleted. The pass reads its copies off the main thread (#2507), so the test awaits
    /// the request until the pass is scheduled, then makes every change below without yielding the main actor. The
    /// pass can publish only on the main actor, so each change lands after the copy and before the publish.
    @MainActor
    func testAPlacementPassKeepsTheListenersChangesMadeWhileItRuns() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-held-placement-pass")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packets = try ["Ana", "Ben"].map { sender in
            try writePodcastPackage(
                to: root.appendingPathComponent("\(sender).spokenmargins"),
                packageID: "package-held-pass-\(sender.lowercased())", sender: sender
            )
        }
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        for sender in ["Ana", "Ben"] {
            model.handleIncomingURL(root.appendingPathComponent("\(sender).spokenmargins"))
            model.confirmSpokenMarginsPackageImport()
            try await waitForImportToFinish(model)
            XCTAssertNil(model.spokenMarginsPackageImportError, sender)
        }
        let item = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Never unlink an open SQLite/WAL file; a retained fixture stays in the test host's temp area.
            if model == nil, store == nil { try FileManager.default.removeItem(at: root) }
        }
        let kept = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: XCTUnwrap(packets[0].contentDigest)))
        let deleted = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: XCTUnwrap(packets[1].contentDigest)))
        XCTAssertEqual(kept.itemId, item.id)
        XCTAssertEqual(deleted.itemId, item.id)
        XCTAssertNil(kept.resolvedRecipientEditionSHA256, "no pass has run before the download")
        XCTAssertNotEqual(kept.sourceResolutionStatus, .resolved)
        XCTAssertTrue(kept.isEnabled, "an imported layer starts on")
        XCTAssertNotEqual(kept.revealMode, .guided)

        let localURL = root.appendingPathComponent("recipient.mp3")
        try Data("recipient-edition".utf8).write(to: localURL)
        let recipientDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
        // The transcript the alignment pass would hand over, so this one pass places the Margins.
        let outcome = await model.importedPodcastPlacement.resolveAndWait(
            itemId: item.id, localURL: localURL,
            recipientTranscriptOverride: PackageAnchorTranscriptionClient.recipientTimeline(durationMs: 300_000)
        )
        XCTAssertEqual(outcome, .scheduled(joined: false))
        let key = "importedPodcastAnchorResolution:\(item.id)"
        XCTAssertEqual(model.diagnostics[key], "scheduled:2", "the pass has copied both layers")

        // While it runs: the listener turns one layer off, switches its reveal mode, and deletes the other.
        model.setImportedCommentaryLayerEnabled(kept.id, enabled: false)
        model.setImportedCommentaryRevealMode(kept.id, mode: .guided)
        // The app has no delete control for a shared layer today (3d52686c removed the unused entry point);
        // this is the same write it made.
        var removed = try XCTUnwrap(store.loadImportedCommentaryLayer(id: deleted.id))
        removed.deletedAt = Date()
        removed.isEnabled = false
        try store.saveImportedCommentaryLayer(removed)
        XCTAssertEqual(model.diagnostics[key], "scheduled:2", "the pass has not published yet")

        // Release the pass.
        for _ in 0..<500 where model.diagnostics[key]?.hasPrefix("complete") != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.diagnostics[key]?.hasPrefix("complete:1/1"), true, model.diagnostics[key] ?? "never published")

        let keptAfter = try XCTUnwrap(store.loadImportedCommentaryLayer(id: kept.id))
        XCTAssertFalse(keptAfter.isEnabled, "turning the layer off stands")
        XCTAssertEqual(keptAfter.revealMode, .guided, "the reveal mode stands")
        XCTAssertEqual(keptAfter.sourceResolutionStatus, .resolved, "the pass's own result is saved")
        XCTAssertEqual(keptAfter.resolvedRecipientEditionSHA256, recipientDigest)
        let keptMargin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: kept.id).first)
        XCTAssertEqual(keptMargin.resolution.evidenceClass, .transcriptVerified)

        let deletedAfter = try XCTUnwrap(store.loadImportedCommentaryLayer(id: deleted.id))
        XCTAssertNotNil(deletedAfter.deletedAt, "the deleted layer does not come back")
        XCTAssertFalse(deletedAfter.isEnabled, "the deleted layer cannot play")
        XCTAssertNil(deletedAfter.resolvedRecipientEditionSHA256, "the pass wrote nothing onto the deleted layer")
        let deletedMargin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: deleted.id).first)
        XCTAssertNotEqual(deletedMargin.resolution.evidenceClass, .transcriptVerified, "nor onto its Margins")
    }

    private static let podcastTitle = "Can you spot the imported story?"
    private static let podcastURL = "https://podcasts.example.com/episodes/imported-story"
    private static let podcastAudioURL = "https://cdn.example.com/imported-story.mp3"

    private func podcastResolver() -> PackagePodcastLinkResolver {
        PackagePodcastLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: Self.podcastURL, provider: "podcast", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://podcasts.example.com/feed.xml", provider: "rss", role: "canonical_feed"),
                title: Self.podcastTitle,
                durationMs: 300_000,
                audioURL: Self.podcastAudioURL,
                confidence: 1
            )
        ))
    }

    private func writePodcastPackage(
        to url: URL,
        packageID: String,
        sender: String = "Cole",
        exactEditionSHA256: String? = nil,
        item: SharedItemIdentity? = nil,
        anchor: PortableAnchorEvidence? = nil
    ) throws -> SpokenMarginsPackageManifest {
        let revision = InterjectionShareRevision(
            id: "revision-\(packageID)",
            interjectionId: "sender-margin",
            itemId: "sender-item",
            sessionId: "sender-session",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            approvedTranscript: "A sender-reviewed observation.",
            anchorBefore: "the durable prefix has exactly enough unique words here",
            anchorAfter: "the following suffix is also uniquely present right now",
            status: .senderApproved
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: packageID,
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            item: item ?? SharedItemIdentity(
                itemType: .podcast,
                canonicalURL: Self.podcastURL,
                originalURL: Self.podcastURL,
                title: Self.podcastTitle,
                enclosureURL: Self.podcastAudioURL,
                durationMs: 300_000,
                exactEditionSHA256: exactEditionSHA256
            ),
            itemTransportSelection: .reference,
            selections: [ReviewedInterjectionSelection(
                packageScopedId: "margin-001",
                revision: revision,
                anchor: anchor ?? PortableAnchorEvidence(
                    anchorType: .transcript,
                    prefix: "the durable prefix has exactly enough unique words here",
                    suffix: "the following suffix is also uniquely present right now",
                    mediaTimeMs: 5_000
                ),
                representation: .textOnly
            )],
            senderDisplayLabel: sender,
            suggestedRevealMode: .companion
        )
        return try SpokenMarginsPackageArchive.write(prepared, to: url)
    }

    private func temporaryDirectory(named prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func waitForImportToFinish(_ model: Gate1AppModel) async throws {
        for _ in 0..<250 {
            if model.spokenMarginsPackageImportReview == nil, !model.isImportingSpokenMarginsPackage {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the package import to finish: \(model.spokenMarginsPackageImportError ?? "no error")")
        throw SessionKitError.persistenceFailed("package_import_test_timeout")
    }
}

private actor PackageAnchorTranscriptionClient: SourceTranscriptionClient {
    private var requestCount = 0

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        requestCount += 1
        return Self.recipientTimeline(durationMs: durationMs)
    }

    /// The recipient's words around the sender's Margin, close enough for the fuzzy context match.
    static func recipientTimeline(durationMs: Int?) -> TranscriptTimeline {
        TranscriptTimeline(
            segments: [
                .init(
                    id: "recipient-prefix",
                    startMs: 4_000,
                    endMs: 5_000,
                    text: "the durable prefix has nearly enough unique words here"
                ),
                .init(
                    id: "recipient-suffix",
                    startMs: 6_000,
                    endMs: 7_000,
                    text: "the following suffix was also uniquely present right now"
                )
            ],
            chapters: [],
            durationMs: durationMs
        )
    }

    func fullRequestCount() -> Int {
        requestCount
    }
}

private final class PackagePodcastLinkResolver: LinkResolutionClient {
    private let result: LinkResolutionResult

    init(result: LinkResolutionResult) {
        self.result = result
    }

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: result.status,
            originalLink: SourceLink(
                url: request.inputURL,
                provider: result.originalLink.provider,
                title: result.originalLink.title,
                role: result.originalLink.role
            ),
            selectedCandidate: result.selectedCandidate,
            candidates: result.candidates,
            failureReason: result.failureReason
        )
    }
}

private final class FailingPackagePodcastLinkResolver: LinkResolutionClient {
    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        throw URLError(.badServerResponse)
    }
}

private final class ArticlePackageExtractor: ReadablePageExtracting {
    private let outcome: Result<BrowserTextHandoff, Error>
    private(set) var requested: [URL] = []
    private(set) var lastExtractor: String?
    private(set) var contactedHosts: [String] = []

    init(_ outcome: Result<BrowserTextHandoff, Error>) {
        self.outcome = outcome
    }

    func extract(url: URL) async throws -> BrowserTextHandoff {
        requested.append(url)
        contactedHosts = [url.host ?? ""]
        let handoff = try outcome.get()
        lastExtractor = "recorded"
        return handoff
    }
}

@MainActor
private final class ShareLinkFailureLog {
    var first: [String] = []
    var second: [String] = []
}

/// Holds a stub download until the test answers it. The wait ignores cancellation on purpose: it stands
/// for a server reply that is already on its way when the listener taps another link.
private final class ShareLinkAnswerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting = false
    private var released = false

    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    var answered: Bool { lock.lock(); defer { lock.unlock() }; return released }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            waiting = true
            lock.unlock()
        }
    }

    func answer() {
        lock.lock()
        released = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class ShareLinkRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(url)
    }

    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return recorded }
}
