import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// Persona packs and recent publish dates in the source catalog (#4285, PR 1): the contract only. Nothing in the
/// app reads either field yet.
final class SourceCatalogPacksTests: XCTestCase {
    private static func fixtureURL() throws -> URL { try TestInputs.url(.contracts, "fixtures/source-catalog/packs-small.json") }
    private static func smallURL() throws -> URL { try TestInputs.url(.contracts, "fixtures/source-catalog/top-podcasts-small.json") }
    private static func publishedURL() throws -> URL { try TestInputs.url(.site, "onboarding/catalog/v1/catalog.json") }

    private static func fixture() throws -> SourceCatalog {
        try JSONDecoder().decode(SourceCatalog.self, from: Data(contentsOf: fixtureURL()))
    }

    // MARK: Old and new builds read each other's catalogs

    /// A test-only copy of the catalog shape before packs: what a build in testers' hands decodes. Every field, so a
    /// new catalog that stops satisfying one of them fails here. Keep it as it is; it is the old reader.
    private struct ShippedSourceCatalogV3: Decodable {
        struct Provenance: Decodable {
            var id: String; var kind: String; var url: String?; var country: String?; var appleGenreId: Int?
            var chartUpdatedAt: String?; var fetchedAt: String; var note: String?
        }
        struct Subject: Decodable { var id: String; var title: String; var appleGenreId: Int? }
        struct StarterRow: Decodable { var subjectId: String; var title: String; var entryIds: [String]; var curatedBy: String? }
        struct ChartPosition: Decodable { var provenanceId: String; var rank: Int }
        struct ExternalIds: Decodable {
            var applePodcastsId: String?; var podcastIndexId: String?; var podcastGuid: String?
            var youtubeChannelId: String?; var spotifyShowId: String?
        }
        struct Entry: Decodable {
            var id: String; var kind: String; var contentKind: String; var title: String; var author: String?
            var feedURL: String; var artworkURL: String?; var websiteURL: String?; var summary: String?
            var subjects: [String]; var explicit: Bool?; var chartPositions: [ChartPosition]?
            var externalIds: ExternalIds?; var provenanceIds: [String]
        }
        var schemaVersion: String; var catalogId: String; var contentVersion: Int; var title: String
        var generatedAt: String; var locale: String?; var provenance: [Provenance]; var subjects: [Subject]
        var starterRows: [StarterRow]?; var entries: [Entry]
    }

    func testAnOlderBuildStillReadsACatalogThatCarriesPacksAndDates() throws {
        let old = try JSONDecoder().decode(ShippedSourceCatalogV3.self, from: Data(contentsOf: Self.fixtureURL()))
        let new = try Self.fixture()
        XCTAssertEqual(old.entries.map(\.id), new.entries.map(\.id))
        XCTAssertEqual(old.entries.map(\.feedURL), new.entries.map(\.feedURL))
        XCTAssertEqual(old.subjects.map(\.id), new.subjects.map(\.id))
        XCTAssertNotNil(new.packs, "the fixture must carry packs, or this proves nothing")
        XCTAssertTrue(new.entries.contains { $0.recentPublishedAt != nil })
    }

    func testANewBuildReadsTodaysCatalogsWithNoPacksOrDates() throws {
        for url in [try Self.smallURL(), try Self.publishedURL()] {
            let catalog = try JSONDecoder().decode(SourceCatalog.self, from: Data(contentsOf: url))
            XCTAssertNil(catalog.packs, url.lastPathComponent)
            XCTAssertTrue(catalog.entries.allSatisfy { $0.recentPublishedAt == nil }, url.lastPathComponent)
            let validated = try SourceCatalogValidator.validated(catalog)
            XCTAssertNil(validated.packs, "a catalog with no packs stays without packs")
            XCTAssertEqual(validated.entries.count, catalog.entries.count)
        }
    }

