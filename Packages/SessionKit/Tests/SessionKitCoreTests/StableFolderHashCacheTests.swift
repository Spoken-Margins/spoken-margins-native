import Foundation
import SessionKit
import XCTest

/// #2055 audit 4: a downloaded voice's model files are hashed once per install, not on every preparation turn,
/// and an install or remove makes the next call hash them again. Real folders; the hash is counted, not faked.
final class StableFolderHashCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stable-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func counting(_ cache: StableFolderHashCache, _ folder: URL, _ calls: inout Int) -> String {
        cache.value(at: folder) {
            calls += 1
            return "hash-\(calls)"
        }
    }

    func testAFolderUnderAStableRootIsHashedOnceUntilItsVoiceChanges() {
        let voices = root.appendingPathComponent("Voices", isDirectory: true)
        let cache = StableFolderHashCache(stableRoots: [voices])
        let onnx = voices.appendingPathComponent("supertonic-3-int8/1/onnx", isDirectory: true)
        var calls = 0
        let first = counting(cache, onnx, &calls)
        XCTAssertEqual(counting(cache, onnx, &calls), first)
        XCTAssertEqual(counting(cache, URL(fileURLWithPath: onnx.path + "/"), &calls), first, "a trailing slash is the same folder")
        XCTAssertEqual(calls, 1, "every preparation turn after the first reuses the hash")

        cache.forget(under: voices)
        XCTAssertNotEqual(counting(cache, onnx, &calls), first)
        XCTAssertEqual(calls, 2, "after an install or remove the files are hashed again")
    }

    func testAnyOtherFolderIsHashedEveryTime() {
        let cache = StableFolderHashCache(stableRoots: [root.appendingPathComponent("Voices", isDirectory: true)])
        var calls = 0
        let lookalikes = [
            root.appendingPathComponent("Imports/onnx", isDirectory: true),
            root.appendingPathComponent("VoicesOld/onnx", isDirectory: true),  // shares the prefix, not the folder
            root.appendingPathComponent("Voices", isDirectory: true).deletingLastPathComponent(),
        ]
        for folder in lookalikes {
            _ = counting(cache, folder, &calls)
            _ = counting(cache, folder, &calls)
        }
        XCTAssertEqual(calls, lookalikes.count * 2)
    }

    func testForgettingOneRootLeavesTheOtherAlone() {
        let bundle = root.appendingPathComponent("App.app", isDirectory: true)
        let voices = root.appendingPathComponent("Voices", isDirectory: true)
        let cache = StableFolderHashCache(stableRoots: [bundle, voices])
        var calls = 0
        _ = counting(cache, bundle.appendingPathComponent("Supertonic/onnx"), &calls)
        _ = counting(cache, voices.appendingPathComponent("a/1/onnx"), &calls)
        cache.forget(under: voices)
        _ = counting(cache, bundle.appendingPathComponent("Supertonic/onnx"), &calls)
        _ = counting(cache, voices.appendingPathComponent("a/1/onnx"), &calls)
        XCTAssertEqual(calls, 3, "the bundle's hash outlives a voice being removed")
    }

    func testAHashComputedWhileTheVoiceWasRemovedIsNotKept() {
        let voices = root.appendingPathComponent("Voices", isDirectory: true)
        let cache = StableFolderHashCache(stableRoots: [voices])
        let onnx = voices.appendingPathComponent("a/1/onnx", isDirectory: true)
        _ = cache.value(at: onnx) {
            cache.forget(under: voices)  // Remove lands while the old files are being read
            return "stale"
        }
        XCTAssertEqual(cache.value(at: onnx) { "fresh" }, "fresh")
    }

    func testAFailedHashIsNotKept() {
        let voices = root.appendingPathComponent("Voices", isDirectory: true)
        let cache = StableFolderHashCache(stableRoots: [voices])
        let onnx = voices.appendingPathComponent("a/1/onnx", isDirectory: true)
        struct Missing: Error {}
        XCTAssertThrowsError(try cache.value(at: onnx) { throw Missing() })
        XCTAssertEqual(cache.value(at: onnx) { "after" }, "after")
    }
}
