import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #4683, PR 3a: a link list from the listener's own AI arrives as a collection (or loose items), its follow entries wait
/// as suggestions, Undo takes back what the arrival made, and a pasted prompt is never added. Real temporary files and a
/// real store; links resolve through a per-address resolver, so no network is touched. The SessionKit rules (key,
/// banner, Undo selection, retry) are `LinkListArrivalPlanTests`; this checks the app runs them.
@MainActor
final class LinkListArrivalAppTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        // The suggestions and the last-arrival record live in the standard defaults.
        UserDefaults.standard.removeObject(forKey: AIFollowSuggestions.defaultsKey)
        UserDefaults.standard.removeObject(forKey: LinkListArrivalRecord.defaultsKey)
        super.tearDown()
    }

    private func makeModel(playable: [String: String] = [:]) throws -> Gate1AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "link-list-arrival-\(UUID().uuidString)")
        directories.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: AIFollowSuggestions.defaultsKey)
        let model = Gate1AppModel(
            sourceLinkResolver: ArrivalResolver(playable: playable), audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: root.appending(path: "library.sqlite"))
        model.resetAndSeed(); model.declineCurrentTerms()
        model.aiFollowSuggestionsModel.reload()
        return model
    }

    private let playable = [
        "https://example.com/one": "https://audio.example/one.mp3",
        "https://example.com/two": "https://audio.example/two.mp3",
    ]

    private func brief(title: String? = "Morning brief") -> LinkListFile {
        LinkListFile(title: title, entries: [
            .init(url: "https://example.com/one", title: "One"),
            .init(url: "https://feeds.example.org/show.xml", follow: true),
            .init(url: "https://example.com/two", title: "Two"),
        ])
    }

    func testATitledListArrivesAsACollectionWithUndoAndItsFollowsWaitAsSuggestions() async throws {
        let model = try makeModel(playable: playable)
        let screen = model.screen

        let result = await model.runLinkListArrival(brief(), route: .pasteAndGo)

        XCTAssertTrue(result.attempted)
        XCTAssertTrue(result.allLanded)
        XCTAssertEqual(model.feedbackEvent?.message, "Made “Morning brief” with 2 items.")
        XCTAssertEqual(model.feedbackEvent?.action?.identifier, "linkList.undo.button")
        let collection = try XCTUnwrap(model.libraryCollections.collections.first { $0.name == "Morning brief" })
        XCTAssertEqual(collection.itemIDs.count, 2, "the follow entry is not a member")
        XCTAssertEqual(model.aiFollowSuggestionsModel.suggestions.map(\.url), ["https://feeds.example.org/show.xml"])
        XCTAssertEqual(model.screen, screen, "an arrival opens nothing")
        XCTAssertNil(model.libraryCollections.importCapture)
        XCTAssertNil(model.sourceImportTask)
        XCTAssertEqual(LinkListArrivalRecord.load()?.title, "Morning brief")
    }

    func testTheSameListTwiceIsOneCollection() async throws {
        let model = try makeModel(playable: playable)
        await model.runLinkListArrival(brief(), route: .pasteAndGo)
        await model.runLinkListArrival(brief(), route: .quickFolderTapped)
        XCTAssertEqual(model.libraryCollections.collections.filter { $0.name.hasPrefix("Morning brief") }.count, 1)
        XCTAssertEqual(model.aiFollowSuggestionsModel.suggestions.count, 1, "the show is suggested once")
    }

    func testUndoMovesTheNewItemsAndTheCollectionAndTheSuggestionsAndIsUsedUpByTheFirstTap() async throws {
        let model = try makeModel(playable: playable)
        await model.runLinkListArrival(brief(), route: .pasteAndGo)
        let collection = try XCTUnwrap(model.libraryCollections.collections.first { $0.name == "Morning brief" })
        let made = collection.itemIDs
        let undo = try XCTUnwrap(model.feedbackEvent?.action)

        undo.perform()
        let firstBanner = try XCTUnwrap(model.trashUndo?.id)
        undo.perform() // a second tap does nothing: no second Recently Deleted banner
        XCTAssertEqual(model.trashUndo?.id, firstBanner)

        XCTAssertEqual(Set(model.trashUndo?.itemIds ?? []), Set(made), "only this arrival's items went to Recently Deleted")
        XCTAssertTrue(model.aiFollowSuggestionsModel.suggestions.isEmpty, "that list's suggestions went too")
        try await pollUntil { !model.libraryCollections.collections.contains { $0.id == collection.id } }
        XCTAssertFalse(model.libraryCollections.collections.contains { $0.id == collection.id })
    }

    func testAnUntitledListArrivesAsLooseItemsWithUndoAndNoCollection() async throws {
        let model = try makeModel(playable: playable)
        let collectionsBefore = model.libraryCollections.collections.count

        let result = await model.runLinkListArrival(brief(title: nil), route: .pasteAndGo)

        XCTAssertTrue(result.allLanded)
        XCTAssertEqual(model.feedbackEvent?.message, "Added 2 links from your list.")
        XCTAssertEqual(model.feedbackEvent?.action?.identifier, "linkList.undo.button")
        XCTAssertEqual(model.libraryCollections.collections.count, collectionsBefore)
        XCTAssertEqual(model.aiFollowSuggestionsModel.suggestions.count, 1)
    }

    func testAListOfOnlyShowsAddsNoItemsAndSaysSo() async throws {
        let model = try makeModel()
        let list = LinkListFile(title: "Shows", entries: [.init(url: "https://feeds.example.org/a.xml", follow: true)])
        let itemsBefore = model.libraryItems.count

        let result = await model.runLinkListArrival(list, route: .quickFolderAutomatic)

        XCTAssertTrue(result.allLanded)
        XCTAssertEqual(model.feedbackEvent?.message, "Your AI suggested 1 show.")
        XCTAssertNil(model.feedbackEvent?.action, "nothing was made, so nothing to undo")
        XCTAssertEqual(model.libraryItems.count, itemsBefore)
        XCTAssertFalse(model.libraryCollections.collections.contains { $0.name == "Shows" })
    }

    func testABadLinkIsCountedAsNotLandedSoTheQuickFolderCanTryAgain() async throws {
        let model = try makeModel(playable: playable)
        let list = LinkListFile(title: "Mixed", entries: [
            .init(url: "https://example.com/one"), .init(url: "https://example.com/broken"),
        ])
        let result = await model.runLinkListArrival(list, route: .quickFolderAutomatic)
        XCTAssertTrue(result.attempted)
        XCTAssertFalse(result.allLanded)
        XCTAssertEqual(model.feedbackEvent?.kind, .warning)
    }

    func testAPastedReplyGoesThroughPasteAndGoToACollection() async throws {
        let model = try makeModel(playable: playable)
        let reply = """
        Here is your brief:

        ```json
        {"schemaVersion":"spoken-margins.link-list.v1","title":"Pasted brief","entries":[{"url":"https://example.com/one"},{"url":"https://example.com/two"}]}
        ```
        """

        XCTAssertEqual(model.pasteAndGo(reply), .readingLinkList)
        try await pollUntil { model.linkListArrival.phase == .added }

        XCTAssertEqual(model.linkListArrival.phase, .added)
        XCTAssertEqual(model.libraryCollections.collections.first { $0.name == "Pasted brief" }?.itemIDs.count, 2)
        XCTAssertNil(model.sourceImportTask)
    }

    func testThePromptTheAppGivesIsNeverPastedAsABrief() async throws {
        let model = try makeModel(playable: playable)
        let prompt = AssistantSetupPrompt.make(date: Date())
        let collectionsBefore = model.libraryCollections.collections.count
        let itemsBefore = model.libraryItems.count

        XCTAssertEqual(model.pasteAndGo(prompt), .notAdded(LinkListArrivalPlan.assistantPromptMessage))

        XCTAssertEqual(model.libraryCollections.collections.count, collectionsBefore)
        XCTAssertEqual(model.libraryItems.count, itemsBefore)
        XCTAssertNil(model.sourceImportTask)
    }

    func testAPastedLinkListWhileAnotherImportRunsShowsTheBusyLine() async throws {
        let model = try makeModel(playable: playable)
        model.libraryCollections.importCapture = CollectionImportCapture() // an import is mid-way
        let reply = #"{"schemaVersion":"spoken-margins.link-list.v1","entries":[{"url":"https://example.com/one"}]}"#

        XCTAssertEqual(model.pasteAndGo(reply), .notAdded(Gate1AppModel.collectionImportBusyMessage))
    }

    func testAnArrivalWhileAnotherImportRunsIsNotTriedAndDoesNotTakeItsCapture() async throws {
        let model = try makeModel(playable: playable)
        let running = CollectionImportCapture()
        model.libraryCollections.importCapture = running // a Files folder import began while the entry waited

        let result = await model.runLinkListArrival(brief(), route: .quickFolderAutomatic)

        XCTAssertFalse(result.attempted)
        XCTAssertEqual(result.notTried, .busy)
        XCTAssertTrue(model.libraryCollections.importCapture === running)
        XCTAssertFalse(model.libraryCollections.collections.contains { $0.name == "Morning brief" })
    }

    func testOfflineNothingIsTriedAndNothingIsCounted() async throws {
        let model = try makeModel(playable: playable)
        model.connectivity.update(transport: .unavailable, isOffline: true)
        let itemsBefore = model.libraryItems.count

        let result = await model.runLinkListArrival(brief(), route: .quickFolderAutomatic)

        XCTAssertFalse(result.attempted)
        XCTAssertEqual(result.notTried, .offline)
        XCTAssertEqual(model.libraryItems.count, itemsBefore)
        XCTAssertTrue(model.aiFollowSuggestionsModel.suggestions.isEmpty, "nothing is stored until the list is tried")
    }

    func testASharedLinkThatDrainsDuringAnArrivalKeepsItsOwnItemAndBanner() async throws {
        let model = try makeModel()
        let shared = try XCTUnwrap(model.libraryItems.first?.id) // stands for the page a Safari share just saved
        let running = CollectionImportCapture()
        model.libraryCollections.importCapture = running // a list is mid-arrival
        model.feedbackEvent = nil

        model.reportPendingHandoffsAdded(itemIds: [shared])

        XCTAssertNotNil(model.feedbackEvent, "the share's own banner is shown, not held by the arrival")
        XCTAssertTrue(running.take().itemIDs.isEmpty, "the share is not counted as one of the list's items")
        XCTAssertTrue(model.libraryCollections.importCapture === running, "the arrival keeps its capture")
    }
}

/// Playable for the addresses it knows; anything else fails the way an unreachable page does.
private struct ArrivalResolver: LinkResolutionClient {
    var playable: [String: String]

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        guard let audioURL = playable[request.inputURL] else { throw URLError(.cannotFindHost) }
        return LinkResolutionResult(
            requestId: request.id, status: .playable,
            originalLink: SourceLink(url: request.inputURL, role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: audioURL, role: "media"), title: audioURL, durationMs: 300_000,
                audioURL: audioURL, confidence: 1))
    }
}
