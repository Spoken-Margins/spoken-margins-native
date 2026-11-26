import AVFoundation
import Foundation
import Speech
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #4779 PR 0: does Apple's on-device transcriber write fillers ("um", "uh") down, with times? Run only by hand.
///
/// The audio is the AMI Meeting Corpus (CC BY 4.0, https://groups.inf.ed.ac.uk/ami/corpus/license.shtml), individual
/// headset channels, with the corpus's word-level manual annotations, which mark fillers with times. Nothing is in the
/// repository and nothing is downloaded here. Fetch into `artifacts/ami/` (git-ignored):
///
///     mkdir -p artifacts/ami/audio && cd artifacts/ami
///     curl -fLO https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip
///     unzip -q ami_public_manual_1.6.2.zip 'words/ES2002*' corpusResources/meetings.xml
///     curl -fL -o audio/ES2002b.Headset-1.wav https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2002b/audio/ES2002b.Headset-1.wav
///     (likewise ES2002b.Headset-3.wav and ES2002a.Headset-1.wav; the mirror answers 503 now and then, so retry)
///
/// Then run:
///
///     SPOKEN_MARGINS_FILLER_PROBE_AMI=$PWD/artifacts/ami swift test --package-path Packages/SessionKit \
///         --filter FillerTranscriptionProbeTests
///
/// Transcripts are cached in `artifacts/ami/out/`, and the table is written to `artifacts/ami/out/report.md`.
/// It runs on the Mac's speech engines: a Mac result stands in for an iPhone without being proven equal.
final class FillerTranscriptionProbeTests: XCTestCase {
    struct Token: Codable {
        var text: String
        var startMs: Int
        var endMs: Int
        var span: Range<Int> { startMs..<max(startMs + 1, endMs) }
    }

    struct Label {
        var text: String
        var startMs: Int
        var endMs: Int
        var isFiller: Bool
        var span: Range<Int> { startMs..<endMs }
    }

    struct Row {
        var engine: String
        var labelled = 0
        var found = 0
        var returnedFillers = 0
        var falseFillers = 0
        var unlabelledFillers = 0
        var realWords = 0
        var realWordsCutByFillerSpans = 0
        var fillersInsideFullCut = 0
        var realWordsCutByFullCut = 0
        var ruleBFound = 0
        var ruleBRealWordsCut = 0
        var wallSeconds = 0.0
        var audioSeconds = 0.0
        var note = ""
    }

