import AVFoundation
import Foundation
import OnnxRuntimeBindings
import XCTest
@testable import SessionKitPocket

/// Tests of the Pocket TTS renderer (#459). The first group needs no downloads. The rest read the
/// weights `research/C2/pocket/fetch_weights.sh` fetches (or the folder in `POCKET_TTS_MODEL_DIR`)
/// and say "skipped: weights not fetched" when they aren't there.
final class PocketRendererTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static var weightsFolder: URL {
        if let override = ProcessInfo.processInfo.environment["POCKET_TTS_MODEL_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repoRoot.appending(path: "research/C2/models/pocket", directoryHint: .isDirectory)
    }

    private func fetchedWeights() throws -> PocketAssetLocation {
        let assets = PocketAssetLocation(rootURL: Self.weightsFolder)
        guard (try? assets.validate()) != nil else { throw XCTSkip("skipped: weights not fetched") }
        return assets
    }

    private struct Golden: Decodable {
        struct Tokens: Decodable { var text: String; var ids: [Int] }
        struct Chunk: Decodable { var text: String; var guess: Int; var ids: [Int] }
        struct Split: Decodable { var input: String; var chunks: [Chunk] }
        struct Tiny: Decodable {
            struct Encoding: Decodable { var text: String; var ids: [Int]; var decoded: String }
            var modelBase64: String
            var encodings: [Encoding]
            enum CodingKeys: String, CodingKey { case modelBase64 = "model_base64", encodings }
        }
        var tokens: [Tokens]
        var chunks: [Split]
        var tiny: Tiny
    }

    private func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/pocket-tokenizer-golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    // MARK: Without weights

    // The Viterbi tie-break, byte fallback and unknown-character rules, against Python sentencepiece
    // on a 270-piece model built to have ties.
    func testUnigramEncodingMatchesSentencePieceOnATinyModelWithTies() throws {
        let tiny = try golden().tiny
        let tokenizer = try PocketSentencePiece(modelData: try XCTUnwrap(Data(base64Encoded: tiny.modelBase64)))
        for case_ in tiny.encodings {
            XCTAssertEqual(tokenizer.encode(case_.text), case_.ids, "encode \(case_.text.debugDescription)")
            XCTAssertEqual(tokenizer.decode(case_.ids), case_.decoded, "decode \(case_.text.debugDescription)")
        }
    }

