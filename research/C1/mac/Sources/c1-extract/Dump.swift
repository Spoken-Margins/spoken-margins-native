import Foundation
import PDFKit

/// `--dump`: what the app does with any PDF, for the formula backtest (research/C1/formula). One JSON per PDF:
/// every line with its role, the spoken lines, and the chunks the speech path hands an engine.
func runDump(to directory: URL) {
    let arguments = CommandLine.arguments
    let flag = arguments.firstIndex(of: "--dump")!
    let paths = arguments[(flag + 2)...].filter { $0.hasSuffix(".pdf") }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let wordList = URL(fileURLWithPath: arguments.first { $0.hasSuffix("lexicon.tsv") } ?? "/nonexistent")
    for path in paths {
        let url = URL(fileURLWithPath: path)
        autoreleasepool {
            var record: [String: Any] = ["file": url.lastPathComponent]
            let started = Date()
            do {
                guard let pdf = PDFDocument(url: url) else { throw PDFStructuredTextExtractor.ExtractionError.unreadableDocument }
                let lines = try PDFStructuredTextExtractor.structuredLines(from: pdf, wordListURL: wordList)
                let document = StructuredDocumentBuilder.build(
                    lines: lines, engine: "pdfkit_baseline", version: PDFStructuredTextExtractor.structuredExtractionVersion,
                    pageCount: pdf.pageCount, sourceSHA256: nil
                )
                record["pages"] = pdf.pageCount
                record["lines"] = lines.map { ["p": $0.pageIndex, "r": $0.role.rawValue, "t": $0.text] as [String: Any] }
                let listenable = StructuredDocumentSpeech.listenableText(document).text
                let spoken = SpeechTextNormalizer.normalize(listenable)
                record["spoken_lines"] = StructuredDocumentSpeech.spokenLines(document)
                record["chunks"] = NarrationChunkPlanner.spokenPlan(spokenText: spoken, articleText: nil, articleSpokenStart: 0, budget: RenderedSpeechChunker.spokenCostBudget)
                    .chunks.map { PDFMathSpeech.voiceSafe($0.text) }
            } catch {
                record["error"] = String(describing: error)
            }
            record["elapsed_ms"] = Int(Date().timeIntervalSince(started) * 1000)
            let name = url.deletingPathExtension().lastPathComponent + ".json"
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) {
                try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        }
    }
}
