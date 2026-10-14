import XCTest

// J8: put a Library item in a new collection, then find that collection in the Margins scope.
// The article is the offline seed (SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT), so no audio or network is involved.
// Screenshots of the sheet are attached to the test result (kept by the xcresult), so the Add to Collection
// sheet can be looked at without driving the simulator by hand. Whether the sheet looks right stays with
// the agent run and the owner.
final class J8CollectionsJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let articleTitle = "J8: A short walk"
    private let itemId = "item-ui-text-regression"
    private let collectionName = "HIST 210"

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
            field.typeText(collectionName)
            tap("collection.new.button")
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "collection.row.")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "The new collection is not listed")
            XCTAssertTrue(row.isSelected, "The new collection does not show this item as in it")
            attachScreenshot("collection-sheet-with-collection")
        }

        XCTContext.runActivity(named: "J8 step 3: The Margins scope offers the collection") { _ in
            tap("collection.done.button")
            XCTAssertTrue(element("home.screen").waitForExistence(timeout: 5), "Did not return to the Library")
            tap("navigation.tab.margins")
            XCTAssertTrue(element("margins.screen").waitForExistence(timeout: 5), "Margins did not open")
            let picker = app.buttons["margins.scope.picker"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "The scope picker is missing")
            picker.tap()
            XCTAssertTrue(app.buttons[collectionName].firstMatch.waitForExistence(timeout: 5),
                          "The scope picker does not list the new collection")
            attachScreenshot("margins-scope-picker")
        }
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
