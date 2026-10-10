#if os(macOS) && canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit)
import AVFoundation
import Foundation
import Network
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// Plays a real local file through the real `AVPlayer` client (muted), so the tap is exercised at the boundary
/// that broke on device instead of being fed buffers directly (#154).
final class RealPlayerPodcastEvidenceTests: XCTestCase {
    private final class Traces: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String: String]] = []
        func append(_ value: [String: String]) { lock.withLock { values.append(value) } }
        var all: [[String: String]] { lock.withLock { values } }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PostResumePodcastEvidenceCaptureResult] = []
        func append(_ value: PostResumePodcastEvidenceCaptureResult) { lock.withLock { values.append(value) } }
        var all: [PostResumePodcastEvidenceCaptureResult] { lock.withLock { values } }
    }

    func testContinuousTapInstallsOnceTracksLoadAndCapturesThePreWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "real-player-evidence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = try Self.writeTestEpisode(to: directory.appending(path: "episode.caf"), seconds: 16)
        try assertPreWindowCapture(playbackURL: audioURL, episodeFile: audioURL, sourceType: .nativeMediaFile)
    }

    func testContinuousTapCapturesThePreWindowFromAStreamedEpisode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "real-player-stream-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try Self.writeTestEpisode(to: directory.appending(path: "episode.caf"), seconds: 16)
        let server = try LoopbackAudioServer(data: Data(contentsOf: fileURL), contentType: "audio/x-caf")
        defer { server.stop() }
        let port = try XCTUnwrap(server.waitForPort())
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/episode.caf"))
        try assertPreWindowCapture(playbackURL: url, episodeFile: fileURL, sourceType: .remoteStream)
    }

    private func assertPreWindowCapture(playbackURL audioURL: URL, episodeFile: URL, sourceType: AudioSourceType) throws {
        let client = AVPlayerStreamPlaybackClient()
        try client.setPlaybackVolume(0)
        let results = Results()
        client.postResumePodcastEvidenceHandler = { results.append($0) }
        let traces = Traces()
        client.playbackStartTraceHandler = { traces.append($0) }
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "episode",
            targetType: .transcriptBackedMedia,
            targetId: "episode-target",
            title: "Test episode",
            playbackURL: audioURL.absoluteString,
            durationMs: 16_000,
            sourceType: sourceType
        ))
        defer { try? client.stop() }
        try client.play(targetId: "episode-target", fromMediaTimeMs: 0)

        XCTAssertTrue(spin(until: 5) { client.hasPodcastEvidenceTapOnCurrentItem },
                      "the continuous tap must install once the item's audio track loads")
        XCTAssertTrue(spin(until: 15) { (client.currentMediaTimeMs() ?? 0) >= 9_000 }, "playback did not advance")
        let trace = try XCTUnwrap(traces.all.first, "each media start records one timing trace (#160)")
        XCTAssertEqual(trace["stream"], sourceType == .remoteStream ? "1" : "0")
        XCTAssertEqual(trace["newItem"], "1")
        XCTAssertNotNil(trace["toPlayingMs"].flatMap(Int.init))

        let anchor = try XCTUnwrap(client.currentMediaTimeMs())
        let request = PostResumeAudioSampleRequest(
            interjectionId: "ij-001",
            sessionId: "session",
            itemId: "episode",
            anchorMediaTimeMs: anchor,
            targetDurationMs: 3_000
        )
        XCTAssertTrue(client.captureBufferedPreInterjectionAudioSample(request),
                      "the ring buffer should hold decoded audio from before the Margin")
        XCTAssertTrue(spin(until: 5) { !results.all.isEmpty })
        guard case .captured(let capture) = results.all.first(where: {
            if case .landmark = $0 { return false }
            return true
        }) else {
            return XCTFail("expected a captured pre-window signature, got \(results.all)")
        }
        XCTAssertEqual(capture.windowRole, .preInterjection)
        XCTAssertFalse(capture.signatureData.isEmpty)
        // The window is the 3 s that ended 5 s before the Margin, so it starts about 8 s before it (#1133, ANC-02).
        XCTAssertLessThanOrEqual(abs(capture.durationMs - 3_000), 250, "whole decoded buffers, so within a buffer or two; signature length \(capture.durationMs) ms")
        XCTAssertLessThanOrEqual(abs(capture.anchorOffsetMs - 8_000), 400, "anchor offset \(capture.anchorOffsetMs) ms")
        // The signature must be of the audio that played at those times: matched against the episode itself, it
        // places the Margin where the player's clock said it was.
        let query = PodcastPortableAnchorQuery(
            packageScopedId: "margin",
            senderMediaTimeMs: anchor,
            evidence: [PodcastAcousticEvidenceQuery(
                id: "ij-001-pre", signatureData: capture.signatureData, anchorOffsetMs: capture.anchorOffsetMs
            )]
        )
        let resolution = try resolveSynchronously(query: query, against: episodeFile)
        let placed = try XCTUnwrap(resolution?.localMediaTimeMs, "evidence class: \(String(describing: resolution?.evidenceClass))")
        XCTAssertLessThanOrEqual(abs(placed - anchor), 400, "Margin at \(anchor) ms placed at \(placed) ms")
    }

    /// The resolver is async, and these tests stay synchronous because they spin the main run loop for the
    /// player, so they wait for it on an expectation.
    private func resolveSynchronously(query: PodcastPortableAnchorQuery, against file: URL) throws -> ImportedAnchorResolution? {
        let box = ResolutionBox()
        let done = expectation(description: "resolved")
        Task.detached {
            do {
                let resolutions = try await PodcastAcousticAnchorResolver.resolve(
                    queries: [query], recipientAudioURL: file,
                    senderExactEditionSHA256: nil, senderDurationMs: 16_000, strongSourceIdentity: true
                )
                box.set(.success(resolutions[query.packageScopedId]))
            } catch {
                box.set(.failure(error))
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        return try XCTUnwrap(box.value).get()
    }

    private final class ResolutionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<ImportedAnchorResolution?, any Error>?
        func set(_ value: Result<ImportedAnchorResolution?, any Error>) { lock.withLock { stored = value } }
        var value: Result<ImportedAnchorResolution?, any Error>? { lock.withLock { stored } }
    }

    private final class HeardWindows: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [HeardAudioWindow] = []
        func append(_ value: HeardAudioWindow) { lock.withLock { values.append(value) } }
        var all: [HeardAudioWindow] { lock.withLock { values } }
    }

    /// #156: the source-context window for a streamed Margin comes from the audio the tap heard, before and after.
    func testTapKeepsTheHeardAudioAroundAStreamedMarginForTranscription() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "real-player-heard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try Self.writeTestEpisode(to: directory.appending(path: "episode.caf"), seconds: 16)
        let server = try LoopbackAudioServer(data: Data(contentsOf: fileURL), contentType: "audio/x-caf")
        defer { server.stop() }
        let port = try XCTUnwrap(server.waitForPort())
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/episode.caf"))

        let client = AVPlayerStreamPlaybackClient()
        try client.setPlaybackVolume(0)
        let heard = HeardWindows()
        client.heardSourceWindowHandler = { heard.append($0) }
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "episode", targetType: .transcriptBackedMedia, targetId: "episode-target",
            title: "Test episode", playbackURL: url.absoluteString, durationMs: 16_000, sourceType: .remoteStream
        ))
        try client.play(targetId: "episode-target", fromMediaTimeMs: 0)
        XCTAssertTrue(spin(until: 5) { client.hasPodcastEvidenceTapOnCurrentItem })
        XCTAssertTrue(spin(until: 15) { (client.currentMediaTimeMs() ?? 0) >= 7_000 }, "playback did not advance")

        // As the engine does for a Margin: pause at it, capture when it is saved, then rejoin 3 s earlier (#776)
        // with a plain play, not a noted seek.
        try client.pause()
        let anchor = try XCTUnwrap(client.currentMediaTimeMs())
        let request = PostResumeAudioSampleRequest(
            interjectionId: "ij-001", sessionId: "session", itemId: "episode",
            anchorMediaTimeMs: anchor, targetDurationMs: 3_000
        )
        _ = client.captureBufferedPreInterjectionAudioSample(request)
        try client.play(targetId: "episode-target", fromMediaTimeMs: MarginRejoin.mediaResumeTimeMs(pausedAtMs: anchor))
        XCTAssertTrue(spin(until: 15) { (client.currentMediaTimeMs() ?? 0) >= anchor + 4_000 })
        let stoppedAtMs = try XCTUnwrap(client.currentMediaTimeMs())
        try client.stop()

        XCTAssertTrue(spin(until: 5) { !heard.all.isEmpty }, "stopping must hand over what was heard")
        let window = try XCTUnwrap(heard.all.first)
        XCTAssertEqual(window.request, request)
        XCTAssertEqual(window.endReason, "stopped")
        XCTAssertTrue(window.coversBeforeAnchor, "the rolling minute before the Margin")
        XCTAssertTrue(window.coversAfterAnchor, "what played after it")
        XCTAssertGreaterThanOrEqual(window.sampleRate, 16_000)
        let first = try XCTUnwrap(window.segments.first)
        XCTAssertLessThanOrEqual(first.startMediaTimeMs, 1_000, "kept from near the start of playback")
        let rms = (first.samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, first.samples.count))).squareRoot()
        XCTAssertGreaterThan(rms, 0.01, "real decoded audio, even with the player muted")
        // One run of audio, as long as the media time that played (#1133, ANC-05). Samples labelled at the wrong
        // rate would stretch every transcript time after the first second. The tap decodes up to about half a
        // second ahead of the clock, so the run may end that much past where the player stopped.
        XCTAssertEqual(window.segments.count, 1, "the rejoin replays the read-ahead, so one contiguous run")
        let playedMs = stoppedAtMs - first.startMediaTimeMs
        let keptMs = window.durationMs(of: first)
        XCTAssertGreaterThanOrEqual(keptMs, playedMs - 250, "kept \(keptMs) ms of audio for \(playedMs) ms played")
        XCTAssertLessThanOrEqual(keptMs, playedMs + 1_000, "kept \(keptMs) ms of audio for \(playedMs) ms played")
        // The length alone can't show the samples are the right ones: the recorder trims overlapping chunks, which
        // hides a mislabelled rate. So the kept audio must be the episode's own audio at the times it is labelled
        // with, before the Margin and after the rejoin.
        for atMs in [2_000, anchor + 1_500] {
            let match = try Self.correlation(of: window, segment: first, atMs: atMs, withEpisode: fileURL)
            print("Heard window at \(atMs) ms matches the episode with correlation \(match)")
            XCTAssertGreaterThan(match, 0.8, "the window's audio at \(atMs) ms is not the episode's audio there")
        }
    }

    /// The best normalized correlation, within ±30 ms, between 250 ms of the window from `atMs` and the episode
    /// file mixed and decimated to the window's rate the same way.
    private static func correlation(
        of window: HeardAudioWindow, segment: HeardAudioWindow.Segment, atMs: Int, withEpisode url: URL
    ) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let factor = Int((file.processingFormat.sampleRate / window.sampleRate).rounded())
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let episode = HeardAudioDownsampler.mono(
            channels: [UnsafePointer(channel)], interleavedStride: 1, frameCount: Int(buffer.frameLength), factor: factor
        )
        let rate = window.sampleRate
        let length = Int(rate * 0.25)
        let maxLag = Int(rate * 0.03)
        let heardStart = Int((Double(atMs - segment.startMediaTimeMs) * rate / 1_000).rounded())
        let episodeStart = Int((Double(atMs) * rate / 1_000).rounded())
        guard heardStart >= 0, heardStart + length <= segment.samples.count,
              episodeStart - maxLag >= 0, episodeStart + maxLag + length <= episode.count else {
            XCTFail("\(atMs) ms is outside the window or the episode")
            return 0
        }
        let heard = Array(segment.samples[heardStart..<(heardStart + length)])
        var best: Float = -1
        for lag in -maxLag...maxLag {
            var dot: Float = 0, heardPower: Float = 0, episodePower: Float = 0
            for index in 0..<length {
                let a = heard[index], b = episode[episodeStart + lag + index]
                dot += a * b; heardPower += a * a; episodePower += b * b
            }
            best = max(best, dot / max(.leastNonzeroMagnitude, (heardPower * episodePower).squareRoot()))
        }
        return best
    }

    /// Minimal HTTP/1.1 server with byte-range support, which AVPlayer needs to stream a file progressively.
    private final class LoopbackAudioServer: @unchecked Sendable {
        private let listener: NWListener
        private let data: Data
        private let contentType: String
        private let queue = DispatchQueue(label: "loopback-audio-server")

        init(data: Data, contentType: String) throws {
            self.data = data
            self.contentType = contentType
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }

        func waitForPort() -> UInt16? {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let port = listener.port?.rawValue, port != 0 { return port }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return nil
        }

        func stop() { listener.cancel() }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: queue)
            receiveRequest(on: connection, buffer: Data())
        }

        private func receiveRequest(on connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, complete, error in
                guard let self, error == nil else { connection.cancel(); return }
                var buffer = buffer
                if let chunk { buffer.append(chunk) }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { connection.cancel() } else { self.receiveRequest(on: connection, buffer: buffer) }
                    return
                }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
                self.receiveRequest(on: connection, buffer: Data(buffer[end.upperBound...]))
            }
        }

        private func respond(to head: String, on connection: NWConnection) {
            var lower = 0
            var upper = data.count - 1
            var partial = false
            for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("range: bytes=") {
                let spec = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                if let start = Int(spec.first ?? "") { lower = start; partial = true }
                if spec.count > 1, let finish = Int(spec[1]) { upper = min(finish, data.count - 1) }
            }
            let body = lower <= upper ? data[lower...upper] : Data()
            var header = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(body.count)\r\n"
            if partial { header += "Content-Range: bytes \(lower)-\(upper)/\(data.count)\r\n" }
            header += "\r\n"
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in })
        }
    }

    private func spin(until seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Speech-like audio: noise bursts shaped by a slow, irregular envelope, so ShazamKit has features to sign.
    private static func writeTestEpisode(to url: URL, seconds: Int) throws -> URL {
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate) // one second per buffer
        var state: UInt64 = 0x9E3779B97F4A7C15 // seeded, so every run signs the same audio
        for second in 0..<seconds {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frames) {
                let time = Double(second) + Double(frame) / sampleRate
                let envelope = max(0, sin(time * 5.3) * sin(time * 1.7 + 0.4))
                let tone = sin(2 * .pi * (220 + 180 * sin(time * 0.9)) * time)
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Double(Int64(bitPattern: state >> 11)) / Double(1 << 52) - 1
                samples[frame] = Float(envelope * (0.5 * tone + 0.3 * noise))
            }
            try file.write(from: buffer)
        }
        return url
    }
}
#endif
