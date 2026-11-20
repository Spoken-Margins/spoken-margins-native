import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SessionKit
import ZIPFoundation

/// The paragraphs of a Word .docx as plain text, one per line (#2481): Teams and Google Meet transcripts come
/// as .docx, and `TranscriptImport` reads the text. Tabs stay tabs, so "Name<tab>0:03" keeps its separator.
/// Lives here because this module already links ZIPFoundation.
///
/// `paragraphs(from:)` gives the same paragraphs with each one's heading level, for a Word document imported as a
/// Library item (#4594). Both read the text as Word shows it with tracked changes accepted: inserted text is read,
/// deleted and moved-away text is not, and a text box's fallback copy is not read twice.
public enum DocxPlainText {
    public enum Failure: Error, Equatable, LocalizedError {
        case notADocx
        /// The document part is over the cap.
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notADocx: "This file isn't a Word document Spoken Margins can read."
            case .tooLarge: "This Word document is too large for Spoken Margins to read."
            }
        }
    }

    public static let defaultMaximumBytes = 32 * 1_024 * 1_024

    /// One paragraph of the document's body. `headingLevel` is nil for body text, 1 for the Title style and 2 and up
    /// for Heading 1 and down, so a document's title sits above its headings the way a Markdown `#` sits above `##`.
    public typealias Paragraph = DocumentParagraph

    /// Caps the document part at 32 MB so a hostile file can't exhaust memory.
    public static func text(from url: URL, maximumBytes: Int = defaultMaximumBytes) throws -> String {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) } catch { throw Failure.notADocx }
        return try text(from: archive, maximumBytes: maximumBytes)
    }

    /// The same, from a file already read into memory (#2997).
    public static func text(from data: Data, maximumBytes: Int = defaultMaximumBytes) throws -> String {
        try text(from: archive(data), maximumBytes: maximumBytes)
    }

    /// The body's paragraphs with their heading levels, and the title the document's properties give (nil when none).
    public static func paragraphs(
        from data: Data, maximumBytes: Int = defaultMaximumBytes
    ) throws -> (paragraphs: [Paragraph], title: String?) {
        let archive = try archive(data)
        let parsed = try parse(try documentPart(archive, maximumBytes: maximumBytes))
        let styles = (try? part("word/styles.xml", in: archive, maximumBytes: maximumBytes)).map(StyleLevels.parse) ?? [:]
        let paragraphs = parsed.map { raw in
            Paragraph(text: raw.text, headingLevel: headingLevel(styleId: raw.styleId, outlineLevel: raw.outlineLevel, styles: styles))
        }
        let title = (try? part("docProps/core.xml", in: archive, maximumBytes: 1_024 * 1_024)).flatMap(CoreTitle.parse)
        return (paragraphs, title)
    }

    public static func text(fromDocumentXML data: Data) throws -> String {
        try parse(data).map(\.text).joined(separator: "\n")
    }

    private static func archive(_ data: Data) throws -> Archive {
        do { return try Archive(data: data, accessMode: .read) } catch { throw Failure.notADocx }
    }

    private static func text(from archive: Archive, maximumBytes: Int) throws -> String {
        try text(fromDocumentXML: documentPart(archive, maximumBytes: maximumBytes))
    }

    private static func documentPart(_ archive: Archive, maximumBytes: Int) throws -> Data {
        try part("word/document.xml", in: archive, maximumBytes: maximumBytes)
    }

    private static func part(_ path: String, in archive: Archive, maximumBytes: Int) throws -> Data {
        guard let entry = archive[path] else { throw Failure.notADocx }
        guard entry.uncompressedSize <= UInt64(maximumBytes) else { throw Failure.tooLarge }
        var data = Data()
        do { _ = try archive.extract(entry, skipCRC32: false) { data.append($0) } } catch { throw Failure.notADocx }
        return data
    }

    private static func parse(_ data: Data) throws -> [RawParagraph] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw Failure.notADocx }
        return delegate.paragraphs
    }

    /// A paragraph's own outline level wins over its style's; Word's "Title" style is the title.
    private static func headingLevel(styleId: String?, outlineLevel: Int?, styles: [String: StyleLevels.Level]) -> Int? {
        if let outlineLevel { return outlineLevel < 9 ? outlineLevel + 2 : nil }
        guard let styleId else { return nil }
        switch styles[styleId] ?? StyleLevels.fallback(styleId: styleId) {
        case .title: return 1
        case .outline(let level): return level + 2
        case .body, nil: return nil
        }
    }

    /// Track Changes keeps a formatting change's old properties inside the new ones (`w:pPr/w:pPrChange/w:pPr`), so a
    /// reader that walks into them takes the old style or outline level for the current one. Every reader here skips
    /// them whole: Word shows the document with the change accepted.
    static let trackedPropertyChanges: Set<String> = [
        "w:pPrChange", "w:rPrChange", "w:sectPrChange", "w:tblPrChange", "w:tblPrExChange", "w:tblGridChange",
        "w:trPrChange", "w:tcPrChange", "w:numberingChange",
    ]

    struct RawParagraph {
        var text = ""
        var styleId: String?
        var outlineLevel: Int?
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        /// Elements whose text Word doesn't show once tracked changes are accepted, the old properties a tracked
        /// formatting change keeps, and the fallback copy of a text box.
        private static let unread: Set<String> = Set(["w:del", "w:moveFrom", "mc:Fallback"]).union(DocxPlainText.trackedPropertyChanges)

        var paragraphs: [RawParagraph] = []
        /// A text box's paragraphs sit inside another paragraph, so the open ones are a stack; each is kept whole.
        private var open: [RawParagraph] = []
        private var inText = false
        private var inParagraphProperties = false
        private var unreadDepth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if Self.unread.contains(name) { unreadDepth += 1; return }
            guard unreadDepth == 0 else { return }
            switch name {
            case "w:p": open.append(RawParagraph())
            case "w:pPr": inParagraphProperties = true
            case "w:pStyle" where inParagraphProperties:
                if !open.isEmpty { open[open.count - 1].styleId = attributes["w:val"] }
            case "w:outlineLvl" where inParagraphProperties:
                if !open.isEmpty { open[open.count - 1].outlineLevel = attributes["w:val"].flatMap(Int.init) }
            case "w:t": inText = true
            // A tab stop in the paragraph's properties is layout, not a tab in the text.
            case "w:tab" where !inParagraphProperties: append("\t")
            case "w:br", "w:cr": append("\n")
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if Self.unread.contains(name) { unreadDepth = max(0, unreadDepth - 1); return }
            guard unreadDepth == 0 else { return }
            switch name {
            case "w:p": if let paragraph = open.popLast() { paragraphs.append(paragraph) }
            case "w:pPr": inParagraphProperties = false
            case "w:t": inText = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText, unreadDepth == 0 { append(string) }
        }

        private func append(_ string: String) {
            guard !open.isEmpty else { return }
            open[open.count - 1].text += string
        }
    }
}

