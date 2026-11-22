import Foundation
import XCTest
import SessionKitTestInputs
@testable import SessionKit

/// #4044: every queue button says the same words. The names come from `QueueRowAction`, so a swipe button, a menu item and
/// a VoiceOver action cannot drift apart, and the identifiers the Design comment names exist.
///
/// These read the app's `.swift` files as text, because the screens cannot be built on Linux (#4306). Each guard scans the
/// specific button or `swipeActions` call, with comments removed, never the whole file: a tint that sits in a comment, or
/// on another button, does not satisfy it. `SourceTextRules` takes the text so the self-tests can show it fails on a
/// mutated copy.
final class QueueSwipeSourceGuardTests: XCTestCase {
    private let screens = ["ExperienceLibraryScreen.swift", "ExperienceSourcesScreen.swift", "ExperienceShowScreen.swift"]

    /// Each queue swipe button, by file: the identifier that marks it, which `swipeActions` call it sits in, and the
    /// `swipeActions` arguments that call must have.
    private static let swipes: [(file: String, identifier: String, swipeArguments: String)] = [
        ("ExperienceLibraryScreen.swift", "library.queueSwipe.\\(row.id)", "edge: .leading, allowsFullSwipe: !row.isCompleted"),
        ("ExperienceSourcesScreen.swift", "sources.show.\\(row.id).queue", ""),
        ("ExperienceSourcesScreen.swift", "\\(identifier).queue", "edge: .leading, allowsFullSwipe: true"),
        ("ExperienceShowScreen.swift", "show.episode.\\(episode.entry.id).queue", "edge: .leading, allowsFullSwipe: false")
    ]

    enum SourceTextRules {
        static let spelledOut = ["\"Add to Queue\"", "\"Remove from Queue\"", "\"Add newest episode to Queue\"", "\"Remove newest episode from Queue\""]

        static func spelledOutNames(_ text: String) -> [String] {
            let code = SwiftSourceScan.code(text)
            return spelledOut.filter { code.contains($0) }
        }

        /// The queue button that carries `identifier` is tinted swipeSlate: the tint is in that button's own chain.
        static func tintProblems(_ text: String, identifier: String) -> [String] {
            let code = SwiftSourceScan.code(text)
            guard let chain = SwiftSourceScan.chain(endingAt: "accessibilityIdentifier(\"\(identifier)\")", startingWith: ["Button"], in: code) else {
                return ["no Button statement ends with the identifier \(identifier)"]
            }
            return chain.contains(".tint(AppColors.swipeSlate)") ? [] : ["the button \(identifier) is not tinted AppColors.swipeSlate (#4045)"]
        }

        /// The `swipeActions(edge: .leading ...)` call whose block holds `marker` has exactly these arguments.
        static func swipeArgumentProblems(_ text: String, enclosing marker: String, arguments: String) -> [String] {
            let code = SwiftSourceScan.code(text)
            guard let call = SwiftSourceScan.call(".swipeActions(", enclosing: marker, in: code) else {
                return ["\(marker) is not inside a swipeActions block"]
            }
            let written = call.arguments.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return written == arguments ? [] : ["the swipeActions around \(marker) is (\(written)), expected (\(arguments))"]
        }

        /// In the code, `first` is written before `second`, both inside the swipeActions call that holds `second`.
        static func orderProblems(_ text: String, first: String, second: String) -> [String] {
            let code = SwiftSourceScan.code(text)
            guard let call = SwiftSourceScan.call(".swipeActions(", enclosing: second, in: code), let block = call.block else {
                return ["\(second) is not inside a swipeActions block"]
            }
            guard let one = block.range(of: first), let two = block.range(of: second) else { return ["\(first) is not in the same swipeActions block as \(second)"] }
            return one.lowerBound < two.lowerBound ? [] : ["\(first) must come before \(second): the first button takes the long swipe"]
        }
    }

    func testNoScreenSpellsOutTheQueueNamesInSourceText() throws {
        for name in screens {
            let text = try TestInputs.text(.appSources, name)
            XCTAssertEqual(SourceTextRules.spelledOutNames(text), [], "\(name) spells out a queue name: use QueueRowAction so the names stay one")
        }
    }

    func testEveryQueueSwipeIdentifierExistsInSourceText() throws {
        let expected: [(file: String, identifier: String)] = [
            ("ExperienceLibraryScreen.swift", "library.queueSwipe.\\(row.id)"),
            ("ExperienceLibraryScreen.swift", "library.addToQueue.\\(row.id)"),
            ("ExperienceSourcesScreen.swift", "sources.show.\\(row.id).queue"),
            ("ExperienceSourcesScreen.swift", "\\(identifier).queue"),
            ("ExperienceShowScreen.swift", "show.episode.\\(episode.entry.id).queue"),
            ("ExperienceShowScreen.swift", "show.episode.\\(episode.entry.id).more"),
            ("ExperienceLibraryScreen.swift", "library.complete.\\(row.id)"),
            ("ExperienceSourcesScreen.swift", "sources.show.\\(row.id).add")
        ]
        // The journeys tap these by identifier; the new buttons must not have moved them.
        for item in expected {
            let code = SwiftSourceScan.code(try TestInputs.text(.appSources, item.file))
            XCTAssertTrue(code.contains("accessibilityIdentifier(\"\(item.identifier)\")"), "\(item.file) lost \(item.identifier)")
        }
    }

