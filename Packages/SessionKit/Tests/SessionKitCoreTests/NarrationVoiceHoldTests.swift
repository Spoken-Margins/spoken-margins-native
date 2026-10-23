import Foundation
import XCTest
@testable import SessionKit

/// #1786: once a stand-in voice takes an item, the voice doesn't bounce. Each row is a sequence of events and the
/// voice the next chunk gets after it.
final class NarrationVoiceHoldTests: XCTestCase {
    private enum Event {
        case standIn(NarrationVoiceHold.Voice, String)
        case play(String)
        case ended(String)
        case savedRun(String)
        case listener
    }

    private struct Row {
        let name: String
        let events: [Event]
        let item: String
        let chosenMayRender: Bool
        let expected: NarrationVoiceHold.Voice
        var bundledVoiceAvailable = true
    }

    private func apply(_ events: [Event], to hold: inout NarrationVoiceHold) -> [NarrationVoiceHold.Release] {
        var releases: [NarrationVoiceHold.Release] = []
        for event in events {
            let release: NarrationVoiceHold.Release?
            switch event {
            case .standIn(let voice, let item): hold.standInTookOver(voice, item: item); release = nil
            case .play(let item): release = hold.play(item: item)
            case .ended(let item): release = hold.itemEnded(item)
            case .savedRun(let item): release = hold.savedRunStarted(item: item)
            case .listener: release = hold.listenerChoseVoice()
            }
            if let release { releases.append(release) }
        }
        return releases
    }

    func testTheNextChunksVoiceAfterEachSequence() {
        let rows: [Row] = [
            Row(name: "nothing held, cool phone", events: [], item: "a", chosenMayRender: true, expected: .chosen),
            Row(name: "nothing held, hot phone", events: [], item: "a", chosenMayRender: false, expected: .bundled),
            Row(name: "nothing held, hot phone, no bundled voice", events: [], item: "a", chosenMayRender: false,
                expected: .system, bundledVoiceAvailable: false),
            Row(name: "Kitten holds, phone cooled", events: [.standIn(.bundled, "a")], item: "a",
                chosenMayRender: true, expected: .bundled),
            Row(name: "Kitten holds, still hot", events: [.standIn(.bundled, "a")], item: "a",
                chosenMayRender: false, expected: .bundled),
            Row(name: "Kitten holds, cooled, resume", events: [.standIn(.bundled, "a"), .play("a")], item: "a",
                chosenMayRender: true, expected: .bundled),
            Row(name: "Kitten holds, interruption's resume twice", events: [.standIn(.bundled, "a"), .play("a"), .play("a")],
                item: "a", chosenMayRender: true, expected: .bundled),
            Row(name: "Kitten holds, a new item starts with the chosen voice",
                events: [.standIn(.bundled, "a"), .play("b")], item: "b", chosenMayRender: true, expected: .chosen),
            Row(name: "Kitten held a, back to a after b", events: [.standIn(.bundled, "a"), .play("b"), .play("a")],
                item: "a", chosenMayRender: true, expected: .chosen),
            Row(name: "Kitten holds, item ended, replayed", events: [.standIn(.bundled, "a"), .ended("a"), .play("a")],
                item: "a", chosenMayRender: true, expected: .chosen),
            Row(name: "another item's end leaves the hold", events: [.standIn(.bundled, "a"), .ended("b")],
                item: "a", chosenMayRender: true, expected: .bundled),
            Row(name: "saved run, cool at its end: Supertonic carries on",
                events: [.standIn(.bundled, "a"), .savedRun("a")], item: "a", chosenMayRender: true, expected: .chosen),
            Row(name: "saved run, still hot at its end: back to Kitten",
                events: [.standIn(.bundled, "a"), .savedRun("a")], item: "a", chosenMayRender: false, expected: .bundled),
            Row(name: "listener retried", events: [.standIn(.bundled, "a"), .listener], item: "a",
                chosenMayRender: true, expected: .chosen),
            Row(name: "Kitten failed: the iOS voice takes over",
                events: [.standIn(.bundled, "a"), .standIn(.system, "a")], item: "a", chosenMayRender: true, expected: .system),
            Row(name: "the iOS voice is never replaced by Kitten in an item",
                events: [.standIn(.system, "a"), .standIn(.bundled, "a")], item: "a", chosenMayRender: false, expected: .system),
            Row(name: "the iOS voice holds through a play on a cool phone", events: [.standIn(.system, "a"), .play("a")],
                item: "a", chosenMayRender: true, expected: .system),
            Row(name: "a saved run doesn't release the iOS voice", events: [.standIn(.system, "a"), .savedRun("a")],
                item: "a", chosenMayRender: true, expected: .system),
            Row(name: "choosing the chosen voice is not a stand-in", events: [.standIn(.chosen, "a")], item: "a",
                chosenMayRender: true, expected: .chosen),
        ]
        for row in rows {
            var hold = NarrationVoiceHold()
            _ = apply(row.events, to: &hold)
            XCTAssertEqual(
                hold.nextChunkVoice(item: row.item, chosenMayRender: row.chosenMayRender,
                                    bundledVoiceAvailable: row.bundledVoiceAvailable),
                row.expected, row.name
            )
        }
    }

