import XCTest
@testable import SessionKit

/// #4711: the event "first Margin heard", the one-time migration and the first-run entry.
final class FirstMarginHeardTests: XCTestCase {
    private func progress(steps: [String]? = nil) -> OnboardingProgress {
        OnboardingProgress(storedSteps: steps, storedStage: nil, isCardDismissed: false)
    }

    // MARK: The rule, one test per row of the Design's table

    func testOwnSpokenMarginPlayedToItsEndFires() {
        var value = progress()
        let change = value.marginHeard(.init(isListenersOwn: true, kind: .spoken, outcome: .reachedEnd))
        XCTAssertTrue(change.contains(.steps))
        XCTAssertTrue(value.isComplete(.heardFirstMargin))
    }

    func testOwnSpokenMarginSkippedOrStoppedEarlyDoesNotFireAndTheNextFullPlaybackCan() {
        var value = progress()
        XCTAssertTrue(value.marginHeard(.init(isListenersOwn: true, kind: .spoken, outcome: .stoppedEarly)).isEmpty)
        XCTAssertFalse(value.isComplete(.heardFirstMargin))
        XCTAssertTrue(value.marginHeard(.init(isListenersOwn: true, kind: .spoken, outcome: .reachedEnd)).contains(.steps))
    }

    func testOwnSpokenMarginThatCouldNotPlayDoesNotFire() {
        var value = progress()
        XCTAssertTrue(value.marginHeard(.init(isListenersOwn: true, kind: .spoken, outcome: .couldNotPlay)).isEmpty)
        XCTAssertFalse(value.isComplete(.heardFirstMargin))
    }

    func testAFriendsOrColesMarginNeverFiresWhateverTheOutcome() {
        for kind in [MarginHearing.Kind.spoken, .written] {
            for outcome in [MarginHearing.Outcome.reachedEnd, .stoppedEarly, .couldNotPlay, .savedAndShown] {
                var value = progress()
                let hearing = MarginHearing(isListenersOwn: false, kind: kind, outcome: outcome)
                XCTAssertFalse(OnboardingProgress.firesFirstMarginHeard(hearing), "\(kind) \(outcome)")
                XCTAssertTrue(value.marginHeard(hearing).isEmpty, "\(kind) \(outcome)")
            }
        }
    }

    func testOwnWrittenMarginFiresWhenSavedAndShown() {
        var value = progress()
        XCTAssertTrue(value.marginHeard(.init(isListenersOwn: true, kind: .written, outcome: .savedAndShown)).contains(.steps))
    }

    /// Every combination, so a new outcome or kind has to be decided here.
    func testOnlyTheTwoDocumentedCombinationsFire() {
        var firing: [String] = []
        for own in [true, false] {
            for kind in [MarginHearing.Kind.spoken, .written] {
                for outcome in [MarginHearing.Outcome.reachedEnd, .stoppedEarly, .couldNotPlay, .savedAndShown]
                where OnboardingProgress.firesFirstMarginHeard(.init(isListenersOwn: own, kind: kind, outcome: outcome)) {
                    firing.append("\(own) \(kind) \(outcome)")
                }
            }
        }
        XCTAssertEqual(firing.sorted(), ["true spoken reachedEnd", "true written savedAndShown"])
    }

    func testItFiresOnce() {
        var value = progress()
        let hearing = MarginHearing(isListenersOwn: true, kind: .spoken, outcome: .reachedEnd)
        XCTAssertTrue(value.marginHeard(hearing).contains(.steps))
        XCTAssertTrue(value.marginHeard(hearing).isEmpty)
        XCTAssertTrue(value.marginHeard(.init(isListenersOwn: true, kind: .written, outcome: .savedAndShown)).isEmpty)
    }

    func testTheStoredStepsIncludeTheNewName() {
        var value = progress()
        value.marginHeard(.init(isListenersOwn: true, kind: .spoken, outcome: .reachedEnd))
        XCTAssertEqual(value.storedSteps, ["heard_first_margin"])
        XCTAssertTrue(progress(steps: value.storedSteps).isComplete(.heardFirstMargin))
    }

    // MARK: hasRunBefore: a table of neighbouring inputs