    func testTheFixtureRoundTripsThroughTheEncoderWithItsPacksAndDates() throws {
        let catalog = try Self.fixture()
        let again = try JSONDecoder().decode(SourceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(again, catalog)
    }

    // MARK: Dates

    func testGeneratedAtAndPublishDatesParseWithAndWithoutFractionsAndOffsets() throws {
        let catalog = try Self.fixture()
        XCTAssertEqual(catalog.generatedAtDate, Date(timeIntervalSince1970: 1_790_597_945), "2026-09-28T12:19:05Z")
        let slow = try XCTUnwrap(catalog.entries.first { $0.id == "pack-fixture-03" })
        XCTAssertEqual(slow.recentPublishedDates.count, 2, "a fractional-seconds time parses too")
        XCTAssertEqual(slow.recentPublishedDates[0].timeIntervalSince(slow.recentPublishedDates[1]), 31 * 86_400 + 0.5, accuracy: 0.001)
        let daily = try XCTUnwrap(catalog.entries.first { $0.id == "pack-fixture-01" })
        XCTAssertEqual(daily.recentPublishedDates.count, 8)
        let none = try XCTUnwrap(catalog.entries.first { $0.id == "pack-fixture-04" })
        XCTAssertEqual(none.recentPublishedDates, [])
    }

    func testATimeThatIsNotISO8601IsDroppedAndAnOffsetIsHonoured() {
        XCTAssertNil(SourceCatalogDates.parse("yesterday"))
        XCTAssertNil(SourceCatalogDates.parse(""))
        XCTAssertNil(SourceCatalogDates.parse("2026-11-14"))
        let utc = SourceCatalogDates.parse("2026-11-14T12:00:00Z")
        let offset = SourceCatalogDates.parse("2026-11-14T05:00:00-07:00")
        XCTAssertNotNil(utc)
        XCTAssertEqual(utc, offset)
        var entry = Self.entry("a")
        entry.recentPublishedAt = ["2026-11-14T12:00:00Z", "nope", "2026-11-13T12:00:00.250Z"]
        XCTAssertEqual(entry.recentPublishedDates.count, 2)
        var catalog = Self.catalog(entries: [entry], packs: nil)
        catalog.generatedAt = "not a time"
        XCTAssertNil(catalog.generatedAtDate)
    }

    func testFractionalSecondsOfAnyLengthParse() throws {
        let base = try XCTUnwrap(SourceCatalogDates.parse("2026-11-14T12:00:00Z"))
        for (text, extra) in [(".5", 0.5), (".25", 0.25), (".250", 0.25), (".123456", 0.123456), (".000000001", 0.000000001)] {
            let parsed = try XCTUnwrap(SourceCatalogDates.parse("2026-11-14T12:00:00\(text)Z"), text)
            XCTAssertEqual(parsed.timeIntervalSince(base), extra, accuracy: 0.000001, text)
        }
        XCTAssertNotNil(SourceCatalogDates.parse("2026-11-14T05:00:00.5-07:00"))
        XCTAssertNil(SourceCatalogDates.parse("2026-11-14T12:00:00.Z"))
        XCTAssertNil(SourceCatalogDates.parse("2026-11-14T12:00:00.5"), "a time with no zone is not ISO 8601 date-time")
    }

    func testMoreThanTwentyDatesKeepTheNewestTwentyWhateverTheOrder() throws {
        var catalog = try Self.fixture()
        let index = try XCTUnwrap(catalog.entries.firstIndex { $0.id == "pack-fixture-01" })
        // Days 1...25, shuffled, with one time that doesn't parse: the five oldest go, and so does the bad one.
        var days = Array(1...25)
        var generator = SeededGenerator(seed: 7)
        days.shuffle(using: &generator)
        catalog.entries[index].recentPublishedAt = days.map { String(format: "2026-10-%02dT08:00:00Z", $0) } + ["not a time"]
        let validated = try SourceCatalogValidator.validated(catalog)
        let kept = try XCTUnwrap(validated.entries[index].recentPublishedAt)
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(kept, (6...25).reversed().map { String(format: "2026-10-%02dT08:00:00Z", $0) }, "newest first")
        // Exactly 20 are left alone, bad times and all.
        catalog.entries[index].recentPublishedAt = Array(repeating: "not a time", count: 20)
        XCTAssertEqual(try SourceCatalogValidator.validated(catalog).entries[index].recentPublishedAt?.count, 20)
    }

    func testTheMetadataPathDecodesTheFixtureWithItsPacks() throws {
        let catalog = try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: Self.fixtureURL()))
        XCTAssertEqual(catalog.packs?.map(\.id), ["curious-fixture", "science-fixture"])
    }

    // MARK: Pack validation

    func testTheFixturesPacksSurviveValidationInTheirOwnOrder() throws {
        let validated = try SourceCatalogValidator.validated(try Self.fixture())
        let packs = try XCTUnwrap(validated.packs)
        XCTAssertEqual(packs.map(\.id), ["curious-fixture", "science-fixture"])
        XCTAssertEqual(packs[1].entryIds, ["pack-fixture-07", "pack-fixture-01", "pack-fixture-04", "pack-fixture-06", "pack-fixture-08"],
                       "a pack keeps the order its builder gave")
    }

    func testPackRulesOverNeighbouringInputs() throws {
        func run(_ name: String, _ packs: [SourceCatalogPack], expect: [SourceCatalogPack], file: StaticString = #filePath, line: UInt = #line) throws {
            var catalog = try Self.fixture()
            catalog.packs = packs
            let validated = try SourceCatalogValidator.validated(catalog)
            XCTAssertEqual(validated.packs, expect, name, file: file, line: line)
        }
        let ids = (1...8).filter { $0 != 9 }.map { Self.id($0) }
        let good = SourceCatalogPack(id: "good", title: "Good", summary: "A pack.", entryIds: Array(ids.prefix(4)))

        try run("kept as it is", [good], expect: [good])
        try run("duplicate pack id: the first wins", [good, SourceCatalogPack(id: "good", title: "Other", summary: "Other.", entryIds: Array(ids.suffix(4)))], expect: [good])
        try run("a different id is another pack", [good, SourceCatalogPack(id: "good2", title: "Good", summary: "A pack.", entryIds: Array(ids.suffix(4)))],
                expect: [good, SourceCatalogPack(id: "good2", title: "Good", summary: "A pack.", entryIds: Array(ids.suffix(4)))])
        try run("an unknown entry id is removed, leaving 4", [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: ["no-such-entry"] + ids.prefix(4))],
                expect: [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: Array(ids.prefix(4)))])
        try run("an unknown entry id leaves 3: the pack goes", [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: ["no-such-entry"] + ids.prefix(3))], expect: [])
        try run("a pack of 3 goes", [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: Array(ids.prefix(3)))], expect: [])
        try run("an explicit entry is removed", [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: [Self.id(9)] + ids.prefix(4))],
                expect: [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: Array(ids.prefix(4)))])
        try run("a repeated entry id counts once", [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: [ids[0], ids[0], ids[1], ids[2]])], expect: [])
        for badId in ["", "Curious", "-p", "p q", "p_q", "é", String(repeating: "a", count: 41)] {
            try run("id \(badId.debugDescription) is not a lower-case slug", [SourceCatalogPack(id: badId, title: "P", summary: "S", entryIds: Array(ids.prefix(4)))], expect: [])
        }
        let id40 = String(repeating: "a", count: 40)
        try run("an id of 40 is kept", [SourceCatalogPack(id: id40, title: "P", summary: "S", entryIds: Array(ids.prefix(4)))],
                expect: [SourceCatalogPack(id: id40, title: "P", summary: "S", entryIds: Array(ids.prefix(4)))])
        try run("blank title", [SourceCatalogPack(id: "p", title: "  \n", summary: "S", entryIds: Array(ids.prefix(4)))], expect: [])
        try run("blank summary", [SourceCatalogPack(id: "p", title: "P", summary: "", entryIds: Array(ids.prefix(4)))], expect: [])
        let title40 = String(repeating: "t", count: 40)
        let summary90 = String(repeating: "s", count: 90)
        let edge = SourceCatalogPack(id: "edge", title: title40, summary: summary90, entryIds: Array(ids.prefix(4)))
        try run("title 40 and summary 90 are kept", [edge], expect: [edge])
        try run("title 41 goes, never shortened", [SourceCatalogPack(id: "p", title: title40 + "t", summary: "S", entryIds: Array(ids.prefix(4)))], expect: [])
        try run("summary 91 goes, never shortened", [SourceCatalogPack(id: "p", title: "P", summary: summary90 + "s", entryIds: Array(ids.prefix(4)))], expect: [])
        try run("a title of 40 emoji counts characters, not bytes", [SourceCatalogPack(id: "p", title: String(repeating: "🎧", count: 40), summary: "S", entryIds: Array(ids.prefix(4)))],
                expect: [SourceCatalogPack(id: "p", title: String(repeating: "🎧", count: 40), summary: "S", entryIds: Array(ids.prefix(4)))])
        let family = "👨‍👩‍👧‍👦" // one character, seven scalars: JSON Schema counts scalars
        try run("a title of 6 family emoji is 42 scalars, so it goes", [SourceCatalogPack(id: "p", title: String(repeating: family, count: 6), summary: "S", entryIds: Array(ids.prefix(4)))], expect: [])
        try run("a title of 5 family emoji is 35 scalars, so it stays", [SourceCatalogPack(id: "p", title: String(repeating: family, count: 5), summary: "S", entryIds: Array(ids.prefix(4)))],
                expect: [SourceCatalogPack(id: "p", title: String(repeating: family, count: 5), summary: "S", entryIds: Array(ids.prefix(4)))])
        try run("no packs left is an empty list, not nil", [], expect: [])
    }

    func testAPackKeepsTheFirstTwelveOfMoreThanTwelveEntries() throws {
        let entries = (1...14).map { Self.entry(Self.id($0)) }
        let all = entries.map(\.id)
        var catalog = Self.catalog(entries: entries, packs: [SourceCatalogPack(id: "big", title: "Big", summary: "S", entryIds: all)])
        let kept = try XCTUnwrap(try SourceCatalogValidator.validated(catalog).packs?.first)
        XCTAssertEqual(kept.entryIds, Array(all.prefix(12)))
        catalog.packs = [SourceCatalogPack(id: "big", title: "Big", summary: "S", entryIds: all.reversed())]
        XCTAssertEqual(try SourceCatalogValidator.validated(catalog).packs?.first?.entryIds, Array(all.reversed().prefix(12)))
    }

    func testAPackCannotNameAnEntryTheValidatorItselfRemoved() throws {
        // The second entry repeats the first one's feed, so the validator drops it; a pack naming it loses it too.
        var entries = (1...5).map { Self.entry(Self.id($0)) }
        entries[1].feedURL = entries[0].feedURL
        let catalog = Self.catalog(entries: entries, packs: [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: entries.map(\.id))])
        let validated = try SourceCatalogValidator.validated(catalog)
        XCTAssertEqual(validated.entries.count, 4)
        XCTAssertEqual(validated.packs?.first?.entryIds, [Self.id(1), Self.id(3), Self.id(4), Self.id(5)])
    }

    func testAnEntryThisBuildCannotFollowIsNotKeptInAPack() throws {
        var entries = (1...5).map { Self.entry(Self.id($0)) }
        entries[0].kind = .bridgedSite
        let catalog = Self.catalog(entries: entries, packs: [SourceCatalogPack(id: "p", title: "P", summary: "S", entryIds: entries.map(\.id))])
        let validated = try SourceCatalogValidator.validated(catalog)
        XCTAssertEqual(validated.packs?.first?.entryIds, [Self.id(2), Self.id(3), Self.id(4), Self.id(5)])
    }

    // MARK: Fixtures

    private static func id(_ number: Int) -> String { String(format: "pack-fixture-%02d", number) }

    private static func entry(_ id: String) -> SourceCatalogEntry {
        SourceCatalogEntry(id: id, kind: .podcastFeed, contentKind: .podcast, title: "Show \(id)", feedURL: "https://feeds.example.com/\(id).xml",
                           subjects: ["science"], provenanceIds: ["p"])
    }

    private static func catalog(entries: [SourceCatalogEntry], packs: [SourceCatalogPack]?) -> SourceCatalog {
        SourceCatalog(
            schemaVersion: SourceCatalog.currentSchemaVersion, catalogId: "test", contentVersion: 1, title: "Test",
            generatedAt: "2026-11-14T12:00:00Z", locale: nil,
            provenance: [SourceCatalogProvenance(id: "p", kind: "hand_curated", url: nil, country: nil, appleGenreId: nil, chartUpdatedAt: nil, fetchedAt: "2026-11-14T12:00:00Z", note: nil)],
            subjects: [SourceCatalogSubject(id: "science", title: "Science")], starterRows: nil, packs: packs, entries: entries
        )
    }
}

/// A repeatable shuffle, so a test of order doesn't depend on luck.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
