import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #1020: what Library bootstrap seeds on launch, pinned before the bootstrap moves out of the model.
/// The seed keys live in `UserDefaults.standard`, so each test saves them in `setUp` and restores them
/// in `tearDown`. The key strings are written out here on purpose: they must not change.
@MainActor
final class Gate1LibrarySeedingTests: XCTestCase {
    private static let welcomeVersionKey = "welcomeSampleSeedVersion"
    private static let tourVersionKey = "guidedOnboardingSeedVersion"
    private static let tourTombstoneKey = "guidedOnboardingTombstone"
    private var priorDefaults: [String: Any] = [:]
    private var root: URL!

    override func setUp() {
        super.setUp()
        for key in [Self.welcomeVersionKey, Self.tourVersionKey, Self.tourTombstoneKey] {
            priorDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gate1LibrarySeedingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for key in [Self.welcomeVersionKey, Self.tourVersionKey, Self.tourTombstoneKey] {
            if let value = priorDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        priorDefaults = [:]
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var databaseURL: URL { root.appendingPathComponent("library.sqlite") }

    private func bootstrappedModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.bootstrapLibraryIfNeeded()
        return model
    }

    private func saveExistingItem() throws {
        var item = Gate1AppModel.makeBundledGuidedOnboardingItem()
        item.id = "item-existing"
        item.title = "An item the listener added"
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveItem(item)
    }

    func testAnEmptyLibraryWithNoStoredVersionGetsTheWelcomeSampleAndStoresVersion2() throws {
        UserDefaults.standard.set(true, forKey: Self.tourTombstoneKey)

        let model = bootstrappedModel()

        XCTAssertEqual(model.libraryItems.map(\.id), [Gate1AppModel.welcomeSampleItemId])
        XCTAssertEqual(UserDefaults.standard.integer(forKey: Self.welcomeVersionKey), 2)
        XCTAssertEqual(model.diagnostics["welcomeSample"], "seeded:v2")
        XCTAssertEqual(model.diagnostics["libraryBootstrap"], "loaded:1")
        XCTAssertEqual(model.statusMessage, "Library ready.")
        XCTAssertNil(model.libraryAccessError)
    }

    func testAStoredVersion2DoesNotReseedTheWelcomeSample() throws {
        UserDefaults.standard.set(2, forKey: Self.welcomeVersionKey)
        UserDefaults.standard.set(true, forKey: Self.tourTombstoneKey)

        let model = bootstrappedModel()

        XCTAssertEqual(model.libraryItems.map(\.id), [])
        XCTAssertNil(model.diagnostics["welcomeSample"])
        XCTAssertEqual(model.diagnostics["libraryBootstrap"], "loaded:0")
        XCTAssertEqual(model.statusMessage, "Add a source to begin.")
    }

    func testALibraryWithItemsGetsNoWelcomeSampleButStillStoresVersion2() throws {
        UserDefaults.standard.set(true, forKey: Self.tourTombstoneKey)
        try saveExistingItem()

        let model = bootstrappedModel()

        XCTAssertEqual(model.libraryItems.map(\.id), ["item-existing"])
        XCTAssertNil(model.diagnostics["welcomeSample"])
        XCTAssertEqual(UserDefaults.standard.integer(forKey: Self.welcomeVersionKey), 2,
                       "bootstrap advances the welcome version even when it adds no welcome item")
    }

    func testTheGuidedTourIsSeededWithItsBundledItemAndMapAndStoresVersion1() throws {
        UserDefaults.standard.set(2, forKey: Self.welcomeVersionKey)

        let model = bootstrappedModel()

        XCTAssertEqual(model.libraryItems.map(\.id), [Gate1AppModel.guidedOnboardingItemId])
        XCTAssertEqual(UserDefaults.standard.integer(forKey: Self.tourVersionKey), 1)
        XCTAssertEqual(model.diagnostics["guidedOnboardingItem"], "bundled_fallback_seeded")

        let store = try model.libraryStoreForTesting()
        let item = try store.loadItem(id: "guided-onboarding")
        XCTAssertEqual(item.title, "Guided Tour: Add and Prepare Sources")
        XCTAssertEqual(item.mediaType, "guided_tour")
        XCTAssertEqual(item.externalReference, "bundled://guided-onboarding.v1")
        XCTAssertEqual(item.externalReferenceType, "guided_onboarding")
        XCTAssertEqual(item.status, "ready")
        XCTAssertEqual(item.sourceTitle, "Spoken Margins")
        XCTAssertEqual(item.text, Gate1AppModel.makeBundledGuidedOnboardingItem().text)
        XCTAssertTrue(item.text?.hasPrefix("Welcome to Spoken Margins. Add text, PDF, a readable webpage, or a podcast") == true)

        let map = try XCTUnwrap(store.loadListeningMap(itemId: "guided-onboarding"))
        XCTAssertEqual(map.id, "map-guided-onboarding")
        XCTAssertEqual(map.overview, "Practice listening, interjecting, reviewing the timeline, and exporting a session.")
        XCTAssertEqual(map.chapters.map(\.id), ["guided-onboarding-core-loop"])
        XCTAssertEqual(map.chapters.first?.title, "The Core Loop")
        XCTAssertEqual(map.chapters.first?.startChar, 0)
        XCTAssertEqual(map.chapters.first?.endChar, item.text?.count)
        XCTAssertEqual(map.chapters.first?.percent, 0)
    }

    func testAStoredTourVersionOf1MeansTheTourIsNotSeededAgain() throws {
        UserDefaults.standard.set(2, forKey: Self.welcomeVersionKey)
        UserDefaults.standard.set(1, forKey: Self.tourVersionKey)

        let model = bootstrappedModel()

        XCTAssertEqual(model.libraryItems.map(\.id), [])
        XCTAssertNil(model.diagnostics["guidedOnboardingItem"])
    }

    func testATombstonedTourIsNotSeeded() throws {
        UserDefaults.standard.set(2, forKey: Self.welcomeVersionKey)
        UserDefaults.standard.set(true, forKey: Self.tourTombstoneKey)

        let model = bootstrappedModel()

        XCTAssertEqual(model.libraryItems.map(\.id), [])
        XCTAssertNil(model.diagnostics["guidedOnboardingItem"])
        XCTAssertEqual(UserDefaults.standard.integer(forKey: Self.tourVersionKey), 0)
    }

    func testAnExistingTourItemIsNotSeededOverOrCounted() throws {
        UserDefaults.standard.set(2, forKey: Self.welcomeVersionKey)
        var existing = Gate1AppModel.makeBundledGuidedOnboardingItem()
        existing.title = "The tour the listener already has"
        try SQLiteSessionStore(path: databaseURL.path).saveItem(existing)

        let model = bootstrappedModel()

        XCTAssertNil(model.diagnostics["guidedOnboardingItem"])
        XCTAssertEqual(UserDefaults.standard.integer(forKey: Self.tourVersionKey), 0)
        XCTAssertEqual(try model.libraryStoreForTesting().loadItem(id: "guided-onboarding").title,
                       "The tour the listener already has")
    }

    func testALibraryThatCannotBeOpenedIsReportedAndLeftUntouched() throws {
        let unreadable = Data("this is not a SQLite database, and bootstrap must not replace it".utf8)
        try unreadable.write(to: databaseURL)

        let model = bootstrappedModel()

        XCTAssertEqual(
            model.libraryAccessError?.hasPrefix(
                "This build could not open your existing library. This attempt did not reset it. Do not use Reset Library or delete the app; install a compatible build and try again. Details: "
            ),
            true,
            model.libraryAccessError ?? "no libraryAccessError"
        )
        XCTAssertTrue(model.diagnostics["libraryBootstrap"]?.hasPrefix("failed_without_reset:") == true,
                      model.diagnostics["libraryBootstrap"] ?? "no libraryBootstrap diagnostic")
        XCTAssertEqual(try Data(contentsOf: databaseURL), unreadable, "the unreadable library file is left as it was")
    }
}
