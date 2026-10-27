import Foundation
import XCTest
@testable import SessionKitSupertonic

/// The rendered-speech disk cache, moved from the app target so it is tested on the host (#318). The
/// audio check in `cachedAudio` reads the file with AVFoundation, so these run on the Mac only.
final class RenderedSpeechDiskCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "rendered-speech-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var cacheDirectory: URL { root.appending(path: "cache", directoryHint: .isDirectory) }

    /// A file of `byteCount` bytes standing in for a render; the cache copies it without reading it.
    private func rendered(_ name: String = "render.wav", byteCount: Int = 100) throws -> SupertonicNarrationResult {
        let url = root.appending(path: name)
        try Data(repeating: 7, count: byteCount).write(to: url)
        return SupertonicNarrationResult(
            audioURL: url, duration: 1.5, sampleRate: 44_100, renderDuration: 0.4, sessionLoadCount: 2,
            engine: SupertonicNarrationResult.systemVoiceEngine, trimmedSilence: 0.25
        )
    }

    @discardableResult
    private func store(
        _ cache: RenderedSpeechDiskCache, _ result: SupertonicNarrationResult, text: String = "one",
        voice: SupertonicVoiceID = .m2, language: String = "en", speed: Float = 1, steps: Int = 8
    ) throws -> SupertonicNarrationResult {
        try cache.store(result, text: text, voice: voice, language: language, speed: speed, synthesisSteps: steps)
    }

    private func age(_ url: URL, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path)
    }

    private func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// A 16-bit mono WAV of silence, so AVFoundation reads it back with a known length.
    private func wav(sampleRate: Int = 8_000, frames: Int) -> Data {
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) } }
        func le16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8((value >> ($0 * 8)) & 0xff) } }
        let dataBytes = frames * 2
        var bytes = Array("RIFF".utf8) + le32(36 + dataBytes) + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16)
        bytes += Array("data".utf8) + le32(dataBytes)
        return Data(bytes) + Data(count: dataBytes)
    }

    func testStoreCopiesTheRenderIntoTheCacheAndKeepsItsMetadata() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)
        let source = try rendered()

        let stored = try store(cache, source)

        XCTAssertTrue(cache.owns(stored.audioURL))
        XCTAssertNotEqual(stored.audioURL, source.audioURL)
        XCTAssertEqual(stored.audioURL.pathExtension, "wav")
        XCTAssertEqual(stored.audioURL.deletingPathExtension().lastPathComponent.count, 64, "a SHA-256 digest names the file")
        XCTAssertEqual(try Data(contentsOf: stored.audioURL), try Data(contentsOf: source.audioURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.audioURL.path), "the render it copied from is left alone")
        XCTAssertEqual(stored.duration, 1.5)
        XCTAssertEqual(stored.sampleRate, 44_100)
        XCTAssertEqual(stored.renderDuration, 0.4)
        XCTAssertEqual(stored.sessionLoadCount, 2)
        XCTAssertEqual(stored.trimmedSilence, 0.25)
        XCTAssertEqual(cache.sizeBytes, 100)
    }

    func testEveryPartOfTheRequestChangesTheFileAndTheSameRequestFindsTheSameFile() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)
        let source = try rendered(byteCount: 10)

        let base = try store(cache, source).audioURL
        let again = try store(cache, source).audioURL
        let variants = try [
            store(cache, source, text: "one "),
            store(cache, source, text: "One"),
            store(cache, source, voice: .f1),
            store(cache, source, language: "fr"),
            store(cache, source, speed: 1.25),
            store(cache, source, steps: 12),
        ].map(\.audioURL)

        XCTAssertEqual(again, base)
        XCTAssertEqual(Set(variants + [base]).count, 7, "each variation is its own file")
        XCTAssertEqual(try files(in: cacheDirectory).count, 7)
    }

    func testStoringPastTheLimitDropsTheLeastRecentlyUsedFilesAndKeepsTheNewOne() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 250)
        let source = try rendered(byteCount: 100)
        let oldest = try store(cache, source, text: "a")
        let middle = try store(cache, source, text: "b")
        try age(oldest.audioURL, secondsAgo: 300)
        try age(middle.audioURL, secondsAgo: 200)

        let newest = try store(cache, source, text: "c")

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.audioURL.path))
        XCTAssertEqual(cache.sizeBytes, 200)
    }

    func testAFileLargerThanTheWholeLimitIsStillKeptWhileItIsTheOneJustStored() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 50)
        let small = try store(cache, try rendered("small.wav", byteCount: 40), text: "small")
        try age(small.audioURL, secondsAgo: 60)

        let big = try store(cache, try rendered("big.wav", byteCount: 500), text: "big")

        XCTAssertFalse(FileManager.default.fileExists(atPath: small.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.audioURL.path), "the file just stored is protected")
    }

    func testAPlayedFileIsRefreshedSoItOutlivesOlderOnes() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 250)
        let source = try rendered(byteCount: 100)
        let stale = try store(cache, source, text: "stale")
        let played = try store(cache, source, text: "played")
        try age(stale.audioURL, secondsAgo: 200)
        try age(played.audioURL, secondsAgo: 300)
        // Storing the same request again counts as a use and moves it to the front.
        _ = try store(cache, source, text: "played")

        _ = try store(cache, source, text: "fresh")

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: played.audioURL.path))
    }

    func testLoweringTheLimitEvictsOldestFirstAndAZeroLimitStillKeepsOneByte() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 1_000)
        let source = try rendered(byteCount: 100)
        let older = try store(cache, source, text: "older")
        let newer = try store(cache, source, text: "newer")
        try age(older.audioURL, secondsAgo: 100)

        cache.setLimitBytes(150)

        XCTAssertFalse(FileManager.default.fileExists(atPath: older.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.audioURL.path))

        cache.setLimitBytes(0)
        XCTAssertEqual(cache.sizeBytes, 0, "the limit is clamped to 1 byte, which no 100-byte file fits under")
    }

    func testRemoveAllClearsTheWavFilesReportsTheBytesAndLeavesOtherFiles() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)
        let source = try rendered(byteCount: 30)
        try store(cache, source, text: "a")
        try store(cache, source, text: "b")
        let bystander = cacheDirectory.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: bystander)

        XCTAssertEqual(cache.removeAll(), 60)

        XCTAssertEqual(cache.sizeBytes, 0)
        XCTAssertEqual(try files(in: cacheDirectory), ["notes.txt"])
    }

    func testRemoveAllInADirectoryNoCacheHasOpenCountsTheSameBytes() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5).write(to: cacheDirectory.appending(path: "a.wav"))
        try Data(repeating: 1, count: 7).write(to: cacheDirectory.appending(path: "B.WAV"))

        XCTAssertEqual(RenderedSpeechDiskCache.removeAll(in: cacheDirectory), 12)
        XCTAssertEqual(try files(in: cacheDirectory), [])
        XCTAssertEqual(RenderedSpeechDiskCache.removeAll(in: root.appending(path: "missing")), 0)
    }

    func testOwnsOnlyFilesDirectlyInsideTheCacheDirectoryAndInvalidateOnlyDeletesThose() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)
        let stored = try store(cache, try rendered())
        let outside = try rendered("outside.wav").audioURL
        let nested = cacheDirectory.appending(path: "sub", directoryHint: .isDirectory).appending(path: "x.wav")

        XCTAssertTrue(cache.owns(stored.audioURL))
        XCTAssertTrue(cache.owns(cacheDirectory.appending(path: "../cache/x.wav")), "a path that resolves into the directory")
        XCTAssertFalse(cache.owns(outside))
        XCTAssertFalse(cache.owns(nested))

        cache.invalidate(outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a file the cache doesn't own is never deleted")
        cache.invalidate(stored.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.audioURL.path))
    }

    func testANewCacheOverTheSameDirectoryFindsWhatTheLastOneStored() throws {
        let first = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)
        try store(first, try rendered(byteCount: 64))

        let second = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)

        XCTAssertEqual(second.sizeBytes, 64)
    }

    func testOpeningACacheOverItsLimitTrimsItAtOnce() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let old = cacheDirectory.appending(path: "old.wav")
        let recent = cacheDirectory.appending(path: "recent.wav")
        try Data(repeating: 1, count: 100).write(to: old)
        try Data(repeating: 1, count: 100).write(to: recent)
        try age(old, secondsAgo: 500)

        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 150)

        XCTAssertEqual(try files(in: cacheDirectory), ["recent.wav"])
        XCTAssertEqual(cache.sizeBytes, 100)
    }

    func testOpeningWithoutTrimLeavesTheListingToTheCallersSetLimit() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let old = cacheDirectory.appending(path: "old.wav")
        let recent = cacheDirectory.appending(path: "recent.wav")
        try Data(repeating: 1, count: 100).write(to: old)
        try Data(repeating: 1, count: 100).write(to: recent)
        try age(old, secondsAgo: 500)

        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 150, trimsOnInit: false)
        XCTAssertEqual(try files(in: cacheDirectory), ["old.wav", "recent.wav"], "opening lists nothing and trims nothing")

        cache.setLimitBytes(150)

        XCTAssertEqual(try files(in: cacheDirectory), ["recent.wav"])
    }

    func testCachedAudioMissesWhenNothingWasStoredAndTheMissLeavesNoFile() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)

        XCTAssertNil(cache.cachedAudio(text: "none", voice: .m2, language: "en", speed: 1, synthesisSteps: 8))
        XCTAssertEqual(try files(in: cacheDirectory), [])
    }

    func testCachedAudioThrowsAwayAFileThatIsNotAudio() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)
        let stored = try store(cache, try rendered(byteCount: 100))

        let hit = cache.cachedAudio(text: "one", voice: .m2, language: "en", speed: 1, synthesisSteps: 8)

        XCTAssertNil(hit, "100 bytes of 0x07 is not a WAV")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.audioURL.path), "so it is deleted and rendered again")
    }

    func testCachedAudioReadsTheLengthFromTheFileAndCountsAsAUse() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)
        let source = root.appending(path: "real.wav")
        try wav(sampleRate: 8_000, frames: 4_000).write(to: source)
        let stored = try store(cache, SupertonicNarrationResult(
            audioURL: source, duration: 99, sampleRate: 1, renderDuration: 5, sessionLoadCount: 3,
            engine: SupertonicNarrationResult.supertonicEngine))
        try age(stored.audioURL, secondsAgo: 1_000)

        let hit = try XCTUnwrap(cache.cachedAudio(text: "one", voice: .m2, language: "en", speed: 1, synthesisSteps: 8))

        XCTAssertEqual(hit.audioURL, stored.audioURL)
        XCTAssertEqual(hit.duration, 0.5, accuracy: 0.001, "the duration comes from the file, not from what was stored")
        XCTAssertEqual(hit.sampleRate, 8_000)
        XCTAssertEqual(hit.renderDuration, 0, "a hit rendered nothing")
        XCTAssertEqual(hit.sessionLoadCount, 0)
        let modified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: stored.audioURL.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(modified.timeIntervalSinceNow, -60, "a hit refreshes the file's age")
    }

    func testCachedAudioMissesOnAnEmptyAudioFile() throws {
        let cache = try RenderedSpeechDiskCache(directory: cacheDirectory, limitBytes: 10_000)
        let source = root.appending(path: "empty.wav")
        try wav(frames: 0).write(to: source)
        try store(cache, SupertonicNarrationResult(
            audioURL: source, duration: 0, sampleRate: 8_000, renderDuration: 0, sessionLoadCount: 0,
            engine: SupertonicNarrationResult.supertonicEngine))

        XCTAssertNil(cache.cachedAudio(text: "one", voice: .m2, language: "en", speed: 1, synthesisSteps: 8))
    }
}
