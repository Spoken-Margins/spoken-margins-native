import Foundation
import SessionKit
import XCTest

/// #3461: a run that stops keeps what it wrote and the next one continues, it pauses for heat and Low Power Mode, and a
/// long text stays under a packet's scene limit.
private func sampleLabel(_ draft: TextSceneDraft) -> ListeningMapSummaryValidator.SceneLabel {
    .init(title: "About \(draft.id)", description: "Summary of \(draft.id).", eligibility: .eligible, eligibilityReason: nil)
}

final class TextSceneSummaryRunTests: XCTestCase {
    private func makeText(paragraphs: Int) -> (text: String, chapters: [Chapter]) {
        var text = ""
        var chapters: [Chapter] = []
        for number in 0..<paragraphs {
            let start = text.count
            let body = "Paragraph \(number) explains one plain thing about the harbour, its tides and the boats that wait there. "
                + "A second sentence adds the detail that makes it worth hearing."
            text += (number == 0 ? "" : "\n\n") + body
            chapters.append(Chapter(id: "ch-\(number)", title: "Part \(number)", startChar: start, endChar: 0, percent: 0))
        }
        return (text, chapters)
    }

    private func drafts(paragraphs: Int) -> (drafts: [TextSceneDraft], characters: [Character]) {
        let made = makeText(paragraphs: paragraphs)
        return (TextSceneSummaryPlanner.plan(text: made.text, chapters: made.chapters), Array(made.text))
    }


    private final class Counter: @unchecked Sendable { var value = 0 }

    /// The saves a run made, newest last, standing in for the store.
    private final class Saves: @unchecked Sendable {
        var proposals: [PortableListeningMapProposalArtifact] = []
        var accept = true
        var latest: PortableListeningMapProposalArtifact? { proposals.last }
        func save(_ scenes: [PortableListeningMapScene]) -> Bool {
            guard accept else { return false }
            proposals.append(TextSceneAssembly.proposal(safeItemComponent: "item", scenes: scenes))
            return true
        }
    }

    private func summaries(_ proposal: PortableListeningMapProposalArtifact?) -> [String] {
        (proposal?.scenes ?? []).compactMap { $0.summaryText?.isEmpty == false ? $0.id : nil }
    }

    func testACancelledRunKeepsEverySummaryWrittenBeforeIt() async throws {
        let (drafts, characters) = drafts(paragraphs: 5)
        XCTAssertEqual(drafts.count, 5)
        let saves = Saves()
        let asked = Counter()
        let task = Task { () -> TextSceneSummaryRun.Result in
            try await TextSceneSummaryRun.run(
                drafts: drafts, characters: characters, saved: nil,
                label: { draft in
                    asked.value += 1
                    if asked.value == 3 { withUnsafeCurrentTask { $0?.cancel() } } // the listener cancels while scene 3 is being read
                    return .label(sampleLabel(draft))
                },
                yieldReason: { nil },
                checkpoint: { saves.save($0) }
            )
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled run throws")
        } catch is CancellationError {}

        XCTAssertEqual(summaries(saves.latest), drafts.prefix(3).map(\.id),
                       "the scene being read when the cancel came finished and was kept; the rest were never started")
        XCTAssertEqual(saves.proposals.count, 3, "saved after every scene, not once at the end")
    }

    func testTheNextRunContinuesWhereTheLastStopped() async throws {
        let (drafts, characters) = drafts(paragraphs: 5)
        let saves = Saves()
        let firstRunAsked = Counter()
        let first = Task { () -> TextSceneSummaryRun.Result in
            try await TextSceneSummaryRun.run(
                drafts: drafts, characters: characters, saved: nil,
                label: { draft in
                    firstRunAsked.value += 1
                    if firstRunAsked.value == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                    return .label(sampleLabel(draft))
                },
                yieldReason: { nil }, checkpoint: { saves.save($0) }
            )
        }
        _ = try? await first.value
        XCTAssertEqual(summaries(saves.latest).count, 2)

        var askedAgain: [String] = []
        let second = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: saves.latest,
            label: { askedAgain.append($0.id); return .label(sampleLabel($0)) },
            yieldReason: { nil }, checkpoint: { saves.save($0) }
        )

