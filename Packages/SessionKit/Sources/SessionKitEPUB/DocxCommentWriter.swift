import Foundation
import SessionKit
import ZIPFoundation

/// Where one Margin's comment went in a Word document (#4595).
public struct DocxMarginPlacement: Equatable, Sendable {
    public enum Spot: Equatable, Sendable {
        /// On the sentence, or on its start when only that was found (`wholeSentence` false).
        case sentence(wholeSentence: Bool)
        /// The sentence was not found: the comment covers the paragraph that held it, found by the text before it.
        case paragraph
        /// Neither the sentence nor the text before it was found: the comment covers the first paragraph with text.
        case firstParagraph
    }

    public var marginId: String
    public var spot: Spot

    public init(marginId: String, spot: Spot) {
        self.marginId = marginId
        self.spot = spot
    }

    /// True when the export sheet should say this comment is not on its own sentence.
    public var fellBack: Bool {
        if case .sentence = spot { return false }
        return true
    }
}

/// Writes a copy of a Word `.docx` with the listener's own Margins as real Word comments (#4595, #4338 slice 3b).
///
/// The copy is the source package entry for entry. Only three parts change: `word/document.xml` gains a
/// `w:commentRangeStart` / `w:commentRangeEnd` pair and a `w:commentReference` run around each Margin's sentence;
/// `word/comments.xml` gains one `w:comment` per Margin (created when the document has none, appended to when it
/// has some); and when the comments part is new, its relationship and content type are added. The document part is
/// edited as bytes, never parsed and re-serialized, so everything the writer does not touch (formatting, rsids,
/// namespaces, tracked changes, fields) stays byte for byte what the author saved. A run is split where a sentence
/// starts or ends inside it, the second half carrying the same run properties.
///
/// The sentence is found with `PDFSentenceLocator`, the rule the PDF placer uses (NFC, case, quotes, white space,
/// whole words, the longest start of eight words when the whole is missing, and the text before it to choose between
/// two copies), over the document's visible text: the `w:t` text of each paragraph, tabs and breaks included, with
/// deleted text, field codes and text boxes left out. A sentence not found becomes a comment on the paragraph that
/// held it, or on the first paragraph as a last resort, and `DocxMarginPlacement.fellBack` says so.
///
/// The source file is only read. Nothing here is called from the app yet.
public enum DocxCommentWriter {
    public enum Failure: Error, Equatable, Sendable {
        /// Not a zip with a `word/document.xml` this writer can read, or a part over the size cap.
        case notADocx
        /// A Strict Open XML document, or one whose main namespace has another prefix: valid Word, but not a shape
        /// this writer edits.
        case unsupportedDocument
        /// The copy could not be written.
        case writeFailed
    }

    /// One comment to add.
    public struct Request: Equatable, Sendable {
        public var marginId: String
        /// The sentence as the item's text spells it.
        public var sentenceText: String
        /// Text just before the sentence, to choose between two copies and to find the paragraph when the sentence is gone.
        public var precedingText: String
        /// The comment's words.
        public var commentText: String

        public init(marginId: String, sentenceText: String, precedingText: String = "", commentText: String) {
            self.marginId = marginId
            self.sentenceText = sentenceText
            self.precedingText = precedingText
            self.commentText = commentText
        }

        public init(entry: MarginCommentPlan.Entry) {
            self.init(marginId: entry.marginId, sentenceText: entry.sentenceText, precedingText: entry.precedingText, commentText: entry.commentText)
        }
    }

    /// Caps each part the writer reads, as `DocxPlainText` does, so a hostile file can't exhaust memory.
    public static let maximumPartBytes = 32 * 1_024 * 1_024

    static let documentPath = "word/document.xml"
    static let documentRelsPath = "word/_rels/document.xml.rels"
    static let contentTypesPath = "[Content_Types].xml"
    static let mainNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let commentsRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments"
    static let commentsContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"