    func testSafetensorsReaderReadsNamedTensorsAndModuleState() throws {
        let floats: [Float] = [1, 2, 3, 4, 5, 6]
        let header = #"{"m.a/cache":{"dtype":"F32","shape":[2,3],"data_offsets":[0,24]},"m.a/offset":{"dtype":"I64","shape":[1],"data_offsets":[24,32]},"__metadata__":{}}"#
        var file = Data()
        withUnsafeBytes(of: UInt64(header.utf8.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(Data(header.utf8))
        file.append(floats.withUnsafeBytes { Data($0) })
        file.append([Int64(6)].withUnsafeBytes { Data($0) })

        let state = try PocketSafetensors(data: file).moduleState("m.a")
        XCTAssertEqual(Set(state.keys), ["cache", "offset"])
        XCTAssertEqual(state["cache"]?.shape, [2, 3])
        XCTAssertEqual(state["cache"]?.data, floats.withUnsafeBytes { Data($0) })
        XCTAssertEqual(PocketSafetensors.ReadError.malformed("tensor bad"), PocketSafetensors.ReadError.malformed("tensor bad"))
        XCTAssertThrowsError(try PocketSafetensors(data: file.dropLast(4)), "a truncated file is refused")
    }

    // The saved voice cache holds 126 steps and the network's holds 1,000; the rest stays NaN.
    func testSavedCacheIsPlacedInTheCornerOfTheLargerNaNCache() {
        let saved = PocketTensor(dtype: .float32, shape: [2, 1, 2, 3], data: (1...12).map(Float.init).withUnsafeBytes { Data($0) })
        let placed = saved.placed(intoShape: [2, 1, 4, 3], fill: .nan)
        let values = placed.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(Array(values[0..<6]), [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(values[6..<12].allSatisfy(\.isNaN))
        XCTAssertEqual(Array(values[12..<18]), [7, 8, 9, 10, 11, 12])
        XCTAssertTrue(values[18..<24].allSatisfy(\.isNaN))
    }

    // The bindings can't build a boolean tensor, so the decoder's "first" flags come from a model.
    func testBooleanConstantModelGivesATrueTensor() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pocket-bool-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "true.onnx")
        try Data(PocketBoolModel.trueConstantModel).write(to: url)
        let session = try ORTSession(env: try ORTEnv(loggingLevel: .warning), modelPath: url.path, sessionOptions: nil)
        let flag = try XCTUnwrap(try session.run(withInputs: [:], outputNames: ["flag"], runOptions: nil)["flag"])
        // The bindings can't read a boolean tensor back, so this checks the model ran and made a value.
        // The render tests below feed it to the decoder, which refuses anything but a true boolean.
        XCTAssertNotNil(flag)
    }

    // MARK: With the downloaded weights

    func testTokenizerAndSplitterMatchPythonOnTheExportsFiles() throws {
        let assets = try fetchedWeights()
        let golden = try golden()
        let tokenizer = try PocketSentencePiece(contentsOf: assets.url("tokenizer.model"))
        for case_ in golden.tokens {
            XCTAssertEqual(tokenizer.encode(case_.text), case_.ids, "encode \(case_.text.debugDescription)")
        }
        let preparation = PocketTextPreparation(tokenizer: tokenizer, maxTokensPerChunk: 50)
        for split in golden.chunks {
            let chunks = preparation.chunks(for: split.input)
            XCTAssertEqual(chunks.map(\.text), split.chunks.map(\.text), "chunks of \(split.input.debugDescription)")
            XCTAssertEqual(chunks.map(\.tokenIDs), split.chunks.map(\.ids))
            XCTAssertEqual(chunks.map(\.framesAfterEnd), split.chunks.map { $0.guess + 2 })
        }
    }

    func testRendersAndRefusesEmptyAndCancelledText() async throws {
        let assets = try fetchedWeights()
        let output = FileManager.default.temporaryDirectory.appending(path: "pocket-small-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let renderer = try PocketNarrationRenderer(assets: assets, outputDirectory: output, noiseSeed: 1)

        do {
            _ = try await renderer.render(text: "  \n ")
            XCTFail("empty text should throw")
        } catch { XCTAssertEqual(error as? PocketNarrationError, .emptyText) }

        // Cancel while frames are being made, so the per-frame check and the handler run.
        try await renderer.preload()
        let task = Task { try await renderer.render(text: "This sentence will be cancelled before it finishes. It is long enough that the model is still working when the cancel arrives.") }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled render should throw") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }

        let result = try await renderer.render(text: "Hello from the narrator.")
        let file = try AVAudioFile(forReading: result.audioURL)
        XCTAssertEqual(file.processingFormat.sampleRate, 24_000)
        XCTAssertEqual(Double(file.length) / 24_000, result.duration, accuracy: 0.01)
        XCTAssertTrue((1.0...6.0).contains(result.duration), "duration \(result.duration)")
        XCTAssertEqual(result.sessionLoadCount, 1)
        await renderer.discardGeneratedAudio(at: result.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.audioURL.path))
    }

    private struct PassageRender {
        var id: String
        var audioURL: URL
        var duration: Double
        var renderSeconds: Double
    }

    private static let renders = PassageRenders()

    private actor PassageRenders {
        var cached: (load: Double, renders: [PassageRender])?

        func get(assets: PocketAssetLocation) async throws -> (load: Double, renders: [PassageRender]) {
            if let cached { return cached }
            let directory = PocketRendererTests.repoRoot.appending(path: "artifacts/pocket", directoryHint: .isDirectory)
            let renderer = try PocketNarrationRenderer(assets: assets, outputDirectory: directory, threads: 1, noiseSeed: 20_261_014)
            let load = try await renderer.preload()
            struct File: Decodable { struct Passage: Decodable { var id: String; var text: String }; var passages: [Passage] }
            let passages = try JSONDecoder().decode(File.self, from: Data(contentsOf: PocketRendererTests.repoRoot.appending(path: "research/C2/passages.json"))).passages
            var renders: [PassageRender] = []
            for passage in passages {
                let result = try await renderer.render(text: passage.text)
                renders.append(PassageRender(id: passage.id, audioURL: result.audioURL, duration: result.duration, renderSeconds: result.renderDuration))
            }
            cached = (load, renders)
            return (load, renders)
        }
    }

    private struct Reference: Decodable {
        struct Passage: Decodable { var audio_s: Double; var rtf: Double }
        var passages: [String: Passage]
    }

    // Done when 3: the three C2 passages, real-time factor on one thread. The reference is the
    // PyTorch run on this Mac (research/C2/results/darwin/pocket-alba.t1.json): 0.28 of real time.
    func testRendersTheThreeC2PassagesFasterThanRealTimeOnOneThread() async throws {
        let assets = try fetchedWeights()
        let (load, renders) = try await Self.renders.get(assets: assets)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: Self.repoRoot.appending(path: "research/C2/results/darwin/pocket-alba.t1.json")))
        var totalAudio = 0.0, totalRender = 0.0
        for render in renders {
            let expected = try XCTUnwrap(reference.passages[render.id]).audio_s
            XCTAssertEqual(render.duration, expected, accuracy: expected * 0.35, "\(render.id) audio length against the PyTorch run")
            totalAudio += render.duration
            totalRender += render.renderSeconds
            print("POCKET passage=\(render.id) audio_s=\(String(format: "%.2f", render.duration)) render_s=\(String(format: "%.2f", render.renderSeconds)) rtf=\(String(format: "%.3f", render.renderSeconds / render.duration))")
        }
        let rtf = totalRender / totalAudio
        print("POCKET threads=1 load_s=\(String(format: "%.2f", load)) rtf=\(String(format: "%.3f", rtf)) speed_x=\(String(format: "%.2f", 1 / rtf))")
        XCTAssertLessThan(rtf, 1.0, "slower than real time on one thread: rtf \(rtf)")
    }

