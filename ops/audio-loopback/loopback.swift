// loopback: the macOS half of the audio loopback harness (#1790).
//
// It lists audio devices, routes the Mac's default output to a loopback device (BlackHole 2ch) for the
// length of one command and always puts the previous device back, records a device's input to a wav,
// plays a file to a chosen device, and transcribes a wav on-device. The analysis lives in loopback.py,
// so it can be host-tested without any audio hardware.
//
// It never changes the default input device, and never changes the system (alert) output device.
// Build with ./build.sh; usage is in README.md. build-app.sh builds the same source as
// SpokenMarginsLaneRecorder.app, which the lane launches through LaunchServices (`--job`, below) so macOS asks
// for Microphone and Speech Recognition in the app's own name (README, The recorder app).

import AVFoundation
import CoreAudio
import Foundation
import Speech

// MARK: - Errors and output

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("loopback: " + message + "\n").utf8))
    finish(code)
}

// MARK: - Job mode (the recorder app)

/// Set by `--job <folder>`. An app that LaunchServices starts (`open -W -a ...`) has no stdout, stderr or exit
/// status its caller can read, so in job mode they go to files in that folder: `stdout`, `stderr`, and `status`
/// (the exit code, written last). The caller can't signal the app either; it asks it to stop by creating `stop`.
var jobFolder: String?
var jobWatch: DispatchSourceTimer?

func finish(_ code: Int32) -> Never {
    if let jobFolder {
        fflush(stdout)
        let status = jobFolder + "/status"
        if (try? "\(code)\n".write(toFile: status + ".part", atomically: false, encoding: .utf8)) != nil {
            rename(status + ".part", status)
        }
    }
    exit(code)
}

func startJob(_ folder: String) {
    jobFolder = folder
    for (name, descriptor) in [("stdout", STDOUT_FILENO), ("stderr", STDERR_FILENO)] {
        let handle = open(folder + "/" + name, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if handle >= 0 { dup2(handle, descriptor); close(handle) }
    }
    setvbuf(stdout, nil, _IOLBF, 0)
    let watch = DispatchSource.makeTimerSource(queue: .global())
    watch.schedule(deadline: .now() + 0.25, repeating: 0.25)
    watch.setEventHandler {
        if FileManager.default.fileExists(atPath: folder + "/stop") { note("stopped: the caller asked"); finish(143) }
    }
    watch.resume()
    jobWatch = watch
}

/// Waits on the run loop, so permission answers and recogniser callbacks can arrive.
func waitUntil(_ seconds: Double, _ done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
}

func microphoneAccess() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "allowed"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not asked yet"
    @unknown default: return "unknown"
    }
}

func speechAccess(_ status: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()) -> String {
    switch status {
    case .authorized: return "allowed"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not asked yet"
    @unknown default: return "unknown"
    }
}

/// `permissions`: asks for both, once, so the owner can answer the two prompts at the Mac. `--status` only reports.
/// Unattended jobs never ask (nobody is there to click); they fail with the status instead.
func permissions(ask: Bool) -> Bool {
    if ask && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        var answered = false
        AVCaptureDevice.requestAccess(for: .audio) { _ in answered = true }
        waitUntil(600) { answered }
    }
    if ask && SFSpeechRecognizer.authorizationStatus() == .notDetermined {
        var answered = false
        SFSpeechRecognizer.requestAuthorization { _ in answered = true }
        waitUntil(600) { answered }
    }
    printJSON(["microphone": microphoneAccess(), "speech_recognition": speechAccess()])
    return microphoneAccess() == "allowed" && speechAccess() == "allowed"
}

let setupHint = "run ops/audio-loopback/setup-recorder-app.sh at the Mac (README, The recorder app)"

func note(_ message: String) {
    FileHandle.standardError.write(Data(("loopback: " + message + "\n").utf8))
}

