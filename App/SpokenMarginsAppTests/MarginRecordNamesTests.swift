import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #3849: the record button's drawn words were not in its accessible name, so a spoken "Tap Add a Margin" could miss it.
/// #4312: these read the drawn button's names from the accessibility tree, as Voice Control does. Comparing the constants
/// with each other still passed with `.accessibilityInputLabels` taken off the button.
@MainActor
final class MarginRecordNamesTests: XCTestCase {
    private static var automationWasEnabled: Int32?

    override class func setUp() {
        super.setUp()
        automationWasEnabled = AccessibilityAutomation.enable()
    }

    override class func tearDown() {
        if let automationWasEnabled { AccessibilityAutomation.set(automationWasEnabled) }
        super.tearDown()
    }

    func testVoiceControlCanReachTheButtonByItsDrawnWordsAtEveryTextSize() async throws {
        for (textSize, accessibilitySize) in [(DynamicTypeSize.large, false), (.accessibility3, true)] {
            let button = try await recordButton(textSize: textSize)
            let drawn = MarginRecordNames.visible(accessibilitySize: accessibilitySize)
            XCTAssertTrue(button.inputLabels.contains(drawn),
                          "\"\(drawn)\" is drawn on the button but Voice Control has only \(button.inputLabels)")
        }
    }

    func testVoiceOverKeepsItsClearName() async throws {
        let button = try await recordButton(textSize: .large)
        XCTAssertEqual(button.label, "Record a Margin")
        XCTAssertTrue(button.inputLabels.contains("Record a Margin"),
                      "someone who learned the VoiceOver name can still say it; Voice Control has \(button.inputLabels)")
    }

    func testTheFirstInputLabelIsTheDefaultSizeWords() async throws {
        let button = try await recordButton(textSize: .large)
        XCTAssertEqual(button.inputLabels.first, "Add a Margin")
    }

    private func recordButton(textSize: DynamicTypeSize) async throws -> AccessibilityNode {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let buttons = MarginAddButtons(record: {}, write: {}, recordIdentifier: "test.record", writeIdentifier: "test.write")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: buttons.environment(\.dynamicTypeSize, textSize))
        window.makeKeyAndVisible()
        let mounted = MountedTree(window: window, previousKeyWindow: previousKeyWindow)
        defer { mounted.close() }
        return try await mounted.waitForNode("the record button") { $0.identifier == "test.record" }
    }
}
