import Foundation
import SessionKit
import SessionKitTestInputs
import XCTest

/// Runs every case in Contracts/fixtures/margins-control-center/cases.json (part of #3216) through SessionKit. The
/// same file is meant for the web prototype, so both read one set of rules.
final class MarginsControlCenterCasesTests: XCTestCase {
    // MARK: The file's shape (see Contracts/schemas/margins-control-center-cases.schema.json)

    struct File: Decodable {
        struct Constants: Decodable {
            let leadInMs: Int
            let startFromBeginningMs: Int
            let leadInExcerptCharacters: Int
            let missingParentNote: String
            let ownSender: String
        }
        struct Labels: Decodable {
            struct RowStart: Decodable { let arrival: String; let playback: String }
            struct Autoplay: Decodable { let unheard: String; let all: String; let none: String }
            let rowStart: RowStart
            let startWithUnheard: String
            let startFromBeginning: String
            let autoplayMenuTitle: String
            let autoplay: Autoplay
        }
        let constants: Constants
        let labels: Labels
        let cases: [Case]
    }

    struct Case: Decodable {
        struct Input: Decodable {
            let autoplay: String
            let playheadMs: Int
            let margins: [Margin]
        }
        struct Expected: Decodable {
            let rows: [ExpectedRow]
            let nextMargin: ExpectedNext?
            let unheardCount: Int
            let opensOnMarginsTab: Bool
            let startWithUnheardMs: Int?
        }
        let id: String
        let input: Input
        let expected: Expected
    }

    struct Margin: Decodable {
        let id: String
        let sender: String
        let parentId: String?
        let timeMs: Int?
        let listenedMs: Int
        let words: String?
        let starred: Bool
        let sourceTextBefore: String?
    }

    struct ExpectedRow: Decodable, Equatable, CustomStringConvertible {
        let id: String
        let depth: Int
        let sender: String
        let hearing: String
        let words: String?
        let wordsComing: Bool
        let leadIn: String?
        let timeMs: Int?
        let startHereMs: Int?
        let starred: Bool
        let note: String?
        let arrival: String

        var description: String {
            "\(id) d\(depth) \(sender) \(hearing) \(wordsComing ? "coming" : words ?? "nil") lead=\(leadIn ?? "nil") "
                + "t=\(timeMs.map(String.init) ?? "nil") start=\(startHereMs.map(String.init) ?? "nil") "
                + "star=\(starred) note=\(note ?? "nil") \(arrival)"
        }
    }

    struct ExpectedNext: Decodable, Equatable {
        let marginTimeMs: Int
        let leadInStartMs: Int
        let msUntilMargin: Int
        let action: String
        let destinationMs: Int
        let countdown: String
        let firstToPlayId: String
    }

