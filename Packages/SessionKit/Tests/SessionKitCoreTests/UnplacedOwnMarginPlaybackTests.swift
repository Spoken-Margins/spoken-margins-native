import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4233, PR 3a: a Margin moved from a live session that has no place on its item (`Interjection.hasPlace == false`)
/// stores zeros for its position. Every SessionKit function that seeks to, marks, plans or navigates by a Margin's place
/// must read `hasPlace` first, or those zeros send Skim, the bar, "Play this moment" and a tap to the start of the item and
/// call it the Margin's moment. One table per surface: an unplaced Margin whose anchor is all zeros (the stored shape),
/// next to a placed Margin that must behave as it always did.
final class UnplacedOwnMarginPlaybackTests: XCTestCase {
    private func margin(_ id: String = "m", unplaced: Bool, media: Bool = true, atMs: Int = 90_000, char: Int = 400,
                        voice: Bool = true) -> Interjection {
        var margin = Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000), roughPercent: unplaced ? 0 : 10,
            anchor: media
                // The shape PR 1 stores for an unplaced Margin: zeros, not nils, so a nil check alone cannot catch it.
                ? Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: unplaced ? 0 : atMs)
                : Anchor(anchorType: .text, startChar: unplaced ? 0 : char, endChar: unplaced ? 0 : char + 5, anchorBefore: "", anchorAfter: ""),
            audioPath: voice ? "SpokenMargins/interjections/\(id).m4a" : nil, audioStatus: "recorded",
            transcriptionStatus: "transcribed", transcript: "Words for \(id).", cleanedTranscript: nil,
            displayText: "Words for \(id).", status: "active", captureKind: voice ? .audio : .written)
        if unplaced {
            margin.movedOrigin = MovedMarginOrigin(
                marginId: id, itemId: "item", sessionId: "session", liveMarginId: "live-\(id)", fromLiveSessionId: "live-quick",
                fromLiveSessionTitle: "Quick session", markedAt: margin.createdAt,
                movedAt: margin.createdAt.addingTimeInterval(60), placeKnown: false)
        }
        return margin
    }

    // MARK: Skim

    func testSkimHasNoStopForAnUnplacedMarginInEitherUnit() {
        let units: [(String, SkimStops.PositionUnit, Bool)] = [
            ("milliseconds", .milliseconds, true), ("characters", .characters(perSecond: 15), false)
        ]
        for (name, unit, media) in units {
            XCTAssertNil(SkimStop.margin(margin(unplaced: true, media: media), unit: unit), "\(name): no stop at 0")
            let placed = SkimStop.margin(margin("p", unplaced: false, media: media), unit: unit)
            XCTAssertEqual(placed?.position, media ? 90_000 : 400, "\(name): a placed Margin is still a stop")
            let stops = SkimStopRouting.stops(
                textChapters: [], mediaChapters: [], ownMargins: [margin("a", unplaced: true, media: media), margin("p", unplaced: false, media: media)],
                sharedMargins: [], unit: unit)
            XCTAssertEqual(stops.stops.map(\.id), ["p"], "\(name): the list of stops leaves it out")
        }
    }

    // MARK: Playback bar, Now and the live passage

    func testNoBarMarkAndNoNowOrPassageMarkerForAnUnplacedMargin() {
        XCTAssertNil(PlaybackBarLayout.Mark.media(margin(unplaced: true), durationSeconds: 3_600))
        XCTAssertNil(PlaybackBarLayout.Mark.text(margin(unplaced: true, media: false)))
        XCTAssertEqual(PlaybackBarLayout.Mark.media(margin("p", unplaced: false), durationSeconds: 3_600)?.position, 90)
        XCTAssertEqual(PlaybackBarLayout.Mark.text(margin("p", unplaced: false, media: false))?.position, 400)

        XCTAssertNil(PlaybackNowMargins.Margin(own: margin(unplaced: true), itemID: "item"))
        XCTAssertEqual(PlaybackNowMargins.Margin(own: margin("p", unplaced: false), itemID: "item")?.position, 90)

        XCTAssertNil(PlaybackLivePassage.Margin(own: margin(unplaced: true, media: false), itemID: "item", textLength: 1_000))
        XCTAssertNotNil(PlaybackLivePassage.Margin(own: margin("p", unplaced: false, media: false), itemID: "item", textLength: 1_000))
    }

    // MARK: Play this moment

    func testThePlannerPlacesNoUnplacedMarginOnAnyClock() throws {
        let clocks: [(String, MarginMomentClock, Bool, Int?)] = [
            ("media", .media, true, nil),
            // A publisher recording or prepared narration found a time for a text-only Margin (#1537): still not for an unplaced one.
            ("publisher recording", .media, false, 88_000),
            ("narrated text", .liveNarration, false, nil)
        ]
        for (name, clock, media, targetMs) in clocks {
            let unplaced = margin("u", unplaced: true, media: media)
            // Early in the text, so the narrated clock's reading start is 0 and an unplaced Margin at offset 0 would pass its
            // filter; a media-shaped ghost with a zero media time, so the media clocks would count it too.
            let placed = margin("p", unplaced: false, media: media, atMs: 120_000, char: 20)
            let ghost = margin("g", unplaced: true, media: true)
            let among = [unplaced, ghost, placed]
            XCTAssertNil(MarginMomentPlanner.anchors(
                played: unplaced, among: among, clock: clock, targetMediaTimeMs: targetMs), "\(name): it can't be played")

            let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
                played: placed, among: among, clock: clock, targetMediaTimeMs: targetMs), name)
            XCTAssertEqual(anchors.others, [], "\(name): nor heard among the others at 0:00")
        }
        XCTAssertFalse(margin(unplaced: true).isInlineSpokenMargin)
        XCTAssertTrue(margin("p", unplaced: false).isInlineSpokenMargin)
    }

    /// A Margin really placed at the start, or moved with a place it knew, is still a place: `hasPlace` reads the record, not the zeros.
    func testAMarginPlacedAtZeroOrMovedWithAKnownPlaceIsStillPlaced() throws {
        var atStart = margin("start", unplaced: false, atMs: 0, char: 0)
        XCTAssertNotNil(SkimStop.margin(atStart, unit: .milliseconds))
        XCTAssertNotNil(PlaybackBarLayout.Mark.media(atStart, durationSeconds: 3_600))
        XCTAssertEqual(MarginRowTap.action(for: atStart), .playMoment)

        var known = margin("known", unplaced: true)
        known.movedOrigin?.placeKnown = true
        known.movedOrigin?.placeSource = "savedRun"
        known.anchor.mediaTimeMs = 42_000
        XCTAssertTrue(known.hasPlace)
        XCTAssertEqual(SkimStop.margin(known, unit: .milliseconds)?.position, 42_000)
        XCTAssertEqual(MarginRowTap.action(for: known), .playMoment)
        XCTAssertTrue(known.isInlineSpokenMargin)
        atStart.movedOrigin = nil
        XCTAssertTrue(atStart.hasPlace)
    }

    // MARK: A tap

    func testARowTapPlaysAPlacedMomentAndOpensAnUnplacedMarginsDetails() {
        for media in [true, false] {
            XCTAssertEqual(MarginRowTap.action(for: margin("p", unplaced: false, media: media)), .playMoment)
            XCTAssertEqual(MarginRowTap.action(for: margin(unplaced: true, media: media)), .openDetails)
        }
        XCTAssertEqual(MarginRowTap.action(for: margin("w", unplaced: false, voice: false)), .playMoment, "a written Margin with a place plays as before")
    }

    // MARK: The engine, on a real store

    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online", displayName: "Phone/Tablet Online",
        capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"]])

    private func rig(media: Bool, unplaced: Bool) throws -> (engine: SessionEngine, store: SQLiteSessionStore, note: Interjection, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "unplaced-play-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: folder.appending(path: "library.sqlite").path)
        let item = media
            ? Item(id: "item", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
                   externalReference: "https://example.com/episode", status: "ready", externalReferenceType: "url",
                   media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 4_740_000))
            : Item(id: "item", title: "Article", mediaType: "text", text: String(repeating: "A sentence. ", count: 200),
                   externalReference: nil, status: "ready")
        let session = Session(
            id: "session", itemId: "item", status: "in_progress", phase: .itemPlayback,
            currentTargetType: media ? .transcriptBackedMedia : .itemTextTTS, currentTargetId: "item",
            position: media ? Position(charOffset: 0, mediaTimeMs: 3_000_000, chapterId: nil) : Position(charOffset: 1_500),
            completionPercent: 60, playbackRate: 1)
        let note = margin(unplaced: unplaced, media: media, atMs: 120_000, char: 900)
        try store.saveItem(item)
        try store.saveSession(session)
        try store.saveInterjection(note)
        if let origin = note.movedOrigin { try store.saveMovedMarginOrigin(origin) }
        return (SessionEngine(profile: profile, repository: store), store, note, folder)
    }

    func testGoingToAnUnplacedMarginThrowsNoPlaceAndLeavesTheSessionAlone() throws {
        for media in [true, false] {
            let rig = try rig(media: media, unplaced: true)
            defer { try? FileManager.default.removeItem(at: rig.folder) }
            let before = try XCTUnwrap(rig.store.loadSession(id: "session"))

            XCTAssertThrowsError(try rig.engine.playInterjectionAnchor(rig.note), "media: \(media)") {
                XCTAssertEqual($0 as? MarginPlaceError, .noPlace)
            }
            // The app may hold a copy built before the origin was written: the stored Margin decides, not the caller's copy.
            var staleCopy = rig.note
            staleCopy.movedOrigin = nil
            XCTAssertThrowsError(try rig.engine.playInterjectionAnchor(staleCopy), "media: \(media), a copy with no origin") {
                XCTAssertEqual($0 as? MarginPlaceError, .noPlace)
            }
            XCTAssertEqual(try rig.store.loadSession(id: "session"), before, "media: \(media). The listener's place did not move to 0")
        }
    }

    func testGoingToAPlacedMarginStillMovesThere() throws {
        for media in [true, false] {
            let rig = try rig(media: media, unplaced: false)
            defer { try? FileManager.default.removeItem(at: rig.folder) }

            _ = try rig.engine.playInterjectionAnchor(rig.note)

            let after = try XCTUnwrap(rig.store.loadSession(id: "session"))
            if media {
                XCTAssertEqual(after.position.mediaTimeMs, 120_000)
            } else {
                XCTAssertEqual(after.position.charOffset, 900)
            }
        }
    }
}
