import Foundation
import XCTest
import SessionKitTestInputs
@testable import SessionKit

/// #4044: every queue button says the same words. The names come from `QueueRowAction`, so a swipe button, a menu item and
/// a VoiceOver action cannot drift apart, and the identifiers the Design comment names exist.
final class QueueSwipeSourceGuardTests: XCTestCase {
    private let screens = ["ExperienceLibraryScreen.swift", "ExperienceSourcesScreen.swift", "ExperienceShowScreen.swift"]

    func testNoScreenSpellsOutTheQueueNames() throws {
        for name in screens {
            let text = try TestInputs.text(.appSources, name)
            for word in ["\"Add to Queue\"", "\"Remove from Queue\"", "\"Add newest episode to Queue\"", "\"Remove newest episode from Queue\""] {
                XCTAssertFalse(text.contains(word), "\(name) spells out \(word): use QueueRowAction so the names stay one")
            }
        }
    }

    /// Source-text guard (#4306): reads the comment-stripped code of each screen, and checks the line before each queue
    /// swipe button's identifier, not the file as a whole, so another `swipeSlate` elsewhere in the file can't stand in.
    func testSourceTextEveryQueueSwipeIsTheSwipeSlateTintAndHasItsIdentifier() throws {
        let expected: [(file: String, identifier: String, tinted: Bool)] = [
            ("ExperienceLibraryScreen.swift", "library.queueSwipe.\\(row.id)", true),
            ("ExperienceLibraryScreen.swift", "library.addToQueue.\\(row.id)", false),
            ("ExperienceSourcesScreen.swift", "sources.show.\\(row.id).queue", true),
            ("ExperienceSourcesScreen.swift", "\\(identifier).queue", true),
            ("ExperienceShowScreen.swift", "show.episode.\\(episode.entry.id).queue", true),
            ("ExperienceShowScreen.swift", "show.episode.\\(episode.entry.id).more", false)
        ]
        for item in expected {
            let lines = try TestInputs.code(.appSources, item.file).components(separatedBy: "\n")
            let line = "accessibilityIdentifier(\"\(item.identifier)\")"
            let index = try XCTUnwrap(lines.firstIndex { $0.contains(line) }, "\(item.file) lost \(item.identifier)")
            guard item.tinted else { continue }
            let before = lines[..<index].last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            XCTAssertEqual(before?.trimmingCharacters(in: .whitespaces), ".tint(AppColors.swipeSlate)",
                           "\(item.file): the queue swipe \(item.identifier) uses the fixed swipeSlate tint (#4045)")
        }
        // The journeys tap these by identifier; the new buttons must not have moved them.
        let library = try TestInputs.code(.appSources, "ExperienceLibraryScreen.swift")
        let sources = try TestInputs.code(.appSources, "ExperienceSourcesScreen.swift")
        XCTAssertTrue(library.contains("library.complete.\\(row.id)"))
        XCTAssertTrue(sources.contains("sources.show.\\(row.id).add"))
    }

    /// Source-text guard (#4306): the call's own text, comments removed, so a comment that quotes the old flag can't pass.
    func testSourceTextTheLongSwipeStillBelongsToTheFirstButtonOnEachRow() throws {
        // The first button in a leading swipeActions block takes the long swipe, so Add to Queue is written after Complete
        // and after Add, and a row with only the queue button turns the long swipe off.
        let library = try TestInputs.code(.appSources, "ExperienceLibraryScreen.swift")
        XCTAssertLessThan(try XCTUnwrap(library.range(of: "library.complete.\\(row.id)")).lowerBound,
                          try XCTUnwrap(library.range(of: "library.queueSwipe.\\(row.id)")).lowerBound)
        XCTAssertTrue(library.contains("swipeActions(edge: .leading, allowsFullSwipe: !row.isCompleted)"))
        let sources = try TestInputs.code(.appSources, "ExperienceSourcesScreen.swift")
        XCTAssertLessThan(try XCTUnwrap(sources.range(of: "sources.show.\\(row.id).add\")")).lowerBound,
                          try XCTUnwrap(sources.range(of: "queueSwipeButton(row)")).lowerBound)
        XCTAssertTrue(sources.contains("swipeActions(edge: .leading, allowsFullSwipe: row.addEntryID != nil)"))
        let show = try TestInputs.code(.appSources, "ExperienceShowScreen.swift")
        XCTAssertTrue(show.contains("swipeActions(edge: .leading, allowsFullSwipe: false)"), "an in-Library episode has no long swipe")
    }
}