    /// Writes the copy for the Margins of `plan` that have words (`plan.included`), in the plan's order.
    @discardableResult
    public static func write(source: URL, plan: MarginCommentPlan, author: String, date: Date = Date(), to destination: URL) throws -> [DocxMarginPlacement] {
        try write(source: source, requests: plan.included.map(Request.init(entry:)), author: author, date: date, to: destination)
    }

    /// Writes the copy to `destination`, replacing a file already there. `source` is only read.
    @discardableResult
    public static func write(source: URL, requests: [Request], author: String, date: Date = Date(), to destination: URL) throws -> [DocxMarginPlacement] {
        let archive: Archive
        do { archive = try Archive(url: source, accessMode: .read) } catch { throw Failure.notADocx }
        let entries = Array(archive)
        func read(_ path: String) throws -> Data? {
            guard let entry = entries.first(where: { $0.path == path }) else { return nil }
            guard entry.type == .file, entry.uncompressedSize <= UInt64(maximumPartBytes) else { throw Failure.notADocx }
            var data = Data()
            do { _ = try archive.extract(entry, skipCRC32: false) { data.append($0) } } catch { throw Failure.notADocx }
            return data
        }

        guard let documentData = try read(documentPath), let documentXML = String(data: documentData, encoding: .utf8) else { throw Failure.notADocx }
        guard declaresMainNamespace(documentXML) else { throw Failure.unsupportedDocument }

        let relsXML = try read(documentRelsPath).flatMap { String(data: $0, encoding: .utf8) }
        let existingCommentsPath = relsXML.flatMap(commentsTarget(inRels:)).map { "word/" + $0 }
        let commentsPath = existingCommentsPath ?? "word/comments.xml"
        let existingComments = try read(commentsPath).flatMap { String(data: $0, encoding: .utf8) }

        let firstId = max(maxCommentId(in: documentXML), existingComments.map(maxCommentId(in:)) ?? -1) + 1
        let annotated = annotate(documentXML: documentXML, requests: requests, firstId: firstId)

        let commentElements = zip(requests, annotated.ids).map { request, id in
            commentElement(id: id, author: author, date: date, text: request.commentText)
        }.joined()

        var replaced: [String: Data] = [documentPath: Data(annotated.xml.utf8)]
        var added: [(String, Data)] = []
        if let existingComments {
            replaced[commentsPath] = Data(appendComments(commentElements, to: existingComments).utf8)
        } else {
            added.append((commentsPath, Data(newCommentsPart(commentElements).utf8)))
            let rels = addCommentsRelationship(to: relsXML)
            if relsXML == nil { added.append((documentRelsPath, Data(rels.utf8))) } else { replaced[documentRelsPath] = Data(rels.utf8) }
            guard let types = try read(contentTypesPath).flatMap({ String(data: $0, encoding: .utf8) }) else { throw Failure.notADocx }
            replaced[contentTypesPath] = Data(addCommentsContentType(to: types, partName: "/" + commentsPath).utf8)
        }

        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).docx")
        do {
            let output = try Archive(url: temporary, accessMode: .create)
            for entry in entries {
                switch entry.type {
                case .directory:
                    try output.addEntry(with: entry.path, type: .directory, uncompressedSize: 0, provider: { (_: Int64, _: Int) -> Data in Data() })
                case .file:
                    let data: Data
                    if let new = replaced[entry.path] { data = new } else if let old = try read(entry.path) { data = old } else { continue }
                    try add(data, at: entry.path, to: output)
                case .symlink:
                    continue
                }
            }
            for (path, data) in added { try add(data, at: path, to: output) }
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch let failure as Failure {
            try? fileManager.removeItem(at: temporary)
            throw failure
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw Failure.writeFailed
        }
        return annotated.placements
    }

    private static func add(_ data: Data, at path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { (position: Int64, size: Int) -> Data in
            data.subdata(in: Int(position) ..< Int(position) + size)
        }
    }

    // MARK: - The document part

    struct Annotated {
        var xml: String
        var placements: [DocxMarginPlacement]
        /// The comment id given to each request, in order.
        var ids: [Int]
    }

