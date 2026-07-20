import Foundation
import PDFKit
import UIKit

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
        var title: String
        var level: Int
        var pageIndex: Int
    }

    private struct TextLine {
        var text: String
        var pointSize: CGFloat
        var isBold: Bool
    }

    static func markdown(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadableDocument
        }
        return try markdown(from: document)
    }

    static func markdown(from document: PDFDocument) throws -> String {
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
        let outlineByTitle = Dictionary(grouping: outline, by: { normalized($0.title) })
        var insertedOutlineTitles = Set<String>()
        var output: [String] = []

        for (pageIndex, pageLines) in pages.enumerated() {
            let unmatchedPageOutline = outline.filter { heading in
                heading.pageIndex == pageIndex && !pageLines.contains(where: { normalized($0.text) == normalized(heading.title) })
            }
            for heading in unmatchedPageOutline {
                appendHeading(heading.title, level: heading.level, to: &output)
                insertedOutlineTitles.insert(normalized(heading.title))
            }

            for line in pageLines {
                let key = normalized(line.text)
                if let heading = outlineByTitle[key]?.first {
                    if insertedOutlineTitles.insert(key).inserted {
                        appendHeading(line.text, level: heading.level, to: &output)
                    }
                } else if isVisualHeading(line, bodySize: bodySize) {
                    appendHeading(line.text, level: visualHeadingLevel(line, bodySize: bodySize), to: &output)
                } else {
                    appendParagraph(line.text, to: &output)
                }
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
                .map { TextLine(text: cleaned($0), pointSize: 0, isBold: false) }
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
                result.append(TextLine(
                    text: text,
                    pointSize: font?.pointSize ?? 0,
                    isBold: font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true
                ))
            }
            location = NSMaxRange(range)
        }
        return result
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
}
