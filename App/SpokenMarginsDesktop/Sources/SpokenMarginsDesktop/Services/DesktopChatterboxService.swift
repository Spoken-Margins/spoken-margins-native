import AVFoundation
import Darwin
import DesktopCore
import Foundation

typealias ChatterboxProgressHandler = @Sendable (_ phase: String, _ fraction: Double?) -> Void

enum ChatterboxFailure: LocalizedError {
    case incompleteSetup(String)
    case resourceMonitoringUnavailable
    case workerStopped(String)
    case invalidResponse
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .incompleteSetup(let reason): reason
        case .resourceMonitoringUnavailable: "Chatterbox was not started because macOS memory and swap monitoring is unavailable. Choose Supertonic or a Mac voice."
        case .workerStopped(let reason): "Chatterbox stopped: \(reason)."
        case .invalidResponse: "Chatterbox returned an unreadable result."
        case .missingOutput: "Chatterbox did not create playable audio."
        }
    }
}

struct ChatterboxConfiguration: Sendable {
    let variant: DesktopChatterboxModel
    let pythonURL: URL
    let modelURL: URL
    let helperURL: URL
    let outputDirectory: URL

    func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw ChatterboxFailure.incompleteSetup("Choose a valid Python executable in Settings.")
        }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw ChatterboxFailure.incompleteSetup("The bundled Chatterbox helper is missing. Rebuild Spoken Margins Desktop.")
        }
        let checkpoint = variant == .nano ? "t3_nano_v1.safetensors" : "t3_turbo_v1.safetensors"
        guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent(checkpoint).path) else {
            throw ChatterboxFailure.incompleteSetup("The selected Chatterbox \(variant.title) checkpoint (\(checkpoint)) is not in this model folder.")
        }
        if variant == .nano, ChatterboxRuntimeCompatibility.nanoSupport(in: pythonURL) == false {
            throw ChatterboxFailure.incompleteSetup("This Chatterbox Python runtime does not support Nano. Choose a Nano-compatible local runtime.")
        }
        for required in ["s3gen_meanflow.safetensors", "ve.safetensors", "conds.pt"] {
            guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent(required).path) else {
                throw ChatterboxFailure.incompleteSetup("The selected Chatterbox model folder is missing \(required).")
            }
        }
        let tokenizerJSON = modelURL.appendingPathComponent("tokenizer.json").path
        let vocab = modelURL.appendingPathComponent("vocab.json").path
        let merges = modelURL.appendingPathComponent("merges.txt").path
        guard FileManager.default.fileExists(atPath: tokenizerJSON) ||
                (FileManager.default.fileExists(atPath: vocab) && FileManager.default.fileExists(atPath: merges)) else {
            throw ChatterboxFailure.incompleteSetup("The selected Chatterbox model folder is missing tokenizer files.")
        }
    }
}

private enum ChatterboxRuntimeCompatibility {
    /// Read the local package signature when it is available. `nil` means an
    /// unfamiliar Python layout; the isolated worker performs the same check
    /// before loading weights.
    static func nanoSupport(in pythonURL: URL) -> Bool? {
        let runtime = pythonURL.deletingLastPathComponent().deletingLastPathComponent()
        let library = runtime.appendingPathComponent("lib", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }

        for version in versions where version.lastPathComponent.hasPrefix("python") {
            let sourceURL = version.appendingPathComponent("site-packages/chatterbox/tts_turbo.py")
            guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
                  let declaration = source.range(of: "def from_local") else { continue }
            let signatureStart = declaration.lowerBound
            guard let signatureEnd = source[signatureStart...].firstIndex(of: ")") else { continue }
            return source[signatureStart...signatureEnd].contains("nano")
        }
        return nil
    }
}