    /// The document part with a comment range around each request's sentence. Pure, for host tests.
    static func annotate(documentXML: String, requests: [Request], firstId: Int) -> Annotated {
        let model = DocumentText(xml: documentXML)
        var edits = EditList()
        var placements: [DocxMarginPlacement] = []
        var ids: [Int] = []
        for (offset, request) in requests.enumerated() {
            let id = firstId + offset
            ids.append(id)
            let start = "<w:commentRangeStart w:id=\"\(id)\"/>"
            let end = "<w:commentRangeEnd w:id=\"\(id)\"/><w:r><w:commentReference w:id=\"\(id)\"/></w:r>"
            let spot: DocxMarginPlacement.Spot
            if let found = model.locate(sentence: request.sentenceText, preceding: request.precedingText) {
                model.insert(start, before: found.characters.lowerBound, into: &edits)
                model.insert(end, after: found.characters.upperBound - 1, into: &edits)
                spot = .sentence(wholeSentence: found.whole)
            } else if let paragraph = model.paragraph(after: request.precedingText) {
                model.wrap(paragraph: paragraph, start: start, end: end, into: &edits)
                spot = .paragraph
            } else if let paragraph = model.firstParagraphWithText {
                model.wrap(paragraph: paragraph, start: start, end: end, into: &edits)
                spot = .firstParagraph
            } else {
                // A document with no text at all: the comment marks the start of the body, so it still reaches the reader.
                if let body = documentXML.utf8Offset(after: "<w:body>") {
                    edits.insert(start + end.replacingOccurrences(of: "<w:r>", with: "<w:p><w:r>") + "</w:p>", at: body)
                }
                spot = .firstParagraph
            }
            placements.append(DocxMarginPlacement(marginId: request.marginId, spot: spot))
        }
        return Annotated(xml: edits.apply(to: documentXML), placements: placements, ids: ids)
    }

    /// Byte-offset edits to a UTF-8 string, applied together. Insertions at the same offset keep the order they were made.
    struct EditList {
        private struct Edit {
            var offset: Int
            var length: Int
            var text: String
            var order: Int
        }

        private var edits: [Edit] = []
        private var replacedAt: Set<Int> = []

        mutating func insert(_ text: String, at offset: Int) {
            edits.append(Edit(offset: offset, length: 0, text: text, order: edits.count))
        }

        /// Replaces `range` once, however many callers ask (two splits in one `w:t` both need its tag rewritten).
        mutating func replace(_ range: Range<Int>, with text: String) {
            guard replacedAt.insert(range.lowerBound).inserted else { return }
            edits.append(Edit(offset: range.lowerBound, length: range.count, text: text, order: edits.count))
        }

        func apply(to string: String) -> String {
            var bytes = Array(string.utf8)
            for edit in edits.sorted(by: { ($0.offset, $0.order) > ($1.offset, $1.order) }) {
                bytes.replaceSubrange(edit.offset ..< edit.offset + edit.length, with: Array(edit.text.utf8))
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: - Package parts

    static func declaresMainNamespace(_ xml: String) -> Bool {
        xml.contains("xmlns:w=\"\(mainNamespace)\"") || xml.contains("xmlns:w='\(mainNamespace)'")
    }

    /// The highest comment id in `xml` (a document part or a comments part), or -1 when it has none.
    static func maxCommentId(in xml: String) -> Int {
        let pattern = #"<w:(?:comment|commentRangeStart|commentRangeEnd|commentReference)\b[^>]*?\bw:id\s*=\s*["'](-?\d+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return -1 }
        let string = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: string.length))
            .compactMap { Int(string.substring(with: $0.range(at: 1))) }
            .max() ?? -1
    }

    /// The target of the comments relationship in a document's rels part, relative to `word/`.
    static func commentsTarget(inRels rels: String) -> String? {
        let pattern = #"<Relationship\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let string = rels as NSString
        for match in regex.matches(in: rels, range: NSRange(location: 0, length: string.length)) {
            let tag = string.substring(with: match.range)
            guard attribute("Type", in: tag) == commentsRelationshipType, let target = attribute("Target", in: tag) else { continue }
            return target.hasPrefix("/word/") ? String(target.dropFirst("/word/".count)) : target
        }
        return nil
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*([\"'])(.*?)\\1") else { return nil }
        let string = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: string.length)) else { return nil }
        return string.substring(with: match.range(at: 2))
    }

