import Foundation
import XCTest
@testable import SessionKit

/// #4339 PR 3: when a spoken Margin gets the model's rewrite, and when it gets the filler-only version.
final class MarginTidyProposerTests: XCTestCase {
    private let spoken = "um so the the result was not 12 percent"
    private let filler = "The result was not 12 percent"
    private let rewrite = "The result was not 12 percent."

    /// A scripted model that counts its calls and records what it was asked.
    private final class ScriptedModel: @unchecked Sendable {
        enum Reply { case text(String), fail }
        private let lock = NSLock()
        private var reply: Reply
        private(set) var asked: [(transcript: String, before: String, after: String)] = []

        init(_ reply: Reply) { self.reply = reply }

        var calls: Int { lock.withLock { asked.count } }

        func set(_ reply: Reply) { lock.withLock { self.reply = reply } }

        var model: MarginTidyProposer.Model {
            { [self] transcript, before, after in
                let reply = lock.withLock { () -> Reply in
                    asked.append((transcript, before, after))
                    return self.reply
                }
                switch reply {
                case .text(let text): return text
                case .fail: throw ScriptError.failed
                }
            }
        }
    }

    private enum ScriptError: Error { case failed }

    // MARK: Without the model

    func testNoModelOffersTheFillerOnlyVersion() async {
        let proposer = MarginTidyProposer(model: nil)
        let proposal = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(proposal, MarginTidyProposal(text: filler, source: .fillers))
    }

    func testModelThatThrowsFallsBackToFillers() async {
        let model = ScriptedModel(.fail)
        let proposer = MarginTidyProposer(model: model.model)
        let proposal = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(proposal, MarginTidyProposal(text: filler, source: .fillers))
        XCTAssertEqual(model.calls, 1)
    }

    func testRewriteThatDropsANumberFallsBackToFillers() async {
        let model = ScriptedModel(.text("The result was not that high."))
        let proposer = MarginTidyProposer(model: model.model)
        let proposal = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(proposal, MarginTidyProposal(text: filler, source: .fillers))
    }

    func testRewriteTableFallsBackWhenTheGuardRejects() async {
        let rows: [(name: String, transcript: String, rewrite: String)] = [
            ("a dropped negation", "um the result was not good at all", "The result was good at all."),
            ("a dropped name", "I think um Sarah Chen found it", "I think she found it."),
            ("a dropped quotation", "so he said \"never again\" and left, uh, quickly", "He said never again and left quickly."),
            ("an empty rewrite", "um the result held", ""),
            ("a whitespace rewrite", "um the result held", "   \n"),
            ("far too short", "um the result of the experiment was that the group held up under every condition", "It held."),
        ]
        for row in rows {
            let model = ScriptedModel(.text(row.rewrite))
            let proposer = MarginTidyProposer(model: model.model)
            let proposal = await proposer.proposal(marginId: "m1", transcript: row.transcript)
            XCTAssertEqual(proposal?.source, .fillers, row.name)
            XCTAssertEqual(proposal?.text, MarginTidy.fillerOnly(row.transcript), row.name)
        }
    }

    func testRewriteLiftedFromThePassageFallsBackToFillers() async {
        // Only the copied-run rule rejects this one: the length is right and nothing is dropped.
        let passage = "the committee reviewed the long report and found that the main result stands on firm ground overall"
        let transcript = "um I think the review was fine and I also think the main result stands"
        let model = ScriptedModel(.text("I think the review was fine and the main result stands on firm ground overall"))
        let proposer = MarginTidyProposer(model: model.model)
        let proposal = await proposer.proposal(marginId: "m1", transcript: transcript, before: passage, after: "")
        XCTAssertEqual(proposal, MarginTidyProposal(text: MarginTidy.fillerOnly(transcript), source: .fillers))
        XCTAssertEqual(model.calls, 1)
        // The same rewrite with no passage to copy from is fine.
        let withoutPassage = await MarginTidyProposer(model: model.model).proposal(marginId: "m2", transcript: transcript)
        XCTAssertEqual(withoutPassage?.source, .onDeviceAI)
    }

    // MARK: With the model

    func testGoodRewriteIsOfferedAsTheModelsOwn() async {
        let model = ScriptedModel(.text("  \(rewrite)\n"))
        let proposer = MarginTidyProposer(model: model.model)
        let proposal = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(proposal, MarginTidyProposal(text: rewrite, source: .onDeviceAI))
    }

