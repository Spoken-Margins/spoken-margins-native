import Combine
import XCTest
@testable import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
@testable import SpokenMarginsApp

/// The packet import flow without `Gate1AppModel` (T5, #963): real packet files, a real SQLite store and a real
/// Application Support folder, with the app's side of the flow recorded by `ImportHarness`.
@MainActor
final class SpokenMarginsPackageImportCoordinatorTests: XCTestCase {
    // MARK: Stage

    func testStageShowsAnEmbeddedPacketForReviewAndLeavesTheLibraryAlone() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)

        assertStaged(await h.coordinator.stage(from: packet.url))

        let review = try XCTUnwrap(h.coordinator.review)
        XCTAssertEqual(review.contents.manifest.packageId, "package-alpha")
        XCTAssertNil(review.matchingItemId)
        XCTAssertFalse(h.coordinator.isImporting)
        XCTAssertNil(h.coordinator.importError)
        XCTAssertEqual(h.diagnostics["lastSpokenMarginsPackageImport"], "previewed:\(packet.digest)")
        XCTAssertNil(try h.store.loadImportedCommentaryLayer(packageDigest: packet.digest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.packageURL.path))
        XCTAssertEqual(review.extractionDirectory.deletingLastPathComponent().path, h.incomingDirectory.path)
        XCTAssertEqual(h.events, ["error:nil", "review:\(review.id)"], "the error clears before the review shows, once each")
    }

    func testUnreadablePacketIsRejectedAndLeavesNoFolderBehind() async throws {
        let h = try makeHarness()
        let junk = h.root.appendingPathComponent("junk.spokenmargins")
        try Data("not a zip".utf8).write(to: junk)

        guard case .rejected = await h.coordinator.stage(from: junk) else { return XCTFail("a corrupt packet must be rejected") }

        XCTAssertNil(h.coordinator.review)
        XCTAssertTrue(h.diagnostics["lastSpokenMarginsPackageImport"]?.hasPrefix("rejected:") == true)
        XCTAssertEqual(h.failures.count, 1)
        XCTAssertEqual(h.incomingFolderNames(), [], "a failed stage removes the folder it made")
        XCTAssertTrue(h.events.isEmpty, "nothing was published")
    }

    func testStagingTheSamePacketAfterImportOpensItsItemAndRemovesTheNewFolder() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        assertStaged(await h.coordinator.stage(from: packet.url))
        let firstFolder = try XCTUnwrap(h.coordinator.review).extractionDirectory
        await h.confirmCurrentReview()
        XCTAssertEqual(h.shownItems.count, 1)
        h.events.removeAll()

        assertStaged(await h.coordinator.stage(from: packet.url))

        XCTAssertEqual(h.openedItems, h.shownItems, "the existing item opens")
        XCTAssertEqual(h.diagnostics["lastSpokenMarginsPackageImport"], "duplicate:\(packet.digest)")
        XCTAssertEqual(h.successes.last, "These shared Margins are already in your library. Playback has not started.")
        XCTAssertNil(h.coordinator.review, "a duplicate is never shown for review")
        XCTAssertEqual(h.incomingFolderNames(), [firstFolder.lastPathComponent], "only the first import's folder is left")
        XCTAssertTrue(h.events.isEmpty)
    }

    // MARK: Listening Map packets (#1471)

    func testAMapPacketForAnArticleInTheLibraryIsMatchedAndAddsChaptersWithoutMargins() async throws {
        let h = try makeHarness()
        let item = try h.seedArticle(id: "mine", reference: "https://example.com/harbour")
        let packet = try h.writeMapPacket(named: "map-a")

        assertStaged(await h.coordinator.stage(from: packet.url))

        let review = try XCTUnwrap(h.coordinator.review)
        XCTAssertTrue(review.isListeningMap)
        XCTAssertEqual(review.mapChapterCount, 5)
        XCTAssertEqual(review.matchingItemId, item.id)
        XCTAssertFalse(review.replacesExistingMap)
        XCTAssertFalse(review.requiresRecipientItem)

        await h.confirmCurrentReview()

        XCTAssertEqual(try h.store.loadListeningMap(itemId: item.id)?.chapters.count, 5)
        XCTAssertEqual(try h.store.loadPortableListeningMapProposals(itemId: item.id).first?.id, "map-a")
        XCTAssertEqual(try h.store.loadImportedCommentaryLayers(itemId: item.id).count, 0, "a map makes no Margin layer")
        XCTAssertEqual(h.shownItems, [item.id])
        XCTAssertEqual(h.confirmations.last, "Added the Listening Map: 5 chapters. Playback has not started.")
        XCTAssertNil(h.coordinator.review)
        XCTAssertFalse(h.coordinator.isImporting)
        XCTAssertTrue(h.packetImports.isEmpty)
    }

    func testAddingTheSameMapAgainSaysItIsAlreadyThereAndDuplicatesNothing() async throws {
        let h = try makeHarness()
        let item = try h.seedArticle(id: "mine", reference: "https://example.com/harbour")
        let packet = try h.writeMapPacket(named: "map-a")
        assertStaged(await h.coordinator.stage(from: packet.url))
        await h.confirmCurrentReview()
        assertStaged(await h.coordinator.stage(from: packet.url))

        await h.confirmCurrentReview()

        XCTAssertEqual(h.confirmations.last, "This Listening Map is already on your copy (5 chapters). Playback has not started.")
        XCTAssertEqual(try h.store.loadPortableListeningMapProposals(itemId: item.id).count, 1)
    }

    func testAnotherMapIsOfferedAsAReplacementAndReplacesTheFirst() async throws {
        let h = try makeHarness()
        let item = try h.seedArticle(id: "mine", reference: "https://example.com/harbour")
        assertStaged(await h.coordinator.stage(from: try h.writeMapPacket(named: "map-a").url))
        await h.confirmCurrentReview()

        assertStaged(await h.coordinator.stage(from: try h.writeMapPacket(named: "map-b").url))

        XCTAssertEqual(h.coordinator.review?.replacesExistingMap, true, "the sheet says Replace Map before anything changes")
        XCTAssertEqual(try h.store.loadPortableListeningMapProposals(itemId: item.id).map(\.id), ["map-a"])
        await h.confirmCurrentReview()
        XCTAssertEqual(try h.store.loadPortableListeningMapProposals(itemId: item.id).map(\.id), ["map-b"], "the new map is the only one left")
        XCTAssertEqual(h.confirmations.last, "Added the Listening Map: 5 chapters. Playback has not started.")
    }

    func testAMapForAnArticleNotInTheLibraryFetchesItFirst() async throws {
        let h = try makeHarness()
        let fetched = Item(id: "fetched", title: "The Harbour Town", mediaType: "text", text: Self.harbourText,
                           externalReference: "https://example.com/harbour", status: "ready", externalReferenceType: "url")
        var fetchedFor: [String?] = []
        h.acquireArticleHook = { identity in
            fetchedFor.append(identity.canonicalURL)
            try h.store.seed(item: fetched)
            return fetched.id
        }
        assertStaged(await h.coordinator.stage(from: try h.writeMapPacket(named: "map-a").url))
        XCTAssertNil(h.coordinator.review?.matchingItemId)
        XCTAssertEqual(h.coordinator.review?.requiresRecipientItem, false, "an article with a link is fetched, not asked for")

        await h.confirmCurrentReview()

        XCTAssertEqual(fetchedFor, ["https://example.com/harbour"])
        XCTAssertEqual(try h.store.loadListeningMap(itemId: "fetched")?.chapters.count, 5)
    }

    func testAMapForAPDFTheListenerLacksAsksThemToAddIt() async throws {
        let h = try makeHarness()
        let packet = try h.writeMapPacket(named: "map-pdf", itemType: .pdf, link: "https://example.com/harbour.pdf")

        assertStaged(await h.coordinator.stage(from: packet.url))

        let review = try XCTUnwrap(h.coordinator.review)
        XCTAssertNil(review.matchingItemId)
        XCTAssertTrue(review.requiresRecipientItem, "a PDF can't be fetched from a link, so the listener picks their copy")
        XCTAssertNil(h.coordinator.beginConfirmation())
    }

    func testAPickedPDFWithDifferentTextIsMatchedByWhereTheChaptersLand() async throws {
        let h = try makeHarness()
        let pdf = try h.seedArticle(id: "pdf", reference: "harbour.pdf", mediaType: "pdf", text: Self.harbourText.replacingOccurrences(of: "harbour", with: "harbor"))
        let packet = try h.writeMapPacket(named: "map-pdf", itemType: .pdf, link: nil)

        assertStaged(await h.coordinator.stage(from: packet.url))

        XCTAssertEqual(h.coordinator.review?.matchingItemId, pdf.id)
        XCTAssertEqual(h.coordinator.review?.requiresRecipientItem, false)
    }

    func testAMapThatDoesNotFitTheListenersCopySavesNothingAndSaysWhy() async throws {
        let h = try makeHarness()
        let item = try h.seedArticle(id: "mine", reference: "https://example.com/harbour",
                                     text: "A different edition with entirely other words about gardens and tea.")
        assertStaged(await h.coordinator.stage(from: try h.writeMapPacket(named: "map-a").url))
        XCTAssertEqual(h.coordinator.review?.matchingItemId, item.id, "matched by link")

        await h.confirmCurrentReview()

        XCTAssertNil(try h.store.loadListeningMap(itemId: item.id))
        XCTAssertEqual(try h.store.loadPortableListeningMapProposals(itemId: item.id).count, 0)
        XCTAssertEqual(h.coordinator.importError, SharedMarginsImportMessage.userFacing(SessionKitError.persistenceFailed("shared_map_not_found_in_item")))
        XCTAssertFalse(h.coordinator.isImporting)
        XCTAssertNotNil(h.coordinator.review, "the sheet stays so the listener can cancel")
    }

    func testTheAppGetsToSaveTheMapSoARunningSessionHearsAboutIt() async throws {
        let h = try makeHarness()
        let item = try h.seedArticle(id: "mine", reference: "https://example.com/harbour")
        assertStaged(await h.coordinator.stage(from: try h.writeMapPacket(named: "map-a").url))

        await h.confirmCurrentReview()

        XCTAssertEqual(h.attachedMaps.map(\.itemId), [item.id])
        XCTAssertEqual(h.attachedMaps.first?.chapters.count, 5)
    }

    func testARefusalFromThePlayingItemLeavesNoMapBehindAndCanBeTriedAgain() async throws {
        let h = try makeHarness()
        let item = try h.seedArticle(id: "mine", reference: "https://example.com/harbour")
        h.attachFailure = SessionKitError.persistenceFailed("shared_map_item_is_playing")
        assertStaged(await h.coordinator.stage(from: try h.writeMapPacket(named: "map-a").url))
        await h.confirmCurrentReview()

        XCTAssertEqual(h.coordinator.importError, SharedMarginsImportMessage.userFacing(SessionKitError.persistenceFailed("shared_map_item_is_playing")))
        XCTAssertEqual(try h.store.loadPortableListeningMapProposals(itemId: item.id).count, 0)

        h.attachFailure = nil
        await h.confirmCurrentReview()
        XCTAssertEqual(h.confirmations.last, "Added the Listening Map: 5 chapters. Playback has not started.")
    }

    // MARK: Cancel

    func testCancelClearsTheReviewAndRemovesItsFolder() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        assertStaged(await h.coordinator.stage(from: packet.url))
        let folder = try XCTUnwrap(h.coordinator.review).extractionDirectory

        h.coordinator.cancel()

        XCTAssertNil(h.coordinator.review)
        XCTAssertNil(h.coordinator.importError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(Array(h.events.suffix(2)), ["review:nil", "error:nil"])
    }

    func testCancelDoesNothingWhileAnImportIsRunning() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        assertStaged(await h.coordinator.stage(from: packet.url))
        let folder = try XCTUnwrap(h.coordinator.review).extractionDirectory
        _ = try XCTUnwrap(h.coordinator.beginConfirmation())

        h.coordinator.cancel()

        XCTAssertNotNil(h.coordinator.review)
        XCTAssertTrue(h.coordinator.isImporting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Confirm

    func testConfirmImportsAndKeepsTheIncomingFolderForGood() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        assertStaged(await h.coordinator.stage(from: packet.url))
        let review = try XCTUnwrap(h.coordinator.review)
        h.events.removeAll()

        let began = try XCTUnwrap(h.coordinator.beginConfirmation())
        XCTAssertEqual(began.id, review.id)
        XCTAssertTrue(h.coordinator.isImporting)
        XCTAssertEqual(h.events, ["importing:true", "error:nil"])
        h.events.removeAll()
        await h.coordinator.confirm(began)

        let itemId = "item-shared-\(packet.digest.prefix(20))"
        XCTAssertNotNil(try h.store.loadImportedCommentaryLayer(packageDigest: packet.digest))
        XCTAssertEqual(try h.store.loadItem(id: itemId).text, Self.alphaText)
        XCTAssertEqual(h.shownItems, [itemId])
        XCTAssertEqual(h.packetImports, [PacketImport(itemId: itemId, packetId: "package-alpha", marginCount: 1)])
        XCTAssertTrue(h.diagnostics["lastSpokenMarginsPackageImport"]?.hasPrefix("imported:") == true)
        XCTAssertEqual(h.confirmations, ["Imported shared Margins. Playback has not started."])
        XCTAssertNil(h.coordinator.review)
        XCTAssertFalse(h.coordinator.isImporting)
        XCTAssertEqual(h.events, ["review:nil", "importing:false"], "review clears, then the busy flag")
        // The folder rule (#956): success keeps what the import extracted. Only cancel, a failed stage, a duplicate
        // stage and the restore-audio task remove it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.extractionDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.packageURL.path))
        XCTAssertEqual(h.incomingFolderNames(), [review.extractionDirectory.lastPathComponent])
    }

    func testFailureAfterTheLayerIsSavedKeepsTheReviewAndTheRetryRepairsTheAssociation() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        assertStaged(await h.coordinator.stage(from: packet.url))
        let review = try XCTUnwrap(h.coordinator.review)
        h.showImportedItemFailure = StubFailure()

        await h.confirmCurrentReview()

        XCTAssertNotNil(try h.store.loadImportedCommentaryLayer(packageDigest: packet.digest), "the layer was saved before the failure")
        XCTAssertEqual(h.coordinator.review?.id, review.id, "the sheet stays open for a retry")
        XCTAssertFalse(h.coordinator.isImporting)
        XCTAssertNotNil(h.coordinator.importError)
        XCTAssertTrue(h.diagnostics["lastSpokenMarginsPackageImport"]?.hasPrefix("failed:") == true)
        XCTAssertEqual(h.failureContexts, ["Shared Margins import failed"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.extractionDirectory.path))

        h.showImportedItemFailure = nil
        await h.confirmCurrentReview()

        XCTAssertTrue(h.diagnostics["lastSpokenMarginsPackageRepair"]?.hasPrefix("reassociated:") == true)
        XCTAssertTrue(h.diagnostics["lastSpokenMarginsPackageImport"]?.hasPrefix("duplicate_layer:") == true)
        XCTAssertNil(h.coordinator.review)
        XCTAssertNil(h.coordinator.importError, "a retry clears the earlier error")
        XCTAssertEqual(h.shownItems.count, 1)
    }

    /// #2122: a packet opened while another imports waits its turn. A's success brings B up for review instead of
    /// clearing it, and B can then be imported.
    func testAPacketOpenedDuringAnImportWaitsAndIsShownWhenTheImportSucceeds() async throws {
        let h = try makeHarness()
        let a = try h.writePacket(named: "alpha", text: Self.alphaText)
        let b = try h.writePacket(named: "beta", text: Self.betaText)
        assertStaged(await h.coordinator.stage(from: a.url))
        let captured = try XCTUnwrap(h.coordinator.beginConfirmation())
        assertStaged(await h.coordinator.stage(from: b.url))
        XCTAssertEqual(h.coordinator.review?.id, captured.id, "A's review stays up while A imports")
        XCTAssertTrue(h.coordinator.isImporting)
        XCTAssertEqual(h.diagnostics["lastSpokenMarginsPackageImport"], "queued:\(b.digest)")
        XCTAssertEqual(h.confirmations.last, SpokenMarginsPackageImportCoordinator.waitingMessage, "the listener is told B waits")

        await h.coordinator.confirm(captured)

        XCTAssertNotNil(try h.store.loadImportedCommentaryLayer(packageDigest: a.digest), "A is what was imported")
        XCTAssertNil(try h.store.loadImportedCommentaryLayer(packageDigest: b.digest))
        let next = try XCTUnwrap(h.coordinator.review, "A's success must not clear B")
        XCTAssertEqual(next.contents.manifest.packageId, "package-beta")
        XCTAssertFalse(h.coordinator.isImporting)
        XCTAssertNil(h.coordinator.importError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.extractionDirectory.path), "B's staged files are kept for its review")

        await h.confirmCurrentReview()

        XCTAssertNotNil(try h.store.loadImportedCommentaryLayer(packageDigest: b.digest), "B imports after A")
        XCTAssertNil(h.coordinator.review)
    }

    /// #2122: A's failure stays on A's screen, never on B's; cancelling A brings B up, and cancelling B removes its files.
    func testAFailedImportKeepsItsErrorOnItsOwnReviewAndTheWaitingPacketSurvives() async throws {
        let h = try makeHarness()
        let a = try h.writePacket(named: "alpha", text: Self.alphaText)
        let b = try h.writePacket(named: "beta", text: Self.betaText)
        assertStaged(await h.coordinator.stage(from: a.url))
        let captured = try XCTUnwrap(h.coordinator.beginConfirmation())
        assertStaged(await h.coordinator.stage(from: b.url))
        h.showImportedItemFailure = StubFailure()

        await h.coordinator.confirm(captured)

        XCTAssertEqual(h.coordinator.review?.id, captured.id, "A stays showing, with its own error, for a retry or Cancel")
        XCTAssertNotNil(h.coordinator.importError)
        XCTAssertFalse(h.coordinator.isImporting)

        h.coordinator.cancel()

        let waiting = try XCTUnwrap(h.coordinator.review, "cancelling A brings up B")
        XCTAssertEqual(waiting.contents.manifest.packageId, "package-beta")
        XCTAssertNil(h.coordinator.importError, "A's error does not follow B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.extractionDirectory.path))

        h.coordinator.cancel()

        XCTAssertNil(h.coordinator.review)
        XCTAssertFalse(FileManager.default.fileExists(atPath: waiting.extractionDirectory.path), "B's staged files are removed, not leaked")
        XCTAssertTrue(h.incomingFolderNames().isEmpty)
    }

    /// #2122, the map-packet path: a map's success brings up the packet that waited behind it.
    func testAPacketOpenedDuringAMapImportIsShownWhenTheMapIsAdded() async throws {
        let h = try makeHarness()
        _ = try h.seedArticle(id: "mine", reference: "https://example.com/harbour")
        let map = try h.writeMapPacket(named: "map-a")
        let b = try h.writePacket(named: "beta", text: Self.betaText)
        assertStaged(await h.coordinator.stage(from: map.url))
        let captured = try XCTUnwrap(h.coordinator.beginConfirmation())
        assertStaged(await h.coordinator.stage(from: b.url))

        await h.coordinator.confirm(captured)

        XCTAssertEqual(h.coordinator.review?.contents.manifest.packageId, "package-beta", "the map's success must not clear B")
        XCTAssertFalse(h.coordinator.isImporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.extractionDirectory.path), "the map's own copy goes")
    }

    /// #2122: opening a second packet while the first is only showing does not drop the first or leak its files.
    func testAPacketOpenedWhileAnotherIsShowingWaitsBehindIt() async throws {
        let h = try makeHarness()
        let a = try h.writePacket(named: "alpha", text: Self.alphaText)
        let b = try h.writePacket(named: "beta", text: Self.betaText)
        assertStaged(await h.coordinator.stage(from: a.url))
        let first = try XCTUnwrap(h.coordinator.review)

        assertStaged(await h.coordinator.stage(from: b.url))

        XCTAssertEqual(h.coordinator.review?.id, first.id)
        h.coordinator.cancel()
        XCTAssertEqual(h.coordinator.review?.contents.manifest.packageId, "package-beta")
    }

    func testRecipientSuppliedPacketCannotBeConfirmedUntilASourceMatches() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "gamma", text: Self.alphaText, recipientSupplied: true)
        assertStaged(await h.coordinator.stage(from: packet.url))
        XCTAssertEqual(h.coordinator.review?.requiresRecipientItem, true)

        XCTAssertNil(h.coordinator.beginConfirmation())
        XCTAssertFalse(h.coordinator.isImporting)
        XCTAssertEqual(
            h.coordinator.importError,
            "This package does not include the item. Add the matching source, then return to this pending import."
        )

        let before = try XCTUnwrap(h.coordinator.review)
        await h.coordinator.refreshAfterAddingSource()
        XCTAssertNotEqual(h.coordinator.review?.id, before.id, "re-matching replaces the review")
        XCTAssertEqual(h.coordinator.review?.extractionDirectory, before.extractionDirectory)
        XCTAssertEqual(
            h.coordinator.importError,
            "That source does not match the item described by this package yet. Add the same item or cancel the import."
        )
    }

    /// #2507: the Library is searched off the main actor, so the screen can change while the answer is on its way.
    /// The test is on the main actor, so Cancel runs after the re-match has handed its search off and before its
    /// answer can be used.
    func testAReMatchThatFinishesAfterCancelDoesNotBringTheReviewBack() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "gamma", text: Self.alphaText, recipientSupplied: true)
        assertStaged(await h.coordinator.stage(from: packet.url))
        let showing = try XCTUnwrap(h.coordinator.review)

        let rematch = Task { @MainActor in await h.coordinator.refreshAfterAddingSource() }
        await Task.yield()
        h.coordinator.cancel()
        await rematch.value

        XCTAssertNil(h.coordinator.review, "Cancel ended that review; a late answer must not show it again")
        XCTAssertNil(h.coordinator.importError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: showing.extractionDirectory.path))
    }

    /// #2507: `stage` suspends while the Library is searched, so a second packet can start meanwhile. Both reach
    /// the queue, one showing and one waiting, and neither loses its folder.
    func testTwoPacketsStagedAtTheSameTimeBothReachTheQueueWithTheirFolders() async throws {
        let h = try makeHarness()
        let a = try h.writePacket(named: "alpha", text: Self.alphaText)
        let b = try h.writePacket(named: "beta", text: Self.betaText)

        let first = Task { @MainActor in await h.coordinator.stage(from: a.url) }
        let second = Task { @MainActor in await h.coordinator.stage(from: b.url) }
        assertStaged(await first.value)
        assertStaged(await second.value)

        XCTAssertEqual(h.incomingFolderNames().count, 2, "one showing, one waiting")
        XCTAssertNotNil(h.coordinator.review)
        XCTAssertEqual(h.confirmations.last, SpokenMarginsPackageImportCoordinator.waitingMessage)
    }

    /// #2507: a stage whose caller went away (a replaced share link) leaves no folder and tells nobody.
    func testAStageCancelledWhileTheLibraryIsSearchedLeavesNothingBehind() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        let failuresBefore = h.failures.count

        let staging = Task { @MainActor in await h.coordinator.stage(from: packet.url) }
        await Task.yield()
        staging.cancel()
        let result = await staging.value

        guard case .rejected(let needsNewerApp) = result else { return XCTFail("a cancelled stage is not staged") }
        XCTAssertFalse(needsNewerApp)
        XCTAssertNil(h.coordinator.review)
        XCTAssertTrue(h.incomingFolderNames().isEmpty)
        XCTAssertEqual(h.failures.count, failuresBefore, "nothing to tell the listener")
    }

    // MARK: The file a packet came from (#2123)

    func testTheSourceFileIsReleasedWhenTheReviewIsImportedNotWhenItOpens() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        var released = 0
        assertStaged(await h.coordinator.stage(from: packet.url, releaseSource: { released += 1 }))
        XCTAssertEqual(released, 0, "opening the review keeps the source, so a killed app finds it again")

        await h.confirmCurrentReview()

        XCTAssertEqual(released, 1)
    }

    func testTheSourceFileIsReleasedOnCancelAndKeptThroughAFailedImport() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        var released = 0
        assertStaged(await h.coordinator.stage(from: packet.url, releaseSource: { released += 1 }))
        h.showImportedItemFailure = StubFailure()

        await h.confirmCurrentReview()
        XCTAssertEqual(released, 0, "a failed import keeps the source for a retry")

        h.coordinator.cancel()
        XCTAssertEqual(released, 1)
        h.coordinator.cancel()
        XCTAssertEqual(released, 1, "released once")
    }

    func testAPacketAlreadyInTheLibraryReleasesItsSourceStraightAway() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        assertStaged(await h.coordinator.stage(from: packet.url))
        await h.confirmCurrentReview()
        var released = 0

        assertStaged(await h.coordinator.stage(from: packet.url, releaseSource: { released += 1 }))

        XCTAssertNil(h.coordinator.review)
        XCTAssertEqual(released, 1, "nothing is left to review, so nothing should reopen at the next launch")
    }

    func testARejectedPacketLeavesItsSourceToTheCaller() async throws {
        let h = try makeHarness()
        let junk = h.root.appendingPathComponent("junk.spokenmargins")
        try Data("not a zip".utf8).write(to: junk)
        var released = 0

        guard case .rejected = await h.coordinator.stage(from: junk, releaseSource: { released += 1 }) else { return XCTFail() }

        XCTAssertEqual(released, 0)
    }

    func testAWaitingPacketKeepsItsSourceUntilItsOwnReviewEnds() async throws {
        let h = try makeHarness()
        let a = try h.writePacket(named: "alpha", text: Self.alphaText)
        let b = try h.writePacket(named: "beta", text: Self.betaText)
        var releasedA = 0
        var releasedB = 0
        assertStaged(await h.coordinator.stage(from: a.url, releaseSource: { releasedA += 1 }))
        assertStaged(await h.coordinator.stage(from: b.url, releaseSource: { releasedB += 1 }))

        await h.confirmCurrentReview()
        XCTAssertEqual([releasedA, releasedB], [1, 0])

        h.coordinator.cancel()
        XCTAssertEqual([releasedA, releasedB], [1, 1])
    }

    func testReMatchingAfterAddingASourceKeepsTheSourceToRelease() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "gamma", text: Self.alphaText, recipientSupplied: true)
        var released = 0
        assertStaged(await h.coordinator.stage(from: packet.url, releaseSource: { released += 1 }))
        let before = try XCTUnwrap(h.coordinator.review)

        await h.coordinator.refreshAfterAddingSource()
        XCTAssertNotEqual(h.coordinator.review?.id, before.id)
        h.coordinator.cancel()

        XCTAssertEqual(released, 1, "the rebuilt review still releases the file the packet came from")
    }

    // MARK: State shared with the views

    func testWritesFromTheViewsAreAdoptedWithoutBeingPublishedBackOrCleanedUp() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        assertStaged(await h.coordinator.stage(from: packet.url))
        let folder = try XCTUnwrap(h.coordinator.review).extractionDirectory
        h.events.removeAll()

        h.coordinator.adoptReviewFromViews(nil)
        h.coordinator.adoptIsImportingFromViews(true)
        h.coordinator.adoptErrorFromViews("from a view")

        XCTAssertNil(h.coordinator.review)
        XCTAssertTrue(h.coordinator.isImporting)
        XCTAssertEqual(h.coordinator.importError, "from a view")
        XCTAssertTrue(h.events.isEmpty, "a view's own write is not echoed to it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "a bare write of nil has never removed the folder")

        h.coordinator.adoptReviewFromViews(nil)
        h.coordinator.adoptIsImportingFromViews(true)
        h.coordinator.adoptErrorFromViews("from a view")
        XCTAssertTrue(h.events.isEmpty)
    }

    /// The model's three properties are the views' copy: still `@Published`, still written by the sheet binding, and
    /// each coordinator change reaches them once.
    func testTheModelKeepsItsThreePublishersAndAWritableSheetBinding() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: h.root.appendingPathComponent("model.sqlite")
        )
        model.resetAndSeed()
        var reviewChanges = 0
        var importingChanges = 0
        var errorChanges = 0
        let subscriptions = [
            model.$spokenMarginsPackageImportReview.dropFirst().sink { _ in reviewChanges += 1 },
            model.$isImportingSpokenMarginsPackage.dropFirst().sink { _ in importingChanges += 1 },
            model.$spokenMarginsPackageImportError.dropFirst().sink { _ in errorChanges += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        model.handleIncomingURL(packet.url)
        await model.waitForPackageStaging()

        let review = try XCTUnwrap(model.spokenMarginsPackageImportReview)
        defer { try? FileManager.default.removeItem(at: review.extractionDirectory) }
        XCTAssertEqual(model.packageImport.review?.id, review.id)
        XCTAssertEqual(reviewChanges, 1)
        XCTAssertEqual(errorChanges, 1)
        XCTAssertEqual(importingChanges, 0)

        // `.sheet(item: $model.spokenMarginsPackageImportReview)` writes the property like this.
        model.spokenMarginsPackageImportReview = nil

        XCTAssertNil(model.spokenMarginsPackageImportReview)
        XCTAssertNil(model.packageImport.review, "the coordinator follows the sheet")
        XCTAssertEqual(reviewChanges, 2, "and the write is not echoed back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.extractionDirectory.path), "a bare write of nil leaves the folder")
    }

    func testForcedFirstSourceMissLeavesTheReviewWithoutAMatch() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        h.forceSourceMiss = true

        assertStaged(await h.coordinator.stage(from: packet.url))

        XCTAssertNil(h.coordinator.review?.matchingItemId)
        XCTAssertEqual(h.diagnostics["uiTestSharedSourceMiss"], "forced_once")
        XCTAssertFalse(h.forceSourceMiss, "it fires once")
    }

    // MARK: Launch sweep (#2154)

    func testKillAndRelaunchTwiceLeavesOneStagedCopyOfThePacket() async throws {
        let h = try makeHarness()
        let packet = try h.writePacket(named: "alpha", text: Self.alphaText)
        assertStaged(await h.coordinator.stage(from: packet.url))
        XCTAssertEqual(h.incomingFolderNames().count, 1)

        // The app is killed before Import; each launch sweeps, then reopens the packet from the Share inbox.
        for _ in 1...2 {
            let relaunched = SpokenMarginsPackageImportCoordinator(environment: h.makeEnvironment())
            relaunched.sweepOrphanedFoldersOnce()
            // Staged while the sweep is still running: the sweep must not take the new folder.
            assertStaged(await relaunched.stage(from: packet.url))
            await relaunched.sweepTask?.value
            XCTAssertEqual(h.incomingFolderNames(), [try XCTUnwrap(relaunched.review).extractionDirectory.lastPathComponent],
                           "only the folder of the review that is showing is left")
        }
        XCTAssertTrue(h.diagnostics["lastIncomingPackageSweep"]?.hasPrefix("removed:1") == true)
    }

    func testTheSweepLeavesTheFoldersOfReviewsThisRunOwns() async throws {
        let h = try makeHarness()
        let first = try h.writePacket(named: "alpha", text: Self.alphaText)
        let second = try h.writePacket(named: "beta", text: Self.betaText)
        assertStaged(await h.coordinator.stage(from: first.url))
        assertStaged(await h.coordinator.stage(from: second.url))
        XCTAssertEqual(h.incomingFolderNames().count, 2, "one showing, one waiting")

        h.coordinator.sweepOrphanedFoldersOnce()
        await h.coordinator.sweepTask?.value

        XCTAssertEqual(h.incomingFolderNames().count, 2)
    }

    func testTheSweepLeavesAFolderAnImportedMarginPlaysFromAndRunsOnce() async throws {
        let h = try makeHarness()
        let used = try h.makeFolder(files: ["assets/voice.m4a"])
        let orphan = try h.makeFolder(files: ["package.spokenmargins"])
        try h.saveImportedMargin(playingFrom: h.incomingDirectory.appending(path: "\(used)/assets/voice.m4a").path)

        h.coordinator.sweepOrphanedFoldersOnce()
        await h.coordinator.sweepTask?.value

        XCTAssertEqual(h.incomingFolderNames(), [used])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.incomingDirectory.appending(path: orphan).path))
        // A folder made after the sweep is not swept by a second call: it belongs to this run.
        let later = try h.makeFolder(files: ["package.spokenmargins"])
        h.coordinator.sweepOrphanedFoldersOnce()
        await h.coordinator.sweepTask?.value
        XCTAssertEqual(h.incomingFolderNames(), [used, later].sorted())
    }

    // MARK: Fixtures

    private static let alphaText = "Alpha is a short essay about listening slowly. The exact phrase to remember is quiet mornings help."
    private static let harbourParagraphs = [
        "The harbour town woke slowly that morning, with the fishing boats rocking against their ropes and the gulls arguing over scraps on the quay.",
        "Marta carried her father's ledger down to the customs shed, where a clerk with ink on his cuffs promised to read every line before noon.",
        "By midday the wind had turned, and the captains began to say that the barometer was falling faster than anyone had seen since the great storm.",
        "Nobody believed the old signalman until the lamps along the breakwater began to swing, and then the whole street went quiet at once.",
        "Evening brought the first rain, a thin grey curtain that blurred the lights of the ferry and sent the children running for the arcade."
    ]
    fileprivate static let harbourText = harbourParagraphs.joined(separator: "\n\n")

    private static let betaText = "Beta is another short essay, about margins. The exact phrase to remember is notes become conversations."

    private func makeHarness() throws -> ImportHarness {
        let harness = try ImportHarness()
        addTeardownBlock { [root = harness.root] in try? FileManager.default.removeItem(at: root) }
        return harness
    }

    private func assertStaged(_ result: SpokenMarginsPackageImportCoordinator.StageResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .staged = result else { return XCTFail("expected the packet to be staged", file: file, line: line) }
    }
}

