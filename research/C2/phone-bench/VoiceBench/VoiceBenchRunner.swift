// C2 M2 phone benchmark: runner code for the throwaway VoiceBench app
// (bundle ID com.spokenmargins.voicebench; never a screen in Spoken Margins). See ../README.md.
// Written in a cloud session without a compiler; the Mac session builds and fixes it.
import AVFoundation
import CryptoKit
import Foundation
import OnnxRuntimeBindings
import SessionKitSupertonic

struct VoiceBenchPassageResult: Codable, Sendable {
    var passage: String
    var chunks: Int
    var timeToFirstAudioSeconds: Double
    var renderSeconds: Double
    var audioSeconds: Double
    var speedX: Double { audioSeconds / max(renderSeconds, 1e-9) }

    enum CodingKeys: String, CodingKey { case passage, chunks, timeToFirstAudioSeconds, renderSeconds, audioSeconds, speedX }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(passage, forKey: .passage)
        try c.encode(chunks, forKey: .chunks)
        try c.encode(timeToFirstAudioSeconds, forKey: .timeToFirstAudioSeconds)
        try c.encode(renderSeconds, forKey: .renderSeconds)
        try c.encode(audioSeconds, forKey: .audioSeconds)
        try c.encode(speedX, forKey: .speedX)
    }
}

struct VoiceBenchEngineResult: Codable, Sendable {
    var engine: String
    var threads: String
    var loadSeconds: Double
    var passages: [VoiceBenchPassageResult]
    var peakFootprintMB: Double
    var error: String?
    var speedX: Double {
        let audio = passages.reduce(0) { $0 + $1.audioSeconds }
        let render = passages.reduce(0) { $0 + $1.renderSeconds }
        return audio / max(render, 1e-9)
    }
    var medianTimeToFirstAudioSeconds: Double {
        let t = passages.map(\.timeToFirstAudioSeconds).sorted()
        return t.isEmpty ? 0 : t[t.count / 2]
    }
}

struct VoiceBenchReport: Codable, Sendable {
    var date: Date
    var device: String
    var systemVersion: String
    var lowPowerModeAtStart: Bool
    var lowPowerModeAtEnd: Bool
    var thermalStateAtStart: String
    var thermalStateAtEnd: String
    var passMark: String = "Kitten fp32 speedX >= 4 with Low Power Mode on and the phone warm"
    var engines: [VoiceBenchEngineResult]
}

enum VoiceBenchError: Error, LocalizedError {
    case badDownload(String)
    case missingOutput(String)
    var errorDescription: String? {
        switch self {
        case .badDownload(let s): return "Model download failed: \(s)"
        case .missingOutput(let s): return "Model produced no \(s) output"
        }
    }
}

// MARK: - Device state

