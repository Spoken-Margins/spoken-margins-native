// c1-extract: runs the app's PDF extractor over the C1 corpus.
//
//   swift run -c release c1-extract --root <repo>/research/C1 [--v2] [--only <id> ...]
//
// --v2 scores extraction v2 (I13 roles, C1 M3) as extractor `app-v2`:
// `markdown` is the structured document's canonical text (Item.text for a v2
// import), `spoken` is StructuredDocumentSpeech.spokenLines (I14 applied, then
// SpeechTextNormalizer), and the I13 document goes to cache/i13-app-v2/.
// It also times v1 on the same PDF right before v2, so the import-time budget
// is a per-paper ratio that other work on the Mac affects on both sides. v1's
// time includes normalizeImportedText on each line, which the import's
// Markdown parser runs after extraction (the parser does more than that, so
// the ratio can only overstate v2's cost). v2 does that cleaning in the builder.
//
// For each manifest entry with a fetched PDF (cache/pdf/<id>.pdf) it writes
// cache/candidates/app-baseline/<id>.json in the format tools/score.py reads:
//
//   {"id", "extractor", "markdown", "markdown_sha256", "spoken", "elapsed_ms", "pages", "error"?}
//
// `markdown` is exactly what the app stores on import today
// (PDFStructuredTextExtractor.markdown, the path extractBaseline takes).
// `spoken` is that markdown through SpeechTextNormalizer.normalize, one line
// at a time so the scorer can still see line structure (page furniture is
// detected per line); within a line it is what the speech path receives.

import CryptoKit
import Foundation
import PDFKit

struct Options {
    var root: URL
    var only: Set<String> = []
    var v2 = false
}

func parseOptions() -> Options {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var root: URL?
    var only: Set<String> = []
    var v2 = false
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        switch flag {
        case "--root":
            guard !arguments.isEmpty else { fail("--root needs a path") }
            root = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
        case "--v2":
            v2 = true
        case "--only":
            while let next = arguments.first, !next.hasPrefix("--") {
                only.insert(arguments.removeFirst())
            }
        default:
            fail("unknown argument \(flag)")
        }
    }
    guard let root else { fail("usage: c1-extract --root <repo>/research/C1 [--v2] [--only <id> ...]") }
    return Options(root: root, only: only, v2: v2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

func spokenText(fromMarkdown markdown: String) -> String {
    markdown
        .components(separatedBy: "\n")
        .map { SpeechTextNormalizer.normalize($0) }
        .joined(separator: "\n")
}

func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
}

func write(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    try data.write(to: url, options: .atomic)
}

let options = parseOptions()
let manifestURL = options.root.appendingPathComponent("corpus/manifest.json")
// The app's bundled Kitten lexicon, which the glued-text spacer splits with (#2370).
let wordListURL = options.root.appendingPathComponent("../../App/SpokenMarginsApp/Resources/Kitten/lexicon.tsv").standardizedFileURL
let pdfDirectory = options.root.appendingPathComponent("cache/pdf", isDirectory: true)
let extractorName = options.v2 ? "app-v2" : "app-baseline"
let outDirectory = options.root.appendingPathComponent("cache/candidates/\(extractorName)", isDirectory: true)
let resultsDirectory = options.root.appendingPathComponent("results/\(extractorName)", isDirectory: true)
let i13Directory = options.root.appendingPathComponent("cache/i13-\(extractorName)", isDirectory: true)

guard let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      let entries = manifest["entries"] as? [[String: Any]] else {
    fail("can't read \(manifestURL.path); run from a checkout of ws/c1-pdf")
}
try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
if options.v2 {
    try FileManager.default.createDirectory(at: i13Directory, withIntermediateDirectories: true)
}

let clock = ContinuousClock()
var timings: [Double] = []
var pairedV1Timings: [Double] = []
var pairedRatios: [Double] = []
var extracted = 0
var failed: [String: String] = [:]
var missing: [String] = []
var checksumMismatches: [String] = []

