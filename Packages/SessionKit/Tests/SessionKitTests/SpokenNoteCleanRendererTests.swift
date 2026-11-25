#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #4779: the version file is made with the system's audio engine from real AAC takes, then opened and
/// measured. The takes are only read.
final class SpokenNoteCleanRendererTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func take(_ id: String, seconds: Int, seed: UInt64) throws -> (SpokenNoteWholeAudioLayout.Requested, URL) {
        let url = folder.appendingPathComponent("take-\(id).m4a")
        try SeededNoiseAudio.write(to: url, seconds: seconds, seed: seed)
        return (SpokenNoteWholeAudioLayout.Requested(id: id, audioFileName: url.lastPathComponent, durationMs: seconds * 1_000), url)
    }

    private func cut(durationMs: Int, kept: [(Int, Int)]) -> SpokenNoteTakeCut {
        SpokenNoteTakeCut(durationMs: durationMs, kept: kept.map { .init(startMs: $0.0, endMs: $0.1) }, fillersRemoved: 0, pausesShortened: kept.count - 1)
    }

    private func renderTake(_ pair: (SpokenNoteWholeAudioLayout.Requested, URL), _ cut: SpokenNoteTakeCut) -> SpokenNoteRenderTake {
        SpokenNoteRenderTake(requested: pair.0, url: pair.1, cut: cut, cutFingerprint: SpokenNoteCleanFiles.fingerprint(of: cut))
    }

    private func durationMs(_ url: URL) async throws -> Int {
        Int((try await AVURLAsset(url: url).load(.duration).seconds * 1_000).rounded())
    }

    func testKeptStretchesAreLaidEndToEndAndTheFileIsAsLongAsTheMapSays() async throws {
        let a = try take("a", seconds: 4, seed: 1)
        let b = try take("b", seconds: 3, seed: 2)
        let before = try [a.1, b.1].map { try Data(contentsOf: $0) }
        let cutA = cut(durationMs: 4_000, kept: [(0, 1_000), (2_500, 4_000)])
        let cutB = cut(durationMs: 3_000, kept: [(500, 3_000)])

        let layout = try await SpokenNoteCleanRenderer().render(takes: [renderTake(a, cutA), renderTake(b, cutB)], noteFolder: folder)

        XCTAssertEqual(layout.result, .made(savedMs: 2_000))
        XCTAssertEqual(layout.durationMs, 5_000)
        XCTAssertEqual(layout.placements.map(\.outputStartMs), [0, 1_000, 2_500])
        let exported = try await durationMs(SpokenNoteCleanFiles.audioURL(inNoteFolder: folder))
        XCTAssertEqual(exported, layout.durationMs, accuracy: 30, "audio length, within 30 ms of the map's total")
        XCTAssertEqual(try [a.1, b.1].map { try Data(contentsOf: $0) }, before, "the takes are read, never changed")
        XCTAssertEqual(SpokenNoteCleanFiles.readLayout(inNoteFolder: folder), layout)
    }

    func testASecondRunWithTheSameCutsWritesNothing() async throws {
        let a = try take("a", seconds: 3, seed: 1)
        let cutA = cut(durationMs: 3_000, kept: [(0, 1_000), (2_000, 3_000)])
        let renderer = SpokenNoteCleanRenderer()
        _ = try await renderer.render(takes: [renderTake(a, cutA)], noteFolder: folder)
        let audio = SpokenNoteCleanFiles.audioURL(inNoteFolder: folder)
        let firstDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: audio.path)[.modificationDate] as? Date)
        let firstBytes = try Data(contentsOf: audio)

        _ = try await renderer.render(takes: [renderTake(a, cutA)], noteFolder: folder)

        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: audio.path)[.modificationDate] as? Date, firstDate)
        XCTAssertEqual(try Data(contentsOf: audio), firstBytes)
    }

    func testNothingToCutWritesNoAudio() async throws {
        let a = try take("a", seconds: 2, seed: 1)
        let layout = try await SpokenNoteCleanRenderer().render(takes: [renderTake(a, cut(durationMs: 2_000, kept: [(0, 2_000)]))], noteFolder: folder)
        XCTAssertEqual(layout.result, .nothingToRemove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpokenNoteCleanFiles.audioURL(inNoteFolder: folder).path))
    }

    func testAFullPhoneSaysNoSpaceAndWritesNoAudio() async throws {
        let a = try take("a", seconds: 3, seed: 1)
        let renderer = SpokenNoteCleanRenderer(capacity: { _ in 10 })
        let layout = try await renderer.render(takes: [renderTake(a, cut(durationMs: 3_000, kept: [(0, 1_000), (2_000, 3_000)]))], noteFolder: folder)
        XCTAssertEqual(layout.result, .failed(.noSpace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpokenNoteCleanFiles.audioURL(inNoteFolder: folder).path))
    }

    func testCancellingLeavesNoTemporaryFile() async throws {
        let a = try take("a", seconds: 30, seed: 1)
        let kept = stride(from: 0, to: 30_000, by: 1_000).map { ($0, $0 + 600) }
        let takes = [renderTake(a, cut(durationMs: 30_000, kept: kept))]
        let noteFolder: URL = folder
        let task = Task { try await SpokenNoteCleanRenderer().render(takes: takes, noteFolder: noteFolder) }
        task.cancel()
        _ = try? await task.value
        let names = (try? FileManager.default.contentsOfDirectory(atPath: SpokenNoteCleanFiles.folder(inNoteFolder: folder).path)) ?? []
        XCTAssertFalse(names.contains { $0.hasPrefix(SpokenNoteCleanRenderer.temporaryPrefix) }, "\(names)")
    }

    // MARK: Pipeline

    /// Takes the takes' own quiet flags: a 4 s take, loud for its first and last second, quiet in between.
    private let flags: @Sendable (URL) throws -> SpokenNoteSilentFlags.Result = { _ in
        SpokenNoteSilentFlags.Result(flags: (0..<200).map { $0 >= 50 && $0 < 150 }, durationMs: 4_000)
    }

    func testThePipelineShortensTheLongPauseAndReusesTheSavedCut() async throws {
        let a = try take("a", seconds: 4, seed: 1)
        let pipeline = SpokenNoteCleanPipeline(silentFlags: flags)
        let layout = try await pipeline.run(requested: [a.0], noteFolder: folder)
        XCTAssertEqual(layout.result.savedMs, 1_500, "a 2 s pause keeps 500 ms")
        XCTAssertNotNil(SpokenNoteCleanFiles.read(SpokenNoteCutFile.self, from: SpokenNoteCleanFiles.cutURL(takeId: "a", inNoteFolder: folder)))

        let again = SpokenNoteCleanPipeline(silentFlags: { _ in XCTFail("the saved cut is reused"); throw CancellationError() })
        let second = try await again.run(requested: [a.0], noteFolder: folder)
        XCTAssertEqual(second, layout)
    }

    // MARK: Without ums (#5342)

    private struct FakeTranscriber: SpokenNoteTranscribing {
        let segments: [AlignedTranscriptSegment]?
        func transcribe(fileAt url: URL) async throws -> [AlignedTranscriptSegment] {
            guard let segments else { throw SessionKitError.persistenceFailed("speech_recognizer_unavailable") }
            return segments
        }
    }

    func testWithoutUmsCutsTheFillerAndThePauseIntoItsOwnFolder() async throws {
        let a = try take("a", seconds: 4, seed: 2)
        let words = [
            AlignedTranscriptSegment(id: "s1", text: "So", startMs: 0, endMs: 500),
            AlignedTranscriptSegment(id: "s2", text: "um", startMs: 600, endMs: 900),
            AlignedTranscriptSegment(id: "s3", text: "fine.", startMs: 3_000, endMs: 4_000),
        ]
        let pipeline = SpokenNoteCleanPipeline(silentFlags: flags, transcriber: FakeTranscriber(segments: words))
        let layout = try await pipeline.run(requested: [a.0], noteFolder: folder, version: .withoutUms)
        let saved = try XCTUnwrap(SpokenNoteCleanFiles.read(
            SpokenNoteCutFile.self, from: SpokenNoteCleanFiles.cutURL(takeId: "a", inNoteFolder: folder, version: .withoutUms)))
        XCTAssertEqual(saved.cut.fillersRemoved, 1)
        XCTAssertEqual(saved.cut.pausesShortened, 1)
        XCTAssertEqual(saved.cut.removedMs, 380 + 1_500, "the um with the Margins cleanup's padding, and the 2 s pause down to 500 ms")
        XCTAssertTrue(layout.result.hasAudio)
        XCTAssertEqual(SpokenNoteCleanFiles.readLayout(inNoteFolder: folder, version: .withoutUms), layout)
        XCTAssertNil(SpokenNoteCleanFiles.readLayout(inNoteFolder: folder), "Shorter pauses is not made by it")
    }

    func testWithoutUmsFailsWhenNoTakeCanBeTranscribed() async throws {
        let a = try take("a", seconds: 4, seed: 3)
        let pipeline = SpokenNoteCleanPipeline(silentFlags: flags, transcriber: FakeTranscriber(segments: nil))
        do {
            _ = try await pipeline.run(requested: [a.0], noteFolder: folder, version: .withoutUms)
            XCTFail("no take was transcribed, so there is no Without ums version")
        } catch {}
        XCTAssertNil(SpokenNoteCleanFiles.readLayout(inNoteFolder: folder, version: .withoutUms))
    }
}
#endif