    func testFillerTranscriptionProbe() async throws {
        guard let root = ProcessInfo.processInfo.environment["SPOKEN_MARGINS_FILLER_PROBE_AMI"] else {
            throw XCTSkip("set SPOKEN_MARGINS_FILLER_PROBE_AMI to the AMI folder to run the filler probe (#4779)")
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let ami = URL(fileURLWithPath: root)
        let audioDir = ami.appendingPathComponent("audio")
        let out = ami.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let meetings = (try? String(contentsOf: ami.appendingPathComponent("corpusResources/meetings.xml"), encoding: .utf8)) ?? ""
        let clips = ((try? FileManager.default.contentsOfDirectory(atPath: audioDir.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        guard !clips.isEmpty, !meetings.isEmpty else { throw XCTSkip("no AMI audio or meetings.xml under \(root)") }
        guard await longFormSpeechTranscriptionIsSupported() else { throw XCTSkip("SpeechTranscriber unavailable on this Mac") }

        var totals: [String: Row] = [:]
        var perClip: [String] = []
        for clip in clips {
            let parts = clip.replacingOccurrences(of: ".wav", with: "").components(separatedBy: ".Headset-")
            guard parts.count == 2, let agent = Self.agent(meeting: parts[0], channel: parts[1], in: meetings) else { continue }
            let wordsURL = ami.appendingPathComponent("words/\(parts[0]).\(agent).words.xml")
            guard let xml = try? String(contentsOf: wordsURL, encoding: .isoLatin1) else { continue }
            let labels = Self.labels(fromAMI: xml)
            let url = audioDir.appendingPathComponent(clip)
            let silent = try SpokenNoteSilentFlags.read(url: url)
            for engine in Self.engines {
                let cache = out.appendingPathComponent("\(clip).\(engine).json")
                var tokens: [Token]
                var wall = 0.0
                if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode([Token].self, from: data) {
                    tokens = cached
                } else {
                    let started = Date()
                    do {
                        tokens = try await Self.transcribe(url: url, engine: engine)
                    } catch {
                        var row = totals[engine] ?? Row(engine: engine)
                        row.note = "not run: \(error)"
                        totals[engine] = row
                        continue
                    }
                    wall = Date().timeIntervalSince(started)
                    try JSONEncoder().encode(tokens).write(to: cache)
                }
                let row = Self.score(engine: engine, labels: labels, tokens: tokens, silent: silent)
                perClip.append("| \(clip) | \(engine) | \(row.labelled) | \(row.found) | \(row.returnedFillers) | \(row.falseFillers) | \(row.ruleBFound) | \(row.ruleBRealWordsCut) |")
                var total = totals[engine] ?? Row(engine: engine)
                total.labelled += row.labelled
                total.found += row.found
                total.returnedFillers += row.returnedFillers
                total.falseFillers += row.falseFillers
                total.unlabelledFillers += row.unlabelledFillers
                total.realWords += row.realWords
                total.realWordsCutByFillerSpans += row.realWordsCutByFillerSpans
                total.fillersInsideFullCut += row.fillersInsideFullCut
                total.realWordsCutByFullCut += row.realWordsCutByFullCut
                total.ruleBFound += row.ruleBFound
                total.ruleBRealWordsCut += row.ruleBRealWordsCut
                total.wallSeconds += wall
                total.audioSeconds += Double(silent.durationMs) / 1000
                totals[engine] = total
            }
        }

        var report = "| Engine | Labelled fillers | Found | Recall | Returned fillers | False fillers | False share | Unlabelled fillers | Real words | Real words cut (filler spans) | Fillers inside full cut | Real words cut (full cut) | Rule B found | Rule B real words cut | Speed (audio s / wall s) | Note |\n"
        report += "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
        for engine in Self.engines {
            guard let r = totals[engine] else { continue }
            let recall = r.labelled > 0 ? Double(r.found) / Double(r.labelled) : 0
            let falseShare = r.returnedFillers > 0 ? Double(r.falseFillers) / Double(r.returnedFillers) : 0
            let speed = r.wallSeconds > 0 ? String(format: "%.0f", r.audioSeconds / r.wallSeconds) : "cached"
            report += "| \(engine) | \(r.labelled) | \(r.found) | \(String(format: "%.1f%%", recall * 100)) | \(r.returnedFillers) | \(r.falseFillers) | \(String(format: "%.1f%%", falseShare * 100)) | \(r.unlabelledFillers) | \(r.realWords) | \(r.realWordsCutByFillerSpans) | \(r.fillersInsideFullCut) | \(r.realWordsCutByFullCut) | \(r.ruleBFound) | \(r.ruleBRealWordsCut) | \(speed) | \(r.note) |\n"
        }
        report += "\nPer clip:\n\n| Clip | Engine | Labelled | Found | Returned | False | Rule B found | Rule B real cut |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n"
        report += perClip.joined(separator: "\n") + "\n"
        try report.write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print(report)
    }

    // MARK: - Labels

    static func agent(meeting: String, channel: String, in meetings: String) -> String? {
        guard let block = meetings.range(of: "observation=\"\(meeting)\"") else { return nil }
        let rest = meetings[block.upperBound...]
        let end = rest.range(of: "</meeting>")?.lowerBound ?? rest.endIndex
        for line in rest[..<end].components(separatedBy: "\n") where line.contains("channel=\"\(channel)\"") {
            if let r = line.range(of: "nxt_agent=\"") { return String(line[r.upperBound...].prefix(1)) }
        }
        return nil
    }

    static func labels(fromAMI xml: String) -> [Label] {
        let pattern = try! NSRegularExpression(pattern: "<w ([^>]*)>([^<]*)</w>")
        let ns = xml as NSString
        var labels: [Label] = []
        for match in pattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let attributes = ns.substring(with: match.range(at: 1))
            guard !attributes.contains("punc=\"true\""),
                  let start = attribute("starttime", in: attributes), let end = attribute("endtime", in: attributes) else { continue }
            let text = ns.substring(with: match.range(at: 2)).replacingOccurrences(of: "&#39;", with: "'")
            let startMs = Int((start * 1000).rounded()), endMs = Int((end * 1000).rounded())
            guard endMs > startMs else { continue }
            labels.append(Label(text: text, startMs: startMs, endMs: endMs, isFiller: SpokenNoteCleanPolicy.isFiller(text)))
        }
        return labels
    }

    static func attribute(_ name: String, in attributes: String) -> Double? {
        guard let r = attributes.range(of: "\(name)=\"") else { return nil }
        return Double(attributes[r.upperBound...].prefix { $0 != "\"" })
    }

    // MARK: - Engines

    /// "SpeechTranscriber 60s" is the same engine on silence-aware stretches of at most 60 s, as the issue's word pass
    /// would have run it: spoken-note takes are minutes long, not a 38-minute file. It finds no more fillers.
    static let engines = ["SpeechTranscriber", "SpeechTranscriber 60s", "DictationTranscriber", "SFSpeechRecognizer"]

    @available(macOS 26.0, *)
    static func transcribe(url: URL, engine: String) async throws -> [Token] {
        switch engine {
        case "SpeechTranscriber":
            return try await transcribeLongFormSpeechFile(at: url).flatMap(\.timedText).map {
                Token(text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
            }
        case "SpeechTranscriber 60s":
            return try await chunked(url: url)
        case "DictationTranscriber":
            return try await dictation(url: url)
        default:
            return try await legacy(url: url)
        }
    }

    @available(macOS 26.0, *)
    static func chunked(url: URL) async throws -> [Token] {
        let asset = AVURLAsset(url: url)
        let durationMs = Int((try await asset.load(.duration).seconds * 1000).rounded())
        let ranges = silenceAwareSpeechAudioChunkRanges(
            durationMs: durationMs, silenceRanges: (try? sustainedSilenceRanges(in: url)) ?? [],
            preferredChunkMs: 50_000, maximumChunkMs: 60_000
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("filler-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var tokens: [Token] = []
        for (index, range) in ranges.enumerated() {
            let chunk = directory.appendingPathComponent("chunk-\(index).m4a")
            let exporter = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
            exporter.timeRange = CMTimeRange(
                start: CMTime(value: CMTimeValue(range.startMs), timescale: 1000), duration: CMTime(value: CMTimeValue(range.lengthMs), timescale: 1000)
            )
            try await exporter.export(to: chunk, as: .m4a)
            guard let passages = try? await transcribeLongFormSpeechFile(at: chunk) else { continue }
            tokens += passages.flatMap(\.timedText).map {
                Token(text: $0.text, startMs: $0.startMs + range.startMs, endMs: $0.endMs + range.startMs)
            }
        }
        return tokens
    }

    @available(macOS 26.0, *)
    static func dictation(url: URL) async throws -> [Token] {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw SessionKitError.persistenceFailed("dictation_locale_unsupported")
        }
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected: [Token] = {
            var tokens: [Token] = []
            for try await result in transcriber.results where result.isFinal {
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, let range = run.audioTimeRange else { continue }
                    let start = Int((range.start.seconds * 1000).rounded())
                    tokens.append(Token(text: text, startMs: start, endMs: start + max(1, Int((range.duration.seconds * 1000).rounded()))))
                }
            }
            return tokens
        }()
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    /// The legacy recognizer, on-device, in 40 s pieces (it refuses long files). Needs speech authorization, which a
    /// host test process can't ask for; it reports "not run" then.
    static func legacy(url: URL) async throws -> [Token] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SessionKitError.persistenceFailed("speech authorization is \(SFSpeechRecognizer.authorizationStatus().rawValue) in this process (needs a usage description and a prompt)")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else {
            throw SessionKitError.persistenceFailed("on-device recognizer unavailable")
        }
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let pieceFrames = AVAudioFrameCount(format.sampleRate * 40)
        var tokens: [Token] = []
        var offset = 0
        while source.framePosition < source.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: pieceFrames)!
            try source.read(into: buffer, frameCount: pieceFrames)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.append(buffer)
            request.endAudio()
            let base = offset
            let piece: [Token] = try await withCheckedThrowingContinuation { continuation in
                var done = false
                recognizer.recognitionTask(with: request) { result, error in
                    guard !done else { return }
                    if let result, result.isFinal {
                        done = true
                        continuation.resume(returning: result.bestTranscription.segments.map { segment in
                            let start = base + Int((segment.timestamp * 1000).rounded())
                            return Token(text: segment.substring, startMs: start, endMs: start + max(1, Int((segment.duration * 1000).rounded())))
                        })
                    } else if let error { done = true; continuation.resume(throwing: error) }
                }
            }
            tokens += piece
            offset += Int(Double(buffer.frameLength) / format.sampleRate * 1000)
        }
        return tokens
    }

    // MARK: - Scoring

    static func overlap(_ a: Range<Int>, _ b: Range<Int>) -> Int {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    /// How much of `span` the merged, sorted `ranges` cover.
    static func covered(_ span: Range<Int>, by ranges: [Range<Int>]) -> Int {
        var low = 0, high = ranges.count
        while low < high { let mid = (low + high) / 2; if ranges[mid].upperBound <= span.lowerBound { low = mid + 1 } else { high = mid } }
        var total = 0
        var index = low
        while index < ranges.count, ranges[index].lowerBound < span.upperBound {
            total += overlap(span, ranges[index])
            index += 1
        }
        return total
    }

    static func score(engine: String, labels: [Label], tokens: [Token], silent: SpokenNoteSilentFlags.Result) -> Row {
        var row = Row(engine: engine)
        let fillers = labels.filter(\.isFiller)
        let real = labels.filter { !$0.isFiller }
        row.labelled = fillers.count
        row.realWords = real.count
        let returned = tokens.filter { SpokenNoteCleanPolicy.isFiller($0.text) }
        row.returnedFillers = returned.count
        let returnedSpans = SpokenNoteTakeCut.mergeRanges(returned.map(\.span))
        row.found = fillers.filter { covered($0.span, by: returnedSpans) * 2 >= $0.span.count }.count
        let fillerSpans = SpokenNoteTakeCut.mergeRanges(fillers.map(\.span))
        let realSpans = SpokenNoteTakeCut.mergeRanges(real.map(\.span))
        for token in returned where covered(token.span, by: fillerSpans) == 0 {
            if covered(token.span, by: realSpans) * 2 >= token.span.count { row.falseFillers += 1 } else { row.unlabelledFillers += 1 }
        }
        let words = tokens.map { SpokenNoteTimedWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs) }
        let policySpans = SpokenNoteTakeCut.mergeRanges(SpokenNoteCleanPolicy.fillerSpans(in: words))
        row.realWordsCutByFillerSpans = real.filter { covered($0.span, by: policySpans) * 2 >= $0.span.count }.count

        let cut = SpokenNoteTakeCut.make(words: words, silentFlags: silent.flags, durationMs: silent.durationMs)
        var removed: [Range<Int>] = []
        var cursor = 0
        for span in cut.kept { if span.startMs > cursor { removed.append(cursor..<span.startMs) }; cursor = span.endMs }
        if cursor < silent.durationMs { removed.append(cursor..<silent.durationMs) }
        row.fillersInsideFullCut = fillers.filter { covered($0.span, by: removed) * 2 >= $0.span.count }.count
        row.realWordsCutByFullCut = real.filter { covered($0.span, by: removed) * 2 >= $0.span.count }.count

        let ruleB = ruleBRanges(words: words.filter { !SpokenNoteCleanPolicy.isFiller($0.text) }, flags: silent.flags)
        row.ruleBFound = fillers.filter { covered($0.span, by: ruleB) * 2 >= $0.span.count }.count
        row.ruleBRealWordsCut = real.filter { covered($0.span, by: ruleB) * 2 >= $0.span.count }.count
        return row
    }

    /// Rule B: every untranscribed voiced run 150 to 900 ms long that sits between two transcribed words and touches a
    /// quiet run of at least 250 ms.
    static func ruleBRanges(words: [SpokenNoteTimedWord], flags: [Bool], windowMs: Int = 20) -> [Range<Int>] {
        var runs: [(quiet: Bool, span: Range<Int>)] = []
        var start = 0
        for index in 1...flags.count where index == flags.count || flags[index] != flags[start] {
            runs.append((flags[start], (start * windowMs)..<(index * windowMs)))
            start = index
        }
        let sorted = words.sorted { $0.startMs < $1.startMs }
        var ranges: [Range<Int>] = []
        for (index, run) in runs.enumerated() where !run.quiet && (150...900).contains(run.span.count) {
            let touchesQuiet = (index > 0 && runs[index - 1].span.count >= 250) || (index + 1 < runs.count && runs[index + 1].span.count >= 250)
            guard touchesQuiet else { continue }
            // Between two transcribed words: a word ends at or before it starts, the next word starts at or after it ends,
            // and no word overlaps it.
            var low = 0, high = sorted.count
            while low < high { let mid = (low + high) / 2; if sorted[mid].endMs <= run.span.lowerBound { low = mid + 1 } else { high = mid } }
            guard low > 0, low < sorted.count, sorted[low].startMs >= run.span.upperBound else { continue }
            ranges.append(run.span)
        }
        return ranges
    }
}