    func testHasRunBeforeIsTrueForAnyOneTraceAndFalseForNone() {
        let rows: [(version: Int, steps: [String]?, terms: String?, tombstone: Bool, expected: Bool, why: String)] = [
            (0, nil, nil, false, false, "nothing stored"),
            (0, [], nil, false, false, "an empty list is not a step"),
            (1, nil, nil, false, true, "an old welcome seed"),
            (2, nil, nil, false, true, "the current welcome seed"),
            (0, ["first_interjection"], nil, false, true, "a step"),
            (0, ["a_step_from_a_later_build"], nil, false, true, "a step this build doesn't know"),
            (0, nil, "", false, true, "an empty stored version is still a stored acceptance"),
            (0, nil, "1.0", false, true, "accepted Terms"),
            (0, nil, nil, true, true, "the welcome tombstone"),
            (2, ["first_interjection"], "1.0", true, true, "everything")
        ]
        for row in rows {
            XCTAssertEqual(
                FirstRunHistory.hasRunBefore(
                    storedWelcomeSampleVersion: row.version, storedSteps: row.steps,
                    termsAcceptedVersion: row.terms, welcomeTombstoned: row.tombstone
                ),
                row.expected, row.why
            )
        }
    }

    /// The inputs the app reads, through a real UserDefaults suite.
    func testHasRunBeforeFromARealDefaultsSuite() throws {
        let name = "first-margin-heard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func ran() -> Bool {
            FirstRunHistory.hasRunBefore(
                storedWelcomeSampleVersion: defaults.integer(forKey: "welcomeSampleSeedVersion"),
                storedSteps: defaults.stringArray(forKey: "onboardingCompletedStepsV1"),
                termsAcceptedVersion: SpokenMarginsTerms.acceptedVersion(in: defaults),
                welcomeTombstoned: false
            )
        }
        XCTAssertFalse(ran())
        defaults.set(2, forKey: "welcomeSampleSeedVersion")
        XCTAssertTrue(ran())
        defaults.removeObject(forKey: "welcomeSampleSeedVersion")
        defaults.set("1.0", forKey: SpokenMarginsTerms.acceptanceVersionKey)
        XCTAssertTrue(ran())
    }

    // MARK: The migration, by starting state

    func testFreshInstallStoresColdEntry() {
        XCTAssertEqual(FirstRunHistory.migration(alreadyRan: false, libraryWasEmptyAtLaunch: true, hasRunBefore: false), .freshInstall)
    }

    func testUpgradeWithLibraryMarksHeard() {
        XCTAssertEqual(FirstRunHistory.migration(alreadyRan: false, libraryWasEmptyAtLaunch: false, hasRunBefore: true), .markHeard)
        XCTAssertEqual(FirstRunHistory.migration(alreadyRan: false, libraryWasEmptyAtLaunch: false, hasRunBefore: false), .markHeard)
    }

    func testEmptiedLibraryWithHistoryMarksHeard() {
        XCTAssertEqual(FirstRunHistory.migration(alreadyRan: false, libraryWasEmptyAtLaunch: true, hasRunBefore: true), .markHeard)
    }

    func testMigrationRunsOnce() {
        for empty in [true, false] {
            for ran in [true, false] {
                XCTAssertEqual(FirstRunHistory.migration(alreadyRan: true, libraryWasEmptyAtLaunch: empty, hasRunBefore: ran), .nothing)
            }
        }
    }

    func testSavedButUnheardStillFiresLater() {
        var value = progress()
        XCTAssertEqual(FirstRunHistory.migration(alreadyRan: false, libraryWasEmptyAtLaunch: true, hasRunBefore: false), .freshInstall)
        value.firstInterjectionSaved()
        XCTAssertEqual(FirstRunHistory.migration(alreadyRan: true, libraryWasEmptyAtLaunch: false, hasRunBefore: true), .nothing)
        XCTAssertTrue(value.marginHeard(.init(isListenersOwn: true, kind: .spoken, outcome: .reachedEnd)).contains(.steps))
    }

    func testEntryRawValuesAreTheStoredNames() {
        XCTAssertEqual(FirstRunEntry.coldInstall.rawValue, "cold_install")
        XCTAssertEqual(FirstRunEntry.friendArrival.rawValue, "friend_arrival")
    }
}