func printJSON(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

// MARK: - CoreAudio devices

struct Device {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func channelCount(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func allDevices() -> [Device] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map {
        Device(id: $0, uid: stringProperty($0, kAudioDevicePropertyDeviceUID) ?? "",
               name: stringProperty($0, kAudioObjectPropertyName) ?? "",
               inputChannels: channelCount($0, kAudioObjectPropertyScopeInput),
               outputChannels: channelCount($0, kAudioObjectPropertyScopeOutput))
    }
}

/// A device by exact UID, then exact name, then a case-insensitive name prefix ("BlackHole" finds "BlackHole 2ch").
func findDevice(_ query: String, input: Bool? = nil) -> Device? {
    let devices = allDevices().filter { device in
        switch input {
        case true?: return device.inputChannels > 0
        case false?: return device.outputChannels > 0
        case nil: return true
        }
    }
    return devices.first { $0.uid == query } ?? devices.first { $0.name == query }
        ?? devices.first { $0.name.lowercased().hasPrefix(query.lowercased()) }
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var addr = address(selector)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
}

func setDefaultOutput(_ id: AudioDeviceID) throws {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var value = id
    let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    guard status == noErr else { throw ToolError("could not set the default output (OSStatus \(status))") }
}

func uid(of id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }

// MARK: - Routing with guaranteed restore

/// Where `route` writes the device it must put back. A route that dies without restoring (kill -9, power loss)
/// leaves this file; the next `route` or `restore` puts that device back first.
func statePath(_ arguments: inout [String]) -> String {
    if let given = option("--state", &arguments) { return given }
    let base = ProcessInfo.processInfo.environment["SM_AUDIO_LOOPBACK_STATE"]
        ?? (NSHomeDirectory() + "/SpokenMarginsOps/audio-loopback")
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return base + "/previous-default-output.txt"
}

/// Puts back the device recorded in `path`, if any, and removes the file. Returns the UID restored.
@discardableResult
func restoreFromState(_ path: String) -> String? {
    guard let saved = try? String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty else { return nil }
    guard let device = findDevice(saved, input: false) else {
        note("the saved output device \(saved) is gone; leaving the default output as it is")
        try? FileManager.default.removeItem(atPath: path)
        return nil
    }
    do {
        if defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) != device.id { try setDefaultOutput(device.id) }
        try? FileManager.default.removeItem(atPath: path)
        return saved
    } catch {
        note("restore failed: \(error); the state file stays at \(path)")
        return nil
    }
}

var routeStatePath: String?
var routeChild: pid_t = 0

func restoreOnSignal(_ signal: Int32) {
    if routeChild > 0 { kill(routeChild, SIGTERM) }
    if let path = routeStatePath, let restored = restoreFromState(path) { note("restored default output \(restored) after signal \(signal)") }
    exit(128 + signal)
}

func route(_ arguments: [String]) throws -> Int32 {
    var arguments = arguments
    let path = statePath(&arguments)
    guard let target = option("--to", &arguments) else { throw ToolError("route needs --to <device>") }
    guard let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count else {
        throw ToolError("route needs a command after --")
    }
    let command = Array(arguments[(separator + 1)...])
    if let restored = restoreFromState(path) { note("restored \(restored) left behind by an earlier route") }
    guard let device = findDevice(target, input: false) else { throw ToolError("no output device matches \"\(target)\"") }
    guard let previous = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice), let previousUID = uid(of: previous) else {
        throw ToolError("could not read the current default output")
    }
    // Save first, then switch: whatever happens after this line, the file names the device to put back.
    try previousUID.write(toFile: path, atomically: true, encoding: .utf8)
    routeStatePath = path
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGALRM] { signal(sig, restoreOnSignal) }
    defer {
        if let restored = restoreFromState(path) { note("restored default output \(restored)") }
        routeStatePath = nil
    }
    try setDefaultOutput(device.id)
    note("default output is \(device.name) until the command ends (was \(previousUID))")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    try process.run()
    routeChild = process.processIdentifier
    process.waitUntilExit()
    routeChild = 0
    return process.terminationStatus
}

// MARK: - Engine device binding

func bind(_ unit: AudioUnit?, to device: AudioDeviceID) throws {
    guard let unit else { throw ToolError("no audio unit to bind") }
    var value = device
    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &value, UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { throw ToolError("could not bind the engine to the device (OSStatus \(status))") }
}

// MARK: - Record