        XCTAssertEqual(askedAgain, drafts.dropFirst(2).map(\.id), "the first two are carried over, not asked again")
        XCTAssertEqual(second.ending, .finished)
        XCTAssertEqual(second.newSummaries, 3)
        XCTAssertEqual(summaries(saves.latest), drafts.map(\.id))
        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: [saves.latest!]), .complete)
    }

    func testARunPausesForHeatAndKeepsWhatItWrote() async throws {
        let (drafts, characters) = drafts(paragraphs: 4)
        let saves = Saves()
        var checks = 0
        let result = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: nil,
            label: { .label(sampleLabel($0)) },
            yieldReason: { checks += 1; return checks == 3 ? .heat(.serious) : nil },
            checkpoint: { saves.save($0) }
        )

        XCTAssertEqual(result.ending, .paused(.heat(.serious)))
        XCTAssertEqual(summaries(saves.latest), drafts.prefix(2).map(\.id))
        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: [saves.latest!]), .partial(decided: 2, total: 4))
    }

    func testLowPowerModeStopsABackgroundRunButNotOneTheListenerAsked() {
        let lowPower = SpeechEngineConditions(thermal: .nominal, isLowPowerModeEnabled: true, isOnExternalPower: true)
        XCTAssertEqual(EpisodeMapRunGuard.yieldReason(conditions: lowPower, policy: .whileCharging), .lowPowerMode)
        XCTAssertNil(EpisodeMapRunGuard.yieldReason(conditions: lowPower, policy: .explicit))
        let hot = SpeechEngineConditions(thermal: .critical, isLowPowerModeEnabled: false, isOnExternalPower: true)
        XCTAssertEqual(EpisodeMapRunGuard.yieldReason(conditions: hot, policy: .explicit), .heat(.critical))
    }

    func testNothingIsSavedWhileNoSummaryHasPassed() async throws {
        let (drafts, characters) = drafts(paragraphs: 3)
        let saves = Saves()
        let result = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: nil,
            label: { _ in .rejected }, yieldReason: { nil }, checkpoint: { saves.save($0) }
        )

        XCTAssertTrue(saves.proposals.isEmpty, "an item whose summaries all fail keeps exactly its chapters")
        XCTAssertEqual(result.ending, .finished)
        XCTAssertEqual(result.summarisedScenes, 0)
    }

    func testARunStopsSavingWhenAnotherMapAppears() async throws {
        let (drafts, characters) = drafts(paragraphs: 4)
        let saves = Saves()
        var asked = 0
        let result = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: nil,
            label: { asked += 1; if asked == 2 { saves.accept = false }; return .label(sampleLabel($0)) },
            yieldReason: { nil }, checkpoint: { saves.save($0) }
        )

        XCTAssertEqual(result.ending, .otherMapAppeared)
        XCTAssertEqual(asked, 2, "no more of the model's time is spent once the map is not ours to write")
    }

    func testAScenePassedOverByTheModelIsDecidedAndNotAskedAgain() async throws {
        let (drafts, characters) = drafts(paragraphs: 3)
        let saves = Saves()
        let skipped = ListeningMapSummaryValidator.SceneLabel(
            title: "Front matter", description: "n/a", eligibility: .excluded, eligibilityReason: "Not editorial.")
        let first = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: nil,
            label: { .label($0.id == drafts[1].id ? skipped : sampleLabel($0)) },
            yieldReason: { nil }, checkpoint: { saves.save($0) }
        )
        XCTAssertEqual(first.ending, .finished)
        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: [saves.latest!]), .complete)

        var asked = 0
        _ = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: saves.latest,
            label: { asked += 1; return .label(sampleLabel($0)) }, yieldReason: { nil }, checkpoint: { saves.save($0) }
        )
        XCTAssertEqual(asked, 0)
    }

    func testAnUnknownAnswerFromTheModelIsDecidedSoTheItemCanFinish() async throws {
        let (drafts, characters) = drafts(paragraphs: 3)
        let saves = Saves()
        let unsure = ListeningMapSummaryValidator.SceneLabel(
            title: "Unclear", description: "n/a", eligibility: .unknown, eligibilityReason: nil)
        _ = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: nil,
            label: { .label($0.id == drafts[2].id ? unsure : sampleLabel($0)) }, yieldReason: { nil }, checkpoint: { saves.save($0) }
        )

        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: [saves.latest!]), .complete)
    }

    func testACancelKeepsScenesDecidedWithoutASummaryAfterTheLastSave() async throws {
        let (drafts, characters) = drafts(paragraphs: 4)
        let saves = Saves()
        let asked = Counter()
        let skipped = ListeningMapSummaryValidator.SceneLabel(
            title: "Front matter", description: "n/a", eligibility: .excluded, eligibilityReason: "Not editorial.")
        let task = Task { () -> TextSceneSummaryRun.Result in
            try await TextSceneSummaryRun.run(
                drafts: drafts, characters: characters, saved: nil,
                label: { draft in
                    asked.value += 1
                    if asked.value == 3 { withUnsafeCurrentTask { $0?.cancel() } }
                    return .label(asked.value == 1 ? sampleLabel(draft) : skipped)
                },
                yieldReason: { nil }, checkpoint: { saves.save($0) }
            )
        }
        _ = try? await task.value

        let latest = try XCTUnwrap(saves.latest)
        XCTAssertEqual(latest.scenes.filter(TextSceneSummaryProgress.isDecided).count, 3,
                       "scenes 2 and 3 were judged not editorial before the cancel and are not asked again")
    }

    func testAModelThatThrowsStopsTheRunWithTheEarlierScenesSavedAndNothingJudged() async throws {
        let (drafts, characters) = drafts(paragraphs: 5)
        let saves = Saves()
        var asked = 0
        let result = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: nil,
            label: { draft in asked += 1; return asked <= 2 ? .label(sampleLabel(draft)) : .modelFailed },
            yieldReason: { nil }, checkpoint: { saves.save($0) }
        )

        XCTAssertEqual(result.ending, .modelFailed)
        XCTAssertEqual(asked, 3, "the run stops at the first thrown error instead of spending the charge on every scene")
        XCTAssertEqual(summaries(saves.latest), drafts.prefix(2).map(\.id))
        // The three scenes left are waiting, not judged, so a later run asks about them.
        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: [saves.latest!]), .partial(decided: 2, total: 5))
    }

    func testAModelThatThrowsFromTheStartSavesNothingAndTheItemStaysACandidate() async throws {
        let (drafts, characters) = drafts(paragraphs: 3)
        let saves = Saves()
        let result = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: nil,
            label: { _ in .modelFailed }, yieldReason: { nil }, checkpoint: { saves.save($0) }
        )

        XCTAssertEqual(result.ending, .modelFailed)
        XCTAssertTrue(saves.proposals.isEmpty)
        XCTAssertTrue(TextSceneSummaryProgress.state(proposals: []).offersRun)
    }

    func testASceneWhoseSummaryFailsTheCheckIsSettledSoContinueIsNotOfferedForever() async throws {
        let (drafts, characters) = drafts(paragraphs: 3)
        let saves = Saves()
        _ = try await TextSceneSummaryRun.run(
            drafts: drafts, characters: characters, saved: nil,
            label: { $0.id == drafts[1].id ? .rejected : .label(sampleLabel($0)) },
            yieldReason: { nil }, checkpoint: { saves.save($0) }
        )

        let latest = try XCTUnwrap(saves.latest)
        XCTAssertEqual(latest.scenes[1].eligibility, .excluded)
        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: [latest]), .complete)
    }

    func testAProposalWrittenForOtherChaptersCarriesNothingOver() {
        let (drafts, characters) = drafts(paragraphs: 3)
        var scenes = drafts.map { TextSceneAssembly.scene(draft: $0, label: sampleLabel($0), characters: characters) }
        let moved = TextSceneDraft(
            id: drafts[0].id, order: 0, startChar: drafts[0].startChar, endChar: drafts[0].endChar - 5,
            fallbackTitle: "x", modelText: drafts[0].modelText, isSummarizable: true)
        scenes[0] = TextSceneAssembly.scene(draft: moved, label: sampleLabel(moved), characters: characters)
        let saved = TextSceneAssembly.proposal(safeItemComponent: "item", scenes: scenes)

        let carried = TextSceneSummaryRun.carriedScenes(drafts: drafts, saved: saved)

        XCTAssertNil(carried[drafts[0].id], "same id but different characters")
        XCTAssertEqual(Set(carried.keys), Set(drafts.dropFirst().map(\.id)))
    }

    func testAFriendsOrForeignProposalIsNeverCarriedOverOrContinued() {
        let (drafts, characters) = drafts(paragraphs: 2)
        let scenes = drafts.map { TextSceneAssembly.scene(draft: $0, label: sampleLabel($0), characters: characters) }
        let friends = PortableListeningMapProposalArtifact(
            id: "friend", createdAt: Date(), generator: TextSceneAssembly.sharedGenerator, scenes: scenes)

        XCTAssertTrue(TextSceneSummaryRun.carriedScenes(drafts: drafts, saved: friends).isEmpty)
        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: [friends]), .otherMap)
        XCTAssertFalse(TextSceneSummaryProgress.state(proposals: [friends]).offersRun)
    }

    func testTheStateOfAnItemWithNoSavedSummariesOffersARun() {
        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: []), .notStarted)
        XCTAssertTrue(TextSceneSummaryProgress.state(proposals: []).offersRun)
        XCTAssertFalse(TextSceneSummaryProgress.State.notApplicable.offersRun)
        XCTAssertFalse(TextSceneSummaryProgress.State.complete.offersRun)
    }

    func testASceneTooShortToSummariseIsSettledSoAFinishedItemDoesNotOfferToRunAgain() {
        let text = "Prologue\n\n" + String(repeating: "A full sentence about the harbour and its tides. ", count: 3)
        let characters = Array(text)
        let tooShort = TextSceneDraft(
            id: "s1", order: 0, startChar: 0, endChar: 8, fallbackTitle: "Prologue", modelText: "Prologue", isSummarizable: false)
        let scene = TextSceneAssembly.scene(draft: tooShort, label: nil, characters: characters)
        XCTAssertEqual(scene.eligibility, .excluded)
        XCTAssertTrue(TextSceneSummaryProgress.isDecided(scene))
    }

    // MARK: the packet limit

    func testALongTextIsGroupedBelowThePacketSceneLimit() {
        let made = makeText(paragraphs: 600)
        let planned = TextSceneSummaryPlanner.plan(text: made.text, chapters: made.chapters)

        XCTAssertLessThanOrEqual(planned.count, TextSceneSummaryPlanner.maximumScenes)
        XCTAssertLessThan(TextSceneSummaryPlanner.maximumScenes, 200)
        XCTAssertEqual(planned.first?.startChar, 0)
        XCTAssertEqual(planned.last?.endChar, made.text.count)
        XCTAssertEqual(planned.map(\.order), Array(0..<planned.count))
        XCTAssertEqual(Set(planned.map(\.id)).count, planned.count)
        for (previous, next) in zip(planned, planned.dropFirst()) { XCTAssertEqual(previous.endChar, next.startChar) }
        for draft in planned {
            XCTAssertLessThanOrEqual(draft.modelText.count, TextSceneSummaryPlanner.maximumSceneCharacters)
            XCTAssertTrue(draft.isSummarizable)
        }
    }

    func testATextAtTheLimitIsLeftAlone() {
        let made = makeText(paragraphs: TextSceneSummaryPlanner.maximumScenes)
        let planned = TextSceneSummaryPlanner.plan(text: made.text, chapters: made.chapters)
        XCTAssertEqual(planned.count, TextSceneSummaryPlanner.maximumScenes)
        XCTAssertEqual(planned.map(\.id), made.chapters.map(\.id))
    }
}
