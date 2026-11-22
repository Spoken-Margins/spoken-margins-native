import Foundation
import XCTest
@testable import SessionKit

/// "Where should this go?" (#4672): asked once, after the first Margin has been heard on a cold install; each
/// answer leads to exactly one setup; the answer stays in UserDefaults on the phone.
final class MarginDestinationQuestionTests: XCTestCase {
    typealias Context = MarginDestinationQuestion.Context

    private var suites: [String] = []

    /// A defaults suite of its own, removed afterwards. Rebuilding a question over the same suite is a relaunch.
    private func makeDefaults() -> UserDefaults {
        let suite = "MarginDestinationQuestionTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func present(_ q: MarginDestinationQuestion, heard: Bool = true, active: Bool = true,
                         something: Bool = false, recording: Bool = false, speech: Bool = false,
                         friendCard: Bool = false) -> Bool {
        q.shouldPresent(firstMarginHeardColdInstall: heard, appActive: active, somethingPresented: something,
                        recording: recording, speechAskShowing: speech, friendShareCardShowing: friendCard)
    }

    // MARK: shouldPresent

    func testPresentsWhenEveryConditionHolds() {
        XCTAssertTrue(present(MarginDestinationQuestion(defaults: makeDefaults())))
    }

    func testEachConditionAloneKeepsItFromPresenting() {
        let rows: [(String, (MarginDestinationQuestion) -> Bool)] = [
            ("first Margin not heard on a cold install", { self.present($0, heard: false) }),
            ("app inactive", { self.present($0, active: false) }),
            ("something presented", { self.present($0, something: true) }),
            ("recording", { self.present($0, recording: true) }),
            ("speech ask showing", { self.present($0, speech: true) }),
            ("friend share card showing", { self.present($0, friendCard: true) }),
        ]
        for (name, check) in rows {
            XCTAssertFalse(check(MarginDestinationQuestion(defaults: makeDefaults())), name)
        }
    }

