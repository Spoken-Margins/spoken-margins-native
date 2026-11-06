import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3449, shown on a real SQLite Library and the engine's real export path (the Export screen's call), with the real
/// `PublicSourceMarker` and a probe that records every request it is asked to make.
///
/// Four sources: a PDF from Files, a paid feed (three ways it can look), a public podcast, and the same podcast when
/// nothing but background-style work touches it. Each has a model-written map in the store. The export JSON and the
/// Markdown the Export screen shows are searched for the model's words, and the probe says what was fetched.
@MainActor
final class PublicMapTextEndToEndTests: XCTestCase {
    private let modelWords = ["Crossing the desert", "caravans carried goods", "Editorial content", "On-device scene title"]

    /// Records each request and answers from a table. Anything it was not told about is a 404, so a surprise request
    /// also shows in `requests`.
    private final class RecordingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private let answer: @Sendable (URL) -> PublicSourceVerifier.Response
        init(answer: @escaping @Sendable (URL) -> PublicSourceVerifier.Response = { _ in .init(status: 404) }) { self.answer = answer }
        var requests: [String] { lock.withLock { seen } }
        var probe: PublicSourceVerifier.Probe {
            { [self] url, _ in
                lock.withLock { seen.append(url.absoluteString) }
                return answer(url)
            }
        }
    }

    // MARK: A PDF from Files

    func testAPDFFromFilesKeepsItsSummariesOnThePhoneAndMakesNoRequest() async throws {
        let text = "# Intro\n\nThe first section talks about caravans carried goods over the dunes for many long years.\n\n# Next\n\nThe second section is about water."
        let prepared = try SourceFileItemBuilder.prepare(
            ImportedSourceText(text: text, documentStructure: nil, title: "Paper"),
            fileURL: URL(fileURLWithPath: "/private/var/mobile/Paper.pdf"), itemId: "pdf-1", createdAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(prepared.item.externalReferenceType, "file", "the origin that can never earn a mark")
        let probe = RecordingProbe()
        try await withStore { store, engine in
            engine.publicSourceMarker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe.probe))
            try put(store, prepared.item)
            if let map = prepared.listeningMap { try store.saveListeningMap(map) }
            // The on-device model's scenes for this PDF, stored exactly as the Prepare Listening Map run stores them.
            let draft = TextSceneDraft(id: "ch-generated-01", order: 0, startChar: 0, endChar: 40, fallbackTitle: "Intro",
                                       modelText: "x", isSummarizable: true)
            let label = ListeningMapSummaryValidator.SceneLabel(
                title: "Crossing the desert", description: "How caravans carried goods over the dunes.",
                eligibility: .eligible, eligibilityReason: "Editorial content.")
            try store.savePortableListeningMapProposal(TextSceneAssembly.proposal(
                safeItemComponent: "pdf-1",
                scenes: [TextSceneAssembly.scene(draft: draft, label: label, characters: Array(text))]), itemId: "pdf-1")
            let stored = try store.loadPortableListeningMapProposals(itemId: "pdf-1")
            XCTAssertTrue(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self).contains("Crossing the desert"),
                          "the summaries exist on the phone, so the check below is not vacuous")

            let (json, markdown) = try await export(store: store, engine: engine, itemId: "pdf-1")
            assertNoModelWords(json + markdown)
            XCTAssertEqual(probe.requests, [], "a PDF from Files has no public copy; nothing is fetched")
            let outcome = await engine.publicSourceMarker!.ensureMark(itemId: "pdf-1", repository: store)
            XCTAssertEqual(outcome, .notPublic)
            XCTAssertNil(try store.loadItem(id: "pdf-1").publicSourceMark)
            XCTAssertEqual(probe.requests, [])
            XCTAssertEqual(MapTextDisclosure.withheldSceneCount(stored, for: try store.loadItem(id: "pdf-1")), 1,
                           "the share preview counts the scene the packet leaves out")
        }
    }

    // MARK: A paid feed

    func testAPaidFeedExportsNoModelTextHoweverItLooks() async throws {
        let cases: [(name: String, link: String, enclosure: String, answer: @Sendable (URL) -> PublicSourceVerifier.Response, requests: Int)] = [
            ("a Patreon episode", "https://www.patreon.com/posts/the-episode-123", "https://www.patreon.com/file?h=1&i=2",
             { _ in .init(status: 200, contentType: "audio/mpeg") }, 0),
            ("an enclosure with a subscriber token", "https://paidshow.example.com/episodes/42", "https://cdn.paidshow.example.com/ep42.mp3?auth=abc123def456",
             { _ in .init(status: 200, contentType: "audio/mpeg") }, 0),
            ("an enclosure that wants a login", "https://paidshow.example.com/episodes/43", "https://cdn.paidshow.example.com/ep43.mp3",
             { _ in .init(status: 401) }, 1),
            ("an enclosure that redirects to a login page", "https://paidshow.example.com/episodes/44", "https://cdn.paidshow.example.com/ep44.mp3",
             { url in url.path.hasSuffix(".mp3")
                 ? .init(status: 302, redirect: URL(string: "https://paidshow.example.com/login")!)
                 : .init(status: 200, contentType: "text/html") }, 2), // the redirect is followed anonymously; the page is not audio
        ]
        for testCase in cases {
            let probe = RecordingProbe(answer: testCase.answer)
            try await withStore { store, engine in
                engine.publicSourceMarker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe.probe))
                let item = podcastItem(id: "paid", link: testCase.link, enclosure: testCase.enclosure)
                try put(store, item)
                try saveModelMap(store: store, itemId: "paid")
                let (json, markdown) = try await export(store: store, engine: engine, itemId: "paid")
                assertNoModelWords(json + markdown, testCase.name)
                XCTAssertTrue(json.contains("Scene 1"), "\(testCase.name): the scene starts still travel")
                XCTAssertEqual(probe.requests.count, testCase.requests, "\(testCase.name): \(probe.requests)")
                XCTAssertNil(try store.loadItem(id: "paid").publicSourceMark, testCase.name)
                XCTAssertTrue(probe.requests.allSatisfy { $0.hasPrefix("https://") && !$0.contains("auth=") }, testCase.name)
            }
        }
    }

    // MARK: A public podcast

    func testAPublicPodcastIsCheckedOnTheExportTapAndKeepsItsMap() async throws {
        let probe = RecordingProbe { _ in .init(status: 200, contentType: "audio/mpeg") }
        try await withStore { store, engine in
            engine.publicSourceMarker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe.probe))
            try put(store, podcastItem(id: "pod", link: "https://example.com/episode", enclosure: "https://cdn.example.com/ep.mp3"))
            try saveModelMap(store: store, itemId: "pod")
            XCTAssertEqual(probe.requests, [], "saving the item and its map fetches nothing")

            let (json, markdown) = try await export(store: store, engine: engine, itemId: "pod")
            XCTAssertTrue(json.contains("On-device scene title 2") && markdown.contains("On-device scene title 2"), json)
            XCTAssertEqual(probe.requests, ["https://cdn.example.com/ep.mp3"], "one anonymous request, on the export tap")
            XCTAssertEqual(try store.loadItem(id: "pod").publicSourceMark?.url, "https://example.com/episode")

            _ = try await export(store: store, engine: engine, itemId: "pod")
            XCTAssertEqual(probe.requests.count, 1, "a mark inside its week is trusted; the next tap does not fetch again")
        }
    }

    // MARK: Nothing fetches in the background

    func testWorkThatIsNotAListenerActionNeverFetchesAPublishersPage() async throws {
        let probe = RecordingProbe { _ in .init(status: 200, contentType: "audio/mpeg") }
        try await withStore { store, engine in
            engine.publicSourceMarker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe.probe))
            let item = podcastItem(id: "pod", link: "https://example.com/episode", enclosure: "https://cdn.example.com/ep.mp3")
            try put(store, item)
            try saveModelMap(store: store, itemId: "pod")
            var edited = item
            edited.title = "Renamed"
            try store.saveItem(edited) // a repair or a feed refresh saving the item
            _ = try store.loadPortableListeningMapProposals(itemId: "pod")
            _ = MapTextDisclosure.proposals(try store.loadPortableListeningMapProposals(itemId: "pod"), for: edited)
            _ = try ListeningMapExportResolver.resolve(item: edited, repository: store, durationMs: 600_000)
            // The engine's synchronous export and an export with the Listening Map off (no map is built, so no check).
            _ = try engine.buildExport(options: options(for: "pod", includeListeningMap: true))
            _ = try await engine.buildExportReadingOffMain(options: options(for: "pod", includeListeningMap: false))
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(probe.requests, [], "no request without a listener's add, Prepare Listening Map, share or export tap")
        }
    }

    // MARK: Helpers

    private func assertNoModelWords(_ text: String, _ label: String = "", file: StaticString = #filePath, line: UInt = #line) {
        for word in modelWords {
            XCTAssertFalse(text.contains(word), "\(label): \"\(word)\" left the phone", file: file, line: line)
        }
    }

    private func podcastItem(id: String, link: String, enclosure: String) -> Item {
        Item(id: id, title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil, externalReference: link,
             status: "ready", externalReferenceType: "url",
             media: ItemMedia(sourceType: .remoteStream, url: enclosure, durationMs: 600_000))
    }

    private func saveModelMap(store: SQLiteSessionStore, itemId: String) throws {
        let scenes = [("On-device scene title 1", 0, 120_000), ("On-device scene title 2", 120_000, 300_000)]
        try store.savePortableListeningMapProposal(PortableListeningMapProposalArtifact(
            id: "map-\(itemId)", createdAt: Date(timeIntervalSince1970: 1), generator: "on-device-scene-map.v1",
            scenes: scenes.enumerated().map { index, scene in
                PortableListeningMapScene(
                    id: "scene-\(index)", order: index, title: scene.0, summaryText: "Crossing the desert, part \(index).",
                    summaryProvenance: .modelGenerated, eligibility: .eligible, eligibilityReason: "Editorial content.",
                    startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: scene.1),
                    endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: scene.2))
            }), itemId: itemId)
        try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
            id: "projection-\(itemId)", itemId: itemId, proposalId: "map-\(itemId)",
            algorithmVersion: "episode-projection.exact-edition.v1", points: [], intervals: []))
    }

    private func options(for itemId: String, includeListeningMap: Bool) -> ExportOptions {
        ExportOptions(sessionId: "session-\(itemId)", includeFullText: false, includeReference: true,
                      includeListeningMap: includeListeningMap, includeInterjections: true)
    }

    /// The Export screen's call: `buildExportReadingOffMain` with the Listening Map on, as JSON and as Markdown.
    private func export(store: SQLiteSessionStore, engine: SessionEngine, itemId: String) async throws -> (String, String) {
        let export = try await engine.buildExportReadingOffMain(options: options(for: itemId, includeListeningMap: true))
        return (String(decoding: try JSONEncoder().encode(export), as: UTF8.self), SessionExportMarkdownRenderer.render(export))
    }

    private func withStore(_ body: (SQLiteSessionStore, SessionEngine) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store)
        try await body(store, engine)
    }

    /// Saves the item and a stored session on it, which the Export screen's call reads.
    private func put(_ store: SQLiteSessionStore, _ item: Item) throws {
        try store.saveItem(item)
        try store.saveSession(Session(
            id: "session-\(item.id)", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: item.id,
            position: Position(), completionPercent: 10, playbackRate: 1))
    }
}