    private static func loadCases() throws -> File {
        let url = try TestInputs.url(.contracts, "fixtures/margins-control-center/cases.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    // MARK: Tests

    func testConstantsAndLabelsMatchSessionKit() throws {
        let file = try Self.loadCases()
        XCTAssertEqual(file.constants.leadInMs, MarginsControlCenter.leadInMs)
        XCTAssertEqual(file.constants.startFromBeginningMs, MarginsControlCenter.startFromBeginningMs)
        XCTAssertEqual(file.constants.leadInExcerptCharacters, MarginsControlCenter.leadInExcerptCharacters)
        XCTAssertEqual(file.constants.missingParentNote, MarginThreadPresentation.missingParentNote)
        XCTAssertEqual(file.constants.ownSender, MarginLayerSynthesis.ownSenderLabel)
        XCTAssertEqual(file.labels.rowStart.arrival, MarginsControlCenter.RowStartContext.arrival.label)
        XCTAssertEqual(file.labels.rowStart.playback, MarginsControlCenter.RowStartContext.playback.label)
        XCTAssertEqual(file.labels.startWithUnheard, MarginsControlCenter.startWithUnheardLabel)
        XCTAssertEqual(file.labels.startFromBeginning, MarginsControlCenter.startFromBeginningLabel)
        XCTAssertEqual(file.labels.autoplay.unheard, MarginsControlCenter.Autoplay.unheard.title)
        XCTAssertEqual(file.labels.autoplay.all, MarginsControlCenter.Autoplay.all.title)
        XCTAssertEqual(file.labels.autoplay.none, MarginsControlCenter.Autoplay.none.title)
        XCTAssertEqual(file.labels.autoplayMenuTitle, MarginsControlCenter.Autoplay.menuTitle)
    }

    func testEveryCase() throws {
        let file = try Self.loadCases()
        XCTAssertGreaterThanOrEqual(file.cases.count, 20)
        XCTAssertEqual(Set(file.cases.map(\.id)).count, file.cases.count, "case ids are unique")
        for item in file.cases {
            let rows = try Self.rows(for: item, ownSender: file.constants.ownSender)
            let autoplay = try XCTUnwrap(MarginsControlCenter.Autoplay(rawValue: item.input.autoplay), item.id)
            let actual = rows.map { Self.expectedRow($0, autoplay: autoplay) }
            XCTAssertEqual(actual, item.expected.rows, "\(item.id): rows")

            let next = NextMarginSkip.next(playheadMs: item.input.playheadMs, rows: rows, autoplay: autoplay)
            XCTAssertEqual(next.map(Self.expectedNext), item.expected.nextMargin, "\(item.id): nextMargin")
            XCTAssertEqual(MarginsControlCenter.unheardCount(rows), item.expected.unheardCount, "\(item.id): unheardCount")
            XCTAssertEqual(MarginsControlCenter.opensOnMarginsTab(rows), item.expected.opensOnMarginsTab, "\(item.id): opensOnMarginsTab")
            XCTAssertEqual(MarginsControlCenter.startWithUnheardMs(rows), item.expected.startWithUnheardMs, "\(item.id): startWithUnheardMs")
        }
    }

    // MARK: Building SessionKit's inputs from a case

    private static let itemId = "item-margins-control-center-case"
    private static let listenerDigest = String(format: "%064x", 1)
    private static let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    /// The listener's own Margins become `Interjection`s marked as sent in one packet; each friend becomes one imported
    /// layer. Creation times follow the case's order, oldest first. Heard comes from `listenedMs` through `marksHeard`.
    static func rows(for item: Case, ownSender: String) throws -> [MarginsControlCenter.Row] {
        let margins = item.input.margins
        let friends = margins.map(\.sender).filter { $0 != ownSender }.reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        let digests = Dictionary(uniqueKeysWithValues: friends.enumerated().map { ($1, String(format: "%064x", $0 + 2)) })
        let layers = friends.map { name in
            ImportedCommentaryLayer(
                id: "layer-\(name)", itemId: itemId, packageDigest: digests[name]!, packageId: "package-\(name)",
                itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Case Episode", durationMs: 7_200_000),
                displayLabel: name, importedAt: t0, sourceResolutionStatus: .resolved, isEnabled: true)
        }
        let byId = Dictionary(margins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func identity(_ id: String) -> MarginPacketIdentity {
            let digest = byId[id].flatMap { $0.sender == ownSender ? nil : digests[$0.sender] } ?? listenerDigest
            return MarginPacketIdentity(packageDigest: digest, packageScopedId: id)
        }
        func link(for margin: Margin) -> MarginReplyLink? {
            guard let parentId = margin.parentId else { return nil }
            var root = parentId
            var seen: Set<String> = [margin.id]
            while let up = byId[root]?.parentId, seen.insert(root).inserted { root = up }
            return MarginReplyLink.replying(
                to: identity(parentId), parentConversationId: MarginReplyLink.conversationId(rootedAt: identity(root)))
        }

        var local: [Interjection] = []
        var imported: [ImportedCommentaryInterjection] = []
        for (index, margin) in margins.enumerated() {
            let created = t0.addingTimeInterval(TimeInterval(index))
            if margin.sender == ownSender {
                var anchor = Anchor(
                    anchorType: .media, startChar: 0, endChar: 0, anchorBefore: margin.sourceTextBefore ?? "", anchorAfter: "")
                anchor.mediaTimeMs = margin.timeMs
                var interjection = Interjection(
                    id: margin.id, itemId: itemId, sessionId: "session-case", targetType: .item, targetId: itemId,
                    createdAt: created, roughPercent: 0, anchor: anchor, audioPath: "voice/\(margin.id).m4a",
                    audioStatus: "saved", transcriptionStatus: "transcribed", transcript: margin.words,
                    cleanedTranscript: nil, displayText: margin.words, status: "active",
                    isStarredForSharing: margin.starred ? true : nil, captureKind: .audio)
                interjection.sharedAs = [MarginPacketIdentity(packageDigest: listenerDigest, packageScopedId: margin.id)]
                interjection.replyTo = link(for: margin)
                local.append(interjection)
            } else {
                let heard = MarginsControlCenter.marksHeard(.listened(ms: margin.listenedMs))
                imported.append(ImportedCommentaryInterjection(
                    id: margin.id, layerId: "layer-\(margin.sender)", packageScopedId: margin.id, createdAt: created,
                    anchorEvidence: PortableAnchorEvidence(
                        anchorType: .media, prefix: margin.sourceTextBefore, mediaTimeMs: margin.timeMs),
                    approvedTranscript: margin.words ?? "", audioPath: "voice/\(margin.id).m4a", audioDurationMs: 6_000,
                    resolution: margin.timeMs.map {
                        ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: $0, confidence: 1)
                    } ?? ImportedAnchorResolution(evidenceClass: .unresolved, localMediaTimeMs: nil, confidence: 0),
                    firstHeardAt: heard ? created.addingTimeInterval(3_600) : nil,
                    replyLinks: link(for: margin).map { [$0] }))
            }
        }
        return MarginsControlCenter.rows(itemId: itemId, localMargins: local, layers: layers, importedMargins: imported)
    }

    static func expectedRow(_ row: MarginsControlCenter.Row, autoplay: MarginsControlCenter.Autoplay) -> ExpectedRow {
        let id: String
        switch row.reference {
        case .local(let value): id = bareOwnId(value)
        case .imported(let value): id = value
        }
        let hearing: String
        switch row.hearing {
        case .yours: hearing = "yours"
        case .heard: hearing = "heard"
        case .unheard: hearing = "unheard"
        }
        let words: String?
        switch row.words {
        case .text(let text): words = text
        case .coming: words = nil
        }
        return ExpectedRow(
            id: id, depth: row.depth, sender: row.senderLabel, hearing: hearing, words: words,
            wordsComing: row.words == .coming, leadIn: row.leadIn, timeMs: row.timeMs, startHereMs: row.startHereMs,
            starred: row.isStarred, note: row.note,
            arrival: MarginsControlCenter.arrival(for: row, autoplay: autoplay) == .plays ? "plays" : "tone")
    }

    static func expectedNext(_ skip: NextMarginSkip) -> ExpectedNext {
        ExpectedNext(
            marginTimeMs: skip.marginTimeMs, leadInStartMs: skip.leadInStartMs, msUntilMargin: skip.msUntilMargin,
            action: skip.action.rawValue, destinationMs: skip.destinationMs, countdown: skip.countdown,
            firstToPlayId: skip.firstToPlay.map { reference in
                switch reference {
                case .local(let id): bareOwnId(id)
                case .imported(let id): id
                }
            } ?? "")
    }

    /// The contract's cases name an own Margin by its bare id (one session each, "session-case"); the rows key it by
    /// session and id (#5133).
    private static func bareOwnId(_ scoped: String) -> String {
        scoped.replacingOccurrences(of: "session-case::", with: "")
    }
}