/// Which paragraph styles are headings, from `word/styles.xml`: a style's outline level, inherited through `basedOn`,
/// else its name ("heading 2", "Title"). Reading the levels rather than the ids keeps a document saved by Word in
/// another language right, where Heading 1's id is "berschrift1" or "Titre1".
enum StyleLevels {
    enum Level: Equatable { case title, outline(Int), body }

    static func parse(_ data: Data) -> [String: Level] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        var resolved: [String: Level] = [:]
        func level(of id: String, seen: Set<String>) -> Level {
            if let known = resolved[id] { return known }
            guard let style = delegate.styles[id], !seen.contains(id) else { return .body }
            let result: Level
            if let outline = style.outlineLevel {
                result = outline < 9 ? .outline(outline) : .body
            } else if let named = named(style.name) {
                result = named
            } else if let parent = style.basedOn {
                result = level(of: parent, seen: seen.union([id]))
            } else {
                result = .body
            }
            resolved[id] = result
            return result
        }
        for id in delegate.styles.keys { _ = level(of: id, seen: []) }
        return resolved
    }

    /// For a document with no styles part: Word's own English ids.
    static func fallback(styleId: String) -> Level? {
        named(styleId)
    }

    private static func named(_ name: String?) -> Level? {
        guard let name = name?.lowercased().replacingOccurrences(of: " ", with: "") else { return nil }
        if name == "title" { return .title }
        if name.hasPrefix("heading"), let number = Int(name.dropFirst("heading".count)), (1...9).contains(number) {
            return .outline(number - 1)
        }
        return nil
    }

    private struct Style {
        var name: String?
        var basedOn: String?
        var outlineLevel: Int?
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var styles: [String: Style] = [:]
        private var currentId: String?
        private var current = Style()
        /// Inside a style's tracked old properties, whose outline level is the one before the change.
        private var skipDepth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if DocxPlainText.trackedPropertyChanges.contains(name) { skipDepth += 1; return }
            guard skipDepth == 0 else { return }
            switch name {
            case "w:style":
                currentId = attributes["w:type"] == "paragraph" ? attributes["w:styleId"] : nil
                current = Style()
            case "w:name": current.name = attributes["w:val"]
            case "w:basedOn": current.basedOn = attributes["w:val"]
            case "w:outlineLvl": current.outlineLevel = attributes["w:val"].flatMap(Int.init)
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if DocxPlainText.trackedPropertyChanges.contains(name) { skipDepth = max(0, skipDepth - 1); return }
            guard skipDepth == 0 else { return }
            if name == "w:style", let id = currentId {
                styles[id] = current
                currentId = nil
            }
        }
    }
}

/// The title in a document's properties (`docProps/core.xml`, `dc:title`), nil when blank.
enum CoreTitle {
    static func parse(_ data: Data) -> String? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        let title = delegate.title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var title = ""
        private var inTitle = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "dc:title" { inTitle = true }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "dc:title" { inTitle = false }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inTitle { title += string }
        }
    }
}