for entry in entries {
    guard let id = entry["id"] as? String else { continue }
    if !options.only.isEmpty && !options.only.contains(id) { continue }
    let pdfURL = pdfDirectory.appendingPathComponent("\(id).pdf")
    guard let data = try? Data(contentsOf: pdfURL) else {
        missing.append(id)
        log("skip \(id): not fetched (run tools/fetch.py)")
        continue
    }
    var record: [String: Any] = [
        "id": id,
        "extractor": extractorName,
        "extractor_commit": AppSourcesVersion.commit,
        "extractor_sha256_prefix": AppSourcesVersion.extractorSHA256Prefix,
    ]
    if let expected = (entry["measured"] as? [String: Any])?["sha256"] as? String {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if actual != expected {
            checksumMismatches.append(id)
            record["sha256_mismatch"] = true
            log("warning \(id): PDF differs from the manifest's sha256; scores may not be comparable")
        }
    }
    autoreleasepool {
        var start = clock.now
        do {
            if options.v2 {
                // Paired timing: v1 then v2 on the same, already-read file.
                _ = PDFDocument(url: pdfURL)?.pageCount
                let v1Start = clock.now
                let v1Markdown = (try? PDFStructuredTextExtractor.markdown(from: pdfURL)) ?? ""
                for line in v1Markdown.components(separatedBy: "\n") {
                    _ = SpeechTextNormalizer.normalizeImportedText(line)
                }
                let v1Elapsed = milliseconds(clock.now - v1Start)
                start = clock.now
                let document = try PDFStructuredTextExtractor.structuredDocument(from: pdfURL, wordListURL: wordListURL)
                let elapsed = milliseconds(clock.now - start)
                timings.append(elapsed)
                pairedV1Timings.append(v1Elapsed)
                if v1Elapsed > 0 { pairedRatios.append(elapsed / v1Elapsed) }
                record["markdown"] = document.text
                record["markdown_sha256"] = document.extraction.textSHA256 ?? ""
                record["extraction_version"] = document.extraction.version
                record["spoken"] = StructuredDocumentSpeech.spokenLines(document).joined(separator: "\n")
                record["elapsed_ms"] = Int(elapsed.rounded())
                record["elapsed_ms_v1_paired"] = Int(v1Elapsed.rounded())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(document).write(to: i13Directory.appendingPathComponent("\(id).json"), options: .atomic)
            } else {
                // The same entry point the import path uses (extractBaseline → markdown).
                let markdown = try PDFStructuredTextExtractor.markdown(from: pdfURL)
                let elapsed = milliseconds(clock.now - start)
                timings.append(elapsed)
                record["markdown"] = markdown
                // I13 rule 1(a): a changed fingerprint without a version bump is a bug.
                record["markdown_sha256"] = SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
                record["spoken"] = spokenText(fromMarkdown: markdown)
                record["elapsed_ms"] = Int(elapsed.rounded())
            }
            extracted += 1
        } catch {
            record["spoken"] = ""
            record["error"] = String(describing: error)
            record["elapsed_ms"] = Int(milliseconds(clock.now - start).rounded())
            failed[id] = String(describing: error)
        }
        record["pages"] = PDFDocument(url: pdfURL)?.pageCount ?? 0
    }
    do {
        try write(record, to: outDirectory.appendingPathComponent("\(id).json"))
    } catch {
        fail("can't write output for \(id): \(error)")
    }
    let words = (record["spoken"] as? String)?.split(whereSeparator: \.isWhitespace).count ?? 0
    log("\(record["error"] == nil ? "ok  " : "FAIL") \(id): \(words) words, \(record["elapsed_ms"] ?? 0) ms")
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}
var runInfo: [String: Any] = [
    "extractor": extractorName,
    "extractor_commit": AppSourcesVersion.commit,
    "extractor_uncommitted_changes": AppSourcesVersion.uncommittedChanges,
    "extractor_sha256_prefix": AppSourcesVersion.extractorSHA256Prefix,
    "normalizer_sha256_prefix": AppSourcesVersion.normalizerSHA256Prefix,
    "structured_document_sha256_prefix": AppSourcesVersion.structuredDocumentSHA256Prefix,
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "hardware": hardwareModel(),
    "date": ISO8601DateFormatter().string(from: Date()),
    "extracted": extracted,
    "failed": failed,
    "not_fetched": missing,
    "sha256_mismatches": checksumMismatches,
    "median_extract_ms": Int(median(timings).rounded()),
]
if options.v2 {
    runInfo["extraction_version"] = PDFStructuredTextExtractor.structuredExtractionVersion
    runInfo["median_v1_paired_ms"] = Int(median(pairedV1Timings).rounded())
    // The import-time budget: v2 time over v1 time on the same PDF, median across the corpus.
    runInfo["median_v2_over_v1"] = (median(pairedRatios) * 1000).rounded() / 1000
}
try write(runInfo, to: resultsDirectory.appendingPathComponent("run-info.json"))
log("done: \(extracted) extracted, \(failed.count) failed, \(missing.count) not fetched; median \(Int(median(timings))) ms")
if !missing.isEmpty || !checksumMismatches.isEmpty { exit(1) }
