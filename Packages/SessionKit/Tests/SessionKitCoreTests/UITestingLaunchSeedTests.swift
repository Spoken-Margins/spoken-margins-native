import XCTest
@testable import SessionKit

/// #667: the UI-test seeds, including the offline podcast for J2, never touch a normal launch.
final class UITestingLaunchSeedTests: XCTestCase {
    private let everySeedVariable = [
        "SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY": "1",
        "SPOKEN_MARGINS_UI_TEST_COOP": "1",
        "SPOKEN_MARGINS_UI_TEST_LISTENER_SHARED": "1",
        "SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT": "Some text.",
        "SPOKEN_MARGINS_UI_TEST_PODCAST": "1",
        "SPOKEN_MARGINS_UI_TEST_PDF": "1",
        "SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE": "Title",
    ]

    func testANormalLaunchSeedsNothingWhateverTheEnvironmentHolds() {
        for (key, value) in everySeedVariable {
            let seed = UITestingLaunchSeed(arguments: ["SpokenMarginsApp"], environment: [key: value])
            XCTAssertEqual(seed, .none, key)
            XCTAssertNil(seed.item, key)
            XCTAssertNil(seed.podcastDownload(bytesWritten: 1), key)
            XCTAssertFalse(seed.seedsGeneratedTimeline, key)
            XCTAssertFalse(UITestingLaunchSeed.importsCoopLayer(arguments: ["SpokenMarginsApp"], environment: [key: value]), key)
            XCTAssertFalse(UITestingLaunchSeed.marksListenerMarginShared(arguments: ["SpokenMarginsApp"], environment: [key: value]), key)
        }
        XCTAssertEqual(UITestingLaunchSeed(arguments: ["SpokenMarginsApp"], environment: everySeedVariable), .none)
        XCTAssertFalse(UITestingLaunchSeed.importsCoopLayer(arguments: ["SpokenMarginsApp"], environment: everySeedVariable))
        XCTAssertFalse(UITestingLaunchSeed.marksListenerMarginShared(arguments: ["SpokenMarginsApp"], environment: everySeedVariable))
    }

    func testAUITestLaunchWithNoSeedVariablesKeepsTheFixtureArticle() {
        let seed = UITestingLaunchSeed(arguments: ["SpokenMarginsApp", "--ui-testing"], environment: [:])
        XCTAssertEqual(seed, .fixture)
        XCTAssertTrue(seed.seedsGeneratedTimeline)
    }

    func testTheTextSeedMatchesTheArticleEarlierScriptsExpect() throws {
        let seed = UITestingLaunchSeed(arguments: ["--ui-testing"], environment: [
            "SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT": "On a short walk.",
            "SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE": "J1: A short walk",
            "SPOKEN_MARGINS_UI_TEST_SOURCE_URL": "https://example.com/j1-article",
            "SPOKEN_MARGINS_UI_TEST_PODCAST": "1",
        ])
        let item = try XCTUnwrap(seed.item)
        XCTAssertEqual(item.id, "item-ui-text-regression")
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertEqual(item.title, "J1: A short walk")
        XCTAssertEqual(item.externalReference, "https://example.com/j1-article")
        XCTAssertNil(seed.podcastDownload(bytesWritten: 1), "Text wins over the podcast seed, as before")
        XCTAssertFalse(seed.seedsGeneratedTimeline)
    }