/// Chatterbox stays in a killable child process. One model load serves the
/// current session; the watchdog watches the child, never the desktop app.
actor DesktopChatterboxService {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var watchdog: Task<Void, Never>?
    nonisolated private let control = ChatterboxProcessControl()
    private var configuration: ChatterboxConfiguration?

    func render(_ text: String, configuration: ChatterboxConfiguration,
                onProgress: ChatterboxProgressHandler? = nil) throws -> DesktopRenderedAudio {
        try configuration.validate()
        if let process, !process.isRunning { stop() }
        if self.configuration?.pythonURL != configuration.pythonURL ||
           self.configuration?.modelURL != configuration.modelURL ||
           self.configuration?.variant != configuration.variant {
            stop()
        }
        if process == nil {
            onProgress?("Loading local model", nil)
            try start(configuration)
        }
        let file = configuration.outputDirectory.appendingPathComponent("chatterbox-\(UUID().uuidString).wav")
        let request = try JSONSerialization.data(withJSONObject: ["text": text, "output": file.path])
        guard let input else { throw ChatterboxFailure.workerStopped("input channel closed") }
        try input.write(contentsOf: request + Data([10]))
        let started = Date()
        let response = try readReply(onProgress: onProgress)
        if let error = response["error"] as? String { throw ChatterboxFailure.workerStopped(error) }
        guard response["ok"] as? Bool == true else { throw ChatterboxFailure.invalidResponse }
        control.markProgress()
        guard FileManager.default.fileExists(atPath: file.path),
              let audio = try? AVAudioFile(forReading: file), audio.length > 0 else {
            throw ChatterboxFailure.missingOutput
        }
        return DesktopRenderedAudio(url: file, renderSeconds: Date().timeIntervalSince(started))
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        control.abort(reason: "stopped")
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        configuration = nil
        control.clear()
    }

    nonisolated func abort() { control.abort(reason: "generation cancelled") }

    private func start(_ configuration: ChatterboxConfiguration) throws {
        guard let baselineSwap = Self.swapBytes() else {
            throw ChatterboxFailure.resourceMonitoringUnavailable
        }
        try FileManager.default.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = configuration.pythonURL
        process.arguments = ["-u", configuration.helperURL.path, "--model", configuration.modelURL.path,
                             "--variant", configuration.variant.rawValue]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"
        ]) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        let logURL = configuration.outputDirectory.appendingPathComponent("chatterbox-worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: logURL)
        try process.run()
        control.setPID(process.processIdentifier)
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        self.configuration = configuration
        let pid = process.processIdentifier
        watchdog = Task.detached { [weak self] in
            let physicalMemory = ProcessInfo.processInfo.physicalMemory
            while !Task.isCancelled && kill(pid, 0) == 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let rss = Self.residentBytes(pid: pid), let swap = Self.swapBytes() else {
                    self?.control.abort(reason: "memory and swap could not be monitored")
                    try? await Task.sleep(for: .milliseconds(500))
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                    return
                }
                let swapGrowth = swap.saturatingSubtract(baselineSwap)
                if let reason = ChatterboxResourcePolicy.stopReason(
                    model: configuration.variant, physicalMemory: physicalMemory,
                    residentBytes: rss, swapGrowthBytes: swapGrowth,
                    elapsed: self?.control.secondsSinceProgress ?? 0) {
                    self?.control.abort(reason: reason)
                    try? await Task.sleep(for: .milliseconds(500))
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                    return
                }
            }
        }
        let reply = try readReply()
        guard reply["ready"] as? Bool == true else {
            let reason = reply["error"] as? String ?? "startup failed"
            stop()
            throw ChatterboxFailure.workerStopped(reason)
        }
        control.markProgress()
    }

    private func readReply(onProgress: ChatterboxProgressHandler? = nil) throws -> [String: Any] {
        guard let output else { throw ChatterboxFailure.workerStopped("output channel closed") }
        while true {
            var line = Data()
            while let byte = try output.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 10 { break }
                line.append(byte)
                if line.count > 16_384 { throw ChatterboxFailure.invalidResponse }
            }
            guard !line.isEmpty else {
                throw ChatterboxFailure.workerStopped(control.reason ?? "helper exited; check chatterbox-worker.log")
            }
            guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw ChatterboxFailure.invalidResponse
            }
            if let phase = response["phase"] as? String, response["progress"] != nil {
                onProgress?(phase, response["progress"] as? Double)
                continue
            }
            return response
        }
    }

    private static func residentBytes(pid: pid_t) -> UInt64? {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "rss=", "-p", String(pid)]
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        ps.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let kibibytes = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return kibibytes * 1024
    }

    private static func swapBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }
}

private final class ChatterboxProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopReason: String?
    private var lastProgress = Date()

    var reason: String? { lock.lock(); defer { lock.unlock() }; return stopReason }
    var secondsSinceProgress: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastProgress)
    }
    func markProgress() { lock.lock(); lastProgress = Date(); lock.unlock() }
    func setPID(_ value: pid_t) { lock.lock(); pid = value; stopReason = nil; lastProgress = Date(); lock.unlock() }
    func clear() { lock.lock(); pid = 0; stopReason = nil; lock.unlock() }
    func abort(reason: String) {
        lock.lock()
        let activePID = pid
        stopReason = reason
        lock.unlock()
        if activePID > 0 { kill(activePID, SIGTERM) }
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
