import XCTest
@testable import SessionKit

/// The Help card's progress and the guided tour's stage (#1019, P30 of the Gate1AppModel split).
/// Before the move these rules were covered only by app-hosted tests on a simulator.
final class OnboardingProgressTests: XCTestCase {
    private let allStages: [GuidedOnboardingStage] = [
        .inactive, .practiceInterjection, .reviewTimeline, .optionalAI, .exportSession, .complete
    ]

    private func progress(
        steps: [String]? = nil,
        stage: String? = nil,
        dismissed: Bool = false
    ) -> OnboardingProgress {
        OnboardingProgress(storedSteps: steps, storedStage: stage, isCardDismissed: dismissed)
    }

    private func progress(stage: GuidedOnboardingStage, steps: Set<OnboardingStep> = []) -> OnboardingProgress {
        var value = progress(stage: stage.rawValue)
        value.mark(steps)
        return value
    }

    // MARK: What is stored, and how it loads

    /// Build 29 wrote these names. A changed raw value would reset a listener's tour or hide a step.
    func testStoredNamesAreTheOnesEarlierBuildsWrote() {
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue), [
            "first_interjection", "reviewed_timeline", "exported_session",
            "added_own_source", "added_from_safari", "added_from_files", "added_podcast"
        ])
        XCTAssertEqual(OnboardingStep.core, [.firstInterjection, .reviewedTimeline, .exportedSession])
        XCTAssertEqual(OnboardingStep.sourceExploration, [.addedOwnSource, .addedFromSafari, .addedFromFiles, .addedPodcast])
        XCTAssertEqual(allStages.map(\.rawValue), [
            "inactive", "practice_interjection", "review_timeline", "optional_ai", "export_session", "complete"
        ])
        XCTAssertEqual(OnboardingEvidenceClassifier.defaultSeededItemIDs, ["item-spoken-margins-overview", "guided-onboarding"])
    }

    func testUnknownStoredNamesAreDroppedAndAMissingOrUnknownStageReadsAsInactive() {
        let loaded = progress(steps: ["reviewed_timeline", "not_a_step", "", "First_Interjection"], stage: "not_a_stage")
        XCTAssertEqual(loaded.completedSteps, [.reviewedTimeline], "only exact names count")
        XCTAssertEqual(loaded.stage, .inactive)
        XCTAssertEqual(progress(stage: "").stage, .inactive)
        XCTAssertEqual(progress(stage: nil).stage, .inactive)
        XCTAssertEqual(progress(steps: nil).completedSteps, [])
        XCTAssertEqual(progress(steps: []).completedSteps, [])

        let known = progress(steps: ["added_podcast", "first_interjection"], stage: "optional_ai", dismissed: true)
        XCTAssertEqual(known.completedSteps, [.addedPodcast, .firstInterjection])
        XCTAssertEqual(known.stage, .optionalAI)
        XCTAssertTrue(known.isCardDismissed)
        XCTAssertFalse(progress().isCardDismissed)
    }

    func testStoredFormsAreSortedRawValuesAndTheRawStage() {
        let value = progress(steps: ["reviewed_timeline", "added_podcast", "first_interjection", "added_own_source"], stage: "review_timeline")
        XCTAssertEqual(value.storedSteps, ["added_own_source", "added_podcast", "first_interjection", "reviewed_timeline"])
        XCTAssertEqual(value.storedStage, "review_timeline")
        XCTAssertEqual(progress().storedSteps, [])
        XCTAssertEqual(progress().storedStage, "inactive")
        // What a build stores, a build reads back unchanged.
        let again = progress(steps: value.storedSteps, stage: value.storedStage, dismissed: value.isCardDismissed)
        XCTAssertEqual(again, value)
    }

    // MARK: Marking steps

    func testMarkingReportsAChangeOnlyWhenTheSetGrew() {
        var value = progress()
        XCTAssertEqual(value.mark([.addedOwnSource, .addedFromFiles]), .steps)
        XCTAssertEqual(value.mark([.addedOwnSource]), [], "already there")
        XCTAssertEqual(value.mark([]), [], "nothing to add")
        XCTAssertEqual(value.mark([.addedOwnSource, .addedPodcast]), .steps, "one new step among old ones")
        XCTAssertEqual(value.completedSteps, [.addedOwnSource, .addedFromFiles, .addedPodcast])
        XCTAssertEqual(value.storedSteps, ["added_from_files", "added_own_source", "added_podcast"])
        XCTAssertEqual(value.stage, .inactive, "marking a step never moves the tour")
    }

    func testSettingTheStageAlwaysReportsAStageChange() {
        var value = progress(stage: "review_timeline")
        XCTAssertEqual(value.setStage(.reviewTimeline), .stage, "the same stage is still written")
        XCTAssertEqual(value.setStage(.complete), .stage)
        XCTAssertEqual(value.stage, .complete)
        XCTAssertEqual(value.completedSteps, [], "setting the stage marks nothing")
    }

    func testDismissingAndRestoringTheCardAlwaysReportACardChange() {
        var value = progress()
        XCTAssertEqual(value.dismissCard(), .card)
        XCTAssertTrue(value.isCardDismissed)
        XCTAssertEqual(value.dismissCard(), .card, "dismissing twice is still written")
        XCTAssertEqual(value.restoreCard(), .card)
        XCTAssertFalse(value.isCardDismissed)
        XCTAssertEqual(value.restoreCard(), .card)
        XCTAssertEqual(value.stage, .inactive)
        XCTAssertEqual(value.completedSteps, [])
    }

    // MARK: Each stage advances from exactly one stage

    func testSavingAMarginMarksTheStepAndAdvancesOnlyThePracticeStage() {
        for stage in allStages {
            var value = progress(stage: stage)
            let change = value.firstInterjectionSaved()
            XCTAssertTrue(value.isComplete(.firstInterjection), "from \(stage)")
            if stage == .practiceInterjection {
                XCTAssertEqual(value.stage, .reviewTimeline)
                XCTAssertEqual(change, [.steps, .stage])
            } else {
                XCTAssertEqual(value.stage, stage, "\(stage) stays where it is")
                XCTAssertEqual(change, .steps, "from \(stage)")
            }
        }
        var again = progress(stage: .reviewTimeline, steps: [.firstInterjection])
        XCTAssertEqual(again.firstInterjectionSaved(), [], "a second Margin changes nothing in the tour")
    }

    func testReviewingTheTimelineMarksTheStepAndAdvancesOnlyTheReviewStage() {
        for stage in allStages {
            var value = progress(stage: stage)
            let change = value.timelineReviewed()
            XCTAssertTrue(value.isComplete(.reviewedTimeline), "from \(stage)")
            if stage == .reviewTimeline {
                XCTAssertEqual(value.stage, .optionalAI)
                XCTAssertEqual(change, [.steps, .stage])
            } else {
                XCTAssertEqual(value.stage, stage, "\(stage) stays where it is")
                XCTAssertEqual(change, .steps, "from \(stage)")
            }
        }
    }

    func testExportingMarksTheStepAndAdvancesOnlyTheExportStage() {
        for stage in allStages {
            var value = progress(stage: stage)
            let change = value.sessionExported()
            XCTAssertTrue(value.isComplete(.exportedSession), "from \(stage)")
            if stage == .exportSession {
                XCTAssertEqual(value.stage, .complete)
                XCTAssertEqual(change, [.steps, .stage])
            } else {
                XCTAssertEqual(value.stage, stage, "\(stage) stays where it is")
                XCTAssertEqual(change, .steps, "from \(stage)")
            }
        }
    }

    func testContinuingPastAIMovesOnlyTheAIStage() {
        for stage in allStages {
            var value = progress(stage: stage)
            let change = value.continuePastAI()
            if stage == .optionalAI {
                XCTAssertEqual(value.stage, .exportSession)
                XCTAssertEqual(change, .stage)
            } else {
                XCTAssertEqual(value.stage, stage, "\(stage) stays where it is")
                XCTAssertEqual(change, [], "from \(stage)")
            }
            XCTAssertEqual(value.completedSteps, [], "continuing marks nothing")
        }
    }

    /// Pausing and finishing the tour both set `inactive`, from wherever the tour is.
    func testPausingOrFinishingMovesTheTourToInactiveFromAnyStage() {
        for stage in allStages {
            var value = progress(stage: stage, steps: [.firstInterjection])
            XCTAssertEqual(value.setStage(.inactive), .stage, "from \(stage)")
            XCTAssertEqual(value.stage, .inactive)
            XCTAssertEqual(value.completedSteps, [.firstInterjection], "the steps stay")
        }
    }

    // MARK: Queries

    func testTheCoreIsCompleteOnlyWhenAllThreeCoreStepsAre() {
        XCTAssertFalse(progress().hasCompletedCore)
        XCTAssertEqual(progress().coreCompletedCount, 0)

        var value = progress()
        value.mark(Set(OnboardingStep.sourceExploration))
        XCTAssertFalse(value.hasCompletedCore, "source steps do not count")
        XCTAssertEqual(value.coreCompletedCount, 0)

        value.mark([.firstInterjection, .reviewedTimeline])
        XCTAssertFalse(value.hasCompletedCore)
        XCTAssertEqual(value.coreCompletedCount, 2)

        value.mark([.exportedSession])
        XCTAssertTrue(value.hasCompletedCore)
        XCTAssertEqual(value.coreCompletedCount, 3)
        XCTAssertEqual(OnboardingStep.core.count, 3, "the Help card shows 'n of 3'")
    }

    func testTheCardShowsUnlessSuppressedFinishedOrDismissed() {
        var value = progress()
        XCTAssertTrue(value.shouldShowCard(suppressed: false))
        XCTAssertFalse(value.shouldShowCard(suppressed: true), "unit tests and UI tests never see it")

        value.mark([.firstInterjection, .reviewedTimeline])
        XCTAssertTrue(value.shouldShowCard(suppressed: false), "two of three is not finished")

        var dismissed = progress()
        dismissed.dismissCard()
        XCTAssertFalse(dismissed.shouldShowCard(suppressed: false))
        dismissed.restoreCard()
        XCTAssertTrue(dismissed.shouldShowCard(suppressed: false))

        value.mark([.exportedSession])
        XCTAssertFalse(value.shouldShowCard(suppressed: false), "finished")
    }

    func testTheCoachShowsOnlyDuringTheTourOnTheTourItem() {
        for stage in allStages {
            let value = progress(stage: stage)
            XCTAssertEqual(value.shouldShowCoach(guidedItemIsSelected: true), stage != .inactive, "\(stage)")
            XCTAssertFalse(value.shouldShowCoach(guidedItemIsSelected: false), "another item is selected: \(stage)")
        }
    }

    /// "Start or Resume Guided Tour" puts the tour where the listener left off. The chain asks the
    /// first missing core step, in order, and sends a finished tour back to the start.
    func testTheTourResumesAtTheFirstCoreStepNotYetDone() {
        let first = OnboardingStep.firstInterjection, reviewed = OnboardingStep.reviewedTimeline
        let exported = OnboardingStep.exportedSession
        let table: [(Set<OnboardingStep>, GuidedOnboardingStage)] = [
            ([], .practiceInterjection),
            ([first], .reviewTimeline),
            ([first, exported], .reviewTimeline),
            ([first, reviewed], .optionalAI),
            ([first, reviewed, exported], .practiceInterjection),
            ([reviewed], .practiceInterjection),
            ([exported], .practiceInterjection),
            ([reviewed, exported], .practiceInterjection)
        ]
        for (steps, expected) in table {
            var value = progress()
            value.mark(steps)
            XCTAssertEqual(value.tourResumeStage, expected, "steps \(steps.map(\.rawValue).sorted())")
            value.mark(Set(OnboardingStep.sourceExploration))
            XCTAssertEqual(value.tourResumeStage, expected, "source steps change nothing")
        }
    }

    // MARK: Library evidence (moved from the app's tests)

    func testSeededOnboardingItemsDoNotCountAsUserSourceEvidence() {
        let welcome = item(id: "item-spoken-margins-overview", mediaType: "text", externalReferenceType: "url")
        let guided = item(id: "guided-onboarding", mediaType: "guided_tour", externalReferenceType: "file")

        XCTAssertTrue(OnboardingEvidenceClassifier.sourceSteps(items: [welcome, guided]).isEmpty)
    }

    func testUserOwnedSourcesProduceTypedOnboardingEvidence() {
        let pasted = item(id: "pasted", mediaType: "text", externalReferenceType: nil)
        let webpage = item(id: "webpage", mediaType: "text", externalReferenceType: "url")
        let file = item(id: "file", mediaType: "pdf", externalReferenceType: "file")

        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: [pasted]), [.addedOwnSource])
        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: [webpage]), [.addedOwnSource, .addedFromSafari])
        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: [file]), [.addedOwnSource, .addedFromFiles])
    }

    /// Neighbours of the cases above: what makes an item count as "added from Safari" or "from Files".
    func testEvidenceDependsOnTheKindOfSourceAndIgnoresTheSeededItems() {
        let seeded = [
            item(id: "item-spoken-margins-overview", mediaType: "text", externalReferenceType: "url"),
            item(id: "guided-onboarding", mediaType: "guided_tour", externalReferenceType: "file")
        ]
        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: [Item]()), [])
        // Safari means a web page's text; a PDF fetched from a link is only "own source".
        let pdfFromLink = item(id: "paper", mediaType: "pdf", externalReferenceType: "url")
        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: [pdfFromLink]), [.addedOwnSource])
        // Files means a file reference, whatever the media type.
        let textFromFile = item(id: "notes", mediaType: "text", externalReferenceType: "file")
        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: [textFromFile]), [.addedOwnSource, .addedFromFiles])
        let audioFromFile = item(id: "talk", mediaType: "audio", externalReferenceType: "file")
        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: [audioFromFile]), [.addedOwnSource, .addedFromFiles])
        // A user's item among the seeded ones still counts; a user's page and file together give both.
        let webpage = item(id: "webpage", mediaType: "text", externalReferenceType: "url")
        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: seeded + [webpage]), [.addedOwnSource, .addedFromSafari])
        XCTAssertEqual(
            OnboardingEvidenceClassifier.sourceSteps(items: [webpage, textFromFile]),
            [.addedOwnSource, .addedFromSafari, .addedFromFiles]
        )
        // The classifier treats the ids it is given as the seeded ones.
        XCTAssertEqual(OnboardingEvidenceClassifier.sourceSteps(items: [webpage], seededItemIDs: ["webpage"]), [])
    }

    private func item(id: String, mediaType: String, externalReferenceType: String?) -> Item {
        Item(
            id: id,
            title: id,
            mediaType: mediaType,
            text: "Source text",
            externalReference: "source://\(id)",
            status: "ready",
            externalReferenceType: externalReferenceType
        )
    }
}
