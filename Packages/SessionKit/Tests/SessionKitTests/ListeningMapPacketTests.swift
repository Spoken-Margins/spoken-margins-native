import Foundation
@testable import SessionKit
import SessionKitSharing
import ShippedPacketReader
import XCTest
import ZIPFoundation

/// Listening Map proposals inside `.spokenmargins` packets (#480): the fixture matrix travels and
/// Build 29 imports it, packet validation enforces the scene rules, and no transcript leaks.
final class ListeningMapPacketTests: XCTestCase {
    // MARK: Fixture matrix (Done when 1 and 5)

    func testEveryMatrixFixtureTravelsInAPacketThatBuild29Imports() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = try FileManager.default.contentsOfDirectory(atPath: sharingFixtures.path)
            .filter { $0.hasPrefix("listening-map-proposal-") && $0.hasSuffix(".json") }
            .sorted()
        XCTAssertEqual(names.count, 8, "one fixture per #88 matrix case")
        for name in names {
            let proposal = try JSONDecoder.iso8601.decode(
                PortableListeningMapProposalArtifact.self,
                from: Data(contentsOf: sharingFixtures.appending(path: name))
            )
            let isText = proposal.scenes.allSatisfy { $0.startAnchor.anchorType == .text }
            let prepared = try package(item: isText ? articleItem : podcastItem, proposals: [proposal])
            let url = root.appending(path: "\(name).spokenmargins")
            // exportPacket also imports the packet with Build 29's frozen reader and fails if it refuses.
            _ = try exportPacket(prepared, to: url)
            XCTAssertEqual(try ShippedPacketReader.importPacket(at: url), ["margin-001"], name)
            let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appending(path: "assets-\(name)"))
            XCTAssertEqual(verified.listeningMapProposals, [proposal], name)
        }
    }

    // MARK: Scene rules in packet validation (Done when 3)

    func testPacketRejectsEligibleSceneWithoutSummaryOrProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = proposal([scene(0, .eligible, summary: nil, provenance: nil, from: 0, to: 60_000)])
        let prepared = try replacingProposal(in: package(item: podcastItem), with: bare)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(prepared, to: root.appending(path: "bare.spokenmargins"))) {
            XCTAssertTrue("\($0)".contains("lacks a grounded summary"), "\($0)")
        }
    }

    func testPacketRejectsSummaryOnExcludedOrUnknownScene() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for eligibility in [PortableSceneEligibility.excluded, .unknown] {
            let summarised = proposal([
                scene(0, .eligible, from: 0, to: 60_000),
                scene(1, eligibility, summary: "A mattress company sponsors this episode.", provenance: .modelGenerated, from: 60_000, to: 90_000),
            ])
            let prepared = try replacingProposal(in: package(item: podcastItem), with: summarised)
            XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(prepared, to: root.appending(path: "\(eligibility).spokenmargins"))) {
                XCTAssertTrue("\($0)".contains("excluded or unknown scene scene-1 carries a summary"), "\($0)")
            }

            // The builder drops the summary, as the app's on-device labeller describes every scene.
            let built = try package(item: podcastItem, proposals: [summarised])
            let builtURL = root.appending(path: "built-\(eligibility).spokenmargins")
            _ = try exportPacket(built, to: builtURL)
            let exported = try SpokenMarginsPackageArchive.read(from: builtURL, extractingAssetsTo: root.appending(path: "built-\(eligibility)"))
            XCTAssertNil(exported.listeningMapProposals.first?.scenes[1].summaryText)
            XCTAssertEqual(exported.listeningMapProposals.first?.scenes[0].summaryText, "A short summary.")

            // A Build 29 sender's packet still imports: its Margins arrive and the summary is dropped.
            let oldURL = root.appending(path: "build29-\(eligibility).spokenmargins")
            try writeWithBuild29(prepared, to: oldURL)
            let imported = try SpokenMarginsPackageArchive.read(from: oldURL, extractingAssetsTo: root.appending(path: "build29-\(eligibility)"))
            XCTAssertEqual(imported.commentaryLayers.first?.interjections.map(\.packageScopedId), ["margin-001"])
            let scenes = try XCTUnwrap(imported.listeningMapProposals.first?.scenes)
            XCTAssertNil(scenes[1].summaryText)
            XCTAssertNil(scenes[1].summaryProvenance)
            XCTAssertEqual(scenes[1].eligibility, eligibility)
        }
    }

    func testPacketRejectsScenesOutOfOrderOrOverlapping() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = [
            ("overlapping", proposal([scene(0, .eligible, from: 0, to: 70_000), scene(1, .eligible, from: 60_000, to: 90_000)]), "overlaps an earlier scene"),
            ("backwards", proposal([scene(0, .eligible, from: 60_000, to: 90_000), scene(1, .eligible, from: 0, to: 60_000)]), "starts before an earlier scene"),
            ("inverted", proposal([scene(0, .eligible, from: 90_000, to: 60_000)]), "ends before it starts"),
        ]
        for (name, bad, message) in cases {
            let prepared = try replacingProposal(in: package(item: podcastItem), with: bad)
            XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(prepared, to: root.appending(path: "\(name).spokenmargins"))) {
                XCTAssertTrue("\($0)".contains(message), "\(name): \($0)")
            }
            try assertBuild29PacketImportsWithoutItsMap(prepared, name: name, root: root)

            // The app's builder leaves such a map out instead of failing the share.
            let built = try package(item: podcastItem, proposals: [bad])
            _ = try exportPacket(built, to: root.appending(path: "built-\(name).spokenmargins"))
            XCTAssertFalse(built.manifest.artifacts.contains { $0.kind == SpokenMarginsArtifactKind.listeningMapProposal }, name)
        }
    }

    func testPacketRejectsSummaryThatQuotesTenWordsOfTheSceneSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let passage = "The committee met at dawn and agreed that the old bridge must close before winter storms arrive."
        let text = "A short opening paragraph sets out the town and its river.\n\n" + passage
        let quoting = "In short, the committee met at dawn and agreed that the old bridge must close."
        let item = SharedItemIdentity(
            itemType: .pdf, title: "Bridge Minutes",
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text),
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text)
        )
        let embedded = ReviewedItemTransportSelection.embeddedText(
            text: text, originalMediaType: "pdf", rightsBasis: .senderConfirmedPrivateRights
        )
        let passageStart = text.count - passage.count
        func sceneOverPassage(summary: String) -> PortableListeningMapProposalArtifact {
            proposal([
                PortableListeningMapScene(
                    id: "scene-0", order: 0, summaryText: "The town and its river.", summaryProvenance: .senderAuthored,
                    eligibility: .eligible,
                    startAnchor: .init(anchorType: .text, startChar: 0), endAnchor: .init(anchorType: .text, endChar: passageStart - 2)
                ),
                PortableListeningMapScene(
                    id: "scene-1", order: 1, summaryText: summary, summaryProvenance: .senderAuthored, eligibility: .eligible,
                    startAnchor: .init(anchorType: .text, startChar: passageStart), endAnchor: .init(anchorType: .text, endChar: text.count)
                ),
            ])
        }

        // A paraphrase travels with the embedded text; a 10-word quotation of the scene's own span doesn't.
        let paraphrase = sceneOverPassage(summary: "Officials vote to shut the ageing crossing.")
        let paraphrased = try package(item: item, transport: embedded, proposals: [paraphrase])
        let paraphrasedURL = root.appending(path: "paraphrase.spokenmargins")
        _ = try exportPacket(paraphrased, to: paraphrasedURL)
        XCTAssertEqual(try SpokenMarginsPackageArchive.read(from: paraphrasedURL, extractingAssetsTo: root.appending(path: "paraphrase")).listeningMapProposals, [paraphrase])
        let quoted = try replacingProposal(in: package(item: item, transport: embedded), with: sceneOverPassage(summary: quoting))
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(quoted, to: root.appending(path: "quoted.spokenmargins"))) {
            XCTAssertTrue("\($0)".contains("scene scene-1 summary quotes"), "\($0)")
        }
        try assertBuild29PacketImportsWithoutItsMap(quoted, name: "quoted", root: root)
        let built = try package(item: item, transport: embedded, proposals: [sceneOverPassage(summary: quoting)])
        _ = try exportPacket(built, to: root.appending(path: "built-quoted.spokenmargins"))
        XCTAssertFalse(built.manifest.artifacts.contains { $0.kind == SpokenMarginsArtifactKind.listeningMapProposal })

        // Without embedded text, the scene's source is what its anchors quote.
        let anchored = proposal([PortableListeningMapScene(
            id: "scene-0", order: 0, summaryText: quoting, summaryProvenance: .modelGenerated, eligibility: .eligible,
            startAnchor: .init(anchorType: .text, exactText: passage), endAnchor: .init(anchorType: .text)
        )])
        let referenced = try replacingProposal(in: package(item: articleItem), with: anchored)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(referenced, to: root.appending(path: "anchored.spokenmargins"))) {
            XCTAssertTrue("\($0)".contains("scene scene-0 summary quotes"), "\($0)")
        }
    }

    // MARK: Transcript leak check (Done when 4)

    /// A podcast with an internal transcript, its scene map and phrase sketch, shared with two Margins.
    /// No 10-word run of the transcript may appear anywhere in the archive, except inside the context a
    /// Margin's sender reviewed around it (bounded to 500 characters a side, BoundedAnchorContext).
    func testPacketCarriesNoTranscriptRunOutsideReviewedMarginContext() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timeline = syntheticTranscript(segments: 40, segmentMs: 15_000)
        let transcriptRuns = runs(timeline.segments.map(\.text).joined(separator: " "))
        XCTAssertGreaterThan(transcriptRuns.count, 500)

        let drafts = EpisodeSceneSegmenter.makeDrafts(timeline: timeline)
        XCTAssertGreaterThan(drafts.count, 1)
        let map = PortableListeningMapProposalArtifact(
            id: "episode-map-proposal", createdAt: fixedDate, generator: "on-device-scene-map.v1",
            scenes: drafts.map { draft in
                let eligible = draft.order != 1
                return PortableListeningMapScene(
                    id: draft.id, order: draft.order, title: "Part \(draft.order + 1)",
                    summaryText: eligible ? "The hosts move on to part \(draft.order + 1) of the story." : nil,
                    summaryProvenance: eligible ? .modelGenerated : nil,
                    eligibility: eligible ? .eligible : .unknown,
                    eligibilityReason: eligible ? nil : "The labeller was not confident.",
                    startAnchor: .init(anchorType: .transcript, mediaTimeMs: draft.startMs, transcriptSegmentId: draft.startTranscriptSegmentId),
                    endAnchor: .init(anchorType: .transcript, mediaTimeMs: draft.endMs, transcriptSegmentId: draft.endTranscriptSegmentId)
                )
            }
        )
        let sketch = TranscriptPhraseSketchBuilder.makeArtifact(
            id: "sketch", itemId: "episode-one", timeline: timeline,
            salt: Data(repeating: 7, count: 32), createdAt: fixedDate
        )
        let placed = MediaTimelineAnchorResolver.resolve(mediaTimeMs: 300_000, timeline: timeline)
        let bareMargin = ReviewedInterjectionSelection(
            packageScopedId: "margin-001", revision: revision(before: "", after: ""),
            anchor: .init(anchorType: .media, mediaTimeMs: 125_000, transcriptSegmentId: "segment-0008"),
            representation: .textOnly
        )
        let contextMargin = ReviewedInterjectionSelection(
            packageScopedId: "margin-002", revision: revision(before: placed.anchorBefore, after: placed.anchorAfter),
            anchor: .init(anchorType: .media, mediaTimeMs: placed.mediaTimeMs, transcriptSegmentId: placed.transcriptSegmentId),
            representation: .textOnly
        )

        func archiveRuns(_ selections: [ReviewedInterjectionSelection], name: String) throws -> Set<String> {
            let prepared = try SpokenMarginsPackageBuilder.prepare(
                packageId: "leak-\(name)", createdAt: fixedDate, item: podcastItem, itemTransportSelection: .reference,
                selections: selections, mapProposals: [map], phraseSketches: [sketch]
            )
            let url = root.appending(path: "\(name).spokenmargins")
            _ = try exportPacket(prepared, to: url)
            let entries = try readRawArchive(url)
            XCTAssertTrue(entries.keys.contains { $0.contains("listening-map-proposal") }, name)
            XCTAssertTrue(entries.keys.contains { $0.contains("transcript-phrase-sketch") }, name)
            return entries.values.reduce(into: Set<String>()) { found, data in
                found.formUnion(runs(String(decoding: data, as: UTF8.self)).intersection(transcriptRuns))
            }
        }

        XCTAssertEqual(try archiveRuns([bareMargin], name: "bare"), [], "the map, sketch, manifest and preview carry no transcript")

        let reviewed = BoundedAnchorContext.select(before: placed.anchorBefore, after: placed.anchorAfter)
        let allowed = runs(reviewed.before).union(runs(reviewed.after))
        let found = try archiveRuns([bareMargin, contextMargin], name: "context")
        XCTAssertFalse(found.isEmpty, "the reviewed context is in the packet, so the scan can see transcript text")
        XCTAssertTrue(found.isSubset(of: allowed), "transcript outside reviewed context: \(found.subtracting(allowed).sorted().prefix(3))")
    }

    // MARK: Helpers

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_777_000_000) }

    private var sharingFixtures: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appending(path: "Contracts/fixtures/sharing")
    }

    private var articleItem: SharedItemIdentity {
        SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
    }

    private var podcastItem: SharedItemIdentity {
        SharedItemIdentity(
            itemType: .podcast, canonicalURL: "https://example.com/episodes/one",
            title: "Episode One", publisher: "Example", showTitle: "Example Show", episodeGUID: "episode-one",
            enclosureURL: "https://example.com/audio/one.mp3", durationMs: 3_600_000,
            exactEditionSHA256: String(repeating: "ab", count: 32), languageCode: "en",
            source: SharedSourceIdentity(
                sourceType: .podcastFeed, canonicalURL: "https://example.com/feed.xml",
                title: "Example Show", publisher: "Example"
            )
        )
    }

    private func revision(before: String = "Before this passage.", after: String = "After this passage.") -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-approved", interjectionId: "private-note", itemId: "private-item",
            sessionId: "private-session", createdAt: fixedDate, approvedTranscript: "A sender-reviewed thought.",
            anchorBefore: before, anchorAfter: after, status: .senderApproved
        )
    }

    private func package(
        item: SharedItemIdentity,
        transport: ReviewedItemTransportSelection = .reference,
        proposals: [PortableListeningMapProposalArtifact] = [placeholderProposal]
    ) throws -> PreparedSpokenMarginsPackage {
        try SpokenMarginsPackageBuilder.prepare(
            packageId: "map-package", createdAt: fixedDate, item: item, itemTransportSelection: transport,
            selections: [.init(
                packageScopedId: "margin-001", revision: revision(),
                anchor: .init(anchorType: .media, mediaTimeMs: 5_000), representation: .textOnly
            )],
            mapProposals: proposals
        )
    }

    private static let placeholderProposal = PortableListeningMapProposalArtifact(
        id: "proposal", createdAt: Date(timeIntervalSince1970: 0), generator: "test",
        scenes: [PortableListeningMapScene(
            id: "scene-0", order: 0, summaryText: "Placeholder.", summaryProvenance: .senderAuthored, eligibility: .eligible,
            startAnchor: .init(anchorType: .media, mediaTimeMs: 0), endAnchor: .init(anchorType: .media, mediaTimeMs: 1)
        )]
    )

    /// The package with its one proposal's bytes replaced, bypassing the builder, as a hand-made or older
    /// sender's packet would be.
    private func replacingProposal(
        in prepared: PreparedSpokenMarginsPackage,
        with proposal: PortableListeningMapProposalArtifact
    ) throws -> PreparedSpokenMarginsPackage {
        let descriptor = try XCTUnwrap(prepared.manifest.artifacts.first { $0.kind == SpokenMarginsArtifactKind.listeningMapProposal })
        XCTAssertEqual(descriptor.id, proposal.id)
        var data = prepared.artifactData
        data[descriptor.path] = try SpokenMarginsPackageArchive.encodeArtifact(proposal)
        return PreparedSpokenMarginsPackage(manifest: prepared.manifest, artifactData: data, assetFiles: prepared.assetFiles)
    }

    /// Build 29 exports a map that breaks a scene rule without complaint. This build imports the packet's
    /// Margins and leaves the map out, so a bad optional proposal never costs the recipient the Margins.
    private func assertBuild29PacketImportsWithoutItsMap(
        _ prepared: PreparedSpokenMarginsPackage,
        name: String,
        root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = root.appending(path: "build29-\(name).spokenmargins")
        try writeWithBuild29(prepared, to: url)
        let imported = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appending(path: "build29-\(name)"))
        XCTAssertEqual(imported.commentaryLayers.first?.interjections.map(\.packageScopedId), ["margin-001"], name, file: file, line: line)
        XCTAssertEqual(imported.listeningMapProposals, [], name, file: file, line: line)
    }

    private func writeWithBuild29(_ prepared: PreparedSpokenMarginsPackage, to url: URL) throws {
        XCTAssertTrue(prepared.assetFiles.isEmpty)
        try ShippedPacketReader.writePacket(
            manifestJSON: SpokenMarginsPackageArchive.encodeManifest(prepared.manifest),
            artifacts: prepared.artifactData,
            to: url
        )
    }

    private func proposal(_ scenes: [PortableListeningMapScene]) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(id: "proposal", createdAt: fixedDate, generator: "test", scenes: scenes)
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
            startAnchor: .init(anchorType: .transcript, mediaTimeMs: start),
            endAnchor: .init(anchorType: .transcript, mediaTimeMs: end)
        )
    }

    /// Deterministic transcript: each segment is 18 words drawn from a fixed vocabulary.
    private func syntheticTranscript(segments: Int, segmentMs: Int) -> TranscriptTimeline {
        let vocabulary = """
        harbour pilot tide ledger lantern keeper basalt amber rope splice gull ferry chart compass drift \
        shoal beacon anchor current squall hull keel mast rigging galley brine kelp cove jetty dune \
        wharf storm fog signal buoy estuary reef swell barge netting capstan halyard bilge tiller oar \
        cormorant heron lighthouse quay slipway cannery trawler skiff moor inlet
        """.split(separator: " ").map(String.init)
        var state: UInt64 = 480
        func nextWord() -> String {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return vocabulary[Int((state >> 33) % UInt64(vocabulary.count))]
        }
        var offset = 0
        let list = (0..<segments).map { index -> MediaTimelineSegment in
            let text = (0..<18).map { _ in nextWord() }.joined(separator: " ") + "."
            defer { offset += text.count + 1 }
            return MediaTimelineSegment(
                id: String(format: "segment-%04d", index), startMs: index * segmentMs, endMs: (index + 1) * segmentMs,
                startChar: offset, endChar: offset + text.count, text: text
            )
        }
        return TranscriptTimeline(segments: list, chapters: [], durationMs: segments * segmentMs)
    }

    private func runs(_ text: String, length: Int = PortableListeningMapContract.verbatimRunWords) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard words.count >= length else { return [] }
        return Set((0...(words.count - length)).map { words[$0..<($0 + length)].joined(separator: " ") })
    }

    private func readRawArchive(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: Data] = [:]
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            result[entry.path] = data
        }
        return result
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ListeningMapPacketTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