    func testModelGetsTheMarginAndAtMost500CharactersOfPassageOnEachSide() async {
        let before = String(repeating: "b", count: 700)
        let after = String(repeating: "a", count: 700)
        let model = ScriptedModel(.text(rewrite))
        let proposer = MarginTidyProposer(model: model.model)
        _ = await proposer.proposal(marginId: "m1", transcript: spoken, before: before, after: after)
        XCTAssertEqual(model.asked.count, 1)
        XCTAssertEqual(model.asked[0].transcript, spoken)
        XCTAssertEqual(model.asked[0].before, String(before.suffix(500)))
        XCTAssertEqual(model.asked[0].after, String(after.prefix(500)))
    }

    func testRewriteThatChangesNothingFallsBackToFillers() async {
        // The model hands the words back untouched: nothing to offer from it, but the fillers still go.
        let model = ScriptedModel(.text("  \(spoken.uppercased())  "))
        let proposer = MarginTidyProposer(model: model.model)
        let proposal = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(proposal, MarginTidyProposal(text: filler, source: .fillers))
    }

    // MARK: Nothing to offer

    func testNothingToTidyOffersNothing() async {
        let rows: [(name: String, transcript: String)] = [
            ("no fillers", "The result was not 12 percent"),
            ("empty", ""),
            ("whitespace", "  \n "),
            ("only a filler", "um"),
        ]
        for row in rows {
            let model = ScriptedModel(.text(row.transcript))
            let proposer = MarginTidyProposer(model: model.model)
            let proposal = await proposer.proposal(marginId: "m1", transcript: row.transcript)
            XCTAssertNil(proposal, row.name)
        }
    }

    func testEmptyTranscriptNeverAsksTheModel() async {
        let model = ScriptedModel(.text("Something."))
        let proposer = MarginTidyProposer(model: model.model)
        _ = await proposer.proposal(marginId: "m1", transcript: "   ")
        XCTAssertEqual(model.calls, 0)
    }

    // MARK: Heat and power

    func testModelIsNeverAskedInLowPowerMode() async {
        let model = ScriptedModel(.text(rewrite))
        let proposer = MarginTidyProposer(model: model.model, conditions: { MarginTidyConditions(isLowPowerModeEnabled: true) })
        let proposal = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(proposal, MarginTidyProposal(text: filler, source: .fillers))
        XCTAssertEqual(model.calls, 0)
    }

    func testModelIsNeverAskedWhenTheThermalStateIsSeriousOrWorse() async {
        for thermal in [SpeechThermalLevel.serious, .critical] {
            let model = ScriptedModel(.text(rewrite))
            let proposer = MarginTidyProposer(model: model.model, conditions: { MarginTidyConditions(thermal: thermal) })
            let proposal = await proposer.proposal(marginId: "m1", transcript: spoken)
            XCTAssertEqual(proposal?.source, .fillers, "\(thermal)")
            XCTAssertEqual(model.calls, 0, "\(thermal)")
        }
    }

    func testModelIsAskedWhenTheDeviceIsNominalOrFair() async {
        for thermal in [SpeechThermalLevel.nominal, .fair] {
            let model = ScriptedModel(.text(rewrite))
            let proposer = MarginTidyProposer(model: model.model, conditions: { MarginTidyConditions(thermal: thermal) })
            let proposal = await proposer.proposal(marginId: "m1", transcript: spoken)
            XCTAssertEqual(proposal?.source, .onDeviceAI, "\(thermal)")
        }
    }

    func testHeatIsReadAtEachRequest() async {
        let hot = HotSwitch()
        let model = ScriptedModel(.text(rewrite))
        let proposer = MarginTidyProposer(model: model.model, conditions: { hot.conditions })
        hot.set(MarginTidyConditions(thermal: .serious))
        let whileHot = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(whileHot?.source, .fillers)
        // The filler answer was not remembered, so once the phone cools the model is asked.
        hot.set(MarginTidyConditions())
        let afterCooling = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(afterCooling?.source, .onDeviceAI)
        XCTAssertEqual(model.calls, 1)
    }