enum VoiceBenchDevice {
    static var model: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Current phys_footprint in MB (what Xcode's memory gauge and jetsam use).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

// MARK: - Models (bundled in the VoiceBench app; download is only a fallback, sha256-checked)

struct VoiceBenchModel: Sendable {
    let name: String
    let url: URL
    let sha256: String
    let bytes: Int

    static let kittenFP32 = VoiceBenchModel(
        name: "kitten-nano-0.8-fp32",
        url: URL(string: "https://huggingface.co/KittenML/kitten-tts-nano-0.8-fp32/resolve/7a1db645b1f3ab9420761d87428e042b9cec3f26/kitten_tts_nano_v0_8.onnx")!,
        sha256: "320564d2615f235de972ca27a7f39551c94185cfa24ca85b07a29084135f1e5e",
        bytes: 56_767_095
    )
    static let kittenINT8 = VoiceBenchModel(
        name: "kitten-nano-0.8-int8",
        url: URL(string: "https://huggingface.co/KittenML/kitten-tts-nano-0.8-int8/resolve/84781d74e29ee25217551556398b42f80593a813/kitten_tts_nano_v0_8.onnx")!,
        sha256: "f7b0afcbee92870b32b8e0276d855b954dc25470c9f051b376ac7eee537c76fc",
        bytes: 24_369_971
    )

    /// Bundled copy (add `<name>.onnx` to the app's resources), else the downloaded one.
    var localURL: URL {
        Bundle.main.url(forResource: name, withExtension: "onnx")
            ?? URL.applicationSupportDirectory.appending(path: "VoiceBench/\(name).onnx")
    }

    var isPresent: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    func ensureDownloaded() async throws {
        if isPresent { return }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceBenchError.badDownload("\(name): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw VoiceBenchError.badDownload("\(name): checksum mismatch") }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tmp, to: localURL)
    }
}

// MARK: - Engines

/// KittenTTS nano 0.8 from pre-tokenized ids and style rows (no phonemizer on device).
enum KittenBench {
    static let sampleRate = 24_000.0
    static let tailTrim = 5_000

    static func run(model: VoiceBenchModel, threads: Int32, inputs: VoiceBenchInputs) throws -> VoiceBenchEngineResult {
        let loadStart = Date()
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        if threads > 0 { try options.setIntraOpNumThreads(threads) }
        try options.setGraphOptimizationLevel(.all)
        let session = try ORTSession(env: env, modelPath: model.localURL.path, sessionOptions: options)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        var peak = VoiceBenchDevice.footprintMB()

        func synth(_ chunk: VoiceBenchInputs.KittenChunk) throws -> Int {
            var ids = chunk.inputIds
            var style = chunk.style
            var speed = inputs.kitten.speed
            let idsValue = try ORTValue(
                tensorData: NSMutableData(bytes: &ids, length: ids.count * MemoryLayout<Int64>.size),
                elementType: .int64, shape: [1, NSNumber(value: ids.count)])
            let styleValue = try ORTValue(
                tensorData: NSMutableData(bytes: &style, length: style.count * MemoryLayout<Float>.size),
                elementType: .float, shape: [1, NSNumber(value: style.count)])
            let speedValue = try ORTValue(
                tensorData: NSMutableData(bytes: &speed, length: MemoryLayout<Float>.size),
                elementType: .float, shape: [1])
            let out = try session.run(
                withInputs: ["input_ids": idsValue, "style": styleValue, "speed": speedValue],
                outputNames: ["waveform"], runOptions: nil)
            guard let wave = out["waveform"] else { throw VoiceBenchError.missingOutput("waveform") }
            let samples = try wave.tensorData().length / MemoryLayout<Float>.size
            peak = max(peak, VoiceBenchDevice.footprintMB())
            return max(0, samples - tailTrim)
        }

        // Warm up on the shortest chunk so graph setup isn't counted as listening time.
        if let warm = inputs.kitten.passages.values.flatMap({ $0 }).min(by: { $0.inputIds.count < $1.inputIds.count }) {
            _ = try synth(warm)
        }

        var passages: [VoiceBenchPassageResult] = []
        for id in inputs.passageOrder {
            let chunks = inputs.kitten.passages[id] ?? []
            let start = Date()
            var first: Double?
            var samples = 0
            for (i, chunk) in chunks.enumerated() {
                samples += try synth(chunk)
                if first == nil { first = Date().timeIntervalSince(start) }
                if i > 0 { samples += Int(0.25 * sampleRate) } // same 0.25 s gap as the harness
            }
            passages.append(VoiceBenchPassageResult(
                passage: id, chunks: chunks.count, timeToFirstAudioSeconds: first ?? 0,
                renderSeconds: Date().timeIntervalSince(start), audioSeconds: Double(samples) / sampleRate))
        }
        return VoiceBenchEngineResult(
            engine: model.name, threads: threads > 0 ? "\(threads)" : "default",
            loadSeconds: loadSeconds, passages: passages, peakFootprintMB: peak)
    }
}

/// Supertonic 3 INT8, voice M2, 8 steps, through SessionKitSupertonic's renderer (reference: today's voice).
/// The VoiceBench app bundles App/SpokenMarginsApp/Resources/Supertonic as a folder named "Supertonic".
enum SupertonicBench {
    static func run(inputs: VoiceBenchInputs) async throws -> VoiceBenchEngineResult {
        guard let root = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
            throw SupertonicNarrationError.missingAsset("Supertonic")
        }
        let out = URL.cachesDirectory.appending(path: "VoiceBench/Supertonic", directoryHint: .isDirectory)
        let renderer = try SupertonicNarrationRenderer(assets: SupertonicAssetLocation(rootURL: root), outputDirectory: out)
        let loadStart = Date()
        let warm = try await renderer.render(text: "Warm up.", voice: .m2, speed: 1.0, synthesisSteps: 8)
        await renderer.discardGeneratedAudio(at: warm.audioURL)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        var peak = VoiceBenchDevice.footprintMB()

        var passages: [VoiceBenchPassageResult] = []
        for id in inputs.passageOrder {
            let chunks = inputs.supertonic.passages[id] ?? []
            let start = Date()
            var first: Double?
            var audio = 0.0
            for (i, chunk) in chunks.enumerated() {
                let r = try await renderer.render(text: chunk, voice: .m2, speed: 1.0, synthesisSteps: 8)
                if first == nil { first = Date().timeIntervalSince(start) }
                audio += r.duration + (i > 0 ? 0.25 : 0)
                peak = max(peak, VoiceBenchDevice.footprintMB())
                await renderer.discardGeneratedAudio(at: r.audioURL)
            }
            passages.append(VoiceBenchPassageResult(
                passage: id, chunks: chunks.count, timeToFirstAudioSeconds: first ?? 0,
                renderSeconds: Date().timeIntervalSince(start), audioSeconds: audio))
        }
        await renderer.unload()
        return VoiceBenchEngineResult(engine: "supertonic3-int8-M2-8step", threads: "app default",
                                      loadSeconds: loadSeconds, passages: passages, peakFootprintMB: peak)
    }
}

/// Samantha through AVSpeechSynthesizer.write, rendering offline (reference: today's fallback).
enum SamanthaBench {
    private final class Collector: @unchecked Sendable {
        let synthesizer = AVSpeechSynthesizer()
        var frames: AVAudioFrameCount = 0
        var sampleRate = 22_050.0
        var firstBufferAt: Date?
    }

    static func speak(_ text: String) async -> (seconds: Double, firstAt: Date?) {
        let c = Collector()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var finished = false
            c.synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !finished { finished = true; cont.resume() }
                    return
                }
                if c.firstBufferAt == nil { c.firstBufferAt = Date() }
                c.sampleRate = pcm.format.sampleRate
                c.frames += pcm.frameLength
            }
        }
        return (Double(c.frames) / c.sampleRate, c.firstBufferAt)
    }

    static func run(inputs: VoiceBenchInputs) async -> VoiceBenchEngineResult {
        _ = await speak("Warm up.")
        var passages: [VoiceBenchPassageResult] = []
        for id in inputs.passageOrder {
            let chunks = inputs.supertonic.passages[id] ?? []
            let start = Date()
            var first: Double?
            var audio = 0.0
            for (i, chunk) in chunks.enumerated() {
                let r = await speak(chunk)
                if first == nil, let at = r.firstAt { first = at.timeIntervalSince(start) }
                audio += r.seconds + (i > 0 ? 0.25 : 0)
            }
            passages.append(VoiceBenchPassageResult(
                passage: id, chunks: chunks.count, timeToFirstAudioSeconds: first ?? 0,
                renderSeconds: Date().timeIntervalSince(start), audioSeconds: audio))
        }
        return VoiceBenchEngineResult(engine: "samantha", threads: "system", loadSeconds: 0,
                                      passages: passages, peakFootprintMB: VoiceBenchDevice.footprintMB())
    }
}

