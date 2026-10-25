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
        /// Where the entry points on its page, when the PDF says (v2 only).
        var point: CGPoint? = nil
    }

    private struct TextLine {
        var text: String
        var pointSize: CGFloat
        var isBold: Bool
        var bounds: CGRect?
        /// The size most of the line's visible characters are set in. `pointSize` is the
        /// first character's, which a leading marker or subscript skews (#592).
        var mainPointSize: CGFloat = 0
        /// Character ranges of `text` set as superscripts (v2 only).
        var superscripts: [Range<Int>] = []
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
            if !cleanedTitle.isEmpty, !PDFItemTitle.isPlaceholder(cleanedTitle) {
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

    static func structuredDocument(from url: URL, wordListURL: URL? = bundledWordListURL) throws -> StructuredDocument {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadableDocument
        }
        return try structuredDocument(from: document, wordListURL: wordListURL)
    }

    static func structuredDocument(
        from document: PDFDocument,
        sourceSHA256: String? = nil,
        wordListURL: URL? = bundledWordListURL
    ) throws -> StructuredDocument {
        StructuredDocumentBuilder.build(
            lines: try structuredLines(from: document, wordListURL: wordListURL),
            engine: "pdfkit_baseline",
            version: structuredExtractionVersion,
            pageCount: document.pageCount,
            sourceSHA256: sourceSHA256
        )
    }

    /// The paper's DOI or arXiv id from its first two pages, with the metadata's authors,
    /// year and title, so a Margin note can be matched in Zotero (#206). Nil without an id.
    static func bibliography(for document: PDFDocument) -> PDFBibliography? {
        let attributes = document.documentAttributes
        return BibliographicReferenceExtractor.extract(
            pageTexts: (0..<min(2, document.pageCount)).compactMap { document.page(at: $0)?.string },
            metadataTitle: attributes?[PDFDocumentAttribute.titleAttribute] as? String,
            metadataAuthor: attributes?[PDFDocumentAttribute.authorAttribute] as? String,
            metadataCreationDate: attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date
        )
    }

    /// The item title v1 gave a PDF: its metadata title, else its first level-1
    /// heading (ObsidianMarkdownParser took the first "# " line). The same title
    /// gives a re-imported PDF the same item id, so the edition guard applies.
    static func itemTitle(for document: PDFDocument, structured: StructuredDocument) -> String? {
        let characters = Array(structured.text)
        func text(of segment: StructuredDocument.Segment) -> String {
            String(characters[segment.range.start..<min(segment.range.end, characters.count)])
        }
        // v1 made each line of a printed title a heading; v2 reads the title as one
        // segment (#272) but keeps v1's level on it, so its first line is v1's title.
        let firstHeading = structured.segments.first { ($0.role == .heading || $0.role == .title) && $0.level == 1 }.map {
            text(of: $0).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
        // With an outline the printed title has no heading level, so the first level-1 heading is
        // the outline's "1 Introduction" (#2062): take the printed title instead.
        let printedTitles = headingOutline(in: document).isEmpty ? []
            : structured.segments.filter { $0.role == .title }.map(text(of:))
        return PDFItemTitle.choose(
            metadata: (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).map(cleaned),
            printedTitles: printedTitles,
            firstHeading: firstHeading
        )
    }

    /// The outline entries that can be headings. Merged PDFs can carry a bookmark per source
    /// file ("main.pdf"): not a heading (#355).
    private static func headingOutline(in document: PDFDocument) -> [OutlineHeading] {
        outlineHeadings(in: document).filter {
            $0.title.range(of: #"\.pdf$"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
    }

    /// Every line of the PDF in reading order with a role. Nothing is dropped
    /// except margin stamps (`isSideStamp`): what v1 cut (running heads, contents
    /// pages, the reference list) is labelled, and the speech path decides what is
    /// heard (I14).
    static func structuredLines(from document: PDFDocument, wordListURL: URL? = bundledWordListURL) throws -> [StructuredDocumentLine] {
        let outline = headingOutline(in: document)
        var pages: [[TextLine]] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { pages.append([]); continue }
            let pageBox = page.bounds(for: .mediaBox)
            // A margin stamp is the repository's or publisher's mark, not part of the text. It is
            // dropped here, not labelled page furniture: a labelled one was silent but still the
            // first sentence in Now (#2061).
            pages.append(lines(from: page, detectSuperscripts: true).filter {
                !isSideStamp($0.text, bounds: $0.bounds, pageBox: pageBox)
            })
        }
        respaceGluedText(&pages, wordListURL: wordListURL)
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
        let cover = titleOnlyCover(pages: pages, bodySize: bodySize)
        var result: [StructuredDocumentLine] = []
        // Outline entries on a page with no text start their chapter on the next page.
        var carriedOutline: [StructuredDocumentLine.OutlineEntry] = []

        // The metadata title, unless the first page already prints it (v1 read it twice).
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let cleanedTitle = PDFItemTitle.isPlaceholder(title) ? "" : cleaned(title)
            let firstPage = normalized(pages.first?.prefix(20).map(\.text).joined(separator: " ") ?? "")
            if !cleanedTitle.isEmpty, !firstPage.contains(normalized(cleanedTitle)) {
                result.append(StructuredDocumentLine(text: cleanedTitle, role: .title, pageIndex: 0, level: 1))
            }
        }

        // A contents page comes before the body (#354): the heuristic runs on a page with a
        // "Contents" title, or on pages before the first outline destination, or, with no
        // outline, before any heading has been read.
        let firstOutlinePage = outline.map(\.pageIndex).min()
        for (pageIndex, pageLines) in pages.enumerated() {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageOutline = outline.filter { $0.pageIndex == pageIndex }
            let beforeBody = firstOutlinePage.map { pageIndex < $0 } ?? !result.contains(where: { $0.role == .heading })
            let tableOfContentsLines = beforeBody || pageLines.contains(where: { isTableOfContentsTitle($0.text) })
                ? tableOfContentsLineIndices(in: pageLines, pageIndex: pageIndex, outline: outline, strict: true)
                : []
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
            let titlePage: [Int: StructuredDocument.Role]
            if let cover, pageIndex == 0 {
                titlePage = cover.roles
            } else if pageIndex < 2 {
                // The page after a title-only cover carries the abstract, so it is read as the
                // first page, and its repeat of the cover's title is not read again (#1144).
                titlePage = titlePageRoles(
                    in: pageLines,
                    isFirstPage: pageIndex == 0 || (pageIndex == 1 && cover != nil),
                    bodySize: bodySize,
                    pageBox: page.bounds(for: .mediaBox),
                    coverTitleKey: pageIndex == 1 ? cover?.titleKey : nil
                )
            } else {
                titlePage = [:]
            }
            let footnotes = footnoteLineIndices(in: pageLines, bodySize: bodySize, pageBox: page.bounds(for: .mediaBox))
            // The line each outline entry names on its page is a heading, even where a
            // running head would sit (#347): one line, or two when the heading wraps
            // (#355). A running head that repeats the title takes it only when no other
            // line on the page does. An entry no line matches starts a chapter without
            // adding text, so its title is never read in the wrong place (#355).
            var outlineLines: [Int: (heading: OutlineHeading, text: String, span: Int)] = [:]
            var anchors: [Int: [StructuredDocumentLine.OutlineEntry]] = [:]
            for heading in pageOutline {
                let keys = outlineKeys(heading.title)
                var matches: [(start: Int, text: String, span: Int)] = []
                for index in pageLines.indices where !tableOfContentsLines.contains(index)
                    && !outlineLines.contains(where: { $0.key <= index && index < $0.key + $0.value.span }) {
                    if !outlineKeys(pageLines[index].text).isDisjoint(with: keys) {
                        matches.append((index, pageLines[index].text, 1))
                    } else if index + 1 < pageLines.count, !tableOfContentsLines.contains(index + 1),
                              outlineLines[index + 1] == nil,
                              let joined = joinedHeading(pageLines[index].text, pageLines[index + 1].text, keys: keys) {
                        matches.append((index, joined, 2))
                    }
                }
                if let chosen = matches.first(where: { furnitureRole(pageLines[$0.start], page: page) == nil }) ?? matches.first {
                    outlineLines[chosen.start] = (heading, chosen.text, chosen.span)
                } else if let line = outlineAnchorLine(for: heading, keys: keys, in: pageLines, excluding: tableOfContentsLines,
                                                       isFurniture: { furnitureRole($0, page: page) != nil }) {
                    anchors[line, default: []].append(.init(title: cleaned(heading.title), level: heading.level))
                } else {
                    carriedOutline.append(.init(title: cleaned(heading.title), level: heading.level))
                }
            }
            if !pageLines.isEmpty, !carriedOutline.isEmpty {
                anchors[0, default: []].insert(contentsOf: carriedOutline, at: 0)
                carriedOutline = []
            }
            // A line read as a heading by its type alone, with no other role that comes first.
            func isTypeOnlyHeading(_ index: Int) -> Bool {
                let line = pageLines[index]
                return outlineLines[index] == nil && furnitureRole(line, page: page) == nil
                    && !tableOfContentsLines.contains(index) && titlePage[index] == nil && !footnotes.contains(index)
                    && !tableLines.contains(index) && !figureLines.contains(index) && !layout.looksLikeDisplayMath(line)
                    && outline.isEmpty && (firstContentsPage.map({ pageIndex > $0 }) ?? true)
                    && isVisualHeading(line, bodySize: bodySize)
            }
            var wrappedHeadingLines = Set<Int>()
            var resultIndex: [Int: Int] = [:]
            for (lineIndex, line) in pageLines.enumerated() {
                if lineIndex > 0, outlineLines[lineIndex - 1]?.span == 2 || wrappedHeadingLines.contains(lineIndex) {
                    resultIndex[lineIndex] = result.count - 1
                    continue
                }
                resultIndex[lineIndex] = result.count
                if let match = outlineLines[lineIndex] {
                    result.append(StructuredDocumentLine(text: match.text, role: .heading, pageIndex: pageIndex, level: match.heading.level))
                } else if let role = furnitureRole(line, page: page) {
                    result.append(StructuredDocumentLine(text: line.text, role: role, pageIndex: pageIndex))
                } else if tableOfContentsLines.contains(lineIndex) {
                    result.append(StructuredDocumentLine(text: line.text, role: .frontMatter, pageIndex: pageIndex))
                } else if let role = titlePage[lineIndex] {
                    // A printed title keeps the heading level v1 gave it, so `itemTitle`
                    // still finds v1's title and a re-imported PDF stays the same item.
                    let v1Level: Int? = role == .title && outline.isEmpty
                        && (firstContentsPage.map({ pageIndex > $0 }) ?? true)
                        && isVisualHeading(line, bodySize: bodySize)
                        ? visualHeadingLevel(line, bodySize: bodySize) : nil
                    result.append(StructuredDocumentLine(text: line.text, role: role, pageIndex: pageIndex, level: v1Level))
                } else if footnotes.contains(lineIndex) {
                    result.append(StructuredDocumentLine(text: line.text, role: .footnote, pageIndex: pageIndex))
                } else if tableLines.contains(lineIndex) {
                    result.append(StructuredDocumentLine(text: line.text, role: .table, pageIndex: pageIndex))
                } else if figureLines.contains(lineIndex) {
                    result.append(StructuredDocumentLine(text: line.text, role: .figureText, pageIndex: pageIndex))
                } else if layout.looksLikeDisplayMath(line) {
                    result.append(StructuredDocumentLine(text: line.text, role: .equation, pageIndex: pageIndex))
                } else if outline.isEmpty
                    && (firstContentsPage.map({ pageIndex > $0 }) ?? true)
                    && isVisualHeading(line, bodySize: bodySize) {
                    // A heading printed over two or three lines is one heading (#1144). Not the
                    // first level-1 heading: its first line is the item title v1 gave the PDF,
                    // and so its item id (`itemTitle`).
                    let level = visualHeadingLevel(line, bodySize: bodySize)
                    let mayJoin = level != 1 || result.contains { ($0.role == .heading || $0.role == .title) && $0.level == 1 }
                    var run = [lineIndex]
                    while mayJoin, run.count < PDFWrappedHeading.maximumLines, let last = run.last, last + 1 < pageLines.count,
                          isTypeOnlyHeading(last + 1),
                          let upper = wrappedHeadingLine(pageLines[last], pageIndex: pageIndex),
                          let lower = wrappedHeadingLine(pageLines[last + 1], pageIndex: pageIndex),
                          PDFWrappedHeading.continues(upper, with: lower),
                          PDFWrappedHeading.joined((run + [last + 1]).map { pageLines[$0].text }).count
                            <= PDFWrappedHeading.maximumJoinedLength {
                        run.append(last + 1)
                    }
                    wrappedHeadingLines.formUnion(run.dropFirst())
                    let text = run.count == 1 ? line.text : PDFWrappedHeading.joined(run.map { pageLines[$0].text })
                    result.append(StructuredDocumentLine(text: text, role: .heading, pageIndex: pageIndex, level: level))
                } else {
                    result.append(StructuredDocumentLine(text: line.text, role: .body, pageIndex: pageIndex, superscripts: line.superscripts))
                }
            }
            for (lineIndex, entries) in anchors {
                guard let index = resultIndex[lineIndex] else { continue }
                result[index].outlineEntries += entries
            }
        }
        if !carriedOutline.isEmpty, !result.isEmpty {
            result[result.count - 1].outlineEntries += carriedOutline
        }
        labelReferenceLists(&result)
        joinEquationFragments(&result)
        markSoftHyphens(&result)
        return result
    }

    /// Marks line-end hyphens that only split a word for layout: "agree-" + "ment"
    /// makes "agreement", a dictionary word, so it is spoken whole (#220 T4). A
    /// compound broken at its hyphen ("open-" + "ended", "chain-of-" + "thought")
    /// keeps it. `isWord` is the system dictionary; tests pass their own.
    static func markSoftHyphens(_ lines: inout [StructuredDocumentLine], isWord: ([String]) -> Set<String> = dictionaryWords) {
        var candidates: [(index: Int, word: String)] = []
        for index in lines.indices.dropLast() where lines[index].text.hasSuffix("-") && lines[index + 1].role == lines[index].role {
            guard let leftToken = lines[index].text.dropLast().split(separator: " ").last,
                  let rightToken = lines[index + 1].text.split(separator: " ").first,
                  !leftToken.contains("-") else { continue }
            let left = String(leftToken.reversed().prefix(while: \.isLetter).reversed())
            let right = String(rightToken.prefix(while: \.isLetter))
            guard !left.isEmpty, right.first?.isLowercase == true, left.count == leftToken.count else { continue }
            candidates.append((index, left + right))
        }
        guard !candidates.isEmpty else { return }
        let words = isWord(Array(Set(candidates.map(\.word))))
        for candidate in candidates where words.contains(candidate.word) {
            lines[candidate.index].endsWithSoftHyphen = true
        }
    }

    /// The bundled Kitten lexicon, the word list the glued-text spacer splits with.
    static var bundledWordListURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Kitten/lexicon.tsv")
    }

    /// Puts back word spaces a PDF's text layer lost ("Amodelofbottleneck pressure"), before
    /// any rule reads the lines: the citation, footnote and heading rules all need them (#2370).
    /// Only a document `PDFWordSpacer.isGlued` flags changes, and the word list is opened only
    /// when some line holds a long letter run. Superscript ranges move with the text.
    private static func respaceGluedText(_ pages: inout [[TextLine]], wordListURL: URL?) {
        let run = "\\p{L}{\(PDFWordSpacer.gluedRunLength),}"
        guard pages.contains(where: { $0.contains { $0.text.range(of: run, options: .regularExpression) != nil } }),
              let wordListURL, let wordList = try? SortedWordList(contentsOf: wordListURL) else { return }
        let texts = pages.flatMap { $0.map(\.text) }
        let spacer = PDFWordSpacer(isWord: wordList.contains, context: texts)
        guard spacer.isGlued(texts) else { return }
        // A word broken by a line-end hyphen is split whole: its start on the line before
        // ("Nev-") and its end on the line after ("tised" of "adver-"). The line before is
        // read respaced, so its last word is "AI" of "Of all AI-", not "OfallAI".
        let positions = pages.indices.flatMap { page in pages[page].indices.map { (page, $0) } }
        var previous = ""
        for (position, (pageIndex, lineIndex)) in positions.enumerated() {
            let line = pages[pageIndex][lineIndex]
            defer { previous = pages[pageIndex][lineIndex].text }
            let carried = previous.hasSuffix("-") ? String(previous.dropLast().reversed().prefix(while: \.isLetter).reversed()) : ""
            let next = position + 1 < texts.count ? texts[position + 1] : ""
            let continued = line.text.hasSuffix("-") ? String(next.prefix(while: \.isLowercase)) : ""
            let insertions = spacer.spaceInsertions(in: line.text, protected: line.superscripts, carried: carried, continued: continued)
            guard !insertions.isEmpty else { continue }
            pages[pageIndex][lineIndex].text = PDFWordSpacer.applying(insertions, to: line.text)
            pages[pageIndex][lineIndex].superscripts = line.superscripts.map { PDFWordSpacer.shifted($0, by: insertions) }
        }
    }

    private static func wrappedHeadingLine(_ line: TextLine, pageIndex: Int) -> PDFWrappedHeading.Line? {
        guard let bounds = line.bounds, !bounds.isNull else { return nil }
        return PDFWrappedHeading.Line(
            text: line.text, pageIndex: pageIndex, pointSize: Double(line.pointSize), isBold: line.isBold,
            minX: Double(bounds.minX), maxX: Double(bounds.maxX), minY: Double(bounds.minY), maxY: Double(bounds.maxY)
        )
    }

    /// The system spell checker's English dictionary. UITextChecker is UIKit, so the
    /// lookups run on the main thread, all at once.
    static func dictionaryWords(_ words: [String]) -> Set<String> {
        let check = { () -> Set<String> in
            let checker = UITextChecker()
            let language = UITextChecker.availableLanguages.first { $0.hasPrefix("en") } ?? "en_US"
            return Set(words.filter { word in
                checker.rangeOfMisspelledWord(
                    in: word, range: NSRange(location: 0, length: (word as NSString).length),
                    startingAt: 0, wrap: false, language: language
                ).location == NSNotFound
            })
        }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
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
            // Three entries, as v1 required (#220 audit 4): a short list is still a list.
            guard tail.filter({ looksLikeBibliographyEntry($0.text) }).count >= 3 else { continue }
            // The heading is part of the list: "References skipped." says it once,
            // instead of "References", then "References skipped."
            lines[index].role = .reference
            var cursor = index + 1
            while cursor < lines.count, lines[cursor].role != .heading, !startsAppendix(lines[cursor].text) {
                // A title with formula-like text inside the list is still a reference, not
                // an equation that would split the list into repeated notices.
                if lines[cursor].role == .body || lines[cursor].role == .equation { lines[cursor].role = .reference }
                cursor += 1
            }
            index = labelReferencesResumedAfterHeadings(&lines, from: cursor) - 1
        }
    }

    /// On a two-column reference page PDFKit can read a heading such as "Appendix"
    /// between the columns, so the second column's entries follow it (#220 T4).
    /// After the headings, entries keep the reference role while a new entry starts
    /// within every few lines; a sentence of prose after a finished entry ends them.
    /// Returns the index after the last line it labelled (or `start`).
    private static func labelReferencesResumedAfterHeadings(_ lines: inout [StructuredDocumentLine], from start: Int) -> Int {
        var first = start
        while first < lines.count, lines[first].role == .heading || (lines[first].role == .body && startsAppendix(lines[first].text)) { first += 1 }
        guard first > start, first < lines.count, lines[first].role == .body,
              looksLikeBibliographyEntry(lines[first].text) else { return start }
        var end = first
        var entryStart = first
        while end < lines.count, lines[end].role == .body, !startsAppendix(lines[end].text) {
            let text = lines[end].text
            if looksLikeBibliographyEntry(text) {
                entryStart = end
            } else {
                if end - entryStart > 4 { break }
                // "Names. 2024." is followed by the title, which may read like prose.
                let titleLine = end == entryStart + 1
                    && lines[entryStart].text.range(of: #"(?:19|20)[0-9]{2}[a-z]?\.\s*$"#, options: .regularExpression) != nil
                // A sentence ends the references: after a finished entry, or whenever it
                // opens like one ("The following LLMs were integrated ...", #220 T4).
                let opensSentence = text.range(of: #"^(?:The|This|These|We|Our|In|To|For|As|Here|It|Each|All)\s"#, options: .regularExpression) != nil
                if !titleLine, looksLikeProse(text),
                   opensSentence || lines[end - 1].text.trimmingCharacters(in: .whitespaces).hasSuffix(".") { break }
            }
            end += 1
        }
        for index in first..<end { lines[index].role = .reference }
        return end
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
    private static func titlePageRoles(in lines: [TextLine], isFirstPage: Bool, bodySize: CGFloat, pageBox: CGRect, coverTitleKey: String? = nil) -> [Int: StructuredDocument.Role] {
        var roles: [Int: StructuredDocument.Role] = [:]
        if isFirstPage {
            // Author notes set as a footnote block at the bottom of page 1 ("• Corresponding
            // author.", "• Email: …", "• The authors are with …"): small print starting with
            // a note marker, with its wrapped lines. PDFKit can read it in the middle of a
            // sentence (#250, arXiv 2608.09666).
            let bottom = pageBox.minY + pageBox.height * 0.3
            func inBottomSmallPrint(_ line: TextLine, size: CGFloat) -> Bool {
                guard let bounds = line.bounds else { return false }
                return line.pointSize > 0 && line.pointSize < bodySize - 0.5
                    && abs(line.pointSize - size) < 0.3 && bounds.midY < bottom
            }
            var index = 0
            while index < lines.count {
                let size = lines[index].pointSize
                guard inBottomSmallPrint(lines[index], size: size),
                      lines[index].text.range(of: #"^[•∗*†‡§¶✉]\s?\S"#, options: .regularExpression) != nil else {
                    index += 1
                    continue
                }
                while index < lines.count, inBottomSmallPrint(lines[index], size: size) {
                    roles[index] = .frontMatter
                    index += 1
                }
            }
        }
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
              let abstract = lines.firstIndex(where: { isAbstractLabel($0.text) }), abstract > 0 else { return roles }
        // Display type before the abstract is the title page, not section headings
        // (#272): the largest run of real lines is the title, read once as one segment;
        // display-size author lines are authors; affiliations and short badges ("v1",
        // a journal logo such as "sensors") are front matter; any other display line
        // (a subtitle) is read as title.
        let display = (0..<abstract).filter {
            roles[$0] == nil && lines[$0].pointSize >= bodySize + 1.5 && !looksLikeSectionHeading(lines[$0].text)
        }
        func wordCount(_ index: Int) -> Int { lines[index].text.split(separator: " ").count }
        let titleCandidates = display.contains(where: { wordCount($0) >= 4 }) ? display.filter { wordCount($0) >= 4 } : display
        if let titleSize = titleCandidates.map({ lines[$0].pointSize }).max(),
           let first = titleCandidates.first(where: { abs(lines[$0].pointSize - titleSize) < 0.3 }) {
            var index = titleRunStart(in: lines, from: first, titleSize: titleSize, display: Set(display))
            let runStart = index
            while index < abstract, roles[index] == nil, abs(lines[index].pointSize - titleSize) < 0.3 {
                roles[index] = .title
                index += 1
            }
            // The title again, after a cover that already printed it (#1144).
            if let coverTitleKey, normalized((runStart..<index).map { lines[$0].text }.joined(separator: " ")) == coverTitleKey {
                for repeated in runStart..<index { roles[repeated] = .frontMatter }
            }
        }
        for index in display where roles[index] == nil {
            let text = lines[index].text
            if looksLikeAuthorList(text) {
                roles[index] = .authors
            } else if wordCount(index) <= 3 || looksLikeAffiliation(text) {
                roles[index] = .frontMatter
            } else {
                roles[index] = .title
            }
        }
        for index in 0..<abstract where roles[index] == nil {
            if lines[index].pointSize >= bodySize + 1.5 { continue }  // a section heading, kept above
            let text = lines[index].text
            if looksLikeAuthorList(text) {
                roles[index] = .authors
            } else if !looksLikeProse(text) {
                roles[index] = .frontMatter
            }
        }
        return roles
    }

    static func isAbstractLabel(_ text: String) -> Bool {
        text.range(of: #"^(?:abstract|summary|a b s t r a c t)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A cover page that prints only the title (and a series line or date), with the
    /// authors and "Abstract" on the next page, which repeats the title (#1144,
    /// Cambridge CASP working paper: a 35 pt three-line title, then the same title in
    /// two lines). The cover's largest-type run is the title, read once; its other
    /// lines are front matter. Nil unless page 1 has the abstract, so a cover that
    /// holds real text, or a first page with its own abstract, is read as before.
    private static func titleOnlyCover(pages: [[TextLine]], bodySize: CGFloat) -> (roles: [Int: StructuredDocument.Role], titleKey: String)? {
        // A label is a line of its own ("Abstract"), not a sentence that starts "Summary statistics are".
        func isLabel(_ line: TextLine) -> Bool { isAbstractLabel(line.text) && line.text.split(separator: " ").count <= 3 }
        guard pages.count >= 2, let cover = pages.first, !cover.isEmpty, cover.count <= 12,
              !cover.contains(where: { isAbstractLabel($0.text) || looksLikeProse($0.text) }),
              // Text in body type, however short its lines, means the page is not only a cover.
              !cover.contains(where: { $0.pointSize < bodySize + 1.5 && $0.text.count >= 30 }),
              pages[1].firstIndex(where: isLabel).map({ $0 > 0 }) == true else { return nil }
        let display = cover.indices.filter { cover[$0].pointSize >= bodySize + 1.5 && !looksLikeSectionHeading(cover[$0].text) }
        guard let titleSize = display.map({ cover[$0].pointSize }).max(),
              let first = display.first(where: { abs(cover[$0].pointSize - titleSize) < 0.3 }) else { return nil }
        var roles: [Int: StructuredDocument.Role] = [:]
        var end = first
        while end < cover.count, abs(cover[end].pointSize - titleSize) < 0.3 {
            roles[end] = .title
            end += 1
        }
        let words = (first..<end).flatMap { cover[$0].text.split(separator: " ") }
        guard words.count >= 3 else { return nil }
        // The authors are on the next page, so a series line or imprint here is not a name list.
        for index in cover.indices where roles[index] == nil { roles[index] = .frontMatter }
        return (roles, normalized((first..<end).map { cover[$0].text }.joined(separator: " ")))
    }

    /// Where the title starts, given the first title line of four or more words (#692).
    /// A short opening line ("Understanding uncertainty" above "in modern machine
    /// learning systems") isn't a candidate, so the title also takes the display lines
    /// directly above it in the same type: same size and weight, and no more than a
    /// line of that type above. A badge set apart from the title, or an article-type
    /// label ("Research Article"), stays out.
    private static func titleRunStart(in lines: [TextLine], from first: Int, titleSize: CGFloat, display: Set<Int>) -> Int {
        let articleType = #"(?i)^(?:(?:original|research|review|brief|short|mini|technical|full|regular|invited|systematic)\s+)*(?:article|paper|report|communication|letter|review|note|perspective|commentary|editorial|preprint|research|opinion|methods?)$"#
        var start = first
        while start > 0, display.contains(start - 1) {
            let above = lines[start - 1], line = lines[start]
            // Against the title size, as the forward run checks, so the run still starts there.
            guard abs(above.pointSize - titleSize) < 0.3, above.isBold == line.isBold,
                  let upper = above.bounds, let lower = line.bounds,
                  upper.minY >= lower.midY, upper.minY - lower.maxY <= line.pointSize,
                  above.text.range(of: articleType, options: .regularExpression) == nil else { break }
            start -= 1
        }
        return start
    }

    /// "1 Introduction", "2.1 Methods", "Background": a section heading that can sit
    /// on page 1 above an abstract read out of order, and stays a chapter.
    static func looksLikeSectionHeading(_ text: String) -> Bool {
        text.range(of: #"^(?:[0-9]+(?:\.[0-9]+)*\.?\s+\p{Lu}|(?:introduction|background|methods?|results|discussion|conclusions?)\s*$)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "1BioFrontiers Institute, University of Colorado": an institution or address.
    static func looksLikeAffiliation(_ text: String) -> Bool {
        text.range(of: #"(?i)univ|department|dept\.|institut|laborator|hospital|college|school of|faculty of|academy|research cent"#,
                   options: .regularExpression) != nil
    }

    /// Footnotes at the foot of a page (#250): a block in small type in the bottom 40%
    /// of the page, starting on a line that opens with a note marker ("1 ", "†", "2https")
    /// which the page's body text also sets as a superscript, plus the block's wrapped
    /// lines at the same size. The first line must read as a sentence or a link, so
    /// small math is left alone. A table note or figure legend in the same place has no
    /// matching body superscript, or runs on from small print just above it without
    /// the gap a footnote rule leaves. Emulated with PyMuPDF over the C1 corpus, it
    /// takes no body, caption or table text.
    private static func footnoteLineIndices(in lines: [TextLine], bodySize: CGFloat, pageBox: CGRect) -> Set<Int> {
        let superscriptDigits: [Character: Character] = ["⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4",
                                                         "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9"]
        func digits(_ text: String) -> String {
            String(text.map { superscriptDigits[$0] ?? $0 })
        }
        func isSmall(_ line: TextLine) -> Bool {
            line.mainPointSize > 0 && line.mainPointSize < bodySize - 0.5
        }
        // Markers the body sets as superscripts on this page: "1", "12", "†", "a". Any line
        // not in small type counts: PDFKit can report a page's body a point above the
        // document's body size (TeX Gyre Pagella, 10.9 pt read as 11.8 to 12.1), and a
        // near-exact match then found no markers at all (#2370).
        var bodyMarkers = Set<String>()
        for line in lines where !isSmall(line) {
            let characters = Array(line.text)
            for range in line.superscripts where range.lowerBound >= 0 && range.upperBound <= characters.count {
                let label = digits(String(characters[range]))
                for piece in label.split(whereSeparator: { ",–- ".contains($0) }) where !piece.isEmpty {
                    bodyMarkers.insert(String(piece))
                }
            }
        }
        guard !bodyMarkers.isEmpty else { return [] }
        let bottom = pageBox.minY + pageBox.height * 0.4
        let continuationBottom = pageBox.minY + pageBox.height * 0.45
        var result = Set<Int>()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let text = digits(line.text)
            guard isSmall(line), let bounds = line.bounds, bounds.midY < bottom,
                  let match = text.range(of: #"^([0-9]{1,3}|[*†‡§¶#]|[a-z])(?=\s|\p{Lu}|\(|https?:|www\.)"#,
                                         options: .regularExpression) else {
                index += 1
                continue
            }
            let marker = String(text[match]).trimmingCharacters(in: .whitespaces)
            let rest = String(text[match.upperBound...])
            let letters = rest.filter(\.isLetter).count
            let isLink = rest.range(of: #"https?:|www\."#, options: .regularExpression) != nil
            let readsAsNote = letters >= 15 && (rest.split(separator: " ").count >= 3 || isLink)
            // A new block: after other type, after a gap (the footnote rule), or up a column.
            var startsBlock = true
            if index > 0, let previous = lines[index - 1].bounds, abs(lines[index - 1].mainPointSize - line.mainPointSize) < 0.3 {
                startsBlock = previous.midY - bounds.midY > line.mainPointSize * 1.8 || bounds.midY > previous.midY
            }
            guard bodyMarkers.contains(marker), readsAsNote, startsBlock else {
                index += 1
                continue
            }
            let size = line.mainPointSize
            while index < lines.count, abs(lines[index].mainPointSize - size) < 0.3,
                  let next = lines[index].bounds, next.midY < continuationBottom {
                result.insert(index)
                index += 1
            }
        }
        return result
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

    /// "Appendix B. …", "Supplementary …", "Table 3 …": never a reference entry, and an
    /// appendix line ends a reference list even when PDFKit didn't see a heading.
    static func startsAppendixOrFloat(_ text: String) -> Bool {
        text.range(of: #"^(?:Appendix|APPENDIX|Supplementary|SUPPLEMENTARY|Table|TABLE|Fig\.|Figure|FIGURE|Section|Chapter)\b"#, options: .regularExpression) != nil
    }

    /// "Appendix", "Appendix B", and with a section label in front, "A Appendix".
    static func startsAppendix(_ text: String) -> Bool {
        text.range(of: #"^(?:[A-Z](?:\.[0-9]+)*\.?\s+)?(?:Appendix|APPENDIX)(?:\s+[A-Z0-9]|\s*$|:)"#, options: .regularExpression) != nil
    }

    /// Text printed sideways in a page's outer margin, like arXiv's
    /// "arXiv:2607.28282v1 [cs.CL] 30 Jul 2026" or a publisher's download line: not part
    /// of the text, never read or shown (#162, #220, #2061). The arXiv stamp is also known by
    /// its form, so it is taken when PDFKit reports it with upright bounds or none.
    static func isSideStamp(_ text: String, bounds: CGRect?, pageBox: CGRect) -> Bool {
        if isArXivStamp(text) { return true }
        guard let bounds else { return false }
        let rotated = bounds.height > bounds.width * 4 && bounds.width < 40 && bounds.height > 60
        let inSideMargin = bounds.maxX < pageBox.minX + pageBox.width * 0.15 || bounds.minX > pageBox.maxX - pageBox.width * 0.15
        return rotated && inSideMargin
    }

    /// The whole line is arXiv's stamp: "arXiv:1706.03762v7 [cs.CL] 2 Aug 2023", with the
    /// category missing ("[]") or the version left out, or an old-style id
    /// ("arXiv:hep-th/9901001v2 [hep-th] 5 Jan 1999"). A sentence that cites an id is not.
    static func isArXivStamp(_ text: String) -> Bool {
        text.range(
            of: #"^\s*arXiv:(?:[0-9]{4}\.[0-9]{4,5}|[a-z][a-z\-]*(?:\.[A-Za-z]{2})?/[0-9]{7})(?:v[0-9]+)?\s*(?:\[[^\]]*\])?\s*[0-9]{1,2}\s+[A-Z][a-z]{2,8}\.?\s+[0-9]{4}\s*$"#,
            options: .regularExpression
        ) != nil
    }

    /// The first line of a bibliography entry in the common styles: numbered
    /// ("[12] …", "12. …"), author first ("Agarwal A, …", "Abdul-Hay, S. O., …"), or
    /// any line carrying a parenthesised year or a DOI.
    static func looksLikeBibliographyEntry(_ text: String) -> Bool {
        // "Appendix B. Analysis ..." has the shape of "Agarwal A. ..." but isn't one.
        guard !startsAppendixOrFloat(text) else { return false }
        return text.range(of: #"^\s*(?:\[\^?[0-9]{1,4}\]:?|[0-9]{1,4}[.)])\s+\S"#, options: .regularExpression) != nil
            // ACL/natbib: "Marah Abdin, Sam Ade Jacobs, et al. 2024." (names, then the year)
            || text.range(of: #"^(?:\p{Lu}[\p{L}'’\-]*\.?\s?){2,4}(?:,\s(?:\p{Lu}[\p{L}'’\-]*\.?\s?){1,4})*(?:,?\sand\s(?:\p{Lu}[\p{L}'’\-]*\.?\s?){1,4})?(?:,?\set al\.)?\s*(?:19|20)[0-9]{2}[a-z]?\."#, options: .regularExpression) != nil
            || text.range(of: #"^\p{Lu}[\p{L}'’\-]+(?: [\p{Lu}][\p{L}'’\-]+)?,? (?:\p{Lu}\.?[ -]?){1,3}[,.(]"#, options: .regularExpression) != nil
            || text.range(of: #"\((?:19|20)[0-9]{2}[a-z]?\)|\bdoi[:.]|\b10\.[0-9]{4,}/"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func lines(from page: PDFPage, detectSuperscripts: Bool = false) -> [TextLine] {
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
                let bounds = selection?.bounds(for: page)
                result.append(TextLine(
                    text: text,
                    pointSize: font?.pointSize ?? 0,
                    isBold: font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true,
                    bounds: bounds,
                    mainPointSize: mainPointSize(in: attributed, range: range) ?? font?.pointSize ?? 0,
                    superscripts: detectSuperscripts
                        ? superscriptRanges(in: attributed, lineRange: range, page: page, lineBounds: bounds, cleanedText: text)
                        : []
                ))
            }
            location = NSMaxRange(range)
        }
        return result
    }

    /// Citation and footnote markers set as superscripts ("aptitude,¹", "effects¹²,¹⁴"):
    /// short runs in smaller type, attached to the text before them and not lowered
    /// (a subscript, as in "CO2", isn't one). Ordinals ("20th") and
    /// exponents after a digit ("10⁵") are left alone. PDFKit gives no superscript
    /// attribute, only the size and position. Returns ranges of the cleaned line.
    private static func superscriptRanges(
        in attributed: NSAttributedString,
        lineRange: NSRange,
        page: PDFPage,
        lineBounds: CGRect?,
        cleanedText: String
    ) -> [Range<Int>] {
        guard lineBounds != nil else { return [] }
        var lengthBySize: [CGFloat: Int] = [:]
        var runs: [(range: NSRange, size: CGFloat)] = []
        attributed.enumerateAttribute(.font, in: lineRange) { value, range, _ in
            let size = (value as? UIFont)?.pointSize ?? 0
            lengthBySize[size, default: 0] += range.length
            runs.append((range, size))
        }
        guard runs.count > 1, let main = lengthBySize.max(by: { $0.value < $1.value })?.key, main > 0 else { return [] }
        let source = attributed.string as NSString
        var raised: [NSRange] = []
        for run in runs where run.size > 0 && run.size <= main * 0.8 && run.range.location > lineRange.location {
            var range = run.range
            while range.length > 0, let scalar = UnicodeScalar(source.character(at: NSMaxRange(range) - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                range.length -= 1
            }
            guard range.length > 0, range.length <= 12 else { continue }
            let text = source.substring(with: range)
            guard text.range(of: #"^[0-9,–\-*†‡§¶a-z]+$"#, options: .regularExpression) != nil,
                  !["st", "nd", "rd", "th"].contains(text),
                  let before = UnicodeScalar(source.character(at: range.location - 1)),
                  !CharacterSet.whitespacesAndNewlines.contains(before),
                  !(CharacterSet.decimalDigits.contains(before) && text.allSatisfy(\.isNumber)) else { continue }
            // Level with or above the letters before it; a subscript ("CO2") sits lower.
            // (Some PDFs set citation numbers small but on the baseline.)
            var reference = range.location - 1
            while reference > lineRange.location, let scalar = UnicodeScalar(source.character(at: reference)),
                  !CharacterSet.alphanumerics.contains(scalar) {
                reference -= 1
            }
            let markerBottom = page.characterBounds(at: range.location).minY
            let letterBottom = page.characterBounds(at: reference).minY
            guard markerBottom >= letterBottom - main * 0.15 else { continue }
            raised.append(range)
        }
        guard !raised.isEmpty else { return [] }
        // Map raw UTF-16 offsets to Characters of the cleaned line, cleaning the way
        // `cleaned` does: drop control characters, collapse whitespace, trim.
        let raw = source.substring(with: lineRange)
        var output: [Character] = []
        var rawOffsets: [Int] = []
        var utf16 = lineRange.location
        for character in raw {
            let width = character.utf16.count
            defer { utf16 += width }
            if character.unicodeScalars.allSatisfy({ $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" || $0.value == 0x7F }) { continue }
            if character.isWhitespace {
                if output.last != " " { output.append(" "); rawOffsets.append(utf16) }
                continue
            }
            output.append(character)
            rawOffsets.append(utf16)
        }
        while output.first == " " { output.removeFirst(); rawOffsets.removeFirst() }
        while output.last == " " { output.removeLast(); rawOffsets.removeLast() }
        guard String(output) == cleanedText else { return [] }
        return raised.compactMap { range in
            let kept = rawOffsets.indices.filter { rawOffsets[$0] >= range.location && rawOffsets[$0] < NSMaxRange(range) }
            guard let first = kept.first, let last = kept.last else { return nil }
            return first..<(last + 1)
        }
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

    /// The point size with the most visible characters in `range`; the larger on a tie.
    private static func mainPointSize(in attributed: NSAttributedString, range: NSRange) -> CGFloat? {
        let source = attributed.string as NSString
        var countBySize: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let size = (value as? UIFont)?.pointSize, size > 0 else { return }
            var visible = 0
            for location in run.location..<NSMaxRange(run) {
                if let scalar = UnicodeScalar(source.character(at: location)),
                   !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    visible += 1
                }
            }
            if visible > 0 { countBySize[size, default: 0] += visible }
        }
        return countBySize.max { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value }?.key
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

    /// `strict` is v2's reading (#354); v1 (`markdown(from:)`) keeps the original so the
    /// text of items imported under it doesn't change.
    private static func tableOfContentsLineIndices(
        in lines: [TextLine],
        pageIndex: Int,
        outline: [OutlineHeading],
        strict: Bool = false
    ) -> Set<Int> {
        let contentsTitleIndices = lines.indices.filter { isTableOfContentsTitle(lines[$0].text) }
        let firstContentsTitle = contentsTitleIndices.first
        let offDestinationOutlineMatches = lines.indices.filter { lineIndex in
            let title = headingKey(lines[lineIndex].text)
            if strict {
                // "4.1.1 Experimental Setup" on its own page isn't an entry for "4.3.2
                // Experimental Setup" elsewhere: a same-named entry here, or a different
                // section number, makes it a heading.
                if outline.contains(where: { $0.pageIndex == pageIndex && headingKey($0.title) == title }) { return false }
                let number = sectionNumber(lines[lineIndex].text)
                return outline.contains { heading in
                    heading.pageIndex != pageIndex && headingKey(heading.title) == title
                        && (number == nil || sectionNumber(heading.title) == nil || number == sectionNumber(heading.title))
                }
            }
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
        if strict {
            // A line that continues a sentence isn't an entry: its previous line ends mid-
            // sentence (a lower-case letter, comma, semicolon, hyphen or open bracket).
            // An entry after another entry's page number, or after the "Contents" title, stays.
            result = result.filter { index in
                guard index > 0, !isTableOfContentsTitle(lines[index - 1].text) else { return true }
                return lines[index - 1].text.range(of: #"[\p{Ll},;(\-–]$"#, options: .regularExpression) == nil
            }
        }
        return result
    }

    /// "4.1.1" in "4.1.1 Experimental Setup"; nil when the line has no section number.
    private static func sectionNumber(_ text: String) -> String? {
        let text = cleaned(text)
        guard let range = text.range(of: #"^[0-9]+(?:\.[0-9]+)*"#, options: .regularExpression) else { return nil }
        return String(text[range])
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
                let point = child.destination?.point
                result.append(OutlineHeading(
                    id: result.count,
                    title: title,
                    level: min(6, max(1, level)),
                    pageIndex: document.index(for: page),
                    point: point.flatMap { $0.y == kPDFDestinationUnspecifiedValue ? nil : $0 }
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
    /// Keys for matching outline titles in v2: the text as is, and without a leading
    /// label, numbered or lettered ("4.3", "II.", "A.1", "Appendix A"), which outlines
    /// usually leave off (#355). Both, because a label can look like a word: "LLM as a
    /// Judge" would otherwise lose "LLM" as a roman numeral.
    private static func outlineKeys(_ value: String) -> Set<String> {
        let withoutLabel = cleaned(value).replacingOccurrences(
            of: #"^(?:(?:chapter|appendix|section)\s+)?(?:\d+(?:\.\d+)*|[ivxlcdm]+|[a-z](?:\.?\d+)*)[\s.):-]+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return Set([normalized(value), normalized(withoutLabel)].filter { !$0.isEmpty })
    }

    /// A heading printed over two lines, joined, when it has one of `keys`: "Generative
    /// Mod-" + "els" loses the line-break hyphen; anything else is joined with a space.
    private static func joinedHeading(_ first: String, _ second: String, keys: Set<String>) -> String? {
        var candidates = [first + " " + second]
        if first.hasSuffix("-") { candidates.insert(String(first.dropLast()) + second, at: 0) }
        return candidates.first { !outlineKeys($0).isDisjoint(with: keys) }
    }

    /// Where an outline entry with no printed heading starts its chapter: a line that
    /// opens with the title ("Light stimulation: With fish…") or ends with it (a margin
    /// stamp on the heading's baseline), else the line the entry points at, else the
    /// page's first line that isn't furniture.
    private static func outlineAnchorLine(
        for heading: OutlineHeading,
        keys: Set<String>,
        in lines: [TextLine],
        excluding tableOfContents: Set<Int>,
        isFurniture: (TextLine) -> Bool
    ) -> Int? {
        let candidates = lines.indices.filter { !tableOfContents.contains($0) }
        let long = keys.filter { $0.count >= 6 }
        func printed(_ matches: (String, String) -> Bool) -> Int? {
            candidates.first { index in
                let line = outlineKeys(lines[index].text)
                return long.contains { key in line.contains { matches($0, key) } }
            }
        }
        if let line = printed({ $0.hasPrefix($1) }) ?? printed({ $0.hasSuffix($1) }) {
            return line
        }
        if let point = heading.point {
            let below = candidates.compactMap { index -> (index: Int, gap: CGFloat)? in
                guard let bounds = lines[index].bounds, bounds.maxY <= point.y + 4, bounds.maxX >= point.x else { return nil }
                return (index, point.y - bounds.maxY)
            }
            if let nearest = below.min(by: { $0.gap < $1.gap }) { return nearest.index }
        }
        return candidates.first { !isFurniture(lines[$0]) } ?? candidates.first
    }

    private static func headingKey(_ value: String) -> String {
        let withoutSectionNumber = cleaned(value).replacingOccurrences(
            of: #"^(?:chapter\s+)?(?:\d+(?:\.\d+)*|[ivxlcdm]+)[\s.):-]+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return normalized(withoutSectionNumber.isEmpty ? value : withoutSectionNumber)
    }
}