    private final class HotSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = MarginTidyConditions()
        var conditions: MarginTidyConditions { lock.withLock { value } }
        func set(_ conditions: MarginTidyConditions) { lock.withLock { value = conditions } }
    }

    // MARK: Remembering

    func testSecondRequestForTheSameTranscriptDoesNotAskAgain() async {
        let model = ScriptedModel(.text(rewrite))
        let proposer = MarginTidyProposer(model: model.model)
        let first = await proposer.proposal(marginId: "m1", transcript: spoken)
        let second = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.source, .onDeviceAI)
        XCTAssertEqual(model.calls, 1)
    }

    func testChangedTranscriptAsksAgain() async {
        let model = ScriptedModel(.text(rewrite))
        let proposer = MarginTidyProposer(model: model.model)
        _ = await proposer.proposal(marginId: "m1", transcript: spoken)
        model.set(.text("The result was not 15 percent."))
        let changed = await proposer.proposal(marginId: "m1", transcript: "um so the the result was not 15 percent")
        XCTAssertEqual(changed, MarginTidyProposal(text: "The result was not 15 percent.", source: .onDeviceAI))
        XCTAssertEqual(model.calls, 2)
    }

    func testAnotherMarginWithTheSameWordsAsksAgain() async {
        let model = ScriptedModel(.text(rewrite))
        let proposer = MarginTidyProposer(model: model.model)
        _ = await proposer.proposal(marginId: "m1", transcript: spoken)
        _ = await proposer.proposal(marginId: "m2", transcript: spoken)
        XCTAssertEqual(model.calls, 2)
    }

    func testFailureIsNotRememberedSoNextOpenAsksAgain() async {
        let model = ScriptedModel(.fail)
        let proposer = MarginTidyProposer(model: model.model)
        let failed = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(failed?.source, .fillers)
        model.set(.text(rewrite))
        let retried = await proposer.proposal(marginId: "m1", transcript: spoken)
        XCTAssertEqual(retried?.source, .onDeviceAI)
        XCTAssertEqual(model.calls, 2)
    }

    // MARK: Leaving mid-request

    func testCancelledRequestIsDroppedAndNotRemembered() async {
        let gate = Gate()
        let calls = Counter()
        let proposer = MarginTidyProposer(model: { transcript, _, _ in
            calls.increment()
            await gate.wait()
            return "The result was not 12 percent."
        })
        let task = Task { await proposer.proposal(marginId: "m1", transcript: "um so the the result was not 12 percent") }
        await waitUntil { calls.value == 1 }
        task.cancel()
        await gate.open()
        let dropped = await task.value
        XCTAssertNil(dropped)
        // Next open asks again, and gets an answer.
        let again = await proposer.proposal(marginId: "m1", transcript: "um so the the result was not 12 percent")
        XCTAssertEqual(again?.source, .onDeviceAI)
        XCTAssertEqual(calls.value, 2)
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    /// Waits for the condition itself; the deadline is only a ceiling.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "waited for a condition that never held")
    }

    // MARK: The prompt

    func testPromptIsTheDesignsWordsWithThePassageAndTheNote() {
        let prompt = MarginTidyPrompt.text(transcript: "um it held", before: "Before text.", after: "After text.")
        XCTAssertTrue(prompt.hasPrefix(
            "Rewrite the spoken note below as clear written sentences in the speaker's own voice and person. "
                + "Keep every claim, number, name, quotation and negation. Remove filler words, false starts and repetition. "
                + "Do not add facts, opinions or words from the passage; the passage is only there so you understand what the note "
                + "refers to. Reply with the rewritten note only."
        ))
        XCTAssertTrue(prompt.hasSuffix("Passage before: Before text.\nPassage after: After text.\nSpoken note: um it held"))
    }

    func testSameWordsIgnoresCaseAndEdgeWhitespaceOnly() {
        XCTAssertTrue(MarginTidyProposer.sameWords(" Hello there\n", "hello THERE"))
        XCTAssertFalse(MarginTidyProposer.sameWords("Hello there.", "hello there"))
        XCTAssertFalse(MarginTidyProposer.sameWords("hello  there", "hello there"))
    }

    // MARK: Nothing leaves the phone

    func testProposerSourceNamesNoNetworkClient() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SessionKit/MarginTidyProposer.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        for forbidden in ["URLSession", "URLRequest", "NWConnection", "HTTPClient"] {
            XCTAssertFalse(source.contains(forbidden), "the tidy path must not touch \(forbidden)")
        }
    }
}
