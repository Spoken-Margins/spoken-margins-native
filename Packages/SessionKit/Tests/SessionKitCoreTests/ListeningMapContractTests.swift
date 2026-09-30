import Foundation
import XCTest
@testable import SessionKit

/// The portable Listening Map contract (#480, #88): one fixture per kind of source, the scene rules,
/// and v1 maps keeping their meaning next to v2 proposals.
final class ListeningMapContractTests: XCTestCase {
    /// #88's matrix, one proposal fixture each in Contracts/fixtures/sharing/.
    static let matrix = [
        "native-text",
        "prepared-text-audio",
        "exact-edition-podcast",
        "publisher-chapters",
        "unlabelled-inserted-audio",
        "excluded-and-unknown-spans",
        "unresolved-cross-edition",
        "absent-scene",
    ]

    func testEveryMatrixFixtureDecodesAndMeetsTheContract() throws {
        let present = try FileManager.default.contentsOfDirectory(atPath: sharingFixtures.path)
            .filter { $0.hasPrefix("listening-map-proposal-") && $0.hasSuffix(".json") }
            .map { String($0.dropFirst("listening-map-proposal-".count).dropLast(".json".count)) }
        XCTAssertEqual(Set(present), Set(Self.matrix))

        for name in Self.matrix {
            let proposal = try fixture(name)
            XCTAssertEqual(proposal.schemaVersion, PortableListeningMapProposalArtifact.schemaVersion, name)
            XCTAssertEqual(proposal.scenes.map(\.order), Array(0..<proposal.scenes.count), name)
            XCTAssertEqual(PortableListeningMapContract.violations(in: proposal), [], name)
            XCTAssertEqual(PortableListeningMapContract.withoutIneligibleSummaries(proposal), proposal, name)
        }
    }

    func testMatrixFixturesCarryWhatTheirCaseNames() throws {
        let nativeText = try fixture("native-text")
        XCTAssertTrue(nativeText.scenes.allSatisfy { $0.startAnchor.anchorType == .text && $0.startAnchor.mediaTimeMs == nil })

        let prepared = try fixture("prepared-text-audio")
        XCTAssertTrue(prepared.scenes.allSatisfy { $0.startAnchor.startChar != nil && $0.startAnchor.mediaTimeMs != nil })

        let exact = try fixture("exact-edition-podcast")
        XCTAssertTrue(exact.scenes.allSatisfy { $0.startAnchor.transcriptSegmentId != nil && $0.startAnchor.mediaTimeMs != nil })

        let publisher = try fixture("publisher-chapters")
        XCTAssertTrue(publisher.scenes.allSatisfy { $0.summaryProvenance == .publisherSupplied && $0.startAnchor.chapterTitle == $0.title })

        let inserted = try fixture("unlabelled-inserted-audio")
        let insert = try XCTUnwrap(inserted.scenes.first { $0.eligibility == .unknown })
        XCTAssertNil(insert.title)
        XCTAssertNil(insert.summaryText)
        XCTAssertEqual(insert.startAnchor.anchorType, .media)

        let spans = try fixture("excluded-and-unknown-spans")
        XCTAssertEqual(spans.scenes.map(\.eligibility), [.eligible, .excluded, .unknown, .eligible])
        XCTAssertTrue(spans.scenes.filter { $0.eligibility != .eligible }.allSatisfy {
            $0.summaryText == nil && $0.summaryProvenance == nil && $0.eligibilityReason != nil
        })

        // Phrase evidence and hints, but no producing-edition time a recipient's edition could reuse.
        let crossEdition = try fixture("unresolved-cross-edition")
        XCTAssertTrue(crossEdition.scenes.allSatisfy { $0.startAnchor.mediaTimeMs == nil && $0.startAnchor.exactText != nil })
        XCTAssertTrue(crossEdition.scenes.flatMap { [$0.startAnchor.exactText, $0.endAnchor.exactText] }.allSatisfy {
            ($0?.split(separator: " ").count ?? 0) < PortableListeningMapContract.verbatimRunWords
        })

        // A scene with no locating evidence at all: a recipient must leave it unresolved.
        let absent = try XCTUnwrap(try fixture("absent-scene").scenes.last)
        for anchor in [absent.startAnchor, absent.endAnchor] {
            XCTAssertNil(anchor.mediaTimeMs)
            XCTAssertNil(anchor.startChar)
            XCTAssertNil(anchor.endChar)
            XCTAssertNil(anchor.exactText)
            XCTAssertNil(anchor.transcriptSegmentId)
        }
    }

