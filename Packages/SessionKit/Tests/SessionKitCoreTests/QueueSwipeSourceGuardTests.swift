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

    func testEveryQueueSwipeIsTheSwipeSlateTintAndHasItsIdentifier() throws {
        let expected: [(file: String, identifier: String)] = [
            ("ExperienceLibraryScreen.swift", "library.queueSwipe.\\(row.id)"),
            ("ExperienceLibraryScreen.swift", "library.addToQueue.\\(row.id)"),
            ("ExperienceSourcesScreen.swift", "sources.show.\\(row.id).queue"),
            ("ExperienceSourcesScreen.swift", "\\(identifier).queue"),
            ("ExperienceShowScreen.swift", "show.episode.\\(episode.entry.id).queue"),
            ("ExperienceShowScreen.swift", "show.episode.\\(episode.entry.id).more")
        ]
        for item in expected {
            let text = try TestInputs.text(.appSources, item.file)
            XCTAssertTrue(text.contains("accessibilityIdentifier(\"\(item.identifier)\")"), "\(item.file) lost \(item.identifier)")
        }
        // The journeys tap these by identifier; the new buttons must not have moved them.
        let library = try TestInputs.text(.appSources, "ExperienceLibraryScreen.swift")
        let sources = try TestInputs.text(.appSources, "ExperienceSourcesScreen.swift")
        XCTAssertTrue(library.contains("library.complete.\\(row.id)"))
        XCTAssertTrue(sources.contains("sources.show.\\(row.id).add"))
        for name in ["ExperienceLibraryScreen.swift", "ExperienceSourcesScreen.swift", "ExperienceShowScreen.swift"] {
            let text = try TestInputs.text(.appSources, name)
            if text.contains("QueueRowAction"), text.contains(".queue") || text.contains("queueSwipe") {
                XCTAssertTrue(text.contains("AppColors.swipeSlate"), "\(name): the queue swipe uses the fixed swipeSlate tint (#4045)")
            }
        }
    }

    func testTheLongSwipeStillBelongsToTheFirstButtonOnEachRow() throws {
        // The first button in a leading swipeActions block takes the long swipe, so Add to Queue is written after Complete
        // and after Add, and a row with only the queue button turns the long swipe off.
        let library = try TestInputs.text(.appSources, "ExperienceLibraryScreen.swift")
        XCTAssertLessThan(try XCTUnwrap(library.range(of: "library.complete.\\(row.id)")).lowerBound,
                          try XCTUnwrap(library.range(of: "library.queueSwipe.\\(row.id)")).lowerBound)
        XCTAssertTrue(library.contains("swipeActions(edge: .leading, allowsFullSwipe: !row.isCompleted)"))
        let sources = try TestInputs.text(.appSources, "ExperienceSourcesScreen.swift")
        XCTAssertLessThan(try XCTUnwrap(sources.range(of: "sources.show.\\(row.id).add\")")).lowerBound,
                          try XCTUnwrap(sources.range(of: "queueSwipeButton(row)")).lowerBound)
        XCTAssertTrue(sources.contains("swipeActions(edge: .leading, allowsFullSwipe: row.addEntryID != nil)"))
        let show = try TestInputs.text(.appSources, "ExperienceShowScreen.swift")
        XCTAssertTrue(show.contains("swipeActions(edge: .leading, allowsFullSwipe: false)"), "an in-Library episode has no long swipe")
    }
}