    func testBackgroundThenForegroundPresentsWhenActive() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        XCTAssertFalse(present(q, active: false))
        XCTAssertTrue(present(q, active: true))
    }

    func testRelaunchBeforePresentingStillPresents() {
        let defaults = makeDefaults()
        XCTAssertTrue(present(MarginDestinationQuestion(defaults: defaults)))
        XCTAssertTrue(present(MarginDestinationQuestion(defaults: defaults)), "never marked presented")
    }

    func testPresentedOnceAcrossARelaunch() {
        let defaults = makeDefaults()
        MarginDestinationQuestion(defaults: defaults).markPresented()
        XCTAssertFalse(present(MarginDestinationQuestion(defaults: defaults)))
        XCTAssertFalse(present(MarginDestinationQuestion(defaults: defaults)))
    }

    func testMarkPresentedIsStoredUnderItsKey() {
        let defaults = makeDefaults()
        MarginDestinationQuestion(defaults: defaults).markPresented()
        XCTAssertTrue(defaults.bool(forKey: "marginDestinationPresentedV1"))
    }

    // MARK: answers and setups

    func testEachAnswerReturnsItsSetup() {
        let context = Context(marginOffersShare: true, quizAvailable: true)
        let rows: [(MarginDestination, MarginDestinationSetup)] = [
            (.keepHere, .none),
            (.notes, .notesStep),
            (.person, .personStep(sendThisMargin: true, findSomething: true, note: nil)),
            (.ai, .aiExport),
        ]
        for (answer, setup) in rows {
            let q = MarginDestinationQuestion(defaults: makeDefaults())
            XCTAssertEqual(q.answer(answer, context: context), setup, answer.rawValue)
            XCTAssertEqual(q.current, answer, answer.rawValue)
        }
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(MarginDestination.allCases.map(\.rawValue), ["keep_here", "notes", "person", "ai", "club"])
    }

    func testAnswerIsStoredUnderItsKey() {
        let defaults = makeDefaults()
        _ = MarginDestinationQuestion(defaults: defaults).answer(.notes, context: Context())
        XCTAssertEqual(defaults.string(forKey: "marginDestinationV1"), "notes")
    }

    func testAnswerSurvivesARelaunch() {
        let defaults = makeDefaults()
        _ = MarginDestinationQuestion(defaults: defaults).answer(.ai, context: Context())
        XCTAssertEqual(MarginDestinationQuestion(defaults: defaults).current, .ai)
    }

    func testDoubleTapOpensOneSetupAndRecordsOneAnswer() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        XCTAssertEqual(q.answer(.notes, context: Context()), .notesStep)
        XCTAssertEqual(q.answer(.notes, context: Context()), .none)
        XCTAssertEqual(q.answer(.ai, context: Context()), .none, "a second tap on another row is part of the burst")
        XCTAssertEqual(q.current, .notes)
    }

    func testFirstTimeAnswerAfterAnAnswerWasStoredDoesNothing() {
        let defaults = makeDefaults()
        _ = MarginDestinationQuestion(defaults: defaults).answer(.notes, context: Context())
        let again = MarginDestinationQuestion(defaults: defaults)
        XCTAssertEqual(again.answer(.ai, context: Context()), .none)
        XCTAssertEqual(again.current, .notes)
    }

    // MARK: A person

    func testPersonVisibilityTable() {
        // (offersShare, welcome, quiz, expected)
        let rows: [(Bool, Bool, Bool, Bool)] = [
            (false, false, false, false),
            (true, false, false, true),
            (true, true, false, false),
            (false, true, false, false),
            (false, false, true, true),
            (true, true, true, true),
            (false, true, true, true),
            (true, false, true, true),
        ]
        for (share, welcome, quiz, expected) in rows {
            let q = MarginDestinationQuestion(defaults: makeDefaults())
            let context = Context(marginOffersShare: share, isWelcomeItem: welcome, quizAvailable: quiz)
            XCTAssertEqual(q.visibleAnswers(context: context).contains(.person), expected,
                           "share \(share) welcome \(welcome) quiz \(quiz)")
        }
    }

    func testPersonStepOnTheWelcomeItemWithTheQuiz() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        let context = Context(marginOffersShare: true, isWelcomeItem: true, quizAvailable: true)
        XCTAssertEqual(q.answer(.person, context: context),
                       .personStep(sendThisMargin: false, findSomething: true, note: .welcomeStaysHere))
    }

    func testPersonStepOnAShowWithNoQuiz() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        XCTAssertEqual(q.answer(.person, context: Context(marginOffersShare: true)),
                       .personStep(sendThisMargin: true, findSomething: false, note: nil))
    }

    func testAHiddenPersonCannotBeAnswered() {
        let defaults = makeDefaults()
        let q = MarginDestinationQuestion(defaults: defaults)
        XCTAssertEqual(q.answer(.person, context: Context(isWelcomeItem: true)), .none)
        XCTAssertNil(q.current)
        XCTAssertNil(defaults.string(forKey: "marginDestinationV1"))
        XCTAssertEqual(q.answer(.notes, context: Context()), .notesStep, "a refused answer does not use up the sheet")
    }

    func testSettingsShowsPersonWhenItIsTheCurrentAnswer() {
        let defaults = makeDefaults()
        _ = MarginDestinationQuestion(defaults: defaults).answer(.person, context: Context(quizAvailable: true))
        let settings = Context(fromSettings: true)
        let q = MarginDestinationQuestion(defaults: defaults)
        XCTAssertTrue(q.visibleAnswers(context: settings).contains(.person))
        XCTAssertFalse(q.visibleAnswers(context: Context()).contains(.person), "only Settings keeps it")
        XCTAssertEqual(q.answer(.person, context: settings),
                       .personStep(sendThisMargin: false, findSomething: false, note: .shareFromMarginsTab))
    }

    func testSettingsPersonNoteIsTheWelcomeOneOnTheWelcomeItem() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        let context = Context(isWelcomeItem: true, quizAvailable: true, fromSettings: true)
        XCTAssertEqual(q.answer(.person, context: context),
                       .personStep(sendThisMargin: false, findSomething: true, note: .welcomeStaysHere))
    }

    func testSettingsPersonStepOffersSendWhenTheMarginCanBeShared() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        XCTAssertEqual(q.answer(.person, context: Context(marginOffersShare: true, fromSettings: true)),
                       .personStep(sendThisMargin: true, findSomething: false, note: .shareFromMarginsTab))
    }

    // MARK: Club

    func testClubIsHiddenUntilItHasAScreen() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        XCTAssertEqual(q.visibleAnswers(context: Context()), [.keepHere, .notes, .ai])
        XCTAssertEqual(q.visibleAnswers(context: Context(clubScreenExists: true)), [.keepHere, .notes, .ai, .club])
    }

    func testAnswersKeepTheirOrder() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        let context = Context(marginOffersShare: true, quizAvailable: true, clubScreenExists: true)
        XCTAssertEqual(q.visibleAnswers(context: context), [.keepHere, .notes, .person, .ai, .club])
    }

    func testAHiddenClubCannotBeAnswered() {
        let defaults = makeDefaults()
        let q = MarginDestinationQuestion(defaults: defaults)
        XCTAssertEqual(q.answer(.club, context: Context()), .none)
        XCTAssertNil(defaults.string(forKey: "marginDestinationV1"))
    }

    // MARK: More to try

    func testMoreToTryTable() {
        let q = MarginDestinationQuestion(defaults: makeDefaults())
        XCTAssertEqual(q.moreToTry(quizAvailable: false, meetingsAvailable: false), [.bringMyShows])
        XCTAssertEqual(q.moreToTry(quizAvailable: true, meetingsAvailable: false), [.bringMyShows, .findSomething])
        XCTAssertEqual(q.moreToTry(quizAvailable: false, meetingsAvailable: true), [.bringMyShows, .meetings])
        XCTAssertEqual(q.moreToTry(quizAvailable: true, meetingsAvailable: true),
                       [.bringMyShows, .findSomething, .meetings])
    }

    func testMoreToTryRecordsNothing() {
        let defaults = makeDefaults()
        let q = MarginDestinationQuestion(defaults: defaults)
        _ = q.moreToTry(quizAvailable: true, meetingsAvailable: true)
        XCTAssertNil(defaults.string(forKey: "marginDestinationV1"))
    }

    // MARK: Skip

    func testSkipRecordsSkippedAndReadsAsNoAnswer() {
        let defaults = makeDefaults()
        let q = MarginDestinationQuestion(defaults: defaults)
        q.skip(context: Context())
        XCTAssertEqual(defaults.string(forKey: "marginDestinationV1"), "skipped")
        XCTAssertNil(q.current)
        XCTAssertEqual(q.settingsValue, "Not chosen")
    }

    func testSkipFromSettingsRecordsNothing() {
        let defaults = makeDefaults()
        let q = MarginDestinationQuestion(defaults: defaults)
        q.skip(context: Context(fromSettings: true))
        XCTAssertNil(defaults.string(forKey: "marginDestinationV1"))
    }

    func testSkipFromSettingsKeepsTheCurrentAnswer() {
        let defaults = makeDefaults()
        _ = MarginDestinationQuestion(defaults: defaults).answer(.ai, context: Context())
        let q = MarginDestinationQuestion(defaults: defaults)
        q.skip(context: Context(fromSettings: true))
        XCTAssertEqual(q.current, .ai)
    }

    func testSkipNeverOverwritesAnAnswer() {
        let defaults = makeDefaults()
        _ = MarginDestinationQuestion(defaults: defaults).answer(.notes, context: Context())
        MarginDestinationQuestion(defaults: defaults).skip(context: Context())
        XCTAssertEqual(MarginDestinationQuestion(defaults: defaults).current, .notes)
    }

    func testSkipDoesNotCountAsPresented() {
        let defaults = makeDefaults()
        MarginDestinationQuestion(defaults: defaults).skip(context: Context())
        XCTAssertNotNil(defaults.string(forKey: "marginDestinationV1"))
        XCTAssertFalse(defaults.bool(forKey: "marginDestinationPresentedV1"), "only markPresented counts as asked")
    }

    // MARK: Settings

    func testSettingsCanChangeTheAnswer() {
        let defaults = makeDefaults()
        _ = MarginDestinationQuestion(defaults: defaults).answer(.keepHere, context: Context())
        let settings = MarginDestinationQuestion(defaults: defaults)
        XCTAssertEqual(settings.answer(.notes, context: Context(fromSettings: true)), .notesStep)
        XCTAssertEqual(MarginDestinationQuestion(defaults: defaults).current, .notes)
    }

    func testSettingsCanChangeAfterSkipping() {
        let defaults = makeDefaults()
        MarginDestinationQuestion(defaults: defaults).skip(context: Context())
        let settings = MarginDestinationQuestion(defaults: defaults)
        XCTAssertEqual(settings.answer(.ai, context: Context(fromSettings: true)), .aiExport)
        XCTAssertEqual(settings.current, .ai)
    }

    func testSettingsValueTable() {
        let rows: [(String?, String)] = [
            (nil, "Not chosen"),
            ("skipped", "Not chosen"),
            ("keep_here", "Here"),
            ("notes", "My notes"),
            ("person", "A person"),
            ("ai", "An AI"),
            ("club", "Not chosen"),
            ("", "Not chosen"),
            ("AI", "Not chosen"),
            ("somethingFromALaterBuild", "Not chosen"),
        ]
        for (stored, expected) in rows {
            let defaults = makeDefaults()
            if let stored { defaults.set(stored, forKey: "marginDestinationV1") }
            let q = MarginDestinationQuestion(defaults: defaults)
            XCTAssertEqual(q.settingsValue, expected, stored ?? "nil")
        }
    }

    func testAnUnknownStoredValueReadsAsNoCurrentAnswer() {
        let defaults = makeDefaults()
        defaults.set("somethingFromALaterBuild", forKey: "marginDestinationV1")
        XCTAssertNil(MarginDestinationQuestion(defaults: defaults).current)
    }

    func testANonStringStoredValueReadsAsNotChosen() {
        let defaults = makeDefaults()
        defaults.set(42, forKey: "marginDestinationV1")
        XCTAssertEqual(MarginDestinationQuestion(defaults: defaults).settingsValue, "Not chosen")
    }

    // MARK: Asked means asked

    func testAnAnsweredQuestionIsNotPresentedAgainEvenIfNeverMarkedPresented() {
        let defaults = makeDefaults()
        _ = MarginDestinationQuestion(defaults: defaults).answer(.keepHere, context: Context())
        XCTAssertFalse(present(MarginDestinationQuestion(defaults: defaults)))
    }

    func testASkippedQuestionIsNotPresentedAgain() {
        let defaults = makeDefaults()
        MarginDestinationQuestion(defaults: defaults).skip(context: Context())
        XCTAssertFalse(present(MarginDestinationQuestion(defaults: defaults)))
    }
}