    func testEveryQueueSwipeButtonIsTheSwipeSlateTintInSourceText() throws {
        for swipe in Self.swipes {
            let text = try TestInputs.text(.appSources, swipe.file)
            XCTAssertEqual(SourceTextRules.tintProblems(text, identifier: swipe.identifier), [], swipe.file)
        }
    }

    func testTheLongSwipeStillBelongsToTheFirstButtonOnEachRowInSourceText() throws {
        // The first button in a leading swipeActions block takes the long swipe, so Add to Queue is written after Complete
        // and after Add, and a row with only the queue button turns the long swipe off.
        let library = try TestInputs.text(.appSources, "ExperienceLibraryScreen.swift")
        XCTAssertEqual(SourceTextRules.orderProblems(library, first: "library.complete.\\(row.id)", second: "library.queueSwipe.\\(row.id)"), [])
        let sources = try TestInputs.text(.appSources, "ExperienceSourcesScreen.swift")
        XCTAssertEqual(SourceTextRules.orderProblems(sources, first: "sources.show.\\(row.id).add\")", second: "queueSwipeButton(row)"), [])
        for swipe in Self.swipes where !swipe.swipeArguments.isEmpty {
            let text = try TestInputs.text(.appSources, swipe.file)
            XCTAssertEqual(SourceTextRules.swipeArgumentProblems(text, enclosing: "accessibilityIdentifier(\"\(swipe.identifier)\")", arguments: swipe.swipeArguments), [], swipe.file)
        }
        // The Following show row: the long swipe adds only when there is an episode to add.
        XCTAssertEqual(SourceTextRules.swipeArgumentProblems(sources, enclosing: "queueSwipeButton(row)", arguments: "edge: .leading, allowsFullSwipe: row.addEntryID != nil"), [])
    }

    // MARK: the rules fail on the mutations issue #4306 names

    func testATintOnAnotherButtonOrInACommentDoesNotCountAsTheQueueTint() throws {
        let sources = try TestInputs.text(.appSources, "ExperienceSourcesScreen.swift")
        let queue = "            .tint(AppColors.swipeSlate)\n            .accessibilityIdentifier(\"sources.show.\\(row.id).queue\")"
        XCTAssertTrue(sources.contains(queue), "the mutation below must find the queue button")
        let recoloured = sources.replacingOccurrences(of: queue, with: "            .tint(.red)\n            .accessibilityIdentifier(\"sources.show.\\(row.id).queue\")")
        XCTAssertNotEqual(SourceTextRules.tintProblems(recoloured, identifier: "sources.show.\\(row.id).queue"), [], "other swipeSlate uses remain in the file")
        let commented = sources.replacingOccurrences(of: queue, with: "            .tint(.red) // was .tint(AppColors.swipeSlate)\n            .accessibilityIdentifier(\"sources.show.\\(row.id).queue\")")
        XCTAssertNotEqual(SourceTextRules.tintProblems(commented, identifier: "sources.show.\\(row.id).queue"), [])
        // And the real file is fine.
        XCTAssertEqual(SourceTextRules.tintProblems(sources, identifier: "sources.show.\\(row.id).queue"), [])
    }

    func testAFullSwipeLeftOnWithTheOldValueInACommentIsCaught() throws {
        let library = try TestInputs.text(.appSources, "ExperienceLibraryScreen.swift")
        let real = ".swipeActions(edge: .leading, allowsFullSwipe: !row.isCompleted) {"
        XCTAssertTrue(library.contains(real), "the mutation below must find the swipeActions call")
        let mutated = library.replacingOccurrences(of: real, with: ".swipeActions(edge: .leading, allowsFullSwipe: true) { // was swipeActions(edge: .leading, allowsFullSwipe: !row.isCompleted)")
        XCTAssertNotEqual(SourceTextRules.swipeArgumentProblems(mutated, enclosing: "accessibilityIdentifier(\"library.queueSwipe.\\(row.id)\")", arguments: "edge: .leading, allowsFullSwipe: !row.isCompleted"), [])
    }

    func testTheQueueButtonWrittenFirstTakesTheLongSwipeAndIsCaught() throws {
        let library = try TestInputs.text(.appSources, "ExperienceLibraryScreen.swift")
        let complete = "library.complete.\\(row.id)"
        let queue = "library.queueSwipe.\\(row.id)"
        let swapped = library.replacingOccurrences(of: complete, with: "TEMP").replacingOccurrences(of: queue, with: complete).replacingOccurrences(of: "TEMP", with: queue)
        XCTAssertNotEqual(SourceTextRules.orderProblems(swapped, first: complete, second: queue), [])
    }

    func testAQueueNameSpelledOutIsCaughtButOneInACommentIsNot() {
        XCTAssertNotEqual(SourceTextRules.spelledOutNames("Text(\"Add to Queue\")"), [])
        XCTAssertEqual(SourceTextRules.spelledOutNames("// the old label was \"Add to Queue\"\nText(action.title)"), [])
    }
}
