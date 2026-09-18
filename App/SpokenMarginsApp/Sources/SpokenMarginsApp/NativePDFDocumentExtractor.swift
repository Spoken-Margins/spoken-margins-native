import Foundation
import PDFKit
import SessionKit
import UIKit
import Vision

struct NativePDFImportExtraction: Sendable {
    var markdown: String
    var documentStructure: PDFDocumentStructure
}

/// Keeps PDFKit's exact embedded text and authored outline as the canonical
/// document, then augments it with Vision's on-device layout recognition on
/// iOS 26. Pages are rendered and recognized one at a time to bound memory.
enum NativePDFDocumentExtractor {
    private static let maximumAnalyzedPageCount = 160
    private static let maximumRenderedDimension: CGFloat = 1_800

    private struct RecognizedPageLayout {
        var title: String?
        var paragraphs: [(text: String, bounds: CGRect)]
        var tables: [PDFDocumentTable]
    }

    static func extract(from url: URL) async throws -> NativePDFImportExtraction {
        guard let document = PDFDocument(url: url) else {
            throw PDFStructuredTextExtractor.ExtractionError.unreadableDocument
        }
        return try await extract(from: document)
    }

    static func extract(from data: Data) async throws -> NativePDFImportExtraction {
        guard let document = PDFDocument(data: data) else {
            throw PDFStructuredTextExtractor.ExtractionError.unreadableDocument
        }
        return try await extract(from: document)
    }

    /// Returns embedded PDF text and authored/visual headings without waiting
    /// for Vision document analysis. Import paths use this bounded first pass
    /// so even a large PDF becomes navigable and playable immediately.
    static func extractBaseline(from url: URL) throws -> NativePDFImportExtraction {
        guard let document = PDFDocument(url: url) else {
            throw PDFStructuredTextExtractor.ExtractionError.unreadableDocument
        }
        return try baselineExtraction(from: document)
    }

    static func extractBaseline(from data: Data) throws -> NativePDFImportExtraction {
        guard let document = PDFDocument(data: data) else {
            throw PDFStructuredTextExtractor.ExtractionError.unreadableDocument
        }
        return try baselineExtraction(from: document)
    }

    static func tableAnnouncement(pageIndex: Int, rowCount: Int, columnCount: Int) -> String {
        let rowLabel = rowCount == 1 ? "row" : "rows"
        let columnLabel = columnCount == 1 ? "column" : "columns"
        return "Table on page \(pageIndex + 1), with \(rowCount) \(rowLabel) and \(columnCount) \(columnLabel). Skipped during listening."
    }

