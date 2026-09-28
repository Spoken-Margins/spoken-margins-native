import CryptoKit
import Foundation

/// I13: a PDF's extracted text as role-labelled segments. The draft schema and
/// its rules are in research/C1/I13 (structured-document.v1).
///
/// `text` is canonical: every range indexes it in Characters, the same unit as
/// `Anchor.startChar`/`endChar`, and it is the text written Margins anchor into.
/// Roles never remove text; the speech path decides what is heard (I14,
/// `StructuredDocumentSpeech`).
public struct StructuredDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "structured-document.v1"

    public enum Role: String, Codable, Sendable, CaseIterable {
        case title, heading, abstract, body, caption, table, footnote, equation, reference, authors
        case frontMatter = "front_matter"
        case backMatter = "back_matter"
        case pageHeader = "page_header"
        case pageFooter = "page_footer"
        case unknown
    }

    public enum MarkerKind: String, Codable, Sendable {
        case citation, footnote, math
        case figureReference = "figure_reference"
        case tableReference = "table_reference"
    }

    public struct TextRange: Codable, Equatable, Sendable {
        public var start: Int
        public var length: Int
        public var end: Int { start + length }

        public init(start: Int, length: Int) {
            self.start = start
            self.length = length
        }
    }

    public struct Extraction: Codable, Equatable, Sendable {
        public var engine: String
        public var version: Int
        public var sourceSHA256: String?
        public var pageCount: Int
        public var textSHA256: String?

        public init(engine: String, version: Int, sourceSHA256: String?, pageCount: Int, textSHA256: String?) {
            self.engine = engine
            self.version = version
            self.sourceSHA256 = sourceSHA256
            self.pageCount = pageCount
            self.textSHA256 = textSHA256
        }
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var id: String
        public var role: Role
        public var range: TextRange
        public var level: Int?
        public var pageIndex: Int?
        public var floatId: String?

        public init(id: String, role: Role, range: TextRange, level: Int? = nil, pageIndex: Int? = nil, floatId: String? = nil) {
            self.id = id
            self.role = role
            self.range = range
            self.level = level
            self.pageIndex = pageIndex
            self.floatId = floatId
        }
    }

    public struct Marker: Codable, Equatable, Sendable {
        public var kind: MarkerKind
        public var range: TextRange
        public var label: String?
        public var targetSegmentId: String?

        public init(kind: MarkerKind, range: TextRange, label: String?, targetSegmentId: String? = nil) {
            self.kind = kind
            self.range = range
            self.label = label
            self.targetSegmentId = targetSegmentId
        }
    }

    public struct Float: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case figure, table }
        public var id: String
        public var kind: Kind
        public var label: String?
        public var pageIndex: Int
        public var bounds: PDFNormalizedRect
        public var captionSegmentId: String?

        public init(id: String, kind: Kind, label: String?, pageIndex: Int, bounds: PDFNormalizedRect, captionSegmentId: String?) {
            self.id = id
            self.kind = kind
            self.label = label
            self.pageIndex = pageIndex
            self.bounds = bounds
            self.captionSegmentId = captionSegmentId
        }
    }

    public var schemaVersion: String
    public var extraction: Extraction
    public var text: String
    public var segments: [Segment]
    public var markers: [Marker]
    public var floats: [Float]

    public init(schemaVersion: String = StructuredDocument.currentSchemaVersion, extraction: Extraction, text: String, segments: [Segment], markers: [Marker], floats: [Float] = []) {
        self.schemaVersion = schemaVersion
        self.extraction = extraction
        self.text = text
        self.segments = segments
        self.markers = markers
        self.floats = floats
    }
}

/// One line of extracted text with the role the extractor gave it.
public struct StructuredDocumentLine: Equatable, Sendable {
    public var text: String
    public var role: StructuredDocument.Role
    public var pageIndex: Int?
    public var level: Int?
    /// Character ranges of `text` printed as superscripts: citation or footnote markers.
    public var superscripts: [Range<Int>]

    public init(text: String, role: StructuredDocument.Role, pageIndex: Int? = nil, level: Int? = nil, superscripts: [Range<Int>] = []) {
        self.text = text
        self.role = role
        self.pageIndex = pageIndex
        self.level = level
        self.superscripts = superscripts
    }
}

