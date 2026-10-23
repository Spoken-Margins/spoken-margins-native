#if os(macOS) && canImport(AVFoundation) && canImport(ShazamKit)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKitAudio
import SessionKitTestInputs
import ShazamKit

final class PodcastAssetSignatureGeneratorTests: XCTestCase {
    func testCancelledRequestDoesNotStartSignatureGeneration() async throws {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PodcastAssetSignatureGenerator.signature(
                from: AVURLAsset(url: URL(fileURLWithPath: "/missing-cancelled-episode.mp3"))
            ).duration
        }
        do {
            _ = try await task.value
            XCTFail("cancelled signature request completed")
        } catch is CancellationError {
            // Cancellation must win before the SDK attempts to open the missing file.
        }
    }

    func testUnreadableAudioReleasesTheSlotForTheNextSignature() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "signature-errors-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appending(path: "invalid.m4a")
        try Data("unreadable audio".utf8).write(to: invalid)
        let valid = directory.appending(path: "valid.m4a")
        try SeededNoiseAudio.write(to: valid, seconds: 3)
        try requirePlainSignature(of: valid)
        let results = SignatureResults()
        let completed = DispatchGroup()
        completed.enter()
        Task.detached {
            defer { completed.leave() }
            do {
                let signature = try await PodcastAssetSignatureGenerator.signature(from: AVURLAsset(url: invalid))
                results.record(duration: signature.duration)
            } catch {
                results.record(error: error)
            }
            do {
                let signature = try await PodcastAssetSignatureGenerator.signature(from: AVURLAsset(url: valid))
                results.record(duration: signature.duration)
            } catch {
                results.record(error: error)
            }
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(results.errors.count, 1)
        XCTAssertEqual(results.durations.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(results.durations.first), 2.9)
    }

    func testSignatureJobsLeaveTheCooperativePoolAvailable() throws {
        let episode: URL
        if let realEpisode = ProcessInfo.processInfo.environment["SM_SIGNATURE_TEST_AUDIO"] {
            episode = URL(fileURLWithPath: realEpisode)
        } else {
            episode = try TestInputs.url(.contracts, "fixtures/audio/evidence-length-48k-stereo.mp3")
        }
        let plainSeconds = try requirePlainSignature(
            of: TestInputs.url(.contracts, "fixtures/audio/evidence-length-48k-stereo.mp3")
        )

        let poolThreads = ProcessInfo.processInfo.activeProcessorCount
        // Each job signs a 40 s composition, the resolver's probe chunk length. The starvation this guards
        // against (#869) is a deadlock: once every cooperative worker is inside ShazamKit, none finishes,
        // whatever the length. With the fix, signatures run one at a time, so the test costs jobs x length of audio
        // decoded on one core; 900 s chunks took 12-58 s and timed out under load (#1283).
        let jobSeconds = 40.0
        let entered = DispatchGroup()
        for _ in 0..<poolThreads { entered.enter() }
        let completed = DispatchGroup()
        let results = SignatureResults()
        let tasks = (0..<(poolThreads + 2)).map { index in
            completed.enter()
            return Task.detached {
                defer { completed.leave() }
                if index < poolThreads { entered.leave() }
                do {
                    let source = AVURLAsset(url: episode)
                    defer { withExtendedLifetime(source) {} }
                    let sourceDuration = try await source.load(.duration)
                    guard sourceDuration > .zero else { throw PodcastAnchorEvidenceError.invalidSourceDuration }
                    let tracks = try await source.loadTracks(withMediaType: .audio)
                    let sourceTrack = try XCTUnwrap(tracks.first)
                    // Placement and source-window jobs sign compositions, rather than the enclosure itself.
                    let composition = AVMutableComposition()
                    let track = try XCTUnwrap(composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                    ))
                    let targetDuration = CMTime(seconds: jobSeconds, preferredTimescale: 1_000)
                    var position = CMTime.zero
                    while position < targetDuration {
                        let length = CMTimeMinimum(sourceDuration, CMTimeSubtract(targetDuration, position))
                        try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: sourceTrack, at: position)
                        position = CMTimeAdd(position, length)
                    }
                    results.recordStarted()
                    let signature = try await PodcastAssetSignatureGenerator.signature(from: composition)
                    results.record(duration: signature.duration)
                } catch {
                    results.record(error: error)
                }
            }
        }
        defer { tasks.forEach { $0.cancel() } }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success, "signature tasks did not start")

        // Observe from outside the cooperative pool: a timeout task on that pool would stall with the bug.
        let probing = DispatchGroup()
        probing.enter()
        DispatchQueue(label: "signature-test-heartbeat").async {
            defer { probing.leave() }
            repeat {
                let heartbeat = DispatchGroup()
                heartbeat.enter()
                let started = Date()
                Task.detached { heartbeat.leave() }
                let result = heartbeat.wait(timeout: .now() + 1)
                results.record(heartbeatDelay: Date().timeIntervalSince(started))
                if result == .timedOut { break }
                Thread.sleep(forTimeInterval: 0.02)
            } while completed.wait(timeout: .now()) != .success
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 60), .success, "signature jobs did not finish (one plain signature took \(plainSeconds) s)")
        XCTAssertEqual(probing.wait(timeout: .now() + 2), .success)
        XCTAssertLessThan(try XCTUnwrap(results.heartbeatDelays.max()), 1, "ShazamKit signature jobs starved unrelated async work")
        XCTAssertEqual(results.durations.count, poolThreads + 2, results.errors.joined(separator: "; "))
        XCTAssertTrue(results.durations.allSatisfy { abs($0 - jobSeconds) < 1 }, "\(results.durations)")
        print("Signature stress: \(poolThreads + 2) real jobs, started \(results.started), heartbeat max \(results.heartbeatDelays.max() ?? -1) s, plain probe \(plainSeconds) s, completed \(results.durations.count)")
    }

    /// An environment precondition, not the claim under test. On 10-18 the Mac's signature service wedged: 0 of 10 jobs
    /// finished in 60 s with no code change (#2385). This signs one file with ShazamKit directly, on its own queue and
    /// never through the generator or the cooperative pool, so a generator that starves the pool or leaks a slot cannot
    /// make it skip. When the service itself can't sign one file in time, the test skips with an environment message;
    /// verify-tests.py fails the step on an unexpected skip, naming the test, so a skip that keeps happening is seen.
    @discardableResult
    private func requirePlainSignature(of url: URL, within limit: TimeInterval = 15) throws -> TimeInterval {
        let done = DispatchSemaphore(value: 0)
        let asset = AVURLAsset(url: url)
        let started = Date()
        DispatchQueue(label: "signature-test-environment-probe").async {
            SHSignatureGenerator.generateSignature(from: asset) { _, _ in done.signal() }
        }
        guard done.wait(timeout: .now() + limit) == .success else {
            throw XCTSkip("signature service did not finish one plain signature in \(Int(limit)) s: environment, not the generator")
        }
        return Date().timeIntervalSince(started)
    }
}

private final class SignatureResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDurations: [TimeInterval] = []
    private var storedErrors: [String] = []
    private var storedHeartbeatDelays: [TimeInterval] = []
    private var storedStarted = 0

    var durations: [TimeInterval] { lock.withLock { storedDurations } }
    var errors: [String] { lock.withLock { storedErrors } }
    var heartbeatDelays: [TimeInterval] { lock.withLock { storedHeartbeatDelays } }
    var started: Int { lock.withLock { storedStarted } }
    func record(duration: TimeInterval) { lock.withLock { storedDurations.append(duration) } }
    func record(error: Error) { lock.withLock { storedErrors.append(error.localizedDescription) } }
    func record(heartbeatDelay: TimeInterval) { lock.withLock { storedHeartbeatDelays.append(heartbeatDelay) } }
    func recordStarted() { lock.withLock { storedStarted += 1 } }
}
#endif