    func testEachReleaseNamesItsReasonOnce() {
        let rows: [(String, [Event], [NarrationVoiceHold.Release])] = [
            ("new item", [.standIn(.bundled, "a"), .play("b")], [.newItem]),
            ("same item plays never release", [.standIn(.bundled, "a"), .play("a"), .play("a")], []),
            ("item end", [.standIn(.bundled, "a"), .ended("a"), .ended("a")], [.itemEnded]),
            ("saved run", [.standIn(.bundled, "a"), .savedRun("a"), .savedRun("a")], [.savedRun]),
            ("listener", [.standIn(.bundled, "a"), .listener, .listener], [.listener]),
            ("nothing held releases nothing", [.play("a"), .ended("a"), .savedRun("a"), .listener], []),
            ("a hold taken again releases again", [.standIn(.bundled, "a"), .savedRun("a"), .standIn(.bundled, "a"),
                                                   .ended("a")], [.savedRun, .itemEnded]),
        ]
        for (name, events, expected) in rows {
            var hold = NarrationVoiceHold()
            XCTAssertEqual(apply(events, to: &hold), expected, name)
        }
    }

    func testABackgroundGapGoesToKittenAndTheIOSVoiceOnlyAsTheLastResort() {
        var hold = NarrationVoiceHold()
        XCTAssertEqual(hold.backgroundGapStandIn(item: "a", bundledVoiceAvailable: true), .bundled, "Supertonic was reading")
        XCTAssertEqual(hold.backgroundGapStandIn(item: "a", bundledVoiceAvailable: false), .system, "no bundled voice")
        hold.standInTookOver(.bundled, item: "a")
        XCTAssertEqual(hold.backgroundGapStandIn(item: "a", bundledVoiceAvailable: true), .bundled, "Kitten keeps it")
        hold.standInTookOver(.system, item: "a")
        XCTAssertEqual(hold.backgroundGapStandIn(item: "a", bundledVoiceAvailable: true), .system, "the iOS voice keeps it")
        XCTAssertEqual(hold.backgroundGapStandIn(item: "b", bundledVoiceAvailable: true), .bundled, "another item")
    }

    /// The owner's 2026-10-17 export, item `ed95c51db1b0bce7`, replayed with the temperature it logged. Before this
    /// type, the play at 02:02:41 and the app coming to the front at 02:04:01 each changed the voice; now there is one
    /// change in the item, the first hand-over to Kitten.
    func testTheWarmPhoneEveningHasOneVoiceChange() {
        let item = "ed95c51db1b0bce7"
        var hold = NarrationVoiceHold()
        var voices: [NarrationVoiceHold.Voice] = []
        func chunk(cool: Bool) {
            let next = hold.nextChunkVoice(item: item, chosenMayRender: cool, bundledVoiceAvailable: true)
            if next != .chosen { hold.standInTookOver(next, item: item) }
            if voices.last != next { voices.append(next) }
        }
        hold.play(item: item)
        chunk(cool: true)                                    // 01:46:54 Supertonic
        chunk(cool: false)                                   // 01:54:13 serious: Kitten
        chunk(cool: true)                                    // 01:55:39 fair
        hold.play(item: item)                                // 02:02:41 play after the interruption
        chunk(cool: true)
        let gap = hold.backgroundGapStandIn(item: item, bundledVoiceAvailable: true) // 02:03:06 background seam
        hold.standInTookOver(gap, item: item)
        chunk(cool: true)
        hold.play(item: item)                                // 02:04:01 app in front
        chunk(cool: true)
        chunk(cool: false)                                   // 02:06:09 serious again
        XCTAssertEqual(voices, [.chosen, .bundled])
    }
}