// MARK: - Whole run

enum VoiceBench {
    static func runAll(progress: @Sendable (String) async -> Void) async -> VoiceBenchReport {
        let inputs = VoiceBenchInputs.bundled
        var report = VoiceBenchReport(
            date: Date(), device: VoiceBenchDevice.model,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            lowPowerModeAtStart: ProcessInfo.processInfo.isLowPowerModeEnabled, lowPowerModeAtEnd: false,
            thermalStateAtStart: VoiceBenchDevice.thermal, thermalStateAtEnd: "", engines: [])

        func failed(_ name: String, _ error: Error) -> VoiceBenchEngineResult {
            VoiceBenchEngineResult(engine: name, threads: "-", loadSeconds: 0, passages: [],
                                   peakFootprintMB: VoiceBenchDevice.footprintMB(), error: error.localizedDescription)
        }

        // Kitten first: it's the chosen fallback and the result that matters.
        for (model, threads) in [(VoiceBenchModel.kittenFP32, Int32(1)), (.kittenFP32, 2), (.kittenINT8, 1)] {
            await progress("Kitten \(model.name), \(threads) thread(s)…")
            do {
                try await model.ensureDownloaded()
                report.engines.append(try KittenBench.run(model: model, threads: threads, inputs: inputs))
            } catch {
                report.engines.append(failed(model.name, error))
            }
        }
        await progress("Supertonic (today's voice)…")
        do { report.engines.append(try await SupertonicBench.run(inputs: inputs)) }
        catch { report.engines.append(failed("supertonic3-int8-M2-8step", error)) }
        await progress("Samantha…")
        report.engines.append(await SamanthaBench.run(inputs: inputs))

        report.lowPowerModeAtEnd = ProcessInfo.processInfo.isLowPowerModeEnabled
        report.thermalStateAtEnd = VoiceBenchDevice.thermal
        return report
    }

    static func save(_ report: VoiceBenchReport) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let stamp = ISO8601DateFormatter().string(from: report.date).replacingOccurrences(of: ":", with: "-")
        let url = URL.documentsDirectory.appending(path: "voice-bench-\(stamp).json")
        try encoder.encode(report).write(to: url)
        return url
    }
}
