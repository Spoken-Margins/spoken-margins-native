import Foundation
import PDFKit
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
        let allLines = pages.flatMap { $0 }
        guard allLines.contains(where: { !$0.text.isEmpty }) else {
            throw ExtractionError.noExtractableText
        }

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
                    appendParagraph(line.text, to: &output)
                } else if let heading = pageOutline.first(where: {
                    !insertedOutlineHeadingIDs.contains($0.id) && headingKey($0.title) == key
                }) {
                    insertedOutlineHeadingIDs.insert(heading.id)
                    appendHeading(line.text, level: heading.level, to: &output)
                } else if outline.isEmpty && isVisualHeading(line, bodySize: bodySize) {
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
        return markdown
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
        return key == "contents" || key == "tableofcontents"
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

    private static func cleaned(_ value: String) -> String {
        value
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