    /// v1 maps load exactly as they did before v2 proposals existed, and never decode as a v2 proposal.
    func testV1MapsKeepTheirChaptersOrderAndAnchors() throws {
        let expected: [String: ListeningMap] = [
            "valid-listening-map.json": ListeningMap(
                id: "map-pill", itemId: "item-pill",
                overview: "Trust should come from inspectable process rather than anecdotes.",
                chapters: [
                    Chapter(id: "ch-opening", title: "Reasonable distrust", startChar: 0, endChar: 30, percent: 0),
                    Chapter(id: "ch-anecdotes", title: "Anecdotes mislead", startChar: 31, endChar: 81, percent: 18),
                    Chapter(id: "ch-process", title: "Inspect process", startChar: 134, endChar: 194, percent: 69),
                ]
            ),
            "duplicate-anchor-map.json": ListeningMap(
                id: "map-duplicate-anchor", itemId: "item-duplicate",
                overview: "This fixture exists to verify duplicate anchor repair behavior.",
                chapters: [Chapter(id: "ch-repeat", title: "Repeated phrase", startChar: 0, endChar: 0, percent: 0)]
            ),
            "invalid-anchor-map.json": ListeningMap(
                id: "map-pill-invalid-anchor", itemId: "item-pill",
                overview: "Trust should come from inspectable process.",
                chapters: [Chapter(id: "ch-bad", title: "Invented anchor", startChar: 0, endChar: 0, percent: 0)]
            ),
        ]
        let mapsFolder = contractsRoot.appending(path: "fixtures/maps")
        let files = try FileManager.default.contentsOfDirectory(atPath: mapsFolder.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(Set(files), Set(expected.keys), "a new v1 fixture needs its expected map here")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files.sorted() {
            let url = mapsFolder.appending(path: file)
            let loaded = try ContractFixtureLoader.listeningMap(at: url)
            XCTAssertEqual(loaded, expected[file], file)
            XCTAssertThrowsError(try decoder.decode(PortableListeningMapProposalArtifact.self, from: Data(contentsOf: url)), file)
            // The stored form (SQLite keeps ListeningMap as JSON) doesn't read as a proposal either.
            let stored = try JSONEncoder().encode(loaded)
            XCTAssertThrowsError(try decoder.decode(PortableListeningMapProposalArtifact.self, from: stored), file)
            XCTAssertEqual(try JSONDecoder().decode(ListeningMap.self, from: stored), loaded, file)
        }
    }

    // MARK: Scene rules

    func testEligibleSceneNeedsSummaryAndProvenance() {
        let noSummary = proposal([scene(0, .eligible, summary: nil, provenance: nil, from: 0, to: 10)])
        let noProvenance = proposal([scene(0, .eligible, summary: "A summary.", provenance: nil, from: 0, to: 10)])
        XCTAssertEqual(violations(noSummary), [.eligibleSceneLacksSummary(sceneId: "scene-0")])
        XCTAssertEqual(violations(noProvenance), [.eligibleSceneLacksSummary(sceneId: "scene-0")])
    }

    func testExcludedOrUnknownSceneMustNotCarryASummary() {
        for eligibility in [PortableSceneEligibility.excluded, .unknown] {
            let text = proposal([scene(0, eligibility, summary: "An ad for mattresses.", provenance: .modelGenerated, from: 0, to: 10)])
            XCTAssertEqual(violations(text), [.ineligibleSceneCarriesSummary(sceneId: "scene-0")], "\(eligibility)")
            let voice = proposal([PortableListeningMapScene(
                id: "scene-0", order: 0, summaryAssetId: "asset-summary", eligibility: eligibility,
                startAnchor: .init(anchorType: .media, mediaTimeMs: 0), endAnchor: .init(anchorType: .media, mediaTimeMs: 10)
            )])
            XCTAssertEqual(violations(voice), [.ineligibleSceneCarriesSummary(sceneId: "scene-0")], "\(eligibility)")

            let stripped = PortableListeningMapContract.withoutIneligibleSummaries(text)
            XCTAssertNil(stripped.scenes[0].summaryText)
            XCTAssertNil(stripped.scenes[0].summaryProvenance)
            XCTAssertEqual(stripped.scenes[0].eligibility, eligibility)
            XCTAssertEqual(violations(stripped), [])
        }
    }

    func testScenesMustRunForwardWithoutOverlapping() {
        let ordered = proposal([
            scene(0, .eligible, from: 0, to: 1_000), scene(1, .eligible, from: 1_000, to: 2_000),
        ])
        XCTAssertEqual(violations(ordered), [], "touching scenes are fine")

        let overlapping = proposal([
            scene(0, .eligible, from: 0, to: 1_500), scene(1, .eligible, from: 1_000, to: 2_000),
        ])
        XCTAssertEqual(violations(overlapping), [.sceneOverlapsPrevious(sceneId: "scene-1")])

        let backwards = proposal([
            scene(0, .eligible, from: 1_000, to: 2_000), scene(1, .eligible, from: 0, to: 1_000),
        ])
        XCTAssertEqual(violations(backwards), [.sceneOutOfOrder(sceneId: "scene-1")])

        let inverted = proposal([scene(0, .eligible, from: 2_000, to: 1_000)])
        XCTAssertEqual(violations(inverted), [.sceneEndsBeforeItStarts(sceneId: "scene-0")])

        let overlappingText = proposal([
            PortableListeningMapScene(id: "scene-0", order: 0, summaryText: "One.", summaryProvenance: .senderAuthored,
                eligibility: .eligible, startAnchor: .init(anchorType: .text, startChar: 0), endAnchor: .init(anchorType: .text, endChar: 50)),
            PortableListeningMapScene(id: "scene-1", order: 1, summaryText: "Two.", summaryProvenance: .senderAuthored,
                eligibility: .eligible, startAnchor: .init(anchorType: .text, startChar: 40), endAnchor: .init(anchorType: .text, endChar: 90)),
        ])
        XCTAssertEqual(violations(overlappingText), [.sceneOverlapsPrevious(sceneId: "scene-1")])

        // A scene placed only by rough percentages can't hide an overlap between the scenes either side of it.
        let roughOnly = PortableListeningMapScene(
            id: "scene-1", order: 1, summaryText: "Two.", summaryProvenance: .senderAuthored, eligibility: .eligible,
            startAnchor: .init(anchorType: .media, roughPercent: 40), endAnchor: .init(anchorType: .media, roughPercent: 60)
        )
        let hiddenOverlap = proposal([
            scene(0, .eligible, from: 0, to: 70_000), roughOnly, scene(2, .eligible, from: 60_000, to: 90_000),
        ])
        XCTAssertEqual(violations(hiddenOverlap), [.sceneOverlapsPrevious(sceneId: "scene-2")])
        let hiddenBackwards = proposal([
            scene(0, .eligible, from: 50_000, to: 70_000), roughOnly, scene(2, .eligible, from: 10_000, to: 20_000),
        ])
        XCTAssertEqual(violations(hiddenBackwards), [.sceneOutOfOrder(sceneId: "scene-2")])
        let roughBetweenOrdered = proposal([
            scene(0, .eligible, from: 0, to: 60_000), roughOnly, scene(2, .eligible, from: 60_000, to: 90_000),
        ])
        XCTAssertEqual(violations(roughBetweenOrdered), [])

        // Text and audio both run forward: a character overlap counts even where media time doesn't show one.
        func textAudio(_ order: Int, ms: (Int, Int)?, chars: (Int, Int)) -> PortableListeningMapScene {
            PortableListeningMapScene(
                id: "scene-\(order)", order: order, summaryText: "Scene.", summaryProvenance: .senderAuthored, eligibility: .eligible,
                startAnchor: .init(anchorType: .text, startChar: chars.0, mediaTimeMs: ms?.0),
                endAnchor: .init(anchorType: .text, endChar: chars.1, mediaTimeMs: ms?.1)
            )
        }
        let textOverlapBehindMedia = proposal([
            textAudio(0, ms: (0, 1_000), chars: (0, 100)),
            textAudio(1, ms: nil, chars: (100, 500)),
            textAudio(2, ms: (1_000, 2_000), chars: (300, 600)),
        ])
        XCTAssertEqual(violations(textOverlapBehindMedia), [.sceneOverlapsPrevious(sceneId: "scene-2")])
        let textAudioForward = proposal([
            textAudio(0, ms: (0, 1_000), chars: (0, 100)),
            textAudio(1, ms: nil, chars: (100, 500)),
            textAudio(2, ms: (1_000, 2_000), chars: (500, 600)),
        ])
        XCTAssertEqual(violations(textAudioForward), [])
    }

    func testSummaryMustNotQuoteTenWordsOfItsSourceText() {
        let source = "The committee met at dawn and agreed that the old bridge must close before winter storms arrive."
        let quoting = "In short, the committee met at dawn and agreed that the old bridge must close."
        let paraphrase = "Officials decided to shut an ageing crossing ahead of bad weather."
        let nineWords = "Notably the committee met at dawn and agreed that the plan was fine."

        func withAnchorText(_ summary: String) -> PortableListeningMapProposalArtifact {
            proposal([PortableListeningMapScene(
                id: "scene-0", order: 0, summaryText: summary, summaryProvenance: .modelGenerated, eligibility: .eligible,
                startAnchor: .init(anchorType: .transcript, exactText: "The committee met", suffix: source, mediaTimeMs: 0),
                endAnchor: .init(anchorType: .transcript, mediaTimeMs: 60_000)
            )])
        }
        XCTAssertEqual(violations(withAnchorText(quoting)), [.summaryQuotesSource(sceneId: "scene-0")])
        XCTAssertEqual(violations(withAnchorText(paraphrase)), [])
        XCTAssertEqual(violations(withAnchorText(nineWords)), [], "nine shared words are not a quotation")

        // An anchor's prefix, quoted text and suffix are one stretch of source, so a run across them counts.
        func withSplitAnchor(_ summary: String) -> PortableListeningMapProposalArtifact {
            proposal([PortableListeningMapScene(
                id: "scene-0", order: 0, summaryText: summary, summaryProvenance: .modelGenerated, eligibility: .eligible,
                startAnchor: .init(
                    anchorType: .transcript, exactText: "the committee met at dawn",
                    prefix: "Late in the year", suffix: "and agreed that the old bridge must close", mediaTimeMs: 0
                ),
                endAnchor: .init(anchorType: .transcript, mediaTimeMs: 60_000)
            )])
        }
        XCTAssertEqual(violations(withSplitAnchor(quoting)), [.summaryQuotesSource(sceneId: "scene-0")])
        XCTAssertEqual(
            violations(withSplitAnchor("Late in the year the committee met at dawn and agreed, officials said.")),
            [.summaryQuotesSource(sceneId: "scene-0")], "prefix through quoted text into suffix"
        )
        XCTAssertEqual(violations(withSplitAnchor(paraphrase)), [])

        // Embedded item text: the scene's own span counts, another scene's span doesn't.
        let item = "Unrelated opening words fill this first part of the item before anything happens here. " + source
        let sceneStart = item.count - source.count
        func withEmbedded(from start: Int, to end: Int) -> PortableListeningMapProposalArtifact {
            proposal([PortableListeningMapScene(
                id: "scene-0", order: 0, summaryText: quoting, summaryProvenance: .senderAuthored, eligibility: .eligible,
                startAnchor: .init(anchorType: .text, startChar: start), endAnchor: .init(anchorType: .text, endChar: end)
            )])
        }
        XCTAssertEqual(violations(withEmbedded(from: sceneStart, to: item.count), itemText: item), [.summaryQuotesSource(sceneId: "scene-0")])
        XCTAssertEqual(violations(withEmbedded(from: 0, to: sceneStart), itemText: item), [])
        XCTAssertEqual(violations(withEmbedded(from: sceneStart, to: item.count)), [], "no embedded text, no anchor text")
    }

    /// What a packet carries: ineligible summaries dropped, a proposal that still breaks a rule left out.
    func testForSharingKeepsGoodMapsAndLeavesOutBrokenOnes() {
        let labelled = proposal([
            scene(0, .eligible, from: 0, to: 1_000),
            scene(1, .excluded, summary: "An ad.", provenance: .modelGenerated, from: 1_000, to: 2_000),
        ])
        let overlapping = proposal([
            scene(0, .eligible, from: 0, to: 1_500), scene(1, .eligible, from: 1_000, to: 2_000),
        ])
        let shared = PortableListeningMapContract.forSharing([labelled, overlapping])
        XCTAssertEqual(shared, [PortableListeningMapContract.withoutIneligibleSummaries(labelled)])
        XCTAssertNil(shared.first?.scenes[1].summaryText)
        XCTAssertEqual(shared.first?.scenes[0].summaryText, "A short summary.")
    }

    /// The map the app builds from a prepared Listening Edition meets the contract, so export keeps working.
    func testPreparedEditionMapMeetsTheContract() throws {
        let text = "First block of the source text.\n\nSecond block continues the argument.\n\nThird block concludes it."
        let edition = ListeningEdition(
            title: "Edition", text: text, generator: "fixture", overview: "Overview.",
            scenes: [
                .init(title: "Start", description: "Opening.", summary: "The piece opens.", startBlock: 1, endBlock: 1),
                .init(title: "Rest", description: "Remainder.", summary: "It argues and concludes.", startBlock: 2, endBlock: 3),
            ]
        )
        let blocks = ListeningEdition.blocks(in: text)
        let timeline = TranscriptTimeline(
            segments: blocks.enumerated().map { index, block in
                MediaTimelineSegment(id: "segment-\(index)", startMs: index * 3_000, endMs: (index + 1) * 3_000,
                                     startChar: block.startChar, endChar: block.endChar, text: block.text)
            },
            chapters: [],
            durationMs: 9_000
        )
        let (map, _) = try edition.audioMap(timeline: timeline)
        XCTAssertEqual(violations(map, itemText: text), [])
    }

    // MARK: Helpers

    private var contractsRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appending(path: "Contracts")
    }

