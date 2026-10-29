#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
        /// Text printed inside a figure (axis ticks, panel labels, screenshots).
        case figureText = "figure_text"
        case unknown
    }

    public enum MarkerKind: String, Codable, Sendable {
        case citation, footnote, math
        /// A hyphen that only splits one word across a line ("agree-" + "ment").
        case softHyphen = "soft_hyphen"
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

    /// A chapter the PDF's outline names where no printed line matches it (#355). It
    /// starts at `start` in `text` and has no text of its own, so nothing is spoken for it.
    public struct OutlineAnchor: Codable, Equatable, Sendable {
        public var title: String
        public var level: Int
        public var start: Int

        public init(title: String, level: Int, start: Int) {
            self.title = title
            self.level = level
            self.start = start
        }
    }

    public var schemaVersion: String
    public var extraction: Extraction
    public var text: String
    public var segments: [Segment]
    public var markers: [Marker]
    public var floats: [Float]
    /// Optional, so documents saved before it existed still decode, and absent when
    /// there are none, so readers that don't know it never see it.
    public var outline: [OutlineAnchor]?

    public init(schemaVersion: String = StructuredDocument.currentSchemaVersion, extraction: Extraction, text: String, segments: [Segment], markers: [Marker], floats: [Float] = [], outline: [OutlineAnchor]? = nil) {
        self.schemaVersion = schemaVersion
        self.extraction = extraction
        self.text = text
        self.segments = segments
        self.markers = markers
        self.floats = floats
        self.outline = outline
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
    /// The line ends in a hyphen that splits one word with the next line ("agree-" +
    /// "ment"), not a compound ("open-" + "ended"). The extractor decides.
    public var endsWithSoftHyphen: Bool
    /// Outline chapters that start at this line without a printed heading (#355).
    public var outlineEntries: [OutlineEntry]

    public struct OutlineEntry: Equatable, Sendable {
        public var title: String
        public var level: Int

        public init(title: String, level: Int) {
            self.title = title
            self.level = level
        }
    }

    public init(text: String, role: StructuredDocument.Role, pageIndex: Int? = nil, level: Int? = nil, superscripts: [Range<Int>] = [], endsWithSoftHyphen: Bool = false, outlineEntries: [OutlineEntry] = []) {
        self.text = text
        self.role = role
        self.pageIndex = pageIndex
        self.level = level
        self.superscripts = superscripts
        self.endsWithSoftHyphen = endsWithSoftHyphen
        self.outlineEntries = outlineEntries
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
        var outline: [StructuredDocument.OutlineAnchor] = []
        // An anchor on a line with no text left after cleaning moves to the next line.
        var pendingOutline: [StructuredDocumentLine.OutlineEntry] = []
        // The previous body line ended in a superscript run that is not finished ("19,34–").
        var superscriptContinues = false
        var continuedMarkers: [StructuredDocument.TextRange] = []

        for line in lines {
            pendingOutline += line.outlineEntries
            var superscripts = line.superscripts
            var continuation: Range<Int>?
            if superscriptContinues, line.role == .body, let rest = continuedSuperscript(in: line.text) {
                superscripts.append(rest)
                continuation = rest
            }
            superscriptContinues = line.role == .body && superscriptRunIsOpen(in: line.text, superscripts: superscripts)
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
            outline += pendingOutline.map { StructuredDocument.OutlineAnchor(title: $0.title, level: $0.level, start: start) }
            pendingOutline = []
            text += cleaned.text
            length += cleaned.text.count
            if continues {
                segments[segments.count - 1].range.length = length - segments[segments.count - 1].range.start
            } else {
                segments.append(StructuredDocument.Segment(
                    id: "s\(segments.count)",
                    role: line.role,
                    range: StructuredDocument.TextRange(start: start, length: length - start),
                    // A title keeps its level too: the item title is found by it (#272).
                    level: line.role == .heading || line.role == .title ? line.level : nil,
                    pageIndex: line.pageIndex
                ))
            }
            let cleanedCharacters = Array(cleaned.text)
            if line.endsWithSoftHyphen, cleanedCharacters.last == "-" {
                markers.append(StructuredDocument.Marker(
                    kind: .softHyphen,
                    range: StructuredDocument.TextRange(start: length - 1, length: 1),
                    label: nil
                ))
            }
            for superscript in superscripts {
                // The cleaned characters that came from the superscript run.
                let kept = cleaned.sourceOffsets.indices.filter { superscript.contains(cleaned.sourceOffsets[$0]) }
                guard let first = kept.first, let last = kept.last else { continue }
                let label = String(cleanedCharacters[first...last])
                let range = StructuredDocument.TextRange(start: start + first, length: last - first + 1)
                markers.append(StructuredDocument.Marker(
                    kind: label.allSatisfy { $0.isNumber || ",–-".contains($0) } ? .citation : .footnote,
                    range: range,
                    label: label
                ))
                if superscript == continuation { continuedMarkers.append(range) }
            }
        }

        // A number opening a line is a cut run's end only if it is an entry of the reference list ("12,000
        // patients" and "50 patients" are not), or, with no numbered list, not a thousands figure.
        if !continuedMarkers.isEmpty {
            let references = numberedReferenceCount(characters: Array(text), segments: segments)
            markers.removeAll { marker in
                guard marker.kind == .citation, continuedMarkers.contains(marker.range), let label = marker.label else { return false }
                let numbers = label.split { !$0.isNumber }.compactMap { Int($0) }
                return references > 0
                    ? !numbers.allSatisfy { 1...references ~= $0 }
                    : label.range(of: #",[0-9]{3}\b"#, options: .regularExpression) != nil
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
            markers: markers,
            outline: outline.isEmpty ? nil : outline
        )
    }

    /// A superscript run cut by the line end, "prey capture,19,34–" then "38 and (2) the": the
    /// digits that open the next line finish it. The extractor reads fonts per line, so it does
    /// not see them as small type, and the number was read aloud (#1189).
    static func continuedSuperscript(in text: String) -> Range<Int>? {
        let characters = Array(text)
        var start = 0
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        var end = start
        func digits() -> Bool {
            let begin = end
            while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
            return (1...3).contains(end - begin)
        }
        guard digits() else { return nil }
        while end < characters.count, ",–-".contains(characters[end]) {
            let separator = end
            end += 1
            if !digits() {
                // "38, and 40": a separator that ends the run belongs to it and keeps a cut run open.
                end = characters.count > separator + 1 && !characters[separator + 1].isWhitespace ? separator : separator + 1
                break
            }
        }
        // A number that is the start of a sentence or a list item ("14. Next", "2020 was") is not one,
        // nor is "12,000" or a decimal.
        guard end == characters.count || characters[end].isWhitespace else { return nil }
        return start..<end
    }

    private static func superscriptRunIsOpen(in text: String, superscripts: [Range<Int>]) -> Bool {
        let characters = Array(text)
        var end = characters.count
        while end > 0, characters[end - 1].isWhitespace { end -= 1 }
        guard let last = superscripts.max(by: { $0.upperBound < $1.upperBound }),
              last.upperBound == end, last.upperBound <= characters.count, last.count > 0 else { return false }
        return ",–-".contains(characters[last.upperBound - 1])
    }

    /// Numeric `[12]`, `[3–5, 8]` and parenthetical author–year `(Smith et al., 2020; Lee, 2019)`
    /// citations in text that is read. A narrative citation ("Smith et al. (2020) showed")
    /// keeps its name in the sentence; only its bracketed year would match, and that is left alone.
    ///
    /// Round-bracket numbers, Vancouver style `(17)` or `(3–5, 8)`, are citations only when the
    /// document's reference list is numbered and the number is one of its entries (#138).
    /// "we tested (1) speed and (2) accuracy" and "(95% CI)" are prose and stay.
    ///
    /// A bracket with a locator, `[7, Lemma A.1]` or `[48, p. 214]`, is one citation (#138).
    /// Superscripts the extractor flattened onto punctuation ("concept.13 This") are in
    /// `flattenedSuperscriptMarkers`.
    static func printedCitationMarkers(
        in text: String,
        segments: [StructuredDocument.Segment],
        excluding existing: [StructuredDocument.Marker]
    ) -> [StructuredDocument.Marker] {
        let numeric = #"\[[0-9]{1,4}(?:\s*[,–-]\s*[0-9]{1,4})*(?:,\s*(?i:pp?\.|§|(?:lemma|theorem|thm|corollary|cor|proposition|prop|example|appendix|definition|def|remark|section|sec|chapter|chap|ch|eqs?|equation|fig|figure|table|part|page|pages|claim)\b)\.?\s*[\p{Lu}0-9][^\[\]]{0,40})?\]"#
        // Any number of authors ("Autor, Levy and Murnane", "Smith et al.") and of years
        // ("2019, 2024", "2026a"), several works apart by ";" (#2370). A PDF that lost its
        // spaces prints "Chen,2025", so the comma before a year needs no space.
        let name = #"(?:(?:van|von|de|der|den|du|da|di|le|la)\s+)*\p{Lu}[\p{L}'’\-]+"#
        // A list of names ends in "and" or "&", so "(Paris, France, 2019)" stays prose; as before,
        // the last name may follow with no space ("&Jones", "andChen").
        let authors = #"\#(name)(?:(?:,\s*\#(name))*,?\s+(?:and|&)\s*\#(name))?(?:,?\s+et\s+al\.)?"#
        let years = #"(?:19|20)[0-9]{2}[a-z]?(?:\s*,\s*(?:19|20)[0-9]{2}[a-z]?)*"#
        let work = #"(?:(?:see|e\.g\.,?|cf\.)\s*)?\#(authors)(?:,\s*|\s+)\#(years)"#
        let authorYear = #"\(\#(work)(?:\s*;\s*(?:\#(work)|\#(years)))*\)"#
        let round = #"\([0-9]{1,4}(?:\s*[,–-]\s*[0-9]{1,4})*\)"#
        let characters = Array(text)
        guard let square = try? NSRegularExpression(pattern: #"\[[0-9]{1,4}(?:\s*[,–-]\s*[0-9]{1,4})*\]"#),
              let otherStyles = try? NSRegularExpression(pattern: #"\([0-9]{1,4}(?:\s*[,–-]\s*[0-9]{1,4})*\)|(?<=\p{L}\p{L})[.,;][0-9]{1,3}(?=\s)"#)
        else { return [] }
        let read = segments.filter { StructuredDocumentSpeech.treatment(for: $0.role) == .read }
        let slices = read.map { String(characters[$0.range.start..<$0.range.end]) }
        // A paper that cites "[27]" numbers its equations "(8)": round numbers and numbers after
        // punctuation are citations only when it prints fewer square ones than those (#138).
        func count(_ regex: NSRegularExpression) -> Int {
            slices.reduce(0) { $0 + regex.numberOfMatches(in: $1, range: NSRange(location: 0, length: ($1 as NSString).length)) }
        }
        let squares = count(square)
        let citesInSquareBrackets = squares >= 3 && squares > count(otherStyles)
        let references = citesInSquareBrackets ? 0 : numberedReferenceCount(characters: characters, segments: segments)
        let pattern = references > 0 ? "\(numeric)|\(authorYear)|\(round)" : "\(numeric)|\(authorYear)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let enumerator = try? NSRegularExpression(pattern: #"\(([1-9])\)(?=\s*[\p{L}\p{N}“"'(]|,\s*\()"#) else { return [] }
        let taken = existing.map { $0.range.start..<$0.range.end }
        var result: [StructuredDocument.Marker] = []
        for (segment, slice) in zip(read, slices) {
            let nsRange = NSRange(slice.startIndex..<slice.endIndex, in: slice)
            let enumerators = enumeratorRanges(enumerator, in: slice, range: nsRange)
            for match in regex.matches(in: slice, range: nsRange) {
                guard let range = Range(match.range, in: slice) else { continue }
                if slice[range].hasPrefix("(") && slice[range].dropFirst().first?.isNumber == true {
                    guard roundNumbersAreReferences(slice[range], upTo: references),
                          slice.startIndex < range.lowerBound,
                          // "t(18)", "dup(10)", "f(2)": a bracket stuck to a short word is notation.
                          // "mapper(57)" is a citation in a PDF that lost its spaces.
                          !(1...3).contains(slice[..<range.lowerBound].reversed().prefix { $0.isLetter }.count),
                          !enumerators.contains(match.range),
                          !isReferenceToSomethingElse(before: slice[..<range.lowerBound]) else { continue }
                }
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
        guard references > 0 else { return result }
        return result + flattenedSuperscriptMarkers(
            read: read,
            slices: slices,
            references: references,
            taken: taken + result.map { $0.range.start..<$0.range.end },
            // A paper that sets its citations as superscripts, so a number set apart after a full stop
            // is one more of them.
            setsSuperscripts: existing.filter { $0.kind == .citation }.count >= 5
        )
    }

    /// Superscript citations the extractor read as plain text, left stuck to the punctuation or
    /// bracket before them: "a relative concept.13 This", "not Beta,4–6 likely", "Goleman (1998)6
    /// presents", "values and norms).14 15 Social". Only with a numbered reference list, and only
    /// numbers that are its entries, in order.
    ///
    /// Prose keeps its numbers. After a full stop the number must end the sentence's text, with a new
    /// sentence or nothing after it, so "BA.1 variant", "rc.2, both" and "class II.1 without" are read.
    /// After a comma it must too when the document drops the space after commas ("of these,15 were").
    /// A bracket stuck to a word is a formula or a chemical ("f(x)2", "Pb(NO3)2"), and one holding
    /// a formula, a pair of letters or a single letter is squared ("(a+b)2", "(a, b)2", "(n)2"). A decimal ("0.18"), "B.1", "Fig.2",
    /// "No.5", "v7.3" and a number running into a word ("noon.5mg") stay, and a second number after a
    /// bare space joins only when a new sentence follows ("the dose,3 12 Gy").
    private static func flattenedSuperscriptMarkers(
        read: [StructuredDocument.Segment],
        slices: [String],
        references: Int,
        taken: [Range<Int>],
        setsSuperscripts: Bool
    ) -> [StructuredDocument.Marker] {
        let group = #"([0-9]{1,3}(?:\s*[,–-]\s*[0-9]{1,3}|[ ][0-9]{1,3})*)(?=\s|$|[;:,.](?:\s|$))"#
        // The last form is a number set apart after a full stop and ahead of a new sentence: "respectively. 18,19 Of these",
        // or opening the next line: "such as IFN-γ." then "46 In the CD16+" (#1189).
        guard let regex = try? NSRegularExpression(pattern: #"(?<=\p{L}\p{L})([.,;])"# + group + #"|([)\]”"])[.,;:]?"# + group
                                                    + #"|(\.)(?:(?<=\p{L}\p{L}\.)[ ]|(?<=[\p{L}”’"]\n?\.)\n)"# + group + #"(?= \p{Lu})"#),
              let math = try? NSRegularExpression(pattern: #"[+−×÷^=<>/*|]|(?:^|[^\p{L}])[\p{L}0-9]\s*-\s*[\p{L}0-9](?:[^\p{L}]|$)"#),
              let lostSpace = try? NSRegularExpression(pattern: #"\p{Ll}{2}[,;]\p{Ll}{2}"#),
              // "(a, b)2", "(x, y)2": a pair of variables, squared.
              let letters = try? NSRegularExpression(pattern: #"^\s*\p{L}(?:\s*,\s*\p{L})+\s*$"#)
        else { return [] }
        let dropsSpaces = slices.reduce(0) { $0 + lostSpace.numberOfMatches(in: $1, range: NSRange(location: 0, length: ($1 as NSString).length)) } >= 3
        var result: [StructuredDocument.Marker] = []
        for (segment, slice) in zip(read, slices) {
            let nsSlice = slice as NSString
            // Body lines merge into one long segment, so each match looks only at a short window around
            // it, and offsets advance from the previous match: a book-length segment stays linear.
            var cursor = (index: slice.startIndex, offset: 0)
            for match in regex.matches(in: slice, range: NSRange(location: 0, length: nsSlice.length)) {
                let spaced = match.range(at: 5).location != NSNotFound
                if spaced, !setsSuperscripts { continue }
                let afterWord = match.range(at: 1).location != NSNotFound || spaced
                var digits = match.range(at: spaced ? 6 : afterWord ? 2 : 4)
                func following() -> Character? {
                    let end = digits.location + digits.length
                    return nsSlice.substring(with: NSRange(location: end, length: min(64, nsSlice.length - end)))
                        .drop { $0.isWhitespace }.first
                }
                // "the dose,3 12 Gy": a number after a bare space joins only if a new sentence follows.
                let space = (nsSlice.substring(with: digits) as NSString).range(of: "[0-9] [0-9]", options: .regularExpression)
                // "the dose,3 12 Gy" stops at the 3; "function,35 36 although" is a pair of neighbouring entries.
                let entries = nsSlice.substring(with: digits).split(separator: " ").map { Int($0) }
                // Only across a line break, which a unit or noun ("3 4 mg") does not follow with a lowercase word.
                let afterDigits = nsSlice.substring(with: NSRange(location: digits.location + digits.length, length: min(8, nsSlice.length - digits.location - digits.length)))
                let neighbours = !entries.contains(nil) && zip(entries, entries.dropFirst()).allSatisfy { $1 == $0! + 1 }
                    && afterDigits.prefix { $0.isWhitespace }.contains("\n")
                if space.location != NSNotFound, !neighbours, following().map({ !$0.isUppercase }) ?? false {
                    digits.length = space.location + 1
                }
                let next = following()
                let sentenceFollows = next.map { $0.isUppercase || !($0.isLetter || $0.isNumber || "([,.;:-".contains($0)) } ?? true
                if afterWord {
                    let start = max(0, match.range.location - 32)
                    let before = nsSlice.substring(with: NSRange(location: start, length: match.range.location - start))
                    let word = String(before.reversed().prefix { $0.isLetter }.reversed()).lowercased()
                    let punctuation = nsSlice.substring(with: match.range(at: spaced ? 5 : 1))
                    // "Cao et al.22 considered": a superscript stuck to "et al." is a citation, whatever follows (#1189).
                    let afterEtAl = !spaced && punctuation == "." && before.range(of: #"(?:^|\s)et al$"#, options: .regularExpression) != nil
                    guard afterEtAl || (!nonCitationWords.contains(word) && !nonCitationAbbreviations.contains(word)
                          && (sentenceFollows || (punctuation != "." && !dropsSpaces))) else { continue }
                } else if let close = Range(match.range(at: 3), in: slice), "])".contains(slice[close]) {
                    // What the closing bracket closes, when it opens in this segment.
                    let open: Character = slice[close] == ")" ? "(" : "["
                    let window = slice.index(close.lowerBound, offsetBy: -200, limitedBy: slice.startIndex) ?? slice.startIndex
                    if let start = slice[window..<close.lowerBound].lastIndex(of: open) {
                        let content = String(slice[slice.index(after: start)..<close.lowerBound])
                        let previous = start > slice.startIndex ? slice[slice.index(before: start)] : nil
                        let contentRange = NSRange(location: 0, length: (content as NSString).length)
                        guard previous?.isLetter != true, previous?.isNumber != true, content.count > 2,
                              math.firstMatch(in: content, range: contentRange) == nil,
                              letters.firstMatch(in: content, range: contentRange) == nil
                        else { continue }
                    }
                }
                let numbers = nsSlice.substring(with: digits).split { !$0.isNumber }.compactMap { Int($0) }
                guard !numbers.isEmpty, numbers.allSatisfy({ 1...references ~= $0 }), numbers == numbers.sorted(),
                      let range = Range(digits, in: slice) else { continue }
                cursor = (range.lowerBound, cursor.offset + slice.distance(from: cursor.index, to: range.lowerBound))
                let lower = segment.range.start + cursor.offset
                let upper = lower + slice[range].count
                guard !taken.contains(where: { $0.overlaps(lower..<upper) }) else { continue }
                result.append(StructuredDocument.Marker(
                    kind: .citation,
                    range: StructuredDocument.TextRange(start: lower, length: upper - lower),
                    label: String(slice[range])
                ))
            }
        }
        return result
    }

    private static let nonCitationAbbreviations: Set<String> = [
        "no", "nos", "vol", "vols", "ref", "refs", "p", "pp", "v", "ver", "version", "ch", "chap", "art", "para",
        "approx", "ca", "vs", "op", "pt", "pts", "ex", "exp", "suppl", "doi", "pmid", "isbn", "tab", "thm", "eqn",
        "lem", "cor", "prop", "def", "sect", "chr", "nr", "fn", "al", "supp", "sup", "min", "mins", "sec", "hrs", "mg", "kg",
        "ml", "mm", "cm", "nm", "ng", "ug",
    ]

    /// The highest entry number of a numbered reference list ("17. Smith J, …", "[17] Smith …"),
    /// or 0 when the reference lines are not numbered. Reference lines of one run share a segment, so each
    /// line is read on its own. The list must start at 1 and rise by one, allowing a gap of up to two for an
    /// entry the extractor lost; a wrapped continuation line such as "45 (2):100–5" or "10 mg doses" breaks
    /// no sequence because its number is not next. Three entries make a list.
    private static func numberedReferenceCount(
        characters: [Character],
        segments: [StructuredDocument.Segment]
    ) -> Int {
        var entries = 0
        var last = 0
        for segment in segments where segment.role == .reference {
            let text = String(characters[segment.range.start..<segment.range.end])
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // A column of numbers can come out as one line: "1. 2. 3. 4. Woodworth RS: …" (#138).
                var rest = line[...]
                var first = true
                while true {
                    let trimmed = rest.drop { $0.isWhitespace || $0 == "[" }
                    let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
                    guard (1...3).contains(digits.count), let number = Int(digits),
                          number == 1 && last == 0 || (last > 0 && (last + 1)...(last + 3) ~= number),
                          let next = trimmed.dropFirst(digits.count).first,
                          next == "." || next == "]" || next == ")" || (first && next.isWhitespace)
                    else { break }
                    entries += 1
                    last = number
                    guard !next.isWhitespace else { break }
                    rest = trimmed.dropFirst(digits.count + 1)
                    first = false
                }
            }
        }
        return entries >= 3 ? last : 0
    }

    /// `(1)`, `(2)`, … that list things in the prose ("we tested (1) speed and (2) accuracy", "(1), (2) and (3)"):
    /// a single digit followed by a word, number, quote or another bracket, with the next or previous digit
    /// within 150 characters. A lone "(1) speed" is left to the citation rule.
    private static func enumeratorRanges(_ regex: NSRegularExpression, in slice: String, range: NSRange) -> [NSRange] {
        let found = regex.matches(in: slice, range: range).compactMap { match -> (range: NSRange, number: Int)? in
            guard let digit = Range(match.range(at: 1), in: slice), let number = Int(slice[digit]) else { return nil }
            return (match.range, number)
        }
        return found.filter { item in
            found.contains { other in
                abs(other.number - item.number) == 1 && abs(other.range.location - item.range.location) <= 150
            }
        }.map(\.range)
    }

    /// "Eq. (2)", "Figure (3)", "a scale (1–5)", "ages (10–15)": the number belongs to the thing named just before it.
    private static func isReferenceToSomethingElse(before text: Substring) -> Bool {
        let trimmed = text.reversed().drop { $0.isWhitespace }
        guard let previous = trimmed.first else { return true }
        if "=+−-*/<>^≤≥±×⁰¹²³⁴⁵⁶⁷⁸⁹".contains(previous) || previous.isMathSymbol { return true }
        let word = String(trimmed.prefix { $0.isLetter || $0 == "." }.reversed()).lowercased()
        return nonCitationWords.contains(word.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    private static let nonCitationWords: Set<String> = [
        "eq", "eqs", "equation", "equations", "fig", "figs", "figure", "figures", "table", "tables", "section",
        "sections", "sec", "step", "steps", "panel", "panels", "chapter", "appendix", "scale", "scales", "range",
        "ranging", "ages", "age", "aged", "score", "scores", "scored", "rated", "rating", "ratings", "between", "from",
        "item", "items", "point", "points", "grade", "grades", "stage", "stages", "phase", "group", "groups", "type",
    ]

    /// Every number in `(3–5, 8)` is an entry of the list (a range counts its ends).
    private static func roundNumbersAreReferences(_ printed: Substring, upTo count: Int) -> Bool {
        let numbers = printed.split { !$0.isNumber }.compactMap { Int($0) }
        return !numbers.isEmpty && numbers.allSatisfy { 1...count ~= $0 }
    }
}

/// I14 for I13 documents: what the listener hears for each role and marker.
///
/// Until C2's `DocumentSpeechRules` (#221) reaches `next`, these are C1's copy of
/// the published table, with the owner's rule for the title page (#191): author
/// names are read, the rest of the title page is skipped silently. Text inside a
/// figure is skipped: its caption announces the figure ("Figure 2."). That role is
/// C1's proposal to C2 (#191).
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
        case .footnote, .pageHeader, .pageFooter, .frontMatter, .figureText:
            return .skip
        }
    }

    public static func isSilent(_ kind: StructuredDocument.MarkerKind) -> Bool {
        kind == .citation || kind == .footnote
    }

    /// What the speech path speaks instead of `Item.text` for a PDF on the new reader (extraction
    /// v2), with each character's offset in `Item.text`. Nil for every other item, and for a
    /// document whose text isn't exactly `Item.text`. Live speech and prepared audio share it (#336).
    public static func listenableProjection(item: Item, document: StructuredDocument?) -> NormalizedSpeechText? {
        guard item.mediaType == "pdf", let text = item.text, let document, document.text == text else { return nil }
        return listenableText(document)
    }

    /// The text to hand the speech path, one unit (segment or announcement) per
    /// line, with each character's offset in `document.text`. Announcements map to
    /// the start of the segment they stand for, so skipping never moves an anchor.
    public static func listenableText(_ document: StructuredDocument) -> NormalizedSpeechText {
        var characters: [Character] = []
        var offsets: [Int] = []
        for unit in units(document) {
            // The line break belongs to what came before, so seeking to a unit's first
            // character lands on that character, not on the break.
            if !characters.isEmpty, let last = offsets.last {
                characters.append("\n")
                offsets.append(last)
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
        let softHyphens = Set(document.markers.filter { $0.kind == .softHyphen }.map(\.range.start))
        var markerIndex = 0
        var result: [Unit] = []
        var lastNotice: String?
        for segment in document.segments {
            let range = segment.range.start..<min(segment.range.end, characters.count)
            switch treatment(for: segment.role) {
            case .skip:
                continue
            case .announceAndSkip(let notice):
                // Two tables in a row, split only by a page header, get one notice.
                if lastNotice != notice {
                    result.append(announcement(notice, at: range.lowerBound))
                }
                lastNotice = notice
            case .skipWithNoticeOnce(let notice):
                if lastNotice != notice {
                    result.append(announcement(notice, at: range.lowerBound))
                }
                lastNotice = notice
            case .read:
                // Headings between two runs of skipped text don't end the run: PDFKit can
                // read an Appendix heading between the columns of a reference page, and
                // "References skipped." shouldn't play again after it (#220 T4). Body text
                // does, so a separate list is still announced.
                if segment.role != .heading { lastNotice = nil }
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
                    // A hyphen at a line end: "agree-\nment" (a soft hyphen, one word) is
                    // spoken "agreement"; "open-\nended" or "Mixtral-\n8x7B" keeps its hyphen.
                    // Either way the line break goes, so no pause splits the word.
                    if characters[index] == "-", index + 1 < range.upperBound, characters[index + 1] == "\n",
                       index > range.lowerBound, characters[index - 1].isLetter || characters[index - 1].isNumber {
                        if !softHyphens.contains(index) {
                            unit.characters.append("-")
                            unit.offsets.append(index)
                        }
                        index += 2
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
