import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #2100: scene summaries were rendered on the main thread, which spun a nested run loop for the length of
/// each render. A render now runs on a background queue, and the main thread refuses to start one.
final class SystemTextAudioMainThreadTests: XCTestCase {
    #if canImport(AVFoundation)
    func testSynchronousRenderOnTheMainThreadThrowsInsteadOfSpinningTheRunLoop() throws {
        XCTAssertTrue(Thread.isMainThread, "XCTest runs this synchronous test on the main thread")
        let directory = FileManager.default.temporaryDirectory.appending(path: "system-text-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = SystemTextAudioPreparationClient(outputDirectory: directory)

        XCTAssertThrowsError(try client.prepareTextAudio(itemId: "main-thread", title: "Summary", text: "A short scene summary.")) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed("system_speech_render_on_main_thread"))
        }
    }

    @MainActor
    func testRenderWorkAwaitedFromTheMainActorRunsOffTheMainThread() async throws {
        XCTAssertTrue(Thread.isMainThread, "the caller starts on the main actor")

        let workRanOnMain = try await SystemTextAudioPreparationClient.runOffMainThread { Thread.isMainThread }
        XCTAssertFalse(workRanOnMain)
    }

    func testRenderWorkErrorsReachTheCaller() async {
        struct Boom: Error, Equatable {}
        do {
            _ = try await SystemTextAudioPreparationClient.runOffMainThread { () throws -> Int in throw Boom() }
            XCTFail("expected the work's error")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
    }
    #endif
}
