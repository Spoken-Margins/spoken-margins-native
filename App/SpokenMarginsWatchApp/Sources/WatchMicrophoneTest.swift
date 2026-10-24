import AVFoundation
import SwiftUI

/// The test page for device check 6, AirPods on the Watch (#2487 slice 1b; DESIGN section 6, check 6; default 6).
///
/// 1. With AirPods on the phone and a call running, tap Record: 10 seconds with the Watch's own microphone, then
///    Play. The page lists the inputs the Watch offers and the one it used.
/// 2. With Audible playing on the phone through the AirPods, tap Try headphones: 10 seconds asking for a Bluetooth
///    headset microphone. Note whether Audible kept playing in your ears.
///
/// Nothing here is filed or sent: the recording stays on the Watch and is replaced by the next try.
@MainActor
final class WatchMicrophoneTest: ObservableObject {
    enum Mode: String {
        case watch = "Watch microphone"
        case headphones = "Headphones"
    }

    @Published private(set) var status = "Ready"
    @Published private(set) var inputs: [String] = []
    @Published private(set) var usedInput: String?
    @Published private(set) var mode: Mode?
    @Published private(set) var isBusy = false
    @Published private(set) var hasRecording = false

    private let rig = WatchMicrophoneTestRig()

    func refreshInputs(for mode: Mode = .watch) {
        Task {
            let found = await rig.inputs(mode: mode)
            inputs = found
        }
    }

    func record(_ mode: Mode) {
        guard !isBusy else { return }
        isBusy = true
        self.mode = mode
        status = "Recording 10 seconds…"
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                status = "Microphone not allowed. Turn it on in the Watch app on your iPhone."
                isBusy = false
                return
            }
            do {
                let result = try await rig.record(mode: mode, seconds: 10)
                inputs = result.inputs
                usedInput = result.used
                hasRecording = true
                status = "Recorded with: \(result.used)"
            } catch {
                status = "Couldn't record: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    func play() {
        guard !isBusy, hasRecording else { return }
        isBusy = true
        status = "Playing…"
        Task {
            do {
                try await rig.play()
                status = "Played back"
            } catch {
                status = "Couldn't play: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }
}

/// The audio session work for the test page, off the main thread.
actor WatchMicrophoneTestRig {
    struct Result: Sendable {
        var inputs: [String]
        var used: String
    }

    private var player: AVAudioPlayer?

    private var url: URL {
        FileManager.default.temporaryDirectory.appending(path: "microphone-test.m4a")
    }

    private func configure(_ mode: WatchMicrophoneTest.Mode) throws {
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .watch:
            try session.setCategory(.record, mode: .default)
        case .headphones:
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        }
        try session.setActive(true)
    }

    private static func describe(_ port: AVAudioSessionPortDescription) -> String {
        "\(port.portName) (\(port.portType.rawValue))"
    }

    func inputs(mode: WatchMicrophoneTest.Mode) -> [String] {
        try? configure(mode)
        defer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        return (AVAudioSession.sharedInstance().availableInputs ?? []).map(Self.describe)
    }

    func record(mode: WatchMicrophoneTest.Mode, seconds: Double) async throws -> Result {
        try configure(mode)
        let session = AVAudioSession.sharedInstance()
        let available = (session.availableInputs ?? []).map(Self.describe)
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1
        ])
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw TestError.wouldNotStart
        }
        let used = session.currentRoute.inputs.map(Self.describe).joined(separator: ", ")
        try? await Task.sleep(for: .seconds(seconds))
        recorder.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return Result(inputs: available, used: used.isEmpty ? "unknown" : used)
    }

    func play() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        self.player = player
        player.play()
        try? await Task.sleep(for: .seconds(player.duration + 0.3))
        player.stop()
        self.player = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private enum TestError: LocalizedError {
        case wouldNotStart
        var errorDescription: String? { "The microphone didn't start." }
    }
}

struct WatchMicrophoneTestView: View {
    @StateObject private var test = WatchMicrophoneTest()

    var body: some View {
        List {
            Section {
                Text(test.status).font(.footnote)
            }
            Section("Step 1, during a call") {
                Button {
                    test.record(.watch)
                } label: {
                    Label("Record 10 seconds", systemImage: "mic")
                }
                .disabled(test.isBusy)
                Button {
                    test.play()
                } label: {
                    Label("Play it back", systemImage: "play")
                }
                .disabled(test.isBusy || !test.hasRecording)
            }
            Section("Step 2, Audible playing") {
                Button {
                    test.record(.headphones)
                } label: {
                    Label("Try headphones", systemImage: "headphones")
                }
                .disabled(test.isBusy)
            }
            if let used = test.usedInput {
                Section("Used (\(test.mode?.rawValue ?? ""))") {
                    Text(used).font(.footnote)
                }
            }
            Section("Microphones the Watch offers") {
                if test.inputs.isEmpty {
                    Text("None listed yet").font(.footnote)
                } else {
                    ForEach(test.inputs, id: \.self) { Text($0).font(.footnote) }
                }
            }
        }
        .navigationTitle("Microphone test")
        .onAppear { test.refreshInputs() }
    }
}
