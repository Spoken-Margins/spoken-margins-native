#if canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest
import SessionKit
@testable import SessionKitAudio

/// #467 through real files: a podcast file and Margin recordings written with AVFoundation, measured
/// and leveled by `LeveledMarginCache`, the way the Margin players ask for them.
final class LeveledMarginCacheTests: XCTestCase {
    private var folder: URL!
    private var cacheFolder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("leveled-margins-\(UUID().uuidString)")
        cacheFolder = folder.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func recording(named name: String, seed: UInt64, lufs: Double?, aac: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try MarginLoudnessLevelerTests.write([MarginLoudnessLevelerTests.speechLike(seed: seed, lufs: lufs)], to: url, aac: aac)
        return url
    }

    private func cachedCopies() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "caf" }
    }

    func testAWhisperedMarginPlaysAboutAsLoudAsThePodcastAroundIt() async throws {
        let podcast = try recording(named: "episode.wav", seed: 1, lufs: -20)
        // 20 dB under the episode, as quiet as the owner's whispered Margins.
        let margin = try recording(named: "whisper.wav", seed: 2, lufs: -40)
        let before = try MarginLoudnessLevelerTests.hash(margin)
        let cache = LeveledMarginCache(directory: cacheFolder)
        XCTAssertNil(cache.readyCopy(for: margin), "nothing is made until it is asked for")

        let outcome = await cache.level(margin, sourceWindow: .init(file: podcast, anchorMediaTimeMs: 2_000))

        guard case .leveled(let copy) = outcome else { return XCTFail("expected a leveled copy, got \(outcome)") }
        XCTAssertEqual(try MarginLoudnessLevelerTests.hash(margin), before, "the recording is byte-for-byte unchanged")
        let source = try MarginLoudnessLeveler.measure(fileAt: podcast, startMs: 0, durationMs: 5_000)
        let played = try MarginLoudnessLeveler.measure(fileAt: copy)
        // The boost stops at 18 dB, so a Margin 20 dB under lands 2 LU under the episode.
        XCTAssertEqual(try XCTUnwrap(played.integratedLUFS), try XCTUnwrap(source.integratedLUFS), accuracy: 2.5)
        XCTAssertGreaterThan(try XCTUnwrap(played.integratedLUFS), -40 + 15, "the whisper was turned up")
        XCTAssertLessThanOrEqual(played.truePeakDBTP, LoudnessLeveling.truePeakCeilingDBTP, "and does not clip")
        XCTAssertEqual(cache.readyCopy(for: margin), copy, "the players find the copy afterwards")
        XCTAssertEqual(copy.deletingLastPathComponent().lastPathComponent, "cache", "the copy lives in the cache folder, not beside the recording")
    }

    func testAMarginOnAnEpisodeThatIsNotOnTheDevicePlaysAtThePodcastLevel() async throws {
        let margin = try recording(named: "article-margin.wav", seed: 3, lufs: -30)
        let cache = LeveledMarginCache(directory: cacheFolder)

        let outcome = await cache.level(margin)

        guard case .leveled(let copy) = outcome else { return XCTFail("expected a leveled copy, got \(outcome)") }
        let played = try MarginLoudnessLeveler.measure(fileAt: copy)
        XCTAssertEqual(try XCTUnwrap(played.integratedLUFS), MarginLevelingTarget.fixedLUFS, accuracy: 1.5)
        XCTAssertLessThanOrEqual(played.truePeakDBTP, LoudnessLeveling.truePeakCeilingDBTP)
    }

    func testALoudMarginIsTurnedDownToTheEpisode() async throws {
        let podcast = try recording(named: "quiet-episode.wav", seed: 4, lufs: -26)
        let margin = try recording(named: "shout.m4a", seed: 5, lufs: -10, aac: true)
        let cache = LeveledMarginCache(directory: cacheFolder)

        let outcome = await cache.level(margin, sourceWindow: .init(file: podcast, anchorMediaTimeMs: 1_000))

        guard case .leveled(let copy) = outcome else { return XCTFail("expected a leveled copy, got \(outcome)") }
        let played = try MarginLoudnessLeveler.measure(fileAt: copy)
        XCTAssertEqual(try XCTUnwrap(played.integratedLUFS), -26, accuracy: 2)
        XCTAssertLessThanOrEqual(played.truePeakDBTP, LoudnessLeveling.truePeakCeilingDBTP)
    }

    func testAnEpisodeThatCannotBeMeasuredFallsBackToThePodcastLevel() async throws {
        let notAudio = folder.appendingPathComponent("episode.mp3")
        try Data(repeating: 7, count: 2_000).write(to: notAudio)
        let margin = try recording(named: "margin.wav", seed: 6, lufs: -30)
        let cache = LeveledMarginCache(directory: cacheFolder)

        let outcome = await cache.level(margin, sourceWindow: .init(file: notAudio, anchorMediaTimeMs: 1_000))

        guard case .leveled(let copy) = outcome else { return XCTFail("expected a leveled copy, got \(outcome)") }
        let played = try MarginLoudnessLeveler.measure(fileAt: copy)
        XCTAssertEqual(try XCTUnwrap(played.integratedLUFS), MarginLevelingTarget.fixedLUFS, accuracy: 1.5)
    }

    func testTheSameRecordingIsLeveledOnceWhateverItsPath() async throws {
        let first = try recording(named: "margin.wav", seed: 7, lufs: -30)
        let moved = folder.appendingPathComponent("other-container").appendingPathComponent("margin-copy.wav")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first, to: moved)
        let cache = LeveledMarginCache(directory: cacheFolder)

        let one = await cache.level(first)
        let two = await cache.level(moved)

        XCTAssertEqual(one, two)
        XCTAssertEqual(cachedCopies().count, 1)
        XCTAssertEqual(cache.readyCopy(for: moved), cache.readyCopy(for: first))
    }

    func testAskingTwiceAtOnceSharesOneRender() async throws {
        let margin = try recording(named: "margin.wav", seed: 8, lufs: -30)
        let cache = LeveledMarginCache(directory: cacheFolder)

        async let one = cache.level(margin)
        async let two = cache.level(margin)
        let outcomes = await [one, two]

        XCTAssertEqual(outcomes[0], outcomes[1])
        XCTAssertEqual(cachedCopies().count, 1)
    }

    func testARecordingThatWillNotDecodePlaysAsItIs() async throws {
        let broken = folder.appendingPathComponent("broken.m4a")
        try Data(repeating: 9, count: 3_000).write(to: broken)
        let cache = LeveledMarginCache(directory: cacheFolder)

        let outcome = await cache.level(broken)

        guard case .original(let reason) = outcome else { return XCTFail("expected the original, got \(outcome)") }
        XCTAssertTrue(reason.hasPrefix("failed_"), reason)
        XCTAssertFalse(reason.contains(folder.path), "a diagnostics reason never carries a path")
        XCTAssertNil(cache.readyCopy(for: broken))
        XCTAssertTrue(cachedCopies().isEmpty)
        XCTAssertEqual(outcome.diagnosticValue, "original:\(reason)")
    }

    func testAMissingRecordingPlaysAsItIs() async throws {
        let cache = LeveledMarginCache(directory: cacheFolder)
        let outcome = await cache.level(folder.appendingPathComponent("gone.wav"))
        guard case .original = outcome else { return XCTFail("expected the original, got \(outcome)") }
        XCTAssertNil(cache.readyCopy(for: folder.appendingPathComponent("gone.wav")))
    }

    func testASilentRecordingIsNotCopied() async throws {
        let silent = folder.appendingPathComponent("silence.wav")
        try MarginLoudnessLevelerTests.write([[Float](repeating: 0, count: 48_000)], to: silent, aac: false)
        let cache = LeveledMarginCache(directory: cacheFolder)

        let outcome = await cache.level(silent)

        XCTAssertEqual(outcome, .original(reason: "silent"))
        XCTAssertTrue(cachedCopies().isEmpty)
    }

    func testTheOldestCopiesGoFirstWhenTheFolderIsFull() async throws {
        // Each copy of a 5 s mono 48 kHz Margin is about 960 KB; 1.5 MB holds one.
        let cache = LeveledMarginCache(directory: cacheFolder, maximumBytes: 1_500_000)
        var copies: [URL] = []
        for seed in 20..<23 {
            let margin = try recording(named: "margin-\(seed).wav", seed: UInt64(seed), lufs: -30)
            guard case .leveled(let copy) = await cache.level(margin) else { return XCTFail("expected a leveled copy") }
            copies.append(copy)
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(cachedCopies().map(\.lastPathComponent), [copies[2].lastPathComponent], "the newest copy is kept and the older ones are gone")
    }

    func testAMarginOutsideTheFolderCapIsStillMadeWhenItIsTheOnlyOne() async throws {
        let cache = LeveledMarginCache(directory: cacheFolder, maximumBytes: 10)
        let margin = try recording(named: "margin.wav", seed: 30, lufs: -30)
        guard case .leveled(let copy) = await cache.level(margin) else { return XCTFail("expected a leveled copy") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the copy just made is never the one evicted")
    }
}
#endif