/// Records `device`'s input for `seconds` into a 16-bit mono wav at `rate`. Only this process's engine is pointed
/// at the device; the Mac's default input is not touched.
func record(device query: String, seconds: Double, to path: String, rate: Double) throws {
    // Without access macOS hands the engine digital silence, not an error; in job mode say so up front.
    if jobFolder != nil && microphoneAccess() != "allowed" {
        throw ToolError("Microphone access for this app is \(microphoneAccess()): \(setupHint)")
    }
    guard let device = findDevice(query, input: true) else { throw ToolError("no input device matches \"\(query)\"") }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    try bind(input.audioUnit, to: device.id)
    let sourceFormat = input.outputFormat(forBus: 0)
    guard sourceFormat.sampleRate > 0 else { throw ToolError("\(device.name) reports no input format") }
    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: sourceFormat, to: target) else { throw ToolError("no converter to \(rate) Hz mono") }
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let wanted = AVAudioFramePosition(seconds * rate)
    let lock = NSLock()
    var written: AVAudioFramePosition = 0
    var writeError: Error?
    let done = DispatchSemaphore(value: 0)
    input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { buffer, _ in
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rate / sourceFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        lock.lock(); defer { lock.unlock() }
        guard written < wanted, writeError == nil else { return }
        out.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(out.frameLength), wanted - written))
        do { try file.write(from: out) } catch { writeError = error }
        written += AVAudioFramePosition(out.frameLength)
        if written >= wanted || writeError != nil { done.signal() }
    }
    try engine.start()
    note("recording \(device.name) for \(seconds) s into \(path)")
    // Twice the window plus slack: an input that delivers nothing must still end the command.
    let finished = done.wait(timeout: .now() + seconds * 2 + 5) == .success
    input.removeTap(onBus: 0)
    engine.stop()
    if let writeError { throw writeError }
    if !finished { throw ToolError("\(device.name) delivered \(written) of \(wanted) frames; is the device running?") }
}

// MARK: - Play

/// Plays a file to `device` without changing the default output.
func play(file path: String, device query: String) throws {
    guard let device = findDevice(query, input: false) else { throw ToolError("no output device matches \"\(query)\"") }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let engine = AVAudioEngine()
    try bind(engine.outputNode.audioUnit, to: device.id)
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    let done = DispatchSemaphore(value: 0)
    player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in done.signal() }
    try engine.start()
    player.play()
    let seconds = Double(file.length) / file.processingFormat.sampleRate
    if done.wait(timeout: .now() + seconds + 10) != .success { note("playback did not report finishing") }
    engine.stop()
}

// MARK: - Transcribe