/// Assembles extracted lines into an I13 document. Each line is cleaned the way
/// imported text always has been (`SpeechTextNormalizer.normalizeImportedText`),
/// so the canonical text reads like a v1 PDF import, and every range is exact.
public enum StructuredDocumentBuilder {
    public static func build(
        lines: [StructuredDocumentLine],
        engine: String,
        version: Int,
        pageCount: Int,
        sourceSHA256: String? = nil
    ) -> StructuredDocument {
        var text = ""
        var length = 0
        var segments: [StructuredDocument.Segment] = []
        var markers: [StructuredDocument.Marker] = []

        for line in lines {
            let cleaned = SpeechTextNormalizer.normalizeImportedTextWithSourceOffsets(line.text)
            guard !cleaned.text.isEmpty else { continue }
            let current = segments.last
            let continues = current?.role == line.role && line.role != .heading
            if let current {
                // A heading stands apart, as in v1 text; other lines keep their line breaks.
                let separator = current.role == .heading || line.role == .heading || !continues ? "\n\n" : "\n"
                text += separator
                length += separator.count
            }
            let start = length
            text += cleaned.text
            length += cleaned.text.count
            if continues {
                segments[segments.count - 1].range.length = length - segments[segments.count - 1].range.start
            } else {
                segments.append(StructuredDocument.Segment(
                    id: "s\(segments.count)",
                    role: line.role,
                    range: StructuredDocument.TextRange(start: start, length: length - start),
                    level: line.role == .heading ? line.level : nil,
                    pageIndex: line.pageIndex
                ))
            }
            let cleanedCharacters = Array(cleaned.text)
            for superscript in line.superscripts {
                // The cleaned characters that came from the superscript run.
                let kept = cleaned.sourceOffsets.indices.filter { superscript.contains(cleaned.sourceOffsets[$0]) }
                guard let first = kept.first, let last = kept.last else { continue }
                let label = String(cleanedCharacters[first...last])
                markers.append(StructuredDocument.Marker(
                    kind: label.allSatisfy { $0.isNumber || ",–-".contains($0) } ? .citation : .footnote,
                    range: StructuredDocument.TextRange(start: start + first, length: last - first + 1),
                    label: label
                ))
            }
        }

        markers += printedCitationMarkers(in: text, segments: segments, excluding: markers)
        markers.sort { $0.range.start < $1.range.start }
        return StructuredDocument(
            extraction: StructuredDocument.Extraction(
                engine: engine,
                version: version,
                sourceSHA256: sourceSHA256,
                pageCount: pageCount,
                textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            ),
            text: text,
            segments: segments,
            markers: markers
        )
    }

    /// Numeric `[12]`, `[3–5, 8]` and parenthetical author–year `(Smith et al., 2020; Lee, 2019)`
    /// citations in text that is read. A narrative citation ("Smith et al. (2020) showed")
    /// keeps its name in the sentence; only its bracketed year would match, and that is left alone.
    static func printedCitationMarkers(
        in text: String,
        segments: [StructuredDocument.Segment],
        excluding existing: [StructuredDocument.Marker]
    ) -> [StructuredDocument.Marker] {
        let numeric = #"\[[0-9]{1,4}(?:\s*[,–-]\s*[0-9]{1,4})*\]"#
        let authorYear = #"\((?:(?:see|e\.g\.,?|cf\.)\s+)?\p{Lu}[\p{L}'’\-]+(?:,?\s+(?:et\s+al\.|and|&)\s*(?:\p{Lu}[\p{L}'’\-]+)?)?,?\s+(?:19|20)[0-9]{2}[a-z]?(?:\s*[;,]\s*(?:\p{Lu}[\p{L}'’\-]+(?:,?\s+(?:et\s+al\.|and|&)\s*(?:\p{Lu}[\p{L}'’\-]+)?)?,?\s+)?(?:19|20)[0-9]{2}[a-z]?)*\)"#
        guard let regex = try? NSRegularExpression(pattern: "\(numeric)|\(authorYear)") else { return [] }
        let taken = existing.map { $0.range.start..<$0.range.end }
        let characters = Array(text)
        var result: [StructuredDocument.Marker] = []
        for segment in segments where StructuredDocumentSpeech.treatment(for: segment.role) == .read {
            let slice = String(characters[segment.range.start..<segment.range.end])
            let nsRange = NSRange(slice.startIndex..<slice.endIndex, in: slice)
            for match in regex.matches(in: slice, range: nsRange) {
                guard let range = Range(match.range, in: slice) else { continue }
                let lower = segment.range.start + slice.distance(from: slice.startIndex, to: range.lowerBound)
                let upper = lower + slice[range].count
                guard !taken.contains(where: { $0.overlaps(lower..<upper) }) else { continue }
                let printed = String(slice[range])
                result.append(StructuredDocument.Marker(
                    kind: .citation,
                    range: StructuredDocument.TextRange(start: lower, length: upper - lower),
                    label: String(printed.dropFirst().dropLast())
                ))
            }
        }
        return result
    }
}