    private var sharingFixtures: URL { contractsRoot.appending(path: "fixtures/sharing") }

    private func fixture(_ name: String) throws -> PortableListeningMapProposalArtifact {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            PortableListeningMapProposalArtifact.self,
            from: Data(contentsOf: sharingFixtures.appending(path: "listening-map-proposal-\(name).json"))
        )
    }

    private func violations(
        _ proposal: PortableListeningMapProposalArtifact,
        itemText: String? = nil
    ) -> [PortableListeningMapContract.Violation] {
        PortableListeningMapContract.violations(in: proposal, itemText: itemText)
    }

    private func proposal(_ scenes: [PortableListeningMapScene]) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(id: "proposal", createdAt: Date(timeIntervalSince1970: 0), generator: "test", scenes: scenes)
    }

    private func scene(
        _ order: Int,
        _ eligibility: PortableSceneEligibility,
        summary: String? = "A short summary.",
        provenance: PortableSummaryProvenance? = .senderAuthored,
        from start: Int,
        to end: Int
    ) -> PortableListeningMapScene {
        PortableListeningMapScene(
            id: "scene-\(order)", order: order,
            summaryText: summary, summaryProvenance: provenance, eligibility: eligibility,
            startAnchor: .init(anchorType: .media, mediaTimeMs: start),
            endAnchor: .init(anchorType: .media, mediaTimeMs: end)
        )
    }
}