/// On-device transcription with macOS Speech. Prints JSON: text, each word with its start and length, and
/// `empty_reason` when no words came back.
///
/// The on-device recogniser forgets what it heard when a pause of more than about a second follows it: the
/// final result keeps only the speech after the last long pause, or nothing when the file ends in silence
/// (#1790). This transcribes one file as it is; `loopback.py transcribe` splits a recording at pauses first.
/// Partial results are watched only to tell that case apart from hearing nothing.
func transcribe(file path: String, locale: String) throws -> [String: Any] {
    let status: SFSpeechRecognizerAuthorizationStatus = {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined, jobFolder == nil else { return current }
        let asked = DispatchSemaphore(value: 0)
        var answer = current
        SFSpeechRecognizer.requestAuthorization { answer = $0; asked.signal() }
        _ = asked.wait(timeout: .now() + 60)
        return answer
    }()
    guard status == .authorized else {
        throw ToolError("speech recognition is not authorised for this process (\(speechAccess(status))); "
                        + (jobFolder == nil ? "see README" : setupHint))
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { throw ToolError("no recognizer for \(locale)") }
    guard recognizer.supportsOnDeviceRecognition else { throw ToolError("on-device recognition is not available for \(locale)") }
    guard recognizer.isAvailable else { throw ToolError("the \(locale) recognizer is not available right now") }
    let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.addsPunctuation = false
    var failure: Error?
    var finished = false
    var words: [[String: Any]] = []
    var texts: [String] = []
    var lastPartial = ""
    let task = recognizer.recognitionTask(with: request) { result, error in
        if let result {
            let transcription = result.bestTranscription
            if !result.isFinal {
                if !transcription.formattedString.isEmpty { lastPartial = transcription.formattedString }
            } else if !transcription.formattedString.isEmpty {
                texts.append(transcription.formattedString)
                words += transcription.segments.map {
                    ["word": $0.substring, "start": $0.timestamp, "duration": $0.duration, "confidence": $0.confidence]
                }
            }
            if result.isFinal { finished = true }
        }
        if let error { failure = error; finished = true }
    }
    // The task ends when the file is consumed; wait on the run loop so the callbacks can arrive.
    let deadline = Date().addingTimeInterval(600)
    while task.state != .completed && task.state != .canceling && !finished && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    var output: [String: Any] = ["text": texts.joined(separator: " "), "words": words, "locale": locale, "on_device": true]
    guard texts.isEmpty else { return output }
    if let failure {
        let code = (failure as NSError).code
        // 1110 is "no speech detected": an honest empty transcript, not a tool failure.
        if code != 1110 { throw ToolError("transcription failed: \(failure.localizedDescription) (\(code))") }
        output["empty_reason"] = "no speech detected"
    } else if !finished && Date() >= deadline {
        throw ToolError("transcription timed out after 600 s")
    } else if !lastPartial.isEmpty {
        output["empty_reason"] = "the recogniser heard \"\(lastPartial)\" and then dropped it at a pause longer than "
            + "about a second; use loopback.py transcribe, which splits at pauses"
    } else {
        output["empty_reason"] = "the recogniser returned an empty result"
    }
    return output
}

// MARK: - Command line

func option(_ name: String, _ arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count,
          arguments.firstIndex(of: "--").map({ index < $0 }) ?? true else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func flag(_ name: String, _ arguments: inout [String]) -> Bool {
    guard let index = arguments.firstIndex(of: name), arguments.firstIndex(of: "--").map({ index < $0 }) ?? true else { return false }
    arguments.remove(at: index)
    return true
}

let usage = """
usage: loopback devices [--json]
       loopback route --to <output device> [--state <file>] -- <command> [args...]
       loopback restore [--state <file>]
       loopback record --device <input device> --seconds <s> --out <file.wav> [--rate 16000]
       loopback play --device <output device> <file>
       loopback transcribe <file.wav> [--locale en-US]   (one file as is; loopback.py transcribe splits at pauses)
       loopback permissions [--status]   (asks for Microphone and Speech Recognition unless --status)
       loopback --job <folder> <command> [args...]   (as the recorder app: output and exit status go to files)
"""

var arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
if arguments.first == "--job", arguments.count >= 2 {
    startJob(arguments[1])
    arguments.removeFirst(2)
}
guard let command = arguments.first else { fail(usage, code: 2) }
arguments.removeFirst()

do {
    switch command {
    case "devices":
        let json = flag("--json", &arguments)
        let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let rows = allDevices().map { device -> [String: Any] in
            ["id": Int(device.id), "uid": device.uid, "name": device.name, "inputs": device.inputChannels,
             "outputs": device.outputChannels, "default_output": device.id == output, "default_input": device.id == input]
        }
        if json { printJSON(rows); break }
        for row in rows {
            let marks = [(row["default_output"] as! Bool) ? "default output" : nil, (row["default_input"] as! Bool) ? "default input" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            print("\(row["name"]!)  in:\(row["inputs"]!) out:\(row["outputs"]!)  uid:\(row["uid"]!)\(marks.isEmpty ? "" : "  [\(marks)]")")
        }
    case "route":
        finish(try route(arguments))
    case "restore":
        let path = statePath(&arguments)
        if let restored = restoreFromState(path) { print("restored \(restored)") } else { print("nothing to restore") }
    case "record":
        guard let device = option("--device", &arguments), let seconds = option("--seconds", &arguments).flatMap(Double.init),
              let out = option("--out", &arguments) else { fail(usage, code: 2) }
        try record(device: device, seconds: seconds, to: out, rate: option("--rate", &arguments).flatMap(Double.init) ?? 16000)
    case "play":
        guard let device = option("--device", &arguments), let file = arguments.first else { fail(usage, code: 2) }
        try play(file: file, device: device)
    case "transcribe":
        let locale = option("--locale", &arguments) ?? "en-US"
        guard let file = arguments.first else { fail(usage, code: 2) }
        printJSON(try transcribe(file: file, locale: locale))
    case "permissions":
        finish(permissions(ask: !flag("--status", &arguments)) ? 0 : 1)
    default:
        fail(usage, code: 2)
    }
} catch {
    fail("\(error)")
}
finish(0)
