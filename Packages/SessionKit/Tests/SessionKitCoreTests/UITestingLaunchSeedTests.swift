import XCTest
@testable import SessionKit

/// #667: the UI-test seeds, including the offline podcast for J2, never touch a normal launch.
final class UITestingLaunchSeedTests: XCTestCase {
    private let everySeedVariable = [
        "SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY": "1",
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
        }
        XCTAssertEqual(UITestingLaunchSeed(arguments: ["SpokenMarginsApp"], environment: everySeedVariable), .none)
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
}
