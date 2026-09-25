import AVFoundation
import Foundation
import Network
import SessionKit
import SessionKitAudio
import XCTest
@testable import SpokenMarginsApp

/// Records a spoken Margin on a streamed episode through the real app model and real audio router, the way the
/// Record button does, and checks that both anchor evidence windows are stored. Device Build 29 showed no
/// evidence because starting a Margin stopped the shared router and discarded the podcast player and its tap.
@MainActor
final class RealPlaybackMarginCaptureTests: XCTestCase {
    func testStreamedMarginStoresPreAndPostEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let episode = try Self.writeQuietEpisode(to: root.appending(path: "episode.caf"), seconds: 60)
        let server = try LoopbackAudioServer(data: Data(contentsOf: episode), contentType: "audio/x-caf")
        defer { server.stop() }
        let port = try XCTUnwrap(server.waitForPort())
        let audioURL = "http://127.0.0.1:\(port)/episode.caf"

        let resolver = PlayableLinkResolver(audioURL: audioURL, title: "Capture Journey Episode", durationMs: 60_000)
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "A spoken Margin." },
            databaseURLOverride: root.appending(path: "library.sqlite")
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/capture-episode", sourceSurface: "paste"))

        try await waitFor("the stream to play past 19 s", seconds: 40) {
            model.snapshot.status == .playing && (model.snapshot.currentMediaTimeMs ?? 0) >= 19_000
        }
        model.beginInterjection()
        try await waitFor("recording to start", seconds: 5) { model.snapshot.isRecording }
        try await Task.sleep(for: .seconds(1))
        model.finishInterjection()
        try await waitFor("playback to resume", seconds: 15) { model.snapshot.status == .playing }

        try await waitFor("pre and post evidence to be stored", seconds: 40) {
            let roles = Set((model.selectedItem.interjections.first?.podcastAnchorEvidence ?? []).compactMap(\.windowRole))
            return roles.contains(.preInterjection) && roles.contains(.postResume)
        }
        let margin = try XCTUnwrap(model.selectedItem.interjections.first)
        XCTAssertEqual(margin.podcastAnchorEvidenceCaptureStatus, .ready, margin.podcastAnchorEvidenceFailureReason ?? "")
        if model.snapshot.status == .playing { model.playPause() }
    }

    private struct Timeout: Error { let label: String }

    private func waitFor(_ label: String, seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(label)")
        if !condition() { throw Timeout(label: label) }
    }

    /// Speech-like noise bursts at a low level: enough features for ShazamKit, quiet on the Mac's speakers.
    private static func writeQuietEpisode(to url: URL, seconds: Int) throws -> URL {
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate)
        var generator = SystemRandomNumberGenerator()
        for second in 0..<seconds {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frames) {
                let time = Double(second) + Double(frame) / sampleRate
                let envelope = max(0, sin(time * 5.3) * sin(time * 1.7 + 0.4))
                let tone = sin(2 * .pi * (220 + 180 * sin(time * 0.9)) * time)
                let noise = Double.random(in: -1...1, using: &generator)
                samples[frame] = Float(0.06 * envelope * (0.5 * tone + 0.3 * noise))
            }
            try file.write(from: buffer)
        }
        return url
    }
}

private struct PlayableLinkResolver: LinkResolutionClient {
    let audioURL: String
    let title: String
    let durationMs: Int

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: request.inputURL, provider: "direct_audio", role: "audio_file"),
            title: title,
            durationMs: durationMs,
            audioURL: audioURL,
            confidence: 1
        )
        return LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, provider: "direct_audio", role: "discovery"),
            selectedCandidate: candidate,
            candidates: [candidate]
        )
    }
}

/// Minimal HTTP/1.1 server with byte ranges, which AVPlayer needs to stream progressively.
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