    // Done when 3: whisper word error on the prose passages, within 2 points of the PyTorch run.
    func testProsePassagesAreSpokenWithinTwoPointsOfThePyTorchWordError() async throws {
        let assets = try fetchedWeights()
        let environment = ProcessInfo.processInfo.environment
        let python = environment["POCKET_TTS_PYTHON"] ?? Self.repoRoot.appending(path: "research/C2/.venv/bin/python").path
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("skipped: no python with faster-whisper (set POCKET_TTS_PYTHON)")
        }
        let (_, renders) = try await Self.renders.get(assets: assets)
        let clips = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: renders.map { ($0.id, $0.audioURL.path) }))
        let clipsURL = Self.repoRoot.appending(path: "artifacts/pocket/clips.json")
        try clips.write(to: clipsURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", Self.repoRoot.appending(path: "research/C2/pocket/wer.py").path,
                             Self.repoRoot.appending(path: "research/C2/passages.json").path, clipsURL.path]
        let output = Pipe()
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "wer.py failed (faster-whisper and jiwer installed? try pip install 'av<16'): \(errorText.suffix(600))")
        guard process.terminationStatus == 0 else { return }

        struct Score: Decodable { var wer: Double; var heard: String }
        let scores = try JSONDecoder().decode([String: Score].self, from: data)
        struct Reference: Decodable { var wer: Double }
        let reference = try JSONDecoder().decode([String: [String: Reference]].self, from: Data(contentsOf: Self.repoRoot.appending(path: "research/C2/results/darwin/intelligibility.json")))["pocket-alba"] ?? [:]
        for (id, score) in scores.sorted(by: { $0.key < $1.key }) {
            print("POCKET wer \(id)=\(score.wer) reference=\(reference[id]?.wer ?? -1)")
        }
        for id in ["p1-narrative", "p3-conversational"] {
            let score = try XCTUnwrap(scores[id]), expected = try XCTUnwrap(reference[id])
            XCTAssertLessThanOrEqual(score.wer, expected.wer + 0.02, "\(id) heard: \(score.heard)")
        }
    }
}
