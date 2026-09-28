import Foundation
import PDFKit
import SessionKit
import UIKit

struct PDFDetectedTableRegion: Equatable {
    var bounds: CGRect
    var replacementText: String
}

enum PDFStructuredTextExtractor {
    enum ExtractionError: LocalizedError {
        case unreadableDocument
        case noExtractableText

        var errorDescription: String? {
            switch self {
            case .unreadableDocument:
                return "The PDF could not be opened."
            case .noExtractableText:
                return "The PDF does not contain extractable text."
            }
        }
    }

    private struct OutlineHeading {
        var id: Int
        var title: String
        var level: Int
        var pageIndex: Int
    }

    private struct TextLine {
        var text: String
        var pointSize: CGFloat
        var isBold: Bool
        var bounds: CGRect?
    }

    static func markdown(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadableDocument
        }
        return try markdown(from: document)
    }

    static func markdown(from document: PDFDocument) throws -> String {
        try markdown(from: document, tableRegionsByPage: [:])
    }

    static func markdown(
        from document: PDFDocument,
        tableRegionsByPage: [Int: [PDFDetectedTableRegion]]
    ) throws -> String {
        let outline = outlineHeadings(in: document)
        var pages: [[TextLine]] = []
        for pageIndex in 0..<document.pageCount {
            pages.append(document.page(at: pageIndex).map { lines(from: $0) } ?? [])
        }
        // Repeated text in physical page margins is running furniture, not prose.
        // Keep the cover page and all interior occurrences of the same words.
        func marginKey(_ line: TextLine, page: PDFPage) -> String? {
            guard let bounds = line.bounds else { return nil }
            let box = page.bounds(for: .mediaBox)
            guard bounds.midY > box.maxY - box.height * 0.14 || bounds.midY < box.minY + box.height * 0.10 else { return nil }
            return normalized(line.text)
        }
        if pages.count >= 3 {
            var occurrences: [String: Set<Int>] = [:]
            for (index, lines) in pages.enumerated() {
                guard let page = document.page(at: index) else { continue }
                for line in lines {
                    if let key = marginKey(line, page: page) { occurrences[key, default: []].insert(index) }
                }
            }
            let threshold = max(3, Int(ceil(Double(pages.count) * 0.3)))
            for index in pages.indices where index > 0 {
                guard let page = document.page(at: index) else { continue }
                pages[index].removeAll { line in
                    guard let key = marginKey(line, page: page) else { return false }
                    let pageNumber = line.text.range(of: "^(?:[0-9]+|[ivxlcdm]+)$", options: [.regularExpression, .caseInsensitive]) != nil
                    return occurrences[key, default: []].count >= threshold || pageNumber
                }
            }
        }
        // Explicit download stamps in page margins are acquisition metadata.
        // Do not remove dates from prose, headings, or the middle of a page.
        for index in pages.indices {
            guard let page = document.page(at: index) else { continue }
            pages[index].removeAll { line in
                marginKey(line, page: page) != nil && isDownloadStamp(line.text)
            }
        }
        let allLines = pages.flatMap { $0 }
        guard allLines.contains(where: { !$0.text.isEmpty }) else {
            throw ExtractionError.noExtractableText
        }

        // A contents page establishes front matter without guessing from dates,
        // publisher names, or particular report titles. Keep that text, but do
        // not promote its typography to listening chapters.
        let firstContentsPage = pages.firstIndex { $0.contains { isTableOfContentsTitle($0.text) } }
        let bodySize = inferredBodyPointSize(from: allLines)
        var insertedOutlineHeadingIDs = Set<Int>()
        var output: [String] = []

        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let cleanedTitle = cleaned(title)
            if !cleanedTitle.isEmpty {
                appendHeading(cleanedTitle, level: 1, to: &output)
            }
        }

        for (pageIndex, pageLines) in pages.enumerated() {
            let pageOutline = outline.filter { $0.pageIndex == pageIndex }
            let tableRegions = tableRegionsByPage[pageIndex, default: []]
            let tableOfContentsLines = tableOfContentsLineIndices(
                in: pageLines,
                pageIndex: pageIndex,
                outline: outline
            )
            let unmatchedPageOutline = pageOutline.filter { heading in
                !pageLines.contains(where: { headingKey($0.text) == headingKey(heading.title) })
            }
            for heading in unmatchedPageOutline {
                appendHeading(heading.title, level: heading.level, to: &output)
                insertedOutlineHeadingIDs.insert(heading.id)
            }

            var insertedTableRegionIndices = Set<Int>()
            for (lineIndex, line) in pageLines.enumerated() {
                if let tableRegionIndex = tableRegions.indices.first(where: {
                    lineBelongsToTable(line, region: tableRegions[$0].bounds)
                }) {
                    if insertedTableRegionIndices.insert(tableRegionIndex).inserted {
                        appendParagraph(tableRegions[tableRegionIndex].replacementText, to: &output)
                    }
                    continue
                }
                let key = headingKey(line.text)
                if tableOfContentsLines.contains(lineIndex) {
                    // Directory entries are navigation, not a second reading
                    // of every heading (and their dotted leaders confuse TTS).
                    continue
                } else if let heading = pageOutline.first(where: {
                    !insertedOutlineHeadingIDs.contains($0.id) && headingKey($0.title) == key
                }) {
                    insertedOutlineHeadingIDs.insert(heading.id)
                    appendHeading(line.text, level: heading.level, to: &output)
                } else if outline.isEmpty
                    && (firstContentsPage.map({ pageIndex > $0 }) ?? true)
                    && isVisualHeading(line, bodySize: bodySize) {
                    appendHeading(line.text, level: visualHeadingLevel(line, bodySize: bodySize), to: &output)
                } else {
                    appendParagraph(line.text, to: &output)
                }
            }
            for regionIndex in tableRegions.indices where !insertedTableRegionIndices.contains(regionIndex) {
                appendParagraph(tableRegions[regionIndex].replacementText, to: &output)
            }
        }

        let markdown = output
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { throw ExtractionError.noExtractableText }
        return listeningMarkdown(markdown)
    }

    /// A standalone references heading plus multiple bibliographic records is
    /// required. A prose mention or an early contents entry is not a boundary.
    static func listeningMarkdown(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where index > 0 {
            let heading = line.trimmingCharacters(in: .whitespaces)
            guard heading.range(of: #"(?i)^(?:#{1,6}\s*)?(?:[0-9]+[. ]+)?(?:references|bibliography|works cited)\s*$"#, options: .regularExpression) != nil else { continue }
            let tail = lines.dropFirst(index + 1).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(40)
            let records = tail.filter {
                $0.range(of: #"^\s*(?:\[\^?[0-9]+\]:?|[0-9]+[.)])\s+\S"#, options: .regularExpression) != nil
                    || $0.range(of: #"(?i)\b(?:19|20)[0-9]{2}\b.*(?:doi|journal|press|https?://)"#, options: .regularExpression) != nil
            }
            guard records.count >= 3,
                  tail.filter({ $0.range(of: #"\b(?:19|20)[0-9]{2}\b"#, options: .regularExpression) != nil }).count >= 3 else { continue }
            return lines.prefix(index).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return markdown
    }

    // MARK: - Extraction v2 (I13): roles instead of cuts

    /// Bumped by any change that can change v2 text for some PDF (I13 rule 1a).
    /// v1 is `markdown(from:)`, which stays as it is for items imported under it.
    static let structuredExtractionVersion = 2

    static func structuredDocument(from url: URL) throws -> StructuredDocument {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadableDocument
        }
        return try structuredDocument(from: document)
    }

    static func structuredDocument(from document: PDFDocument, sourceSHA256: String? = nil) throws -> StructuredDocument {
        StructuredDocumentBuilder.build(
            lines: try structuredLines(from: document),
            engine: "pdfkit_baseline",
            version: structuredExtractionVersion,
            pageCount: document.pageCount,
            sourceSHA256: sourceSHA256
        )
    }

    /// Every line of the PDF in reading order with a role. Nothing is dropped:
    /// what v1 cut (running heads, stamps, contents pages, the reference list)
    /// is labelled, and the speech path decides what is heard (I14).
    static func structuredLines(from document: PDFDocument) throws -> [StructuredDocumentLine] {
        let outline = outlineHeadings(in: document)
        var pages: [[TextLine]] = []
        for pageIndex in 0..<document.pageCount {
            pages.append(document.page(at: pageIndex).map { lines(from: $0) } ?? [])
        }
        let allLines = pages.flatMap { $0 }
        guard allLines.contains(where: { !$0.text.isEmpty }) else {
            throw ExtractionError.noExtractableText
        }

        // Page furniture: repeated text or page numbers in the physical margins,
        // and download stamps there. Labelled by edge, not removed.
        enum Edge { case top, bottom }
        func edge(_ line: TextLine, page: PDFPage) -> Edge? {
            guard let bounds = line.bounds else { return nil }
            let box = page.bounds(for: .mediaBox)
            if bounds.midY > box.maxY - box.height * 0.14 { return .top }
            if bounds.midY < box.minY + box.height * 0.10 { return .bottom }
            return nil
        }
        // Digits are ignored, so "New Research 12 of 15" repeats across pages.
        func furnitureKey(_ text: String) -> String {
            normalized(text).replacingOccurrences(of: "[0-9]+", with: "0", options: .regularExpression)
        }
        var occurrences: [String: Set<Int>] = [:]
        for (index, lines) in pages.enumerated() {
            guard let page = document.page(at: index) else { continue }
            for line in lines where edge(line, page: page) != nil {
                occurrences[furnitureKey(line.text), default: []].insert(index)
            }
        }
        let threshold = max(3, Int(ceil(Double(pages.count) * 0.3)))
        func furnitureRole(_ line: TextLine, page: PDFPage) -> StructuredDocument.Role? {
            guard let side = edge(line, page: page) else { return nil }
            let repeated = pages.count >= 3 && occurrences[furnitureKey(line.text), default: []].count >= threshold
            let pageNumber = line.text.range(of: "^(?:[0-9]+|[ivxlcdm]+)$", options: [.regularExpression, .caseInsensitive]) != nil
            guard repeated || pageNumber || isDownloadStamp(line.text) else { return nil }
            return side == .top ? .pageHeader : .pageFooter
        }

        let firstContentsPage = pages.firstIndex { $0.contains { isTableOfContentsTitle($0.text) } }
        let bodySize = inferredBodyPointSize(from: allLines)
        let layout = BodyLayout(lines: allLines, bodySize: bodySize)
        var insertedOutlineHeadingIDs = Set<Int>()
        var result: [StructuredDocumentLine] = []

        // The metadata title, unless the first page already prints it (v1 read it twice).
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let cleanedTitle = cleaned(title)
            let firstPage = normalized(pages.first?.prefix(20).map(\.text).joined(separator: " ") ?? "")
            if !cleanedTitle.isEmpty, !firstPage.contains(normalized(cleanedTitle)) {
                result.append(StructuredDocumentLine(text: cleanedTitle, role: .title, pageIndex: 0, level: 1))
            }
        }

        for (pageIndex, pageLines) in pages.enumerated() {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageOutline = outline.filter { $0.pageIndex == pageIndex }
            let tableOfContentsLines = tableOfContentsLineIndices(in: pageLines, pageIndex: pageIndex, outline: outline)
            let (tableLines, figureLines) = tableAndFigureLineIndices(
                in: pageLines,
                layout: layout,
                // A long table runs on for pages after its caption.
                nearTableCaption: (max(0, pageIndex - 3)...min(pages.count - 1, pageIndex + 1)).contains { neighbour in
                    pages[neighbour].contains { isTableCaption($0.text) }
                },
                nearFigureCaption: (max(0, pageIndex - 1)...min(pages.count - 1, pageIndex + 1)).contains { neighbour in
                    pages[neighbour].contains { isFigureCaption($0.text) }
                }
            )
            let titlePage = pageIndex < 2 ? titlePageRoles(in: pageLines, isFirstPage: pageIndex == 0, bodySize: bodySize) : [:]
            for heading in pageOutline where !pageLines.contains(where: { headingKey($0.text) == headingKey(heading.title) }) {
                result.append(StructuredDocumentLine(text: heading.title, role: .heading, pageIndex: pageIndex, level: heading.level))
                insertedOutlineHeadingIDs.insert(heading.id)
            }
            for (lineIndex, line) in pageLines.enumerated() {
                let key = headingKey(line.text)
                if let role = furnitureRole(line, page: page) {
                    result.append(StructuredDocumentLine(text: line.text, role: role, pageIndex: pageIndex))
                } else if tableOfContentsLines.contains(lineIndex) {
                    result.append(StructuredDocumentLine(text: line.text, role: .frontMatter, pageIndex: pageIndex))
                } else if let role = titlePage[lineIndex] {
                    result.append(StructuredDocumentLine(text: line.text, role: role, pageIndex: pageIndex))
                } else if tableLines.contains(lineIndex) {
                    result.append(StructuredDocumentLine(text: line.text, role: .table, pageIndex: pageIndex))
                } else if figureLines.contains(lineIndex) {
                    result.append(StructuredDocumentLine(text: line.text, role: .figureText, pageIndex: pageIndex))
                } else if layout.looksLikeDisplayMath(line) {
                    result.append(StructuredDocumentLine(text: line.text, role: .equation, pageIndex: pageIndex))
                } else if let heading = pageOutline.first(where: {
                    !insertedOutlineHeadingIDs.contains($0.id) && headingKey($0.title) == key
                }) {
                    insertedOutlineHeadingIDs.insert(heading.id)
                    result.append(StructuredDocumentLine(text: line.text, role: .heading, pageIndex: pageIndex, level: heading.level))
                } else if outline.isEmpty
                    && (firstContentsPage.map({ pageIndex > $0 }) ?? true)
                    && isVisualHeading(line, bodySize: bodySize) {
                    result.append(StructuredDocumentLine(text: line.text, role: .heading, pageIndex: pageIndex, level: visualHeadingLevel(line, bodySize: bodySize)))
                } else {
                    result.append(StructuredDocumentLine(text: line.text, role: .body, pageIndex: pageIndex))
                }
            }
        }
        labelReferenceLists(&result)
        joinEquationFragments(&result)
        return result
    }

    /// A multi-line display equation comes out as several lines with its number
    /// ("(3)") or a lone symbol between them. Those fragments join the equation,
    /// so the listener hears one "Equation not read." for it, not one per line.
    static func joinEquationFragments(_ lines: inout [StructuredDocumentLine]) {
        guard lines.count >= 3 else { return }
        for index in 1..<(lines.count - 1) where lines[index].role == .body {
            let before = lines[index - 1], after = lines[index + 1]
            guard before.role == .equation, after.role == .equation, before.pageIndex == after.pageIndex else { continue }
            let tokens = lines[index].text.split(separator: " ")
            let fragment = tokens.count <= 3 && !tokens.contains { $0.count >= 4 && $0.allSatisfy(\.isLetter) && $0.first?.isLowercase == true }
            if fragment { lines[index].role = .equation }
        }
    }

    /// A references heading followed by bibliography-shaped lines starts a
    /// reference list. Unlike v1, it ends at the next heading, so an appendix after
    /// the references is read (#215).
    static func labelReferenceLists(_ lines: inout [StructuredDocumentLine]) {
        let referencesHeading = #"(?i)^(?:[0-9]+[. ]+)?(?:references|bibliography|works cited|literature cited|references and notes)\s*$"#
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard lines[index].role == .heading || lines[index].role == .body,
                  lines[index].text.range(of: referencesHeading, options: .regularExpression) != nil else { continue }
            let tail = lines[(index + 1)...].filter { $0.role == .body }.prefix(40)
            guard tail.filter({ looksLikeBibliographyEntry($0.text) }).count >= 4 else { continue }
            var cursor = index + 1
            while cursor < lines.count, lines[cursor].role != .heading {
                if lines[cursor].role == .body { lines[cursor].role = .reference }
                cursor += 1
            }
            index = cursor - 1
        }
    }

    /// Where running text sits: its type size, a full line's width, and the x
    /// positions body columns start at (full-width lines only, so indents and
    /// table cells don't count).
    private struct BodyLayout {
        var bodySize: CGFloat
        var lineWidth: CGFloat
        var columnStarts: [CGFloat]

        init(lines: [TextLine], bodySize: CGFloat) {
            self.bodySize = bodySize
            let prose = lines.filter { $0.text.count >= 45 && abs($0.pointSize - bodySize) < 0.6 }
            // The most common full-line width, in 4 pt buckets; justified text makes it sharp.
            var widthCounts: [Int: Int] = [:]
            for line in prose {
                if let width = line.bounds?.width { widthCounts[Int(width / 4), default: 0] += 1 }
            }
            lineWidth = widthCounts.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { CGFloat($0.key) * 4 + 2 } ?? 0
            var starts: [Int: Int] = [:]
            for line in prose {
                guard let bounds = line.bounds, bounds.width >= lineWidth * 0.85 else { continue }
                starts[Int((bounds.minX / 2).rounded()), default: 0] += 1
            }
            columnStarts = starts.filter { $0.value >= 3 }.map { CGFloat($0.key) * 2 }
        }

        /// A table cell line: mostly numbers and not laid out as running text,
        /// or a short fragment that is both off every body column and narrow.
        /// A full-width line is never a cell, and math isn't a table.
        func looksLikeTableCell(_ line: TextLine) -> Bool {
            guard let bounds = line.bounds, lineWidth > 0 else { return false }
            guard !looksLikeMath(line.text) else { return false }
            let tokens = line.text.split(separator: " ")
            guard !tokens.isEmpty else { return false }
            let numeric = tokens.filter { $0.range(of: #"^[(\[]?[-–−+±<>=≤≥~]?[0-9][0-9.,:%–−-]*[)\]*†‡a-z]?[,;]?$"#, options: .regularExpression) != nil }
            let offColumn = !columnStarts.contains { abs($0 - bounds.minX) <= 4 }
            let narrow = bounds.width < lineWidth * 0.5
            let otherSize = abs(line.pointSize - bodySize) >= 0.6
            if Double(numeric.count) / Double(tokens.count) >= 0.4 {
                // A row of numbers can span the page, but not in body type at a column start.
                return offColumn || narrow || otherSize
            }
            return bounds.width < lineWidth * 0.8 && offColumn && narrow && tokens.count <= 12
        }

        /// A display equation: math set apart from the text column (centred or
        /// narrow), not a sentence with some symbols in it.
        func looksLikeDisplayMath(_ line: TextLine) -> Bool {
            guard let bounds = line.bounds, lineWidth > 0 else { return false }
            let offColumn = !columnStarts.contains { abs($0 - bounds.minX) <= 4 }
            guard offColumn && bounds.width < lineWidth * 0.7 else { return false }
            let words = line.text.split(separator: " ").filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) }
            guard words.filter({ $0.first?.isLowercase == true }).count <= 1 else { return false }
            // Stricter than looksLikeMath: "|" in link rows and "+", "=" in labels
            // such as "Scn2a+/+ (n=24)" are not equations.
            let mathScalars = line.text.unicodeScalars.filter { scalar in
                "×·∑∏∫√∂∇≤≥≈≠∈∀∃∞".unicodeScalars.contains(scalar)
                    || (0x0391...0x03C9).contains(scalar.value)
                    || (0x2100...0x214F).contains(scalar.value)
                    || (0x2190...0x22FF).contains(scalar.value)
                    || (0x1D400...0x1D7FF).contains(scalar.value)
            }
            if mathScalars.count >= 2 { return true }
            let tokens = line.text.split(separator: " ")
            let single = tokens.filter { $0.count == 1 && $0.first?.isLetter == true }
            return line.text.contains("=") && tokens.count >= 3 && Double(single.count) / Double(tokens.count) >= 0.4
        }

        /// Display math: operators, Greek or math-alphabet letters, arrows, or
        /// mostly one-letter tokens.
        func looksLikeMath(_ text: String) -> Bool {
            let symbols = text.unicodeScalars.filter { scalar in
                "=+×·∑∏∫√∂∇≤≥≈≠∈∀∃→←⇒∞^_|".unicodeScalars.contains(scalar)
                    || (0x0391...0x03C9).contains(scalar.value)    // Greek
                    || (0x2100...0x214F).contains(scalar.value)    // letterlike: ℰ, ℝ
                    || (0x2190...0x22FF).contains(scalar.value)    // arrows, operators
                    || (0x1D400...0x1D7FF).contains(scalar.value)  // math alphanumerics: 𝑎, 𝒪, 𝔛
            }
            let tokens = text.split(separator: " ")
            let single = tokens.filter { $0.count == 1 && $0.first?.isLetter == true }
            return symbols.count >= 2 || (tokens.count >= 3 && Double(single.count) / Double(tokens.count) >= 0.4)
        }
    }

    /// Runs of table-cell lines on one page. A run next to a "Table N" caption
    /// needs three lines; any other run needs five, so a short list or a
    /// paragraph's last line is never taken for a table. An uncaptioned run is a
    /// table only when a table caption is on this page, the next, or the three
    /// before (long tables run on). Failing that, a run of three or more near a
    /// figure caption is text printed inside the figure: axis ticks, panel
    /// labels, screenshots.
    private static func tableAndFigureLineIndices(
        in lines: [TextLine],
        layout: BodyLayout,
        nearTableCaption: Bool,
        nearFigureCaption: Bool
    ) -> (table: Set<Int>, figure: Set<Int>) {
        let cells = lines.map(layout.looksLikeTableCell)
        let captions = lines.indices.filter { isTableCaption(lines[$0].text) || isFigureCaption(lines[$0].text) }
        let tableCaptions = captions.filter { isTableCaption(lines[$0].text) }
        var result = captionedTableLines(in: lines, captions: tableCaptions, layout: layout)
        var figure = Set<Int>()
        var index = 0
        while index < lines.count {
            guard cells[index] else { index += 1; continue }
            // A run may bridge one short line that doesn't look like a cell (a wrapped
            // label), but not a phrase of running text between two formulas.
            func bridges(_ gap: Int) -> Bool {
                let words = lines[gap].text.split(separator: " ")
                return gap + 1 < lines.count && cells[gap + 1] && !captions.contains(gap)
                    && words.count <= 4
                    && !words.contains { ["where", "and", "the", "of", "is", "are", "for", "with", "which", "that", "by", "to", "in"].contains($0.lowercased()) }
            }
            var end = index
            var probe = index + 1
            while probe < lines.count, cells[probe] || bridges(probe) {
                if cells[probe] { end = probe }
                probe += 1
            }
            let length = end - index + 1
            let captioned = tableCaptions.contains { $0 >= index - 3 && $0 <= end + 3 }
            let run = (index...end).filter { !captions.contains($0) && !result.contains($0) }
            if captioned ? length >= 3 : (nearTableCaption && length >= 5) {
                result.formUnion(run)
            } else if nearFigureCaption && length >= 3 {
                figure.formUnion(run)
            }
            index = end + 1
        }
        return (result, figure)
    }

    static func isFigureCaption(_ text: String) -> Bool {
        text.range(of: #"^(?:Fig(?:ure)?\.?|FIG(?:URE)?\.?)\s*[0-9S]+[0-9.]*(?:[.:|]|\s*$|\s+\p{Lu}|\s*\()"#, options: .regularExpression) != nil
    }

    /// Title-page matter (owner, #191): author names are read, the rest is not.
    /// - Publishing boilerplate on the first two pages (licence, dates,
    ///   correspondence, keywords, identifiers) is front matter. When it's in small
    ///   print, so are the wrapped lines of its paragraph.
    /// - On the first page, the block between the title and an explicit
    ///   "Abstract" or "Summary" line is authors and affiliations. Without that
    ///   line nothing is guessed, so an unlabelled abstract is never skipped.
    private static func titlePageRoles(in lines: [TextLine], isFirstPage: Bool, bodySize: CGFloat) -> [Int: StructuredDocument.Role] {
        var roles: [Int: StructuredDocument.Role] = [:]
        let boilerplate = #"(?i)^(?:\*?\s*correspond|e-?mail\b|(?:received|accepted|revised|published|available online)\b.*\b(?:19|20)[0-9]{2}\b|article history|citation:|copyright|©|\(c\) \d{4}|open access\b|this (?:is an open access )?article is (?:licensed|distributed|an open access)|licensed under|creative commons|keywords?\b|key words\b|edited by\b|reviewed by\b|academic editor|handling editor|orcid\b|https?://(?:dx\.)?doi\.org|doi:|typeset using|preprint\b.*\bsubmitted|submitted to\b|\S+@\S+\.\S+)"#
        var index = 0
        while index < lines.count {
            if lines[index].text.range(of: boilerplate, options: .regularExpression) != nil {
                roles[index] = .frontMatter
                // Its paragraph, if in small print: following lines in the same size, up to a dozen.
                var next = index + 1
                while next < lines.count, next <= index + 12,
                      lines[index].pointSize < bodySize - 0.3,
                      abs(lines[next].pointSize - lines[index].pointSize) < 0.3,
                      lines[next].text.range(of: #"^(?:abstract|summary|introduction|background|[0-9]+\.?\s+\p{Lu})"#, options: [.regularExpression, .caseInsensitive]) == nil {
                    roles[next] = .frontMatter
                    next += 1
                }
                index = next
            } else {
                index += 1
            }
        }
        guard isFirstPage,
              let abstract = lines.firstIndex(where: {
                  $0.text.range(of: #"^(?:abstract|summary|a b s t r a c t)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
              }), abstract > 0 else { return roles }
        for index in 0..<abstract where roles[index] == nil {
            // The title and any other display type are read.
            if lines[index].pointSize >= bodySize + 1.5 { continue }
            let text = lines[index].text
            if looksLikeAuthorList(text) {
                roles[index] = .authors
            } else if !looksLikeProse(text) {
                roles[index] = .frontMatter
            }
        }
        return roles
    }

    /// A sentence, not an affiliation: eight or more words, mostly lower case.
    static func looksLikeProse(_ text: String) -> Bool {
        let words = text.split(separator: " ").filter { $0.first?.isLetter == true }
        return words.count >= 8
            && Double(words.filter { $0.first?.isLowercase == true }.count) / Double(words.count) >= 0.5
            && text.range(of: #"(?i)univ|department|institut|hospital|laborator|college|school of|faculty of"#, options: .regularExpression) == nil
    }

    /// "Ada Example¹, Ben Sample² and C. D. Third*": capitalised names joined by
    /// commas or "and", nearly no lower-case words, no institution or address.
    static func looksLikeAuthorList(_ text: String) -> Bool {
        guard text.range(of: #"(?i)@|univ|department|dept\.|institut|cent(?:er|re)|school|faculty|hospital|laborator|college|academy|street|road|avenue|\b[A-Z]{1,2}-?[0-9]{4,5}\b"#, options: .regularExpression) == nil else { return false }
        let words = text.split(whereSeparator: { " ,;*†‡§".contains($0) }).filter { $0.first?.isLetter == true }
        let names = words.filter { $0.first?.isUppercase == true }
        let lower = words.filter { $0.first?.isLowercase == true && !["and", "de", "van", "von", "der", "da", "del", "di", "la", "le"].contains(String($0)) }
        return names.count >= 2 && lower.count <= max(0, words.count / 5)
    }

    static func isTableCaption(_ text: String) -> Bool {
        text.range(of: #"^(?:Table|TABLE)\s+[0-9IVXS]+[0-9.]*(?:[.:|]|\s*$|\s+\p{Lu})"#, options: .regularExpression) != nil
    }

    /// Lines that follow a "Table N" caption in smaller type than the body: the
    /// table itself, whatever its cells say. The caption is the "Table N" line and
    /// the lines after it in the same type size (at most four); the table runs
    /// until body-size text, a heading-size line, or another caption.
    private static func captionedTableLines(in lines: [TextLine], captions: [Int], layout: BodyLayout) -> Set<Int> {
        var result = Set<Int>()
        for caption in captions {
            let captionSize = lines[caption].pointSize
            guard captionSize > 0, captionSize < layout.bodySize + 0.3 else { continue }
            var index = caption + 1
            while index < lines.count, index <= caption + 4, abs(lines[index].pointSize - captionSize) < 0.2,
                  !isTableCaption(lines[index].text) {
                index += 1
            }
            while index < lines.count {
                let line = lines[index]
                guard line.pointSize > 0, line.pointSize < layout.bodySize - 0.4,
                      !isTableCaption(line.text),
                      line.text.range(of: #"^(?:Fig(?:ure)?\.?|FIGURE)\s+[0-9]"#, options: .regularExpression) == nil else { break }
                result.insert(index)
                index += 1
            }
        }
        return result
    }

    /// The first line of a bibliography entry in the common styles: numbered
    /// ("[12] …", "12. …"), author first ("Agarwal A, …", "Abdul-Hay, S. O., …"), or
    /// any line carrying a parenthesised year or a DOI.
    static func looksLikeBibliographyEntry(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:\[\^?[0-9]{1,4}\]:?|[0-9]{1,4}[.)])\s+\S"#, options: .regularExpression) != nil
            || text.range(of: #"^\p{Lu}[\p{L}'’\-]+(?: [\p{Lu}][\p{L}'’\-]+)?,? (?:\p{Lu}\.?[ -]?){1,3}[,.(]"#, options: .regularExpression) != nil
            || text.range(of: #"\((?:19|20)[0-9]{2}[a-z]?\)|\bdoi[:.]|\b10\.[0-9]{4,}/"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func lines(from page: PDFPage) -> [TextLine] {
        guard let attributed = page.attributedString, attributed.length > 0 else {
            return page.string?
                .components(separatedBy: .newlines)
                .map { TextLine(text: cleaned($0), pointSize: 0, isBold: false, bounds: nil) }
                .filter { !$0.text.isEmpty } ?? []
        }
        let source = attributed.string as NSString
        var result: [TextLine] = []
        var location = 0
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let raw = source.substring(with: range)
            let text = cleaned(raw)
            if !text.isEmpty {
                let visibleLocation = firstVisibleLocation(in: source, range: range)
                let font = attributed.attribute(.font, at: visibleLocation, effectiveRange: nil) as? UIFont
                let selection = page.selection(for: range)
                result.append(TextLine(
                    text: text,
                    pointSize: font?.pointSize ?? 0,
                    isBold: font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true,
                    bounds: selection?.bounds(for: page)
                ))
            }
            location = NSMaxRange(range)
        }
        return result
    }

    private static func lineBelongsToTable(_ line: TextLine, region: CGRect) -> Bool {
        guard let lineBounds = line.bounds,
              !lineBounds.isNull,
              lineBounds.width > 0,
              lineBounds.height > 0 else {
            return false
        }
        let expandedRegion = region.insetBy(dx: -2, dy: -2)
        if expandedRegion.contains(CGPoint(x: lineBounds.midX, y: lineBounds.midY)) {
            return true
        }
        let overlap = expandedRegion.intersection(lineBounds)
        guard !overlap.isNull else { return false }
        return (overlap.width * overlap.height) / (lineBounds.width * lineBounds.height) >= 0.65
    }

    private static func firstVisibleLocation(in source: NSString, range: NSRange) -> Int {
        guard range.length > 0 else { return min(range.location, max(0, source.length - 1)) }
        for location in range.location..<NSMaxRange(range) {
            let scalar = UnicodeScalar(source.character(at: location))
            if let scalar, !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return location
            }
        }
        return range.location
    }

    private static func inferredBodyPointSize(from lines: [TextLine]) -> CGFloat {
        let proseSizes = lines
            .filter { $0.text.count >= 45 && $0.pointSize > 0 }
            .map(\.pointSize)
            .sorted()
        let fallbackSizes = lines.filter { $0.pointSize > 0 }.map(\.pointSize).sorted()
        let sizes = proseSizes.isEmpty ? fallbackSizes : proseSizes
        guard !sizes.isEmpty else { return 12 }
        return sizes[sizes.count / 2]
    }

    private static func isVisualHeading(_ line: TextLine, bodySize: CGFloat) -> Bool {
        guard line.text.count >= 2,
              line.text.count <= 120,
              line.text.range(of: #"^[\d\s./-]+$"#, options: .regularExpression) == nil else {
            return false
        }
        let enlarged = line.pointSize >= max(bodySize + 1.5, bodySize * 1.16)
        let emphasized = line.isBold && line.pointSize >= bodySize * 0.98
        return enlarged || emphasized
    }

    private static func visualHeadingLevel(_ line: TextLine, bodySize: CGFloat) -> Int {
        if line.pointSize >= bodySize * 1.7 { return 1 }
        if line.pointSize >= bodySize * 1.35 { return 2 }
        return 3
    }

    private static func tableOfContentsLineIndices(
        in lines: [TextLine],
        pageIndex: Int,
        outline: [OutlineHeading]
    ) -> Set<Int> {
        let contentsTitleIndices = lines.indices.filter { isTableOfContentsTitle(lines[$0].text) }
        let firstContentsTitle = contentsTitleIndices.first
        let offDestinationOutlineMatches = lines.indices.filter { lineIndex in
            let title = headingKey(lines[lineIndex].text)
            return outline.contains { heading in
                heading.pageIndex != pageIndex && headingKey(heading.title) == title
            }
        }
        let contentsEntries = lines.indices.filter { lineIndex in
            guard firstContentsTitle.map({ lineIndex > $0 }) ?? true else { return false }
            return looksLikeTableOfContentsEntry(lines[lineIndex].text)
        }
        let pageReferencedEntries = lines.indices.filter { lineIndex in
            guard firstContentsTitle.map({ lineIndex > $0 }) ?? true else { return false }
            return looksLikePageReferencedTableOfContentsEntry(lines[lineIndex].text)
        }

        let hasEnoughEvidence = !contentsTitleIndices.isEmpty
            || offDestinationOutlineMatches.count >= 3
            || pageReferencedEntries.count >= 4
        guard hasEnoughEvidence else { return [] }

        var result = Set(contentsTitleIndices)
        result.formUnion(offDestinationOutlineMatches)
        if let firstContentsTitle {
            result.formUnion(contentsEntries.filter { $0 > firstContentsTitle })
        } else {
            result.formUnion(pageReferencedEntries)
        }
        return result
    }

    private static func isTableOfContentsTitle(_ value: String) -> Bool {
        let key = normalized(value)
        return ["contents", "tableofcontents", "contentscontinued", "tableofcontentscontinued"].contains(key)
    }

    private static func looksLikeTableOfContentsEntry(_ value: String) -> Bool {
        if looksLikePageReferencedTableOfContentsEntry(value) {
            return true
        }
        let text = cleaned(value)
        return text.range(
            of: #"(?i)^(?:chapter\s+)?(?:\d+|[ivxlcdm]+)\s*(?:[.):-]|[-–—])\s*\S+"#,
            options: .regularExpression
        ) != nil
    }

    private static func looksLikePageReferencedTableOfContentsEntry(_ value: String) -> Bool {
        let text = cleaned(value)
        return text.range(of: #"(?:\.{2,}|…+)\s*\d{0,4}$"#, options: .regularExpression) != nil
            || text.range(of: #"^\S.+\s+\d{1,4}$"#, options: .regularExpression) != nil
    }

    private static func outlineHeadings(in document: PDFDocument) -> [OutlineHeading] {
        guard let root = document.outlineRoot else { return [] }
        var result: [OutlineHeading] = []
        collectOutlineChildren(root, level: 1, document: document, result: &result)
        return result
    }

    private static func collectOutlineChildren(
        _ outline: PDFOutline,
        level: Int,
        document: PDFDocument,
        result: inout [OutlineHeading]
    ) {
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            if let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               let page = child.destination?.page {
                result.append(OutlineHeading(
                    id: result.count,
                    title: title,
                    level: min(6, max(1, level)),
                    pageIndex: document.index(for: page)
                ))
            }
            collectOutlineChildren(child, level: level + 1, document: document, result: &result)
        }
    }

    private static func appendHeading(_ text: String, level: Int, to output: inout [String]) {
        if output.last?.isEmpty == false { output.append("") }
        output.append("\(String(repeating: "#", count: min(6, max(1, level)))) \(text)")
        output.append("")
    }

    private static func appendParagraph(_ text: String, to output: inout [String]) {
        output.append(text)
    }

    /// PDFKit merges a footer stamp and the page number on the same baseline into one line
    /// ("Downloaded on 25 September 2026 3"), so a page marker may lead or trail the stamp.
    static func isDownloadStamp(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:(?:page\s+)?(?:\d{1,4}|[ivxlcdm]{1,7})\s+)?(?:Downloaded|Retrieved|Accessed)\s+(?:on\s+|from\s+.{1,160}?\s+on\s+)(?:\d{1,4}[./-]\d{1,2}[./-]\d{1,4}|\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}|[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{4})(?:\s+(?:at\s+)?\d{1,2}:\d{2}(?::\d{2})?(?:\s*(?:AM|PM|UTC|GMT))?)?\s*\.?(?:\s+(?:page\s+)?(?:\d{1,4}|[ivxlcdm]{1,7})(?:\s+of\s+\d{1,4})?)?\s*$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func cleaned(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        cleaned(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    /// PDF bookmarks commonly omit the visible section number (for example,
    /// bookmark "Introduction" versus page text "1 Introduction"). Treating
    /// those as different headings duplicates the same authored destination.
    private static func headingKey(_ value: String) -> String {
        let withoutSectionNumber = cleaned(value).replacingOccurrences(
            of: #"^(?:chapter\s+)?(?:\d+(?:\.\d+)*|[ivxlcdm]+)[\s.):-]+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return normalized(withoutSectionNumber.isEmpty ? value : withoutSectionNumber)
    }
}