/// I14 for I13 documents: what the listener hears for each role and marker.
///
/// Until C2's `DocumentSpeechRules` (#221) reaches `next`, these are C1's copy of
/// the published table, with the owner's rule for the title page (#191): author
/// names are read, the rest of the title page is skipped silently.
public enum StructuredDocumentSpeech {
    public enum Treatment: Equatable, Sendable {
        case read
        /// Say `notice` in place of the segment ("Table not read.").
        case announceAndSkip(notice: String)
        /// Say `notice` once for a run of these segments ("References skipped.").
        case skipWithNoticeOnce(notice: String)
        /// Leave it out without a word.
        case skip
    }

    public static func treatment(for role: StructuredDocument.Role) -> Treatment {
        switch role {
        case .title, .abstract, .body, .heading, .caption, .authors, .backMatter, .unknown:
            return .read
        case .table:
            return .announceAndSkip(notice: "Table not read.")
        case .equation:
            return .announceAndSkip(notice: "Equation not read.")
        case .reference:
            return .skipWithNoticeOnce(notice: "References skipped.")
        case .footnote, .pageHeader, .pageFooter, .frontMatter:
            return .skip
        }
    }

    public static func isSilent(_ kind: StructuredDocument.MarkerKind) -> Bool {
        kind == .citation || kind == .footnote
    }

    /// The text to hand the speech path, one unit (segment or announcement) per
    /// line, with each character's offset in `document.text`. Announcements map to
    /// the start of the segment they stand for, so skipping never moves an anchor.
    public static func listenableText(_ document: StructuredDocument) -> NormalizedSpeechText {
        var characters: [Character] = []
        var offsets: [Int] = []
        for unit in units(document) {
            if !characters.isEmpty, let first = unit.offsets.first {
                characters.append("\n")
                offsets.append(first)
            }
            characters += unit.characters
            offsets += unit.offsets
        }
        return NormalizedSpeechText(text: String(characters), sourceOffsets: offsets, sourceLength: document.text.count)
    }

    /// What each engine is given, line by line: the listenable text through
    /// `SpeechTextNormalizer`. The C1 corpus scores this.
    public static func spokenLines(_ document: StructuredDocument) -> [String] {
        units(document).flatMap { unit in
            String(unit.characters)
                .components(separatedBy: "\n")
                .map(SpeechTextNormalizer.normalize)
                .filter { !$0.isEmpty }
        }
    }

    struct Unit {
        var characters: [Character]
        var offsets: [Int]
    }

    static func units(_ document: StructuredDocument) -> [Unit] {
        let characters = Array(document.text)
        let silent = document.markers.filter { isSilent($0.kind) }.sorted { $0.range.start < $1.range.start }
        var markerIndex = 0
        var result: [Unit] = []
        var lastNotice: String?
        for segment in document.segments {
            let range = segment.range.start..<min(segment.range.end, characters.count)
            switch treatment(for: segment.role) {
            case .skip:
                continue
            case .announceAndSkip(let notice):
                result.append(announcement(notice, at: range.lowerBound))
                lastNotice = nil
            case .skipWithNoticeOnce(let notice):
                if lastNotice != notice {
                    result.append(announcement(notice, at: range.lowerBound))
                }
                lastNotice = notice
            case .read:
                lastNotice = nil
                var unit = Unit(characters: [], offsets: [])
                var index = range.lowerBound
                while markerIndex < silent.count, silent[markerIndex].range.end <= range.lowerBound { markerIndex += 1 }
                while index < range.upperBound {
                    if markerIndex < silent.count, silent[markerIndex].range.start == index {
                        let end = min(silent[markerIndex].range.end, range.upperBound)
                        // "reading [3], but" → "reading, but": drop the space the marker leaves.
                        if unit.characters.last == " ", end == range.upperBound || " .,;:)".contains(characters[end]) {
                            unit.characters.removeLast()
                            unit.offsets.removeLast()
                        }
                        index = end
                        markerIndex += 1
                        continue
                    }
                    unit.characters.append(characters[index])
                    unit.offsets.append(index)
                    index += 1
                }
                if !unit.characters.isEmpty { result.append(unit) }
            }
        }
        return result
    }

    private static func announcement(_ notice: String, at offset: Int) -> Unit {
        Unit(characters: Array(notice), offsets: Array(repeating: offset, count: notice.count))
    }
}