    static func addCommentsRelationship(to rels: String?) -> String {
        let relationship = "<Relationship Id=\"\(uniqueRelationshipId(in: rels ?? ""))\" Type=\"\(commentsRelationshipType)\" Target=\"comments.xml\"/>"
        guard let rels else {
            return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationship)</Relationships>"
        }
        return insertBeforeClosing("Relationships", relationship, in: rels)
    }

    static func uniqueRelationshipId(in rels: String) -> String {
        var candidate = "rIdSpokenMarginsComments"
        var counter = 2
        while rels.contains("Id=\"\(candidate)\"") || rels.contains("Id='\(candidate)'") {
            candidate = "rIdSpokenMarginsComments\(counter)"
            counter += 1
        }
        return candidate
    }

    static func addCommentsContentType(to types: String, partName: String) -> String {
        if types.contains("PartName=\"\(partName)\"") || types.contains("PartName='\(partName)'") { return types }
        return insertBeforeClosing("Types", "<Override PartName=\"\(partName)\" ContentType=\"\(commentsContentType)\"/>", in: types)
    }

    static func newCommentsPart(_ comments: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:comments xmlns:w=\"\(mainNamespace)\">\(comments)</w:comments>"
    }

    static func appendComments(_ comments: String, to part: String) -> String {
        if part.range(of: "</w:comments>") != nil { return insertBeforeClosing("w:comments", comments, in: part) }
        // An empty part written as `<w:comments …/>`.
        guard let regex = try? NSRegularExpression(pattern: #"<w:comments\b([^>]*?)\s*/>"#) else { return part }
        let string = part as NSString
        guard let match = regex.firstMatch(in: part, range: NSRange(location: 0, length: string.length)) else { return part }
        let attributes = string.substring(with: match.range(at: 1))
        return string.replacingCharacters(in: match.range, with: "<w:comments\(attributes)>\(comments)</w:comments>")
    }

    /// `content` placed just before the last `</name>` in `xml`.
    static func insertBeforeClosing(_ name: String, _ content: String, in xml: String) -> String {
        guard let range = xml.range(of: "</\(name)>", options: .backwards) else { return xml }
        return xml.replacingCharacters(in: range.lowerBound ..< range.lowerBound, with: content)
    }

    static func commentElement(id: Int, author: String, date: Date, text: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let paragraphs = lines.enumerated().map { index, line in
            let reference = index == 0 ? "<w:r><w:annotationRef/></w:r>" : ""
            return "<w:p>\(reference)<w:r><w:t xml:space=\"preserve\">\(escape(String(line)))</w:t></w:r></w:p>"
        }.joined()
        return "<w:comment w:id=\"\(id)\" w:author=\"\(escape(author))\" w:date=\"\(formatter.string(from: date))\" w:initials=\"\(escape(initials(of: author)))\">\(paragraphs)</w:comment>"
    }

    static func initials(of author: String) -> String {
        String(author.split(whereSeparator: { $0.isWhitespace }).compactMap(\.first).prefix(3)).uppercased()
    }

    /// XML-escaped, with the characters XML 1.0 cannot carry at all dropped.
    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                let value = scalar.value
                let allowed = value == 0x9 || value == 0xA || value == 0xD || (value >= 0x20 && value <= 0xD7FF) || (value >= 0xE000 && value <= 0xFFFD) || value >= 0x10000
                if allowed { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}

// MARK: - The document's visible text, mapped back to bytes

extension DocxCommentWriter {
    /// The visible text of a document part, with where each character came from in the XML's UTF-8 bytes.
    final class DocumentText {
        struct Run {
            var openTag: Range<Int>
            /// Where the run's content starts: after its `w:rPr`, or after its open tag.
            var contentStart: Int
            var closeTag: Range<Int>
            var properties: String
        }

        struct Paragraph {
            /// Where a comment covering the whole paragraph starts: after its `w:pPr`, or after its open tag.
            var contentStart: Int
            var closeStart: Int
            var hasText = false
        }

        enum PieceKind {
            /// A `w:t`; `openTag` is its start tag, which a split may rewrite to keep spaces.
            case text(openTag: Range<Int>, closeTag: Range<Int>)
            /// A tab, break or special hyphen: one character, never split inside.
            case element(Range<Int>)
        }

        struct Piece {
            var kind: PieceKind
            var run: Int
            var paragraph: Int
        }

        /// Where one character of the text came from. A separator between paragraphs has no piece.
        struct Origin {
            var piece: Int?
            var bytes: Range<Int>
        }

        let xml: String
        private let bytes: [UInt8]
        private(set) var runs: [Run] = []
        private(set) var paragraphs: [Paragraph] = []
        private(set) var pieces: [Piece] = []
        /// The visible text, paragraphs separated by a blank line so `SentenceBounds` sees them as breaks.
        private(set) var text = ""
        /// One per `Character` of `Array(text)`.
        private(set) var origins: [Origin] = []

        init(xml: String) {
            self.xml = xml
            self.bytes = Array(xml.utf8)
            scan()
        }

        var firstParagraphWithText: Int? { paragraphs.firstIndex(where: \.hasText) }

        // MARK: Finding

        /// The sentence's characters in `text`, when the locator finds it or its start.
        func locate(sentence: String, preceding: String) -> (characters: Range<Int>, whole: Bool)? {
            guard !text.isEmpty else { return nil }
            let snapshot = text
            switch PDFSentenceLocator.locate(sentence: sentence, hintedPage: 0, preceding: preceding, pageCount: 1, pageText: { _ in snapshot }) {
            case .highlight(_, let range, let whole):
                guard range.lowerBound >= 0, range.upperBound <= origins.count, !range.isEmpty,
                      origins[range.lowerBound].piece != nil, origins[range.upperBound - 1].piece != nil else { return nil }
                return (range, whole)
            case .pageNote:
                return nil
            }
        }

        /// The paragraph holding the first character after the end of `preceding`, when the end of `preceding` is found.
        func paragraph(after preceding: String) -> Int? {
            let words = preceding.split(whereSeparator: { $0.isWhitespace })
            // The first word may be cut in half by the plan's 80-character window; leave it out.
            let tail = words.count > 1 ? words.dropFirst().suffix(12).joined(separator: " ") : words.joined()
            guard tail.count >= 12, let found = locate(sentence: tail, preceding: "") else { return nil }
            var index = found.characters.upperBound
            while index < origins.count {
                if let piece = origins[index].piece, !Array(text)[index].isWhitespace { return pieces[piece].paragraph }
                index += 1
            }
            // Nothing after it: the preceding text ends the document, so its own paragraph.
            return origins[found.characters.upperBound - 1].piece.map { pieces[$0].paragraph }
        }

        // MARK: Marking

        func wrap(paragraph index: Int, start: String, end: String, into edits: inout EditList) {
            let paragraph = paragraphs[index]
            edits.insert(start, at: paragraph.contentStart)
            edits.insert(end, at: paragraph.closeStart)
        }

        /// `markup` placed just before the character at `index`.
        func insert(_ markup: String, before index: Int, into edits: inout EditList) {
            let origin = origins[index]
            guard let pieceIndex = origin.piece else { return }
            place(markup, at: origin.bytes.lowerBound, piece: pieces[pieceIndex], atPieceStart: true, into: &edits)
        }

        /// `markup` placed just after the character at `index`.
        func insert(_ markup: String, after index: Int, into edits: inout EditList) {
            let origin = origins[index]
            guard let pieceIndex = origin.piece else { return }
            place(markup, at: origin.bytes.upperBound, piece: pieces[pieceIndex], atPieceStart: false, into: &edits)
        }

        /// Puts `markup` at byte `offset`, which is inside or at an edge of `piece`. At the edge of its run the markup
        /// goes beside the run; anywhere else the run is split there, both halves keeping its properties.
        private func place(_ markup: String, at offset: Int, piece: Piece, atPieceStart: Bool, into edits: inout EditList) {
            let run = runs[piece.run]
            let reopen = String(decoding: bytes[run.openTag], as: UTF8.self) + run.properties
            switch piece.kind {
            case .text(let openTag, let closeTag):
                if offset == openTag.upperBound, isBlank(run.contentStart ..< openTag.lowerBound) {
                    edits.insert(markup, at: run.openTag.lowerBound)
                } else if offset == closeTag.lowerBound, isBlank(closeTag.upperBound ..< run.closeTag.lowerBound) {
                    edits.insert(markup, at: run.closeTag.upperBound)
                } else {
                    let tag = String(decoding: bytes[openTag], as: UTF8.self)
                    if !tag.contains("xml:space") {
                        edits.replace(openTag, with: tag.replacingOccurrences(of: "<w:t", with: "<w:t xml:space=\"preserve\"", options: .anchored))
                    }
                    edits.insert("</w:t></w:r>" + markup + reopen + "<w:t xml:space=\"preserve\">", at: offset)
                }
            case .element(let range):
                if atPieceStart, isBlank(run.contentStart ..< range.lowerBound) {
                    edits.insert(markup, at: run.openTag.lowerBound)
                } else if !atPieceStart, isBlank(range.upperBound ..< run.closeTag.lowerBound) {
                    edits.insert(markup, at: run.closeTag.upperBound)
                } else {
                    edits.insert("</w:r>" + markup + reopen, at: offset)
                }
            }
        }

        private func isBlank(_ range: Range<Int>) -> Bool {
            guard range.lowerBound <= range.upperBound else { return false }
            return bytes[range].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        }

        // MARK: Scanning

        /// Elements whose text is not part of what a reader sees in the body: alternate renderings (a text box's
        /// fallback copy), text boxes themselves, and deleted or moved-away text.
        private static let skipped: Set<String> = ["mc:AlternateContent", "w:txbxContent", "w:del", "w:moveFrom", "w:pict", "w:object"]
        /// Run children that are one character of text.
        private static let characterElements: [String: String] = [
            "w:tab": "\t", "w:ptab": "\t", "w:br": "\n", "w:cr": "\n",
            "w:noBreakHyphen": "\u{2011}", "w:softHyphen": "\u{00AD}"
        ]

        private func scan() {
            var stack: [String] = []
            var skipDepth = 0
            var paragraphStack: [Int] = []
            var runStack: [Int] = []
            var openText: (tag: Range<Int>, content: Int)?
            var properties: (start: Int, depth: Int)?
            var paragraphProperties: Int?
            var scalars: [(scalar: Unicode.Scalar, piece: Int?, bytes: Range<Int>)] = []
            var lastParagraphWithText: Int?

            func appendPieceText(paragraph: Int) {
                if let last = lastParagraphWithText, last != paragraph {
                    for scalar in "\n\n".unicodeScalars { scalars.append((scalar, nil, 0 ..< 0)) }
                }
                lastParagraphWithText = paragraph
                paragraphs[paragraph].hasText = true
            }

            var index = 0
            let count = bytes.count
            while index < count {
                guard bytes[index] == UInt8(ascii: "<") else {
                    // Character data.
                    let start = index
                    while index < count, bytes[index] != UInt8(ascii: "<") { index += 1 }
                    if skipDepth == 0, openText != nil, runStack.last != nil, let paragraph = paragraphStack.last, stack.last == "w:t" {
                        let pieceIndex = pieces.count
                        // The piece is recorded when its tag closes; characters are added now with its future index.
                        let decoded = decode(start ..< index)
                        if !decoded.isEmpty {
                            appendPieceText(paragraph: paragraph)
                            for item in decoded { scalars.append((item.scalar, pieceIndex, item.bytes)) }
                        }
                    }
                    continue
                }
                let tagStart = index
                // Comments, processing instructions, CDATA and declarations carry no visible body text.
                if starts(with: "<!--", at: index) {
                    index = find("-->", from: index).map { $0 + 3 } ?? count
                    continue
                }
                if starts(with: "<?", at: index) {
                    index = find("?>", from: index).map { $0 + 2 } ?? count
                    continue
                }
                if starts(with: "<![CDATA[", at: index) {
                    index = find("]]>", from: index).map { $0 + 3 } ?? count
                    continue
                }
                if starts(with: "<!", at: index) {
                    index = find(">", from: index).map { $0 + 1 } ?? count
                    continue
                }
                // A tag: find its end, honouring quoted attribute values.
                var cursor = index + 1
                var quote: UInt8?
                while cursor < count {
                    let byte = bytes[cursor]
                    if let open = quote {
                        if byte == open { quote = nil }
                    } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                        quote = byte
                    } else if byte == UInt8(ascii: ">") {
                        break
                    }
                    cursor += 1
                }
                let tagEnd = min(cursor + 1, count)
                index = tagEnd
                let isClosing = tagStart + 1 < count && bytes[tagStart + 1] == UInt8(ascii: "/")
                let selfClosing = tagEnd >= 2 && bytes[tagEnd - 2] == UInt8(ascii: "/")
                let name = tagName(from: tagStart + (isClosing ? 2 : 1), limit: tagEnd)

                if isClosing {
                    // Pop to the matching name (a well-formed part always matches the top).
                    guard let top = stack.last else { continue }
                    stack.removeLast()
                    if skipDepth > 0 {
                        skipDepth -= 1
                        continue
                    }
                    switch top {
                    case "w:t":
                        if let open = openText, let run = runStack.last, let paragraph = paragraphStack.last {
                            let hasText = scalars.last?.piece == pieces.count
                            if hasText {
                                pieces.append(Piece(kind: .text(openTag: open.tag, closeTag: tagStart ..< tagEnd), run: run, paragraph: paragraph))
                            }
                        }
                        openText = nil
                    case "w:rPr":
                        if let props = properties, props.depth == stack.count, let run = runStack.last {
                            runs[run].properties = String(decoding: bytes[props.start ..< tagEnd], as: UTF8.self)
                            runs[run].contentStart = tagEnd
                            properties = nil
                        }
                    case "w:pPr":
                        if paragraphProperties == stack.count, let paragraph = paragraphStack.last {
                            paragraphs[paragraph].contentStart = tagEnd
                            paragraphProperties = nil
                        }
                    case "w:r":
                        if let run = runStack.popLast() { runs[run].closeTag = tagStart ..< tagEnd }
                    case "w:p":
                        if let paragraph = paragraphStack.popLast() { paragraphs[paragraph].closeStart = tagStart }
                    default:
                        break
                    }
                    continue
                }

                if skipDepth > 0 {
                    if !selfClosing { stack.append(name); skipDepth += 1 }
                    continue
                }
                if Self.skipped.contains(name) {
                    if !selfClosing { stack.append(name); skipDepth = 1 }
                    continue
                }

                switch name {
                case "w:p" where !selfClosing:
                    paragraphStack.append(paragraphs.count)
                    paragraphs.append(Paragraph(contentStart: tagEnd, closeStart: tagEnd))
                case "w:pPr" where !selfClosing && stack.last == "w:p":
                    paragraphProperties = stack.count
                case "w:r" where !selfClosing:
                    runStack.append(runs.count)
                    runs.append(Run(openTag: tagStart ..< tagEnd, contentStart: tagEnd, closeTag: tagEnd ..< tagEnd, properties: ""))
                case "w:rPr" where !selfClosing && stack.last == "w:r":
                    properties = (tagStart, stack.count)
                case "w:rPr" where selfClosing && stack.last == "w:r":
                    if let run = runStack.last {
                        runs[run].properties = String(decoding: bytes[tagStart ..< tagEnd], as: UTF8.self)
                        runs[run].contentStart = tagEnd
                    }
                case "w:t" where !selfClosing && stack.last == "w:r":
                    openText = (tagStart ..< tagEnd, tagEnd)
                default:
                    if stack.last == "w:r", let character = Self.characterElements[name], let run = runStack.last, let paragraph = paragraphStack.last {
                        let pieceIndex = pieces.count
                        pieces.append(Piece(kind: .element(tagStart ..< tagEnd), run: run, paragraph: paragraph))
                        appendPieceText(paragraph: paragraph)
                        for scalar in character.unicodeScalars { scalars.append((scalar, pieceIndex, tagStart ..< tagEnd)) }
                    }
                }
                if !selfClosing { stack.append(name) }
            }

            // Characters of `Array(text)` from scalars: each Character takes the origin of its first scalar, and its
            // end from its last, so a split never lands inside a cluster.
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars.map(\.scalar))
            text = String(view)
            var cursor = 0
            origins.reserveCapacity(scalars.count)
            for character in text {
                let size = character.unicodeScalars.count
                let first = scalars[cursor], last = scalars[cursor + size - 1]
                if first.piece == nil || first.piece != last.piece {
                    // A separator, or a cluster that spans two pieces (a combining mark in its own run): marks go at
                    // the cluster's first piece's edges.
                    origins.append(Origin(piece: first.piece ?? last.piece, bytes: first.piece == nil ? last.bytes : first.bytes))
                } else {
                    origins.append(Origin(piece: first.piece, bytes: first.bytes.lowerBound ..< last.bytes.upperBound))
                }
                cursor += size
            }
        }

        private func starts(with prefix: String, at index: Int) -> Bool {
            let needle = Array(prefix.utf8)
            guard index + needle.count <= bytes.count else { return false }
            return Array(bytes[index ..< index + needle.count]) == needle
        }

        private func find(_ needle: String, from index: Int) -> Int? {
            let target = Array(needle.utf8)
            var cursor = index
            while cursor + target.count <= bytes.count {
                if bytes[cursor] == target[0], Array(bytes[cursor ..< cursor + target.count]) == target { return cursor }
                cursor += 1
            }
            return nil
        }

        private func tagName(from start: Int, limit: Int) -> String {
            var end = start
            while end < limit {
                let byte = bytes[end]
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">") { break }
                end += 1
            }
            return String(decoding: bytes[start ..< end], as: UTF8.self)
        }

        /// Character data with entities decoded, each scalar with the bytes it came from.
        private func decode(_ range: Range<Int>) -> [(scalar: Unicode.Scalar, bytes: Range<Int>)] {
            var result: [(Unicode.Scalar, Range<Int>)] = []
            var index = range.lowerBound
            while index < range.upperBound {
                let byte = bytes[index]
                if byte == UInt8(ascii: "&"), let semicolon = bytes[index ..< min(range.upperBound, index + 12)].firstIndex(of: UInt8(ascii: ";")) {
                    let entity = String(decoding: bytes[index + 1 ..< semicolon], as: UTF8.self)
                    let scalar: Unicode.Scalar?
                    switch entity {
                    case "amp": scalar = "&"
                    case "lt": scalar = "<"
                    case "gt": scalar = ">"
                    case "quot": scalar = "\""
                    case "apos": scalar = "'"
                    default:
                        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                            scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                        } else if entity.hasPrefix("#") {
                            scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init)
                        } else {
                            scalar = nil
                        }
                    }
                    if let scalar {
                        result.append((scalar, index ..< semicolon + 1))
                        index = semicolon + 1
                        continue
                    }
                }
                // One UTF-8 scalar.
                let length: Int
                switch byte {
                case 0 ..< 0x80: length = 1
                case 0xC0 ..< 0xE0: length = 2
                case 0xE0 ..< 0xF0: length = 3
                default: length = 4
                }
                let end = min(index + length, range.upperBound)
                let piece = String(decoding: bytes[index ..< end], as: UTF8.self)
                if let scalar = piece.unicodeScalars.first { result.append((scalar, index ..< end)) }
                index = end
            }
            return result
        }
    }
}

private extension String {
    /// The UTF-8 offset just after the first `needle`.
    func utf8Offset(after needle: String) -> Int? {
        guard let range = range(of: needle) else { return nil }
        return utf8.distance(from: utf8.startIndex, to: range.upperBound)
    }
}