    static func enhancedAnalysisShouldPause(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Bool {
        guard !lowPowerMode else { return true }
        switch thermalState {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return true
        }
    }

    static func preferredCellText(recognized: String, exactPDFText: String?) -> String {
        guard let exactPDFText = cleaned(exactPDFText), !exactPDFText.isEmpty else { return recognized }
        guard !recognized.isEmpty else { return exactPDFText }
        let recognizedTokens = recognized.split(whereSeparator: \.isWhitespace).count
        let exactTokens = exactPDFText.split(whereSeparator: \.isWhitespace).count
        // Cell rectangles can clip a final glyph or cover a merged neighbor.
        // Use embedded text only when it is at least as complete as OCR and
        // describes the same number of lexical fields.
        guard exactTokens == recognizedTokens,
              exactPDFText.count >= recognized.count else {
            return recognized
        }
        return exactPDFText
    }

    private static func extract(from document: PDFDocument) async throws -> NativePDFImportExtraction {
        let baselineMarkdown = try? PDFStructuredTextExtractor.markdown(from: document)

        let processInfo = ProcessInfo.processInfo
        if enhancedAnalysisShouldPause(
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState
        ) {
            guard let baselineMarkdown else {
                throw PDFStructuredTextExtractor.ExtractionError.noExtractableText
            }
            return NativePDFImportExtraction(
                markdown: baselineMarkdown,
                documentStructure: PDFDocumentStructure(
                    extractionEngine: .pdfKit,
                    analysisStatus: .resourceConstrained,
                    pageCount: document.pageCount,
                    analyzedPageCount: 0
                )
            )
        }

        return try await enhancedExtraction(from: document, baselineMarkdown: baselineMarkdown)
    }

    private static func baselineExtraction(from document: PDFDocument) throws -> NativePDFImportExtraction {
        NativePDFImportExtraction(
            markdown: try PDFStructuredTextExtractor.markdown(from: document),
            documentStructure: PDFDocumentStructure(
                extractionEngine: .pdfKit,
                analysisStatus: .partial,
                pageCount: document.pageCount,
                analyzedPageCount: 0
            )
        )
    }

    private static func enhancedExtraction(
        from document: PDFDocument,
        baselineMarkdown: String?
    ) async throws -> NativePDFImportExtraction {
        let pageLimit = min(document.pageCount, maximumAnalyzedPageCount)
        var analyzedPageCount = 0
        var failedPageCount = 0
        var stoppedForResources = false
        var recognizedPages: [Int: RecognizedPageLayout] = [:]
        var allTables: [PDFDocumentTable] = []
        var pageTitles: [PDFDocumentPageTitle] = []
        var tableRegionsByPage: [Int: [PDFDetectedTableRegion]] = [:]
        var request = RecognizeDocumentsRequest()
        request.barcodeDetectionOptions.enabled = false
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true

        for pageIndex in 0..<pageLimit {
            try Task.checkCancellation()
            let processInfo = ProcessInfo.processInfo
            if enhancedAnalysisShouldPause(
                lowPowerMode: processInfo.isLowPowerModeEnabled,
                thermalState: processInfo.thermalState
            ) {
                stoppedForResources = true
                break
            }
            guard let page = document.page(at: pageIndex),
                  let image = renderedImage(for: page),
                  let cgImage = image.cgImage else {
                failedPageCount += 1
                continue
            }

            do {
                let observations = try await request.perform(on: cgImage)
                analyzedPageCount += 1
                guard let observation = observations.max(by: { $0.confidence < $1.confidence }) else {
                    continue
                }

                let container = observation.document
                let tables = container.tables.enumerated().map { tableIndex, table in
                    structuredTable(
                        from: table,
                        page: page,
                        pageIndex: pageIndex,
                        tableIndex: tableIndex
                    )
                }
                let title = cleaned(container.title?.transcript)
                if let title, !title.isEmpty {
                    pageTitles.append(PDFDocumentPageTitle(pageIndex: pageIndex, text: title))
                }
                let paragraphs = container.paragraphs.compactMap { paragraph -> (String, CGRect)? in
                    let text = cleaned(paragraph.transcript)
                    guard let text, !text.isEmpty else { return nil }
                    return (text, paragraph.boundingRegion.boundingBox.cgRect)
                }
                recognizedPages[pageIndex] = RecognizedPageLayout(
                    title: title,
                    paragraphs: paragraphs,
                    tables: tables
                )
                allTables.append(contentsOf: tables)

                // PDFKit page and Vision normalized coordinates both use a
                // lower-left origin for an upright page. Rotated pages retain
                // their structure, but do not suppress exact text until that
                // transform can be proven rather than guessed.
                if page.rotation % 360 == 0 {
                    let cropBounds = page.bounds(for: .cropBox)
                    tableRegionsByPage[pageIndex] = tables.map { table in
                        PDFDetectedTableRegion(
                            bounds: denormalized(table.bounds, in: cropBounds),
                            replacementText: tableAnnouncement(
                                pageIndex: pageIndex,
                                rowCount: table.rowCount,
                                columnCount: table.columnCount
                            )
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedPageCount += 1
            }
        }

        let status: PDFDocumentAnalysisStatus
        if stoppedForResources {
            status = .resourceConstrained
        } else if analyzedPageCount == 0 {
            status = .failed
        } else if failedPageCount > 0 || pageLimit < document.pageCount {
            status = .partial
        } else {
            status = .complete
        }
        let structure = PDFDocumentStructure(
            extractionEngine: analyzedPageCount > 0 ? .appleVision : .pdfKit,
            analysisStatus: status,
            pageCount: document.pageCount,
            analyzedPageCount: analyzedPageCount,
            tables: allTables,
            pageTitles: pageTitles
        )

        if baselineMarkdown != nil {
            return NativePDFImportExtraction(
                markdown: try PDFStructuredTextExtractor.markdown(
                    from: document,
                    tableRegionsByPage: tableRegionsByPage
                ),
                documentStructure: structure
            )
        }

        let recognizedMarkdown = markdownFromRecognizedPages(recognizedPages)
        guard !recognizedMarkdown.isEmpty else {
            throw PDFStructuredTextExtractor.ExtractionError.noExtractableText
        }
        return NativePDFImportExtraction(markdown: recognizedMarkdown, documentStructure: structure)
    }

    private static func renderedImage(for page: PDFPage) -> UIImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let longestSide = max(bounds.width, bounds.height)
        let scale = min(2, maximumRenderedDimension / longestSide)
        let size = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        return page.thumbnail(of: size, for: .cropBox)
    }

    private static func structuredTable(
        from table: DocumentObservation.Container.Table,
        page: PDFPage,
        pageIndex: Int,
        tableIndex: Int
    ) -> PDFDocumentTable {
        var seenCells = Set<String>()
        var cells: [PDFDocumentTableCell] = []
        for row in table.rows {
            for cell in row {
                let recognizedText = cleaned(cell.content.text.transcript) ?? ""
                let exactText = exactPDFText(
                    in: cell.content.boundingRegion.boundingBox.cgRect,
                    page: page
                )
                let text = preferredCellText(recognized: recognizedText, exactPDFText: exactText)
                let key = "\(cell.rowRange.lowerBound):\(cell.rowRange.upperBound):\(cell.columnRange.lowerBound):\(cell.columnRange.upperBound):\(text)"
                guard seenCells.insert(key).inserted else { continue }
                cells.append(PDFDocumentTableCell(
                    rowStart: cell.rowRange.lowerBound,
                    rowEnd: cell.rowRange.upperBound,
                    columnStart: cell.columnRange.lowerBound,
                    columnEnd: cell.columnRange.upperBound,
                    text: text
                ))
            }
        }
        let bounds = table.boundingRegion.boundingBox.cgRect
        return PDFDocumentTable(
            id: "pdf-table-page-\(pageIndex + 1)-\(tableIndex + 1)",
            pageIndex: pageIndex,
            rowCount: table.rows.count,
            columnCount: table.columns.count,
            bounds: PDFNormalizedRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: bounds.height
            ),
            cells: cells
        )
    }

    private static func exactPDFText(in normalizedBounds: CGRect, page: PDFPage) -> String? {
        guard page.rotation % 360 == 0 else { return nil }
        let cropBounds = page.bounds(for: .cropBox)
        let pageBounds = CGRect(
            x: cropBounds.minX + (normalizedBounds.minX * cropBounds.width),
            y: cropBounds.minY + (normalizedBounds.minY * cropBounds.height),
            width: normalizedBounds.width * cropBounds.width,
            height: normalizedBounds.height * cropBounds.height
        )
        guard let selected = cleaned(page.selection(for: pageBounds)?.string),
              !selected.isEmpty else {
            return nil
        }
        return selected
    }

    private static func denormalized(_ normalized: PDFNormalizedRect, in pageBounds: CGRect) -> CGRect {
        CGRect(
            x: pageBounds.minX + (normalized.x * pageBounds.width),
            y: pageBounds.minY + (normalized.y * pageBounds.height),
            width: normalized.width * pageBounds.width,
            height: normalized.height * pageBounds.height
        )
    }

    private static func markdownFromRecognizedPages(_ pages: [Int: RecognizedPageLayout]) -> String {
        var output: [String] = []
        var emittedDocumentTitle = false
        var narratedTitleKeys = Set<String>()
        for pageIndex in pages.keys.sorted() {
            guard let page = pages[pageIndex] else { continue }
            if let title = page.title, !title.isEmpty {
                // A per-page Vision title is useful evidence, but is not an
                // authored chapter boundary. Only the first becomes the OCR
                // document title; later titles remain ordinary text.
                let titleKey = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if narratedTitleKeys.insert(titleKey).inserted {
                    output.append(emittedDocumentTitle ? title : "# \(title)")
                    emittedDocumentTitle = true
                }
            }
            let tableRects = page.tables.map(\.bounds)
            for paragraph in page.paragraphs where !tableRects.contains(where: { containsCenter(paragraph.bounds, in: $0) }) {
                output.append(paragraph.text)
            }
            for table in page.tables {
                output.append(tableAnnouncement(
                    pageIndex: pageIndex,
                    rowCount: table.rowCount,
                    columnCount: table.columnCount
                ))
            }
        }
        return output.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsCenter(_ rect: CGRect, in normalized: PDFNormalizedRect) -> Bool {
        CGRect(x: normalized.x, y: normalized.y, width: normalized.width, height: normalized.height)
            .contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    private static func cleaned(_ value: String?) -> String? {
        value?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
