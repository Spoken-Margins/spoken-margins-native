import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest

/// #288: on the owner's phone, Supertonic went silent while reporting "playing" after the #240
/// guard read chunks with the iOS voice, and only changing the output route brought sound back.
/// The iOS voice renders those chunks with AVSpeechSynthesizer.write while Supertonic plays. These
/// tests keep app audio rendering in the app's session, as Supertonic does, while chunks are
/// written, and record what the write does to that session. An agent can't hear the simulator,
/// so rendered frames and session notifications stand in for "still audible".
final class SystemVoiceSessionTests: XCTestCase {
    private struct Probe: CustomStringConvertible {
        var interruptions = 0
        var routeChanges: [String] = []
        var engineConfigurationChanges = 0
        var framesBefore = 0
        var framesDuring = 0
        var framesAfter = 0
        var engineRunningAfter = false
        var categoryBefore = ""
        var categoryAfter = ""
        var written: [Double] = []

        var description: String {
            "interruptions=\(interruptions) routeChanges=\(routeChanges) engineConfigChanges=\(engineConfigurationChanges) "
                + "frames(before/during/after 1 s)=\(framesBefore)/\(framesDuring)/\(framesAfter) engineRunningAfter=\(engineRunningAfter) "
                + "category \(categoryBefore) -> \(categoryAfter) written=\(written.map { String(format: "%.1fs", $0) })"
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var interruptions = 0, configurationChanges = 0
        private var routes: [String] = []
        func interrupted() { lock.withLock { interruptions += 1 } }
        func routeChanged(_ reason: String) { lock.withLock { routes.append(reason) } }
        func configurationChanged() { lock.withLock { configurationChanges += 1 } }
        var snapshot: (Int, [String], Int) { lock.withLock { (interruptions, routes, configurationChanges) } }
    }

    private final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        var value: Int { lock.withLock { frames } }
        func add(_ count: Int) { lock.withLock { frames += count } }
    }

    private func probe(_ renderer: SystemVoiceChunkRenderer) async throws -> Probe {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)

        // App audio playing continuously through the app's session, as Supertonic's player does.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let tone = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        tone.frameLength = 44_100
        let counter = FrameCounter()
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, _ in
            counter.add(Int(buffer.frameLength))
        }
        player.volume = 0
        try engine.start()
        player.scheduleBuffer(tone, at: nil, options: .loops, completionHandler: nil)
        player.play()
        defer {
            player.stop()
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.stop()
        }

        var result = Probe()
        result.categoryBefore = "\(session.category.rawValue)/\(session.mode.rawValue)"
        let center = NotificationCenter.default
        let events = Events()
        var observers: [NSObjectProtocol] = []
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { _ in
            events.interrupted()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            events.routeChanged(reason.map(String.init) ?? "?")
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            events.configurationChanged()
        })
        defer { observers.forEach(center.removeObserver) }

        try await Task.sleep(for: .seconds(1))
        result.framesBefore = counter.value

        // A Supertonic chunk to match, as the output guard does.
        let reference = FileManager.default.temporaryDirectory.appending(path: "reference-\(UUID().uuidString).wav")
        let referenceFile = try AVAudioFile(forWriting: reference, settings: format.settings)
        try referenceFile.write(from: tone)
        defer { try? FileManager.default.removeItem(at: reference) }

        let startDuring = counter.value
        for index in 0..<3 {
            let output = FileManager.default.temporaryDirectory.appending(path: "system-voice-\(index)-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: output) }
            let seconds = try await renderer.render(
                text: "Table \(index + 1) reports 91.1% and 8.9% across 7,494 tool decisions.",
                voiceIdentifier: nil, matching: reference, to: output
            )
            result.written.append(seconds)
        }
        result.framesDuring = counter.value - startDuring

        let startAfter = counter.value
        try await Task.sleep(for: .seconds(1))
        result.framesAfter = counter.value - startAfter
        result.engineRunningAfter = engine.isRunning
        result.categoryAfter = "\(session.category.rawValue)/\(session.mode.rawValue)"
        (result.interruptions, result.routeChanges, result.engineConfigurationChanges) = events.snapshot
        return result
    }

    /// The renderer as it ships: the synthesizer stays off the app's session. App audio must keep
    /// rendering through the writes and afterwards, with no interruption or route change.
    /// APA-06 (#1042): this used to pass `usesApplicationAudioSession: false` itself, so flipping the default
    /// that `SupertonicOutputGuard` relies on left it green. It now builds the renderer the way the guard
    /// does; `SystemVoiceChunkRendererDefaultTests` pins that default on the host, because this probe may not
    /// tell the two settings apart on the simulator. The shared-session setting (#288's) is checked on a phone.
    func testWritingIOSVoiceChunksLeavesTheAppsPlayingAudioUndisturbed() async throws {
        // #768: on a wedged simulator the engine start in `probe` aborts the app; check the voice answers first.
        try await SystemVoiceRuntime.requireAnsweringVoice()
        let result = try await probe(SystemVoiceChunkRenderer())
        print("#288 probe, renderer as the output guard builds it: \(result)")
        XCTAssertEqual(result.written.count, 3, "every chunk was written")
        XCTAssertTrue(result.written.allSatisfy { $0 > 0.5 }, "\(result.written)")
        XCTAssertEqual(result.interruptions, 0, "\(result)")
        XCTAssertEqual(result.engineConfigurationChanges, 0, "\(result)")
        XCTAssertTrue(result.engineRunningAfter, "\(result)")
        XCTAssertGreaterThan(result.framesAfter, 22_050, "app audio still renders a second later: \(result)")
        XCTAssertEqual(result.categoryAfter, result.categoryBefore, "\(result)")
    }
}