    func testThePodcastSeedIsADownloadedEpisodeThatNeedsNoNetwork() throws {
        let seed = UITestingLaunchSeed(arguments: ["--ui-testing"], environment: [
            "SPOKEN_MARGINS_UI_TEST_PODCAST": "1",
            "SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE": "J2: Long episode",
        ])
        XCTAssertEqual(seed, .offlinePodcast(title: "J2: Long episode", durationSeconds: 1_500))
        let item = try XCTUnwrap(seed.item)
        XCTAssertEqual(item.mediaType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(item.media?.sourceType, .remoteStream)
        XCTAssertEqual(item.media?.durationMs, 1_500_000)
        let download = try XCTUnwrap(seed.podcastDownload(bytesWritten: 42))
        XCTAssertEqual(download.itemId, item.id)
        XCTAssertEqual(download.state, .availableOffline)
        XCTAssertEqual(download.localRelativePath, UITestingLaunchSeed.podcastFileName)
        XCTAssertEqual(download.bytesWritten, 42)
        XCTAssertFalse(seed.seedsGeneratedTimeline, "Fixture timeline turns would interrupt the episode")
    }

    func testThePodcastLengthIsClampedToSomethingTheSeedCanWriteQuickly() {
        func seconds(_ raw: String) -> UITestingLaunchSeed {
            UITestingLaunchSeed(arguments: ["--ui-testing"], environment: [
                "SPOKEN_MARGINS_UI_TEST_PODCAST": "1", "SPOKEN_MARGINS_UI_TEST_PODCAST_SECONDS": raw,
            ])
        }
        XCTAssertEqual(seconds("60"), .offlinePodcast(title: "UI Test Episode", durationSeconds: 60))
        XCTAssertEqual(seconds("1"), .offlinePodcast(title: "UI Test Episode", durationSeconds: 10))
        XCTAssertEqual(seconds("99999"), .offlinePodcast(title: "UI Test Episode", durationSeconds: 3_600))
        XCTAssertEqual(seconds("soon"), .offlinePodcast(title: "UI Test Episode", durationSeconds: 1_500))
    }

    func testARelaunchThatKeepsTheLibrarySeedsNothingNew() {
        let seed = UITestingLaunchSeed(arguments: ["--ui-testing"], environment: everySeedVariable)
        XCTAssertEqual(seed, .keepLibrary)
        XCTAssertNil(seed.item)
        XCTAssertFalse(seed.seedsGeneratedTimeline)
    }

    func testStandInAudioServicesNeedAUITestLaunch() {
        let recording = ["SPOKEN_MARGINS_UI_TEST_RECORDING": "1"]
        let podcast = ["SPOKEN_MARGINS_UI_TEST_PODCAST": "1"]
        XCTAssertFalse(UITestingLaunchSeed.usesStandInAudioServices(arguments: ["SpokenMarginsApp"], environment: recording))
        XCTAssertFalse(UITestingLaunchSeed.usesStandInAudioServices(arguments: ["SpokenMarginsApp"], environment: podcast))
        XCTAssertFalse(UITestingLaunchSeed.usesStandInAudioServices(arguments: ["--ui-testing"], environment: [:]))
        XCTAssertTrue(UITestingLaunchSeed.usesStandInAudioServices(arguments: ["--ui-testing"], environment: recording))
        XCTAssertTrue(UITestingLaunchSeed.usesStandInAudioServices(arguments: ["--ui-testing"], environment: podcast))
    }

    /// #4071: a UI-test launch must not ask the production server for the guided tour unless its script opts in.
    func testAUITestLaunchSkipsTheGuidedTourFetchUnlessItOptsIn() {
        let optIn = ["SPOKEN_MARGINS_UI_TEST_GUIDED_TOUR_FETCH": "1"]
        XCTAssertFalse(UITestingLaunchSeed.fetchesGuidedTour(arguments: ["--ui-testing"], environment: [:]))
        XCTAssertFalse(UITestingLaunchSeed.fetchesGuidedTour(arguments: ["--ui-testing"], environment: ["SPOKEN_MARGINS_UI_TEST_PODCAST": "1"]))
        XCTAssertFalse(UITestingLaunchSeed.fetchesGuidedTour(arguments: ["--ui-testing"], environment: ["SPOKEN_MARGINS_UI_TEST_GUIDED_TOUR_FETCH": "0"]))
        XCTAssertTrue(UITestingLaunchSeed.fetchesGuidedTour(arguments: ["--ui-testing"], environment: optIn))
        // A normal launch always fetches, whatever the environment holds.
        XCTAssertTrue(UITestingLaunchSeed.fetchesGuidedTour(arguments: ["SpokenMarginsApp"], environment: [:]))
        XCTAssertTrue(UITestingLaunchSeed.fetchesGuidedTour(arguments: ["SpokenMarginsApp"], environment: optIn))
    }

    func testThePDFSeedImportsThroughTheAppRatherThanWritingAnItem() {
        let seed = UITestingLaunchSeed(arguments: ["--ui-testing"], environment: ["SPOKEN_MARGINS_UI_TEST_PDF": "1"])
        XCTAssertEqual(seed, .importedPDF)
        XCTAssertNil(seed.item, "The PDF item must come from the real import, not a hand-made Item")
        XCTAssertNil(seed.podcastDownload(bytesWritten: 1))
        XCTAssertFalse(seed.seedsGeneratedTimeline, "Fixture timeline turns would interrupt the PDF")
        XCTAssertEqual(
            UITestingLaunchSeed(arguments: ["--ui-testing"], environment: [
                "SPOKEN_MARGINS_UI_TEST_PDF": "1", "SPOKEN_MARGINS_UI_TEST_PODCAST": "1",
            ]),
            .offlinePodcast(title: "UI Test Episode", durationSeconds: 1_500)
        )
    }

    /// #2854: the fresh-install seed adds no item of its own and needs a UI-test launch to be asked for.
    func testTheFirstRunSeedSeedsNothingAndNeedsAUITestLaunch() {
        let seed = UITestingLaunchSeed(arguments: ["--ui-testing"], environment: ["SPOKEN_MARGINS_UI_TEST_FIRST_RUN": "1"])
        XCTAssertEqual(seed, .firstRun)
        XCTAssertNil(seed.item)
        XCTAssertNil(seed.podcastDownload(bytesWritten: 1))
        XCTAssertFalse(seed.seedsGeneratedTimeline)
        XCTAssertEqual(
            UITestingLaunchSeed(arguments: ["SpokenMarginsApp"], environment: ["SPOKEN_MARGINS_UI_TEST_FIRST_RUN": "1"]), .none,
            "a normal launch ignores the switch"
        )
        XCTAssertEqual(
            UITestingLaunchSeed(arguments: ["--ui-testing"], environment: [
                "SPOKEN_MARGINS_UI_TEST_FIRST_RUN": "1", "SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY": "1",
            ]), .keepLibrary, "a kept Library wins, as before"
        )
    }

    func testOnlyTheSeedsThatReplaceTheLibraryWriteToIt() {
        // #1175: the app writes a seed that replaces the Library even when something opened the store first.
        XCTAssertFalse(UITestingLaunchSeed.none.writesLibrary)
        XCTAssertFalse(UITestingLaunchSeed.keepLibrary.writesLibrary)
        XCTAssertTrue(UITestingLaunchSeed.fixture.writesLibrary)
        XCTAssertTrue(UITestingLaunchSeed.importedPDF.writesLibrary)
        XCTAssertTrue(UITestingLaunchSeed.firstRun.writesLibrary)
        XCTAssertTrue(UITestingLaunchSeed.text(title: "t", text: "x", reference: "r").writesLibrary)
        XCTAssertTrue(UITestingLaunchSeed.offlinePodcast(title: "t", durationSeconds: 10).writesLibrary)
        XCTAssertFalse(UITestingLaunchSeed(arguments: ["SpokenMarginsApp"], environment: everySeedVariable).writesLibrary)
        XCTAssertFalse(UITestingLaunchSeed(arguments: ["--ui-testing"], environment: ["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY": "1"]).writesLibrary)
    }

    // #3967: a Live session is a file outside the store, so a launch that resets the store has to clear it too.
    func testOnlyTheSeedsThatReplaceTheLibraryAlsoStartWithNoLiveSessions() {
        let replacing: [UITestingLaunchSeed] = [
            .fixture, .importedPDF, .firstRun,
            .text(title: "t", text: "x", reference: "r"), .offlinePodcast(title: "t", durationSeconds: 10),
        ]
        for seed in replacing {
            XCTAssertTrue(seed.clearsLiveSessions, "\(seed) resets the store, so it clears Live sessions")
        }
        XCTAssertFalse(UITestingLaunchSeed.keepLibrary.clearsLiveSessions, "a force-quit relaunch keeps what the first launch left")
        XCTAssertFalse(UITestingLaunchSeed.none.clearsLiveSessions, "a normal launch never clears the listener's sessions")
        XCTAssertFalse(UITestingLaunchSeed(arguments: ["SpokenMarginsApp"], environment: everySeedVariable).clearsLiveSessions)
        for seed in replacing + [.keepLibrary, .none] {
            XCTAssertEqual(seed.clearsLiveSessions, seed.writesLibrary, "\(seed): a new seed that resets the Library clears Live sessions too")
        }
    }

    // #2918: the kept-Library relaunch reaches the bootstrap, which is where the co-op layer is imported. It used to
    // be dropped there with the seeds that don't write, so J9's friend's Margin never arrived.
    func testAKeptLibraryRelaunchStillReachesTheLibraryBootstrap() {
        let relaunch = UITestingLaunchSeed(arguments: ["--ui-testing"], environment: everySeedVariable)
        XCTAssertEqual(relaunch, .keepLibrary)
        XCTAssertTrue(relaunch.runsAtLibraryBootstrap, "the co-op import runs from the bootstrap's keepLibrary branch")
        XCTAssertFalse(relaunch.writesLibrary, "a kept Library is still never replaced")
        XCTAssertFalse(UITestingLaunchSeed.none.runsAtLibraryBootstrap)
        XCTAssertFalse(UITestingLaunchSeed(arguments: ["SpokenMarginsApp"], environment: everySeedVariable).runsAtLibraryBootstrap)
        for seed: UITestingLaunchSeed in [.fixture, .importedPDF, .firstRun, .offlinePodcast(title: "t", durationSeconds: 10)] {
            XCTAssertTrue(seed.runsAtLibraryBootstrap, "\(seed)")
        }
    }

    // The co-op journey (#474): a relaunch that keeps the Library and adds one friend's Margin.

    func testTheCoopLayerComesOnlyWithAKeptLibraryAndTheCoopSwitch() {
        let keep = "SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY", coop = "SPOKEN_MARGINS_UI_TEST_COOP"
        func imports(_ arguments: [String], _ environment: [String: String]) -> Bool {
            UITestingLaunchSeed.importsCoopLayer(arguments: arguments, environment: environment)
        }
        XCTAssertTrue(imports(["--ui-testing"], [keep: "1", coop: "1"]))
        XCTAssertFalse(imports(["--ui-testing"], [coop: "1"]), "Without a kept Library the first launch seeds the episode itself")
        XCTAssertFalse(imports(["--ui-testing"], [keep: "1"]))
        XCTAssertFalse(imports(["--ui-testing"], [keep: "1", coop: "0"]))
        XCTAssertFalse(imports([], [keep: "1", coop: "1"]), "A normal launch never imports anything")
        XCTAssertEqual(UITestingLaunchSeed(arguments: ["--ui-testing"], environment: [keep: "1", coop: "1"]), .keepLibrary)
    }

    func testTheCoopMarginIsOneNewVoiceMarginReviewCanOffer() throws {
        let layer = UITestingLaunchSeed.coopLayer(importedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let margin = UITestingLaunchSeed.coopInterjection(
            audioPath: "SpokenMargins/interjections/ui-test-coop.m4a", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(layer.itemId, UITestingLaunchSeed.podcastItemId, "It must sit on the episode the first launch seeded")
        let entries = SharedMarginReview.entries(layers: [layer], records: [layer.id: [margin]])
        let entry = try XCTUnwrap(entries.first, "The seeded Margin is not offered by Review new Margins")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.senderLabel, UITestingLaunchSeed.coopSenderLabel)
        XCTAssertEqual(entry.mediaTimeMs, UITestingLaunchSeed.coopMarginMediaTimeMs)
        XCTAssertFalse(entry.isApproximate)
        XCTAssertEqual(SharedMarginReview.offerMessage(for: entries),
                       "1 new Margin from Sam. Hear it in place first, then carry on from where you were.")
    }

    /// #3237: only a keep-library relaunch that asks marks the listener's Margin as sent.
    func testOnlyAKeepLibraryRelaunchMarksTheListenersMarginShared() {
        let ui = ["SpokenMarginsApp", "--ui-testing"]
        XCTAssertTrue(UITestingLaunchSeed.marksListenerMarginShared(arguments: ui, environment: [
            "SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY": "1", "SPOKEN_MARGINS_UI_TEST_LISTENER_SHARED": "1",
        ]))
        XCTAssertFalse(UITestingLaunchSeed.marksListenerMarginShared(arguments: ui, environment: [
            "SPOKEN_MARGINS_UI_TEST_LISTENER_SHARED": "1",
        ]), "a fresh seed wipes the Margin it would mark")
        XCTAssertFalse(UITestingLaunchSeed.marksListenerMarginShared(arguments: ui, environment: [
            "SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY": "1",
        ]))
    }

    /// #3237: the listener's first Margin on the seeded podcast gets the identity Sam's reply names, once.
    func testTheListenersFirstPodcastMarginIsMarkedSentOnce() throws {
        func margin(_ id: String, item: String, at seconds: TimeInterval) -> Interjection {
            Interjection(
                id: id, itemId: item, sessionId: "session", targetType: .item, targetId: item,
                createdAt: Date(timeIntervalSince1970: seconds), roughPercent: 80,
                anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_200_000),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: id, status: "active"
            )
        }
        let podcast = UITestingLaunchSeed.podcastItemId
        let margins = [margin("later", item: podcast, at: 200), margin("other-item", item: "item-other", at: 50),
                       margin("first", item: podcast, at: 100)]
        let marked = try XCTUnwrap(UITestingLaunchSeed.listenerMarginMarkedShared(margins))
        XCTAssertEqual(marked.id, "first")
        XCTAssertEqual(marked.sharedAs, [UITestingLaunchSeed.listenerSharedIdentity])
        XCTAssertNil(UITestingLaunchSeed.listenerMarginMarkedShared([marked]), "a second relaunch marks nothing")
        XCTAssertNil(UITestingLaunchSeed.listenerMarginMarkedShared([margin("other-item", item: "item-other", at: 50)]))
    }
}
