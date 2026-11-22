import Foundation
import XCTest
@testable import SessionKit

/// #4934: a friend's Margin that is never spoken is a Skim stop with no lead-in and no voice, and one press goes to
/// one stop.
final class SkimStopsSilentTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    private func friend(
        _ id: String, mediaMs: Int? = nil, char: Int? = nil, voiced: Bool = false, readAloud: Bool? = false
    ) -> ImportedCommentaryInterjection {
        let resolution = mediaMs.map { ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: $0, confidence: 1) }
            ?? ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: char, localEndChar: char.map { $0 + 10 })
        return ImportedCommentaryInterjection(
            id: id, layerId: "layer-1", packageScopedId: "pkg::\(id)", createdAt: created,
            anchorEvidence: PortableAnchorEvidence(anchorType: mediaMs == nil ? .text : .media, mediaTimeMs: mediaMs),
            approvedTranscript: "A thought.", audioPath: voiced ? "\(id).m4a" : nil, resolution: resolution,
            senderReadAloud: readAloud
        )
    }

    private func chapter(_ id: String, _ position: Int) -> SkimStop { SkimStop(kind: .chapter, id: id, position: position) }
    private func silent(_ id: String, _ position: Int) -> SkimStop { SkimStop(kind: .margin, id: id, position: position, isSilent: true) }
    private func voiced(_ id: String, _ position: Int) -> SkimStop { SkimStop(kind: .margin, id: id, position: position) }

    private func landing(at stop: SkimStop, unit: SkimStops.PositionUnit = .milliseconds) -> SilentMarginLanding {
        SilentMarginLanding(
            itemId: "item-1", marginId: stop.id, subject: .friend("Sam"), words: "A thought.", isApproximate: false,
            position: stop.position, unit: unit)
    }

    private func ids(_ stops: SkimStops) -> [String] { stops.stops.map(\.id) }

    // MARK: No lead-in, one press per stop

    func testASilentStopHasNoLeadInAndStaysAMargin() throws {
        let skim = SkimStops(chapters: [], margins: [silent("s", 300_000)])
        let target = try XCTUnwrap(skim.next(playhead: 0))
        XCTAssertEqual(target.stop.id, "s")
        XCTAssertEqual(target.stop.kind, .margin, "still a Margin, so it beats the scene summary")
        XCTAssertTrue(target.stop.isSilent)
        XCTAssertNil(target.leadInStart)
        XCTAssertNil(target.leadInClamp)
        XCTAssertEqual(target.startPosition, 300_000, "lands on the Margin's own place")
    }

    func testAVoicedMarginKeepsItsLeadInBesideASilentOne() throws {
        let skim = SkimStops(chapters: [], margins: [silent("s", 100_000), voiced("v", 300_000)])
        let target = try XCTUnwrap(skim.next(playhead: 100_000, current: silent("s", 100_000)))
        XCTAssertEqual(target.stop.id, "v")
        XCTAssertEqual(target.leadInStart, 270_000)
        XCTAssertEqual(target.leadInClamp, nil)
    }

    func testOnePressPerSilentStop() throws {
        let skim = SkimStops(chapters: [chapter("c0", 0), chapter("c1", 600_000)], margins: [silent("s", 300_000)])
        var visited: [String] = []
        var playhead = 0
        var current: SkimStop?
        while let target = skim.next(playhead: playhead, current: current) {
            visited.append(target.stop.id)
            if target.stop.isSilent { XCTAssertNil(target.leadInStart, "no lead-in for a silent stop") }
            if visited.count > 6 { break }
            playhead = target.stop.position + 500
            current = target.stop
        }
        XCTAssertEqual(visited, ["s", "c1"])
    }

    // MARK: Never the same stop twice

    func testBackTwiceFromTwentyMinutesDoesNotRepeatTheSilentStop() throws {
        let stops = SkimStops(chapters: [chapter("c0", 0)], margins: [silent("s", 300_000)])
        let first = try XCTUnwrap(stops.previous(playhead: 1_200_000))
        XCTAssertEqual(first.stop.id, "s")
        let place = landing(at: first.stop)
        // The listener sits at the place and plays a little on; a second press goes behind it.
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 300_500, in: stops)?.stop.id, "c0")
        // Without the rule the strict search from 300,500 would find the stop again.
        XCTAssertEqual(stops.previous(playhead: 300_500)?.stop.id, "s", "the repeat the rule prevents")
    }

    func testBackFromTheOnlyStopHasNowhereToGo() {
        let stops = SkimStops(chapters: [], margins: [silent("s", 300_000)])
        let place = landing(at: silent("s", 300_000))
        XCTAssertNil(place.skimTarget(direction: .backward, playhead: 300_000, in: stops))
        XCTAssertNil(place.skimTarget(direction: .backward, playhead: 301_000, in: stops))
    }

    func testForwardAfterASeekThatLandsOneSecondEarlyGoesOn() throws {
        let stops = SkimStops(chapters: [chapter("c1", 600_000)], margins: [silent("s", 300_000)])
        let place = landing(at: silent("s", 300_000))
        XCTAssertEqual(stops.next(playhead: 299_000)?.stop.id, "s", "the repeat the rule prevents")
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 299_000, in: stops)?.stop.id, "c1")
    }

    func testAPressOutsideTheWindowSearchesFromTheListenersPlace() {
        let stops = SkimStops(chapters: [], margins: [silent("s", 300_000)])
        let place = landing(at: silent("s", 300_000))
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 400_000, in: stops)?.stop.id, "s",
                       "30 s past, a back press may come back to it")
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 200_000, in: stops)?.stop.id, "s")
    }

    // The review's finding: a stop between the playhead and the place must still be found, not jumped over.
    func testAStopBetweenThePlayheadAndThePlaceIsNotSkipped() {
        let back = SkimStops(chapters: [chapter("c0", 0), chapter("c", 310_000)], margins: [silent("s", 300_000)])
        let place = landing(at: silent("s", 300_000))
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 320_000, in: back)?.stop.id, "c",
                       "the chapter 10 s past the place is the nearest stop behind")
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 311_000, in: back)?.stop.id, "c")
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 309_000, in: back)?.stop.id, "c0",
                       "past the place but before the chapter: the silent stop is the one the listener is at")
        let forward = SkimStops(chapters: [chapter("c", 298_500), chapter("c2", 600_000)], margins: [silent("s", 300_000)])
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 298_200, in: forward)?.stop.id, "c")
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 299_000, in: forward)?.stop.id, "c2")
    }

    // The listener turned reading back on for the Margin they were just taken to: its stop is voiced now, with a lead-in, so a
    // press meets it instead of treating it as the stop they are already at.
    func testAMarginThatBecameVoicedAfterTheLandingIsMetAgain() throws {
        let place = landing(at: silent("s", 300_000))
        let stops = SkimStops(chapters: [chapter("c0", 0)], margins: [voiced("s", 300_000)])
        let target = try XCTUnwrap(place.skimTarget(direction: .backward, playhead: 301_000, in: stops))
        XCTAssertEqual(target.stop.id, "s")
        XCTAssertFalse(target.stop.isSilent)
        XCTAssertEqual(target.leadInStart, 270_000, "the voiced stop has its lead-in again")
    }

    // MARK: Ties (Default taken 12)

    func testASilentStopTiedWithAnotherStopIsDropped() {
        let stops = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [MediaTimelineChapter(id: "c1", title: "One", startMs: 300_500, transcriptSegmentId: "s1")],
            ownMargins: [], sharedMargins: [friend("v", mediaMs: 600_000, voiced: true)],
            silentSharedMargins: [
                friend("tied-chapter", mediaMs: 300_000), friend("tied-voiced", mediaMs: 600_900),
                friend("clear", mediaMs: 900_000),
            ],
            unit: .milliseconds)
        XCTAssertEqual(ids(stops), ["c1", "v", "clear"])
    }

    func testTheTieEdgeIsOneThousandMilliseconds() {
        func kept(_ gap: Int) -> Bool {
            let stops = SkimStopRouting.stops(
                textChapters: [], mediaChapters: [MediaTimelineChapter(id: "c", title: "C", startMs: 100_000, transcriptSegmentId: "s")],
                ownMargins: [], sharedMargins: [], silentSharedMargins: [friend("s", mediaMs: 100_000 + gap)], unit: .milliseconds)
            return ids(stops).contains("s")
        }
        XCTAssertFalse(kept(0))
        XCTAssertFalse(kept(1_000))
        XCTAssertTrue(kept(1_001))
        XCTAssertFalse(kept(-1_000), "a stop just before is as close as one just after")
        XCTAssertTrue(kept(-1_001))
    }

    func testTwoSilentStopsThatCloseKeepOnlyTheFirstInOrder() {
        let stops = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [], ownMargins: [], sharedMargins: [],
            silentSharedMargins: [friend("b", mediaMs: 200_900), friend("a", mediaMs: 200_000), friend("c", mediaMs: 201_800)],
            unit: .milliseconds)
        XCTAssertEqual(ids(stops), ["a", "c"], "b is within a second of a; c is 1.8 s from a, so it stays")
    }

    func testTwoSilentStopsAtTheSamePlaceKeepTheLowerId() {
        let stops = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [], ownMargins: [], sharedMargins: [],
            silentSharedMargins: [friend("z", mediaMs: 5_000), friend("m", mediaMs: 5_000)], unit: .milliseconds)
        XCTAssertEqual(ids(stops), ["m"])
    }

    func testAnOwnMarginTiesToo() {
        let own = Interjection(
            id: "own", itemId: "item-1", sessionId: "session", targetType: .item, targetId: "item-1", createdAt: created,
            roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 300_400),
            audioPath: "own.m4a", audioStatus: "recorded", transcriptionStatus: "transcribed", transcript: "Mine.",
            cleanedTranscript: nil, displayText: "Mine.", status: "active", captureKind: .audio)
        let stops = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [], ownMargins: [own], sharedMargins: [],
            silentSharedMargins: [friend("s", mediaMs: 300_000)], unit: .milliseconds)
        XCTAssertEqual(ids(stops), ["own"])
    }

    // MARK: Units

    func testTextStopsTieOnlyAtTheSameCharacter() {
        let unit = SkimStops.PositionUnit.characters(perSecond: 15)
        let stops = SkimStopRouting.stops(
            textChapters: [Chapter(id: "c1", title: "One", startChar: 500, endChar: 900, percent: 10)],
            mediaChapters: [], ownMargins: [], sharedMargins: [friend("v", char: 1_200, voiced: true)],
            silentSharedMargins: [friend("at-chapter", char: 500), friend("next-to-chapter", char: 501), friend("at-voiced", char: 1_200)],
            unit: unit)
        XCTAssertEqual(ids(stops), ["c1", "next-to-chapter", "v"])
        XCTAssertEqual(stops.stops.first { $0.id == "next-to-chapter" }?.isSilent, true)
    }

    func testAnAmbiguousOrUnplacedSilentMarginIsNoStop() {
        let ambiguous = ImportedCommentaryInterjection(
            id: "amb", layerId: "layer-1", packageScopedId: "pkg::amb", createdAt: created,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "A thought.", audioPath: nil,
            resolution: ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: 40, isAmbiguous: true),
            senderReadAloud: false)
        let stops = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [], ownMargins: [], sharedMargins: [],
            silentSharedMargins: [ambiguous, friend("none", char: nil)], unit: .characters(perSecond: 15))
        XCTAssertTrue(stops.stops.isEmpty)
    }

    func testAMarginWithAVoiceIsNeverMadeSilent() {
        let stops = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [], ownMargins: [], sharedMargins: [],
            silentSharedMargins: [friend("voice", mediaMs: 5_000, voiced: true)], unit: .milliseconds)
        XCTAssertTrue(stops.stops.isEmpty, "a Margin that can be offered belongs in sharedMargins, with its lead-in")
    }

    func testTodaysCallersGetTheSameStopsAsBefore() {
        let shared = [friend("v", mediaMs: 5_000, voiced: true), friend("read", mediaMs: 9_000, readAloud: true)]
        let stops = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [], ownMargins: [], sharedMargins: shared, unit: .milliseconds)
        XCTAssertEqual(ids(stops), ["v", "read"])
        XCTAssertFalse(stops.stops.contains(where: \.isSilent))
    }

    func testTheUnclampedConversionAndTheLeadInAgree() {
        let text = SkimStops.PositionUnit.characters(perSecond: 15)
        XCTAssertEqual(text.positions(forMs: 2_000), 30, "no 30 s floor")
        XCTAssertEqual(SkimStops.PositionUnit.milliseconds.positions(forMs: 2_000), 2_000)
        XCTAssertEqual(text.positions(forMs: 30_000), 450)
        XCTAssertEqual(SkimStops.PositionUnit.characters(perSecond: .nan).positions(forMs: 30_000), 0)
        XCTAssertEqual(SkimStops.PositionUnit.characters(perSecond: -4).positions(forMs: 30_000), 0)
        let skim = SkimStops(chapters: [], margins: [], unit: text)
        XCTAssertEqual(skim.leadInLength(ms: 1_000), 450, "a lead-in still clamps to 30 s")
        XCTAssertEqual(skim.leadInLength(ms: 500_000), 1_800, "and to 2 min")
    }

    // MARK: The scene summary

    func testASilentStopBeatsTheSummaryOnlyWhenItComesBeforeItsLanding() throws {
        let skim = SkimStops(chapters: [], margins: [silent("s", 300_000)])
        let ahead = try XCTUnwrap(skim.next(playhead: 0))
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: ahead, summaryDestination: 600_000), .stop(ahead))
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: ahead, summaryDestination: 200_000), .summary)
        let behind = try XCTUnwrap(skim.previous(playhead: 900_000))
        XCTAssertEqual(SkimStopRouting.choose(direction: .backward, stop: behind, summaryDestination: 100_000), .stop(behind))
        XCTAssertEqual(SkimStopRouting.choose(direction: .backward, stop: behind, summaryDestination: 500_000), .summary)
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: ahead, summaryDestination: nil), .stop(ahead))
        XCTAssertEqual(Choice(ahead).destination(summaryDestination: 9), 300_000)
    }

    private typealias Choice = SkimStopRouting.Choice
}

private extension SkimStopRouting.Choice {
    init(_ target: SkimStops.Target) { self = .stop(target) }
}
