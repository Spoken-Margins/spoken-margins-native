import XCTest

// J8: put a Library item in a new collection, then choose that collection in the Margins scope and see the
// item and its Margin there. The seed has no Margin, so the script writes one on the item (the same written
// Margin J7 writes) after making the collection and before opening the scope.
// The article is the offline seed (SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT), so no audio or network is involved.
// Screenshots of the sheet are attached to the test result (kept by the xcresult), so the Add to Collection
// sheet can be looked at without driving the simulator by hand. Whether the sheet looks right stays with
// the agent run and the owner.
final class J8CollectionsJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let articleTitle = "J8: A short walk"
    private let itemId = "item-ui-text-regression"
    private let collectionName = "HIST 210"
    private let note = "J8: the light along the path"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing",
            "-libraryContentTypeFilter", "all", "-libraryListeningStateFilter", "unfinished",
            "-libraryOfflineStateFilter", "all", "-librarySort", "recently_added",
            "-libraryUnfinishedDefaultApplied", "YES"]
        app.launchEnvironment["SPOKEN_MARGINS_UI_TESTING"] = "1"
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] = articleTitle
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] = String(
            repeating: "On a short walk, notice the trees and the light along the path. ",
            count: 20
        )
        app.launchEnvironment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] = "https://example.com/j8-article"
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testAddAnItemToANewCollectionAndFindItInMargins() throws {
        XCTContext.runActivity(named: "J8 step 1: Add to Collection opens from the Library row") { _ in
            app.launch()
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 8), "Library did not open")
            let row = element("library.row.\(itemId)")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Seeded article did not appear in the Library")
            row.press(forDuration: 1.2)
            let add = app.buttons["library.addToCollection.\(itemId)"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5), "The row's menu has no Add to Collection")
            add.tap()
            XCTAssertTrue(element("collection.sheet").waitForExistence(timeout: 5), "The Add to Collection sheet did not open")
            attachScreenshot("collection-sheet-empty")
        }

        XCTContext.runActivity(named: "J8 step 2: Make a collection on the spot, with this item in it") { _ in
            let field = app.textFields["collection.new.field"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "The New Collection field is missing")
            field.tap()
            // Return submits the field, so the button never has to be reached past the keyboard.
            field.typeText(collectionName + "\n")
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "collection.row.")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "The new collection is not listed")
            XCTAssertTrue(row.isSelected, "The new collection does not show this item as in it")
            attachScreenshot("collection-sheet-with-collection")
        }

        XCTContext.runActivity(named: "J8 setup: Write a Margin on the item, then return to the Library") { _ in
            tap("collection.done.button")
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 5), "Did not return to the Library")
            tap("queue.start.\(itemId)")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Now Playing did not open")
            tap("playback.write.button")
            XCTAssertTrue(element("writtenMargin.screen").waitForExistence(timeout: 5), "Write a Margin did not open")
            let field = app.textViews["writtenMargin.text"]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "The Margin's text field is missing")
            field.tap()
            field.typeText(note)
            tap("writtenMargin.save.button")
            XCTAssertTrue(element("playback.screen").waitForExistence(timeout: 8), "Did not return to Now Playing")
            tap("playback.home.button")
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 5), "Did not return to the Library")
        }

        XCTContext.runActivity(named: "J8 step 3: Choosing the collection in the Margins scope shows its item and Margin") { _ in
            openMarginsTab()
            XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 5), "Margins did not open")
            let picker = app.buttons["margins.scope.picker"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "The scope picker is missing")
            picker.tap()
            let choice = app.buttons[collectionName].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "The scope picker does not list the new collection")
            attachScreenshot("margins-scope-picker")
            choice.tap()
            // The picker's value is the chosen scope's title, so this fails if the tap landed on another scope.
            let scoped = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", collectionName), object: picker)
            XCTAssertEqual(XCTWaiter().wait(for: [scoped], timeout: 5), .completed,
                           "The Margins scope did not change to the collection")
            XCTAssertTrue(element("margins.openItem.\(itemId)").waitForExistence(timeout: 5),
                          "The collection's item has no Margins group in the collection's scope")
            let rows = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "margins.row.", note))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5),
                          "The item's written Margin is not listed in the collection's scope")
            attachScreenshot("margins-in-collection-scope")
        }
    }

    /// The tab bar on iPhone, the top tabs on iPad: the identifier sits on the tab's label, which iPhone exposes by name.
    private func openMarginsTab() {
        let byIdentifier = app.tabBars.buttons["navigation.tab.margins"].firstMatch
        let tab = byIdentifier.exists ? byIdentifier : app.buttons["Margins"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "The Margins tab is missing")
        tab.tap()
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ identifier: String) {
        let control = app.buttons[identifier].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing control: \(identifier)")
        XCTAssertTrue(control.isHittable, "Control can't be tapped: \(identifier)")
        control.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