private struct StubFailure: LocalizedError {
    var errorDescription: String? { "stub failure" }
}

private struct PacketImport: Equatable {
    let itemId: String?
    let packetId: String
    let marginCount: Int
}

private struct WrittenPacket {
    let url: URL
    let digest: String
}

/// The app's side of the flow: a real store and Application Support folder, with everything else recorded.
@MainActor
private final class ImportHarness {
    let root: URL
    let supportDirectory: URL
    let store: SQLiteSessionStore
    var coordinator: SpokenMarginsPackageImportCoordinator!

    var diagnostics: [String: String] = [:]
    var successes: [String] = []
    var confirmations: [String] = []
    var failures: [String] = []
    var failureContexts: [String] = []
    var openedItems: [String] = []
    var shownItems: [String] = []
    var packetImports: [PacketImport] = []
    /// What the views would see, in order: `review:<id|nil>`, `importing:<bool>`, `error:<text|nil>`.
    var events: [String] = []
    var showImportedItemFailure: Error?
    var forceSourceMiss = false
    var acquireArticleHook: ((SharedItemIdentity) throws -> String)?
    var attachedMaps: [ListeningMap] = []
    var attachFailure: Error?

    var incomingDirectory: URL {
        supportDirectory.appending(path: "SpokenMargins/IncomingPackages", directoryHint: .isDirectory)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-import-coordinator-\(UUID().uuidString)", isDirectory: true)
        supportDirectory = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("recipient.sqlite").path)
        coordinator = SpokenMarginsPackageImportCoordinator(environment: makeEnvironment())
    }

    @discardableResult
    func seedArticle(id: String, reference: String, mediaType: String = "text", text: String = SpokenMarginsPackageImportCoordinatorTests.harbourText) throws -> Item {
        let item = Item(id: id, title: "The Harbour Town", mediaType: mediaType, text: text,
                        externalReference: reference, status: "ready", externalReferenceType: "url")
        try store.seed(item: item)
        return item
    }

    /// A map-only packet for the harbour story: five chapters, no Margins.
    func writeMapPacket(named name: String, itemType: SharedItemType = .text, link: String? = "https://example.com/harbour") throws -> WrittenPacket {
        let text = SpokenMarginsPackageImportCoordinatorTests.harbourText
        let blocks = ListeningEdition.blocks(in: text)
        let proposal = try ListeningMapPacketBuilder.proposal(
            id: name, generator: "test", languageCode: "en", createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            scenes: blocks.enumerated().map { index, block in
                .init(title: "Part \(index + 1)", summary: "Summary \(index + 1) of the harbour story.", startChar: block.startChar, endChar: block.endChar)
            },
            text: text
        )
        let prepared = try ListeningMapPacketBuilder.prepare(
            packageId: "package-\(name)", createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            item: ListeningMapPacketBuilder.identity(itemType: itemType, title: "The Harbour Town", canonicalURL: link, text: text),
            proposal: proposal, senderDisplayLabel: "Cole"
        )
        let url = root.appendingPathComponent("\(name).spokenmargins")
        let manifest = try SpokenMarginsPackageArchive.write(prepared, to: url)
        return WrittenPacket(url: url, digest: try XCTUnwrap(manifest.contentDigest))
    }

    func makeFolder(files: [String]) throws -> String {
        let name = UUID().uuidString
        for file in files {
            let url = incomingDirectory.appending(path: "\(name)/\(file)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bytes".utf8).write(to: url)
        }
        return name
    }

    /// An imported friend's Margin whose recording is at `path`, saved as an import would.
    func saveImportedMargin(playingFrom path: String) throws {
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        try store.saveImportedCommentaryLayer(ImportedCommentaryLayer(
            id: "layer-voice", itemId: nil, packageDigest: "digest-voice", packageId: "package-voice",
            itemIdentity: SharedItemIdentity(itemType: .text, title: "Essay"), displayLabel: "Friend", importedAt: date))
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: "margin-voice", layerId: "layer-voice", packageScopedId: "margin-001", createdAt: date,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text, exactText: "quiet mornings"),
            approvedTranscript: "A voice Margin", audioPath: path, audioDurationMs: 500))
    }

    func incomingFolderNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: incomingDirectory.path)) ?? []).sorted()
    }

    func confirmCurrentReview() async {
        guard let review = coordinator.beginConfirmation() else { return XCTFail("nothing to confirm") }
        await coordinator.confirm(review)
    }

    /// A packet that carries its item as text, so confirming needs no network.
    func writePacket(named name: String, text: String, recipientSupplied: Bool = false) throws -> WrittenPacket {
        let packageID = "package-\(name)"
        let item = SharedItemIdentity(
            itemType: .text,
            title: "Essay \(name)",
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text),
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text)
        )
        let revision = InterjectionShareRevision(
            id: "revision-\(packageID)",
            interjectionId: "sender-margin",
            itemId: "sender-item",
            sessionId: "sender-session",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            approvedTranscript: "A sender-reviewed observation.",
            anchorBefore: "Before this passage.",
            anchorAfter: "After this passage.",
            status: .senderApproved
        )
        let transport: ReviewedItemTransportSelection = recipientSupplied
            ? .recipientSupplied
            : .embeddedText(text: text, originalMediaType: "text", rightsBasis: .senderConfirmedPrivateRights)
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: packageID,
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            item: item,
            itemTransportSelection: transport,
            selections: [ReviewedInterjectionSelection(
                packageScopedId: "margin-001",
                revision: revision,
                anchor: PortableAnchorEvidence(anchorType: .text, exactText: "The exact phrase to remember is"),
                representation: .textOnly
            )],
            senderDisplayLabel: "Cole",
            suggestedRevealMode: .companion
        )
        let url = root.appendingPathComponent("\(name).spokenmargins")
        let manifest = try SpokenMarginsPackageArchive.write(prepared, to: url)
        return WrittenPacket(url: url, digest: try XCTUnwrap(manifest.contentDigest))
    }

    func makeEnvironment() -> SpokenMarginsPackageImportCoordinator.Environment {
        .init(
            requireStore: { [unowned self] in self.store },
            applicationSupportDirectory: { [unowned self] in self.supportDirectory },
            bootstrapLibrary: {},
            recordDiagnostic: { [unowned self] key, value in self.diagnostics[key] = value },
            reportSuccess: { [unowned self] in self.successes.append($0) },
            reportConfirmation: { [unowned self] in self.confirmations.append($0) },
            reportFailureMessage: { [unowned self] in self.failures.append($0) },
            reportFailure: { [unowned self] error, context in
                self.failures.append(error.localizedDescription)
                self.failureContexts.append(context)
            },
            openItem: { [unowned self] in self.openedItems.append($0) },
            showImportedItem: { [unowned self] itemId, _ in
                if let failure = self.showImportedItemFailure { throw failure }
                self.shownItems.append(itemId)
            },
            recordPacketImport: { [unowned self] itemId, packetId, marginCount in
                self.packetImports.append(PacketImport(itemId: itemId, packetId: packetId, marginCount: marginCount))
            },
            localAudiobookDigest: { _ in nil },
            ownedAudiobookURL: { _ in nil },
            validatedLocalURL: { _ in nil },
            registerRemoteDownload: { _, _ in },
            resolvePodcastCommentary: { _, _ in },
            acquirePodcast: { _ in throw StubFailure() },
            acquireArticle: { [unowned self] identity in
                guard let hook = self.acquireArticleHook else { throw StubFailure() }
                return try hook(identity)
            },
            offlineLedger: { store, rootDirectory in
                OfflineStorageLedger(repository: store, rootDirectory: rootDirectory)
            },
            summaryBridgeAssetID: { itemId, proposalId, sceneId, _ in "bridge-\(itemId)-\(proposalId)-\(sceneId)" },
            selectedItemID: { "" },
            refreshSelectedItem: {},
            prepareLocalAudioBridges: { _ in },
            consumeForcedSourceMiss: { [unowned self] in
                defer { self.forceSourceMiss = false }
                return self.forceSourceMiss
            },
            publishReview: { [unowned self] review in self.events.append("review:" + (review?.id.uuidString ?? "nil")) },
            publishIsImporting: { [unowned self] value in self.events.append("importing:\(value)") },
            publishError: { [unowned self] message in self.events.append("error:" + (message ?? "nil")) },
            attachListeningMap: { [unowned self] map in
                if let failure = self.attachFailure { throw failure }
                self.attachedMaps.append(map)
                try self.store.saveListeningMap(map)
            }
        )
    }
}
