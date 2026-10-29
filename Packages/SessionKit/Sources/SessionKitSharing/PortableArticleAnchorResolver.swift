import CryptoKit
import Foundation
import SessionKit

public enum PortableArticleAnchorResolver {
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    public static func normalizedContentSHA256(_ text: String) -> String {
        SHA256.hash(data: Data(normalizedText(text).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Exact-edition hashes are over the unmodified UTF-8 source string whose
    /// character offsets were captured. Normalized hashes identify similar
    /// editions but are never sufficient evidence for reusing raw offsets.
    public static func exactEditionSHA256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Both digests of a text, for the store to keep beside an item (#2506).
    public static func itemTextDigests(_ text: String) -> ItemTextDigests {
        ItemTextDigests(normalizedContentSHA256: normalizedContentSHA256(text), exactEditionSHA256: exactEditionSHA256(text))
    }

    /// Names how `itemTextDigests` hashes, for the store to tell a digest it kept from one this build would make.
    /// Change the number whenever `normalizedText` or either hash changes. The system's major version is part of it
    /// because the folding and the letter classes come from the system's text libraries, which an update can change.
    public static var itemTextDigestFormat: String {
        "1-\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
    }

    public static func resolve(
        anchor: PortableAnchorEvidence,
        in sourceText: String,
        expectedExactEditionSHA256: String?
    ) -> ImportedAnchorResolution {
        resolve(
            anchor: anchor, in: sourceText, expectedExactEditionSHA256: expectedExactEditionSHA256,
            compactIndex: CompactLetterIndex(sourceText)
        )
    }

    /// For callers that place many anchors in one text: they share one `CompactLetterIndex`, which is built only when
    /// an anchor falls through to the separator-free search.
    static func resolve(
        anchor: PortableAnchorEvidence,
        in sourceText: String,
        expectedExactEditionSHA256: String?,
        compactIndex: CompactLetterIndex
    ) -> ImportedAnchorResolution {
        if let expectedExactEditionSHA256,
           expectedExactEditionSHA256 == exactEditionSHA256(sourceText),
           let start = anchor.startChar,
           let end = anchor.endChar,
           start >= 0,
           end > start,
           end <= sourceText.count,
           exactTextMatchesOffsets(anchor: anchor, in: sourceText, start: start, end: end) {
            return ImportedAnchorResolution(
                evidenceClass: .articleTextVerified,
                localStartChar: start,
                localEndChar: end,
                confidence: 1
            )
        }

        guard let exact = anchor.exactText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !exact.isEmpty else {
            return ImportedAnchorResolution(evidenceClass: .unresolved)
        }
        let exactMatches = allRanges(of: exact, in: sourceText)
        if exactMatches.count == 1, let range = exactMatches.first {
            return resolution(for: range, in: sourceText, confidence: 0.98)
        }
        if exactMatches.count > 1,
           let winner = uniqueContextWinner(
               ranges: exactMatches,
               in: sourceText,
               prefix: anchor.prefix,
               suffix: anchor.suffix
           ) {
            return resolution(for: winner, in: sourceText, confidence: 0.92)
        }

        let normalizedMatches = normalizedTokenMatches(of: exact, in: sourceText)
        if normalizedMatches.count == 1, let match = normalizedMatches.first {
            return resolution(for: match, in: sourceText, confidence: 0.88)
        }
        if normalizedMatches.count > 1,
           let winner = uniqueContextWinner(
               ranges: normalizedMatches,
               in: sourceText,
               prefix: anchor.prefix,
               suffix: anchor.suffix
           ) {
            return resolution(for: winner, in: sourceText, confidence: 0.84)
        }
        if normalizedMatches.isEmpty {
            // Last resort (#2402): a PDF whose text layer lost its word spaces, on either side, so the quote and the
            // copy hold the same letters but split them into different words.
            let compactMatches = compactLetterMatches(of: exact, in: compactIndex)
            if compactMatches.count == 1, let match = compactMatches.first {
                return resolution(for: match, in: sourceText, confidence: compactMatchConfidence)
            }
            return ImportedAnchorResolution(evidenceClass: .unresolved)
        }
        return ImportedAnchorResolution(evidenceClass: .ambiguous, isAmbiguous: normalizedMatches.count > 1)
    }

    /// Below the token match (0.88): it ignores where the words break, and it takes only a unique hit.
    private static let compactMatchConfidence = 0.8
    /// Letters and digits a quote needs before the separator-free search is trusted. A shorter run lands inside
    /// unrelated words too easily once the spaces are gone.
    private static let compactMatchMinimumLength = 12

    private static func resolution(
        for range: Range<String.Index>,
        in text: String,
        confidence: Double
    ) -> ImportedAnchorResolution {
        ImportedAnchorResolution(
            evidenceClass: .articleTextVerified,
            localStartChar: text.distance(from: text.startIndex, to: range.lowerBound),
            localEndChar: text.distance(from: text.startIndex, to: range.upperBound),
            confidence: confidence
        )
    }

    private static func exactTextMatchesOffsets(
        anchor: PortableAnchorEvidence,
        in sourceText: String,
        start: Int,
        end: Int
    ) -> Bool {
        guard let exactText = anchor.exactText else { return true }
        let lower = sourceText.index(sourceText.startIndex, offsetBy: start)
        let upper = sourceText.index(sourceText.startIndex, offsetBy: end)
        return sourceText[lower..<upper] == exactText
    }

    private static func uniqueContextWinner(
        ranges: [Range<String.Index>],
        in text: String,
        prefix: String?,
        suffix: String?
    ) -> Range<String.Index>? {
        let scored = ranges.map { range in
            (range, contextScore(range: range, in: text, prefix: prefix, suffix: suffix))
        }.sorted { lhs, rhs in lhs.1 > rhs.1 }
        guard let first = scored.first, first.1 > 0 else { return nil }
        let runnerUp = scored.dropFirst().first?.1 ?? -1
        return first.1 - runnerUp >= 0.25 ? first.0 : nil
    }

    private static func contextScore(
        range: Range<String.Index>,
        in text: String,
        prefix: String?,
        suffix: String?
    ) -> Double {
        var scores: [Double] = []
        if let prefix, !prefix.isEmpty {
            let length = min(prefix.count, text.distance(from: text.startIndex, to: range.lowerBound))
            let start = text.index(range.lowerBound, offsetBy: -length)
            scores.append(similarity(normalizedText(String(text[start..<range.lowerBound])), normalizedText(prefix)))
        }
        if let suffix, !suffix.isEmpty {
            let length = min(suffix.count, text.distance(from: range.upperBound, to: text.endIndex))
            let end = text.index(range.upperBound, offsetBy: length)
            scores.append(similarity(normalizedText(String(text[range.upperBound..<end])), normalizedText(suffix)))
        }
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        let lhsWords = Set(lhs.split(separator: " ").map(String.init))
        let rhsWords = Set(rhs.split(separator: " ").map(String.init))
        let union = lhsWords.union(rhsWords)
        guard !union.isEmpty else { return 0 }
        return Double(lhsWords.intersection(rhsWords).count) / Double(union.count)
    }

    private static func allRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var cursor = haystack.startIndex
        while cursor < haystack.endIndex,
              let range = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            ranges.append(range)
            cursor = range.upperBound
        }
        return ranges
    }

    private static func normalizedTokenMatches(
        of quote: String,
        in source: String
    ) -> [Range<String.Index>] {
        let quoteTokens = normalizedTokens(in: quote).map(\.value)
        let sourceTokens = normalizedTokens(in: source)
        guard !quoteTokens.isEmpty, sourceTokens.count >= quoteTokens.count else { return [] }
        return (0...(sourceTokens.count - quoteTokens.count)).compactMap { start in
            let candidate = sourceTokens[start..<(start + quoteTokens.count)].map(\.value)
            guard candidate == quoteTokens else { return nil }
            return sourceTokens[start].range.lowerBound..<sourceTokens[start + quoteTokens.count - 1].range.upperBound
        }
    }

    /// Matches the quote's letters and digits, with every space and punctuation mark dropped from both sides, and maps
    /// the hit back to the copy's own characters. It is the only tier that can bridge `standardtoolfordescribing`
    /// and `standard tool for describing`. Only a unique hit counts: where the words break is no longer evidence.
    private static func compactLetterMatches(
        of quote: String,
        in index: CompactLetterIndex
    ) -> [Range<String.Index>] {
        let needle = CompactLetterIndex.letters(in: quote).map(\.letter)
        guard needle.count >= compactMatchMinimumLength else { return [] }
        let source = index.text
        let haystack = index.letters
        guard haystack.count >= needle.count else { return [] }
        let quoteRuns = letterRuns(in: quote)
        var matches: [Range<String.Index>] = []
        var start = 0
        let lastStart = haystack.count - needle.count
        while start <= lastStart {
            if haystack[start].letter == needle[0],
               (1..<needle.count).allSatisfy({ haystack[start + $0].letter == needle[$0] }) {
                let lastCharacter = haystack[start + needle.count - 1].at
                let range = haystack[start].at..<source.index(after: lastCharacter)
                // Where the copy breaks its words the way the quote does, the word search should have found the hit, so
                // one that starts or ends inside a word ("data" for "a") is letters lining up by chance.
                let startsInsideWord = range.lowerBound > source.startIndex
                    && isLetterOrNumber(source[source.index(before: range.lowerBound)])
                let endsInsideWord = range.upperBound < source.endIndex && isLetterOrNumber(source[range.upperBound])
                if !(startsInsideWord || endsInsideWord) || letterRuns(in: source[range]) != quoteRuns {
                    matches.append(range)
                    // Two hits are already not unique; there is no need to find a third.
                    if matches.count > 1 { break }
                }
            }
            start += 1
        }
        return matches
    }

    private static func isLetterOrNumber(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    private static func letterRuns<S: StringProtocol>(in text: S) -> Int {
        var runs = 0
        var inRun = false
        for character in text {
            let isLetter = isLetterOrNumber(character)
            if isLetter && !inRun { runs += 1 }
            inRun = isLetter
        }
        return runs
    }

    private static func normalizedTokens(in text: String) -> [(value: String, range: Range<String.Index>)] {
        guard let expression = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = text[range]
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: normalizationLocale)
                .lowercased(with: normalizationLocale)
            return (value, range)
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: normalizationLocale)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: normalizationLocale)
    }
}

/// The folded letters and digits of a text, each with the character it came from. Built once, on first use, for a text
/// that several anchors are placed in (#2402).
final class CompactLetterIndex {
    let text: String
    private var built: [(letter: Character, at: String.Index)]?

    init(_ text: String) { self.text = text }

    var letters: [(letter: Character, at: String.Index)] {
        if let built { return built }
        let letters = Self.letters(in: text)
        built = letters
        return letters
    }

    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    /// A letter that folds to two, like a sharp s, keeps one source character for both.
    static func letters(in text: String) -> [(letter: Character, at: String.Index)] {
        var result: [(letter: Character, at: String.Index)] = []
        result.reserveCapacity(text.utf8.count)
        // Folding goes through Foundation, so each distinct non-ASCII character is folded once (a CJK page repeats few).
        var folded: [Character: [Character]] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            if let ascii = character.asciiValue {
                switch ascii {
                case 0x30...0x39, 0x61...0x7A: result.append((character, index))
                case 0x41...0x5A: result.append((Character(UnicodeScalar(ascii + 0x20)), index))
                default: break
                }
            } else if character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                let letters: [Character]
                if let known = folded[character] {
                    letters = known
                } else {
                    letters = Array(String(character)
                        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: normalizationLocale)
                        .lowercased(with: normalizationLocale))
                        .filter { $0.isLetter || $0.isNumber }
                    folded[character] = letters
                }
                for letter in letters { result.append((letter, index)) }
            }
            index = next
        }
        return result
    }
}

public enum ImportedItemResolver {
    public static func pending(
        interjections: [SharedInterjectionPackageRecord]
    ) -> ImportedPackageSourceResolution {
        result(
            status: .pending,
            interjections: interjections,
            evidenceClass: .unresolved
        )
    }

    public static func resolve(
        item: SharedItemIdentity,
        interjections: [SharedInterjectionPackageRecord],
        against localItem: SharedItemIdentity,
        itemText: String?
    ) -> ImportedPackageSourceResolution {
        guard canRepresentSameWork(item, localItem) else {
            return result(status: .wrongSource, interjections: interjections, evidenceClass: .unresolved)
        }
        if item.itemType == .other, item.durationMs != nil {
            let resolutions = Dictionary(uniqueKeysWithValues: interjections.map { record in
                (record.packageScopedId, ExactLocalAudioImport.resolution(
                    anchor: record.anchor, source: item, recipient: localItem
                ))
            })
            return ImportedPackageSourceResolution(
                status: resolutions.values.allSatisfy { $0.evidenceClass == .exactEdition } ? .resolved : .contextOnly,
                anchorsByPackageScopedId: resolutions
            )
        }
        guard item.itemType != .podcast, let itemText else {
            return result(status: .contextOnly, interjections: interjections, evidenceClass: .unresolved)
        }
        let compactIndex = CompactLetterIndex(itemText)
        let resolutions = Dictionary(uniqueKeysWithValues: interjections.map { record in
            (record.packageScopedId, PortableArticleAnchorResolver.resolve(
                anchor: record.anchor,
                in: itemText,
                expectedExactEditionSHA256: item.exactEditionSHA256,
                compactIndex: compactIndex
            ))
        })
        if resolutions.values.contains(where: \.isAmbiguous) {
            return ImportedPackageSourceResolution(status: .ambiguous, anchorsByPackageScopedId: resolutions)
        }
        let status: ImportedSourceResolutionStatus = resolutions.values.allSatisfy {
            $0.evidenceClass == .articleTextVerified
        } ? .resolved : .contextOnly
        return ImportedPackageSourceResolution(status: status, anchorsByPackageScopedId: resolutions)
    }

    private static func result(
        status: ImportedSourceResolutionStatus,
        interjections: [SharedInterjectionPackageRecord],
        evidenceClass: AnchorResolutionEvidenceClass
    ) -> ImportedPackageSourceResolution {
        ImportedPackageSourceResolution(
            status: status,
            anchorsByPackageScopedId: Dictionary(uniqueKeysWithValues: interjections.map {
                ($0.packageScopedId, ImportedAnchorResolution(evidenceClass: evidenceClass))
            })
        )
    }

    public static func canRepresentSameWork(
        _ packageItem: SharedItemIdentity,
        _ localItem: SharedItemIdentity
    ) -> Bool {
        if let packageEdition = packageItem.exactEditionSHA256,
           let localEdition = localItem.exactEditionSHA256,
           packageEdition == localEdition {
            return true
        }
        if let packageContent = packageItem.normalizedContentSHA256,
           let localContent = localItem.normalizedContentSHA256,
           packageContent == localContent {
            return true
        }
        // A listener's own audio file counts as the episode when they linked it to that episode (#755):
        // it keeps the file's `.other` type, and only a linked file also carries a GUID.
        if packageItem.itemType == .podcast,
           localItem.itemType == .podcast || (localItem.itemType == .other && localItem.episodeGUID != nil),
           let packageGUID = packageItem.episodeGUID,
           let localGUID = localItem.episodeGUID {
            // Feeds reuse short GUIDs (#177), so another show's title rules the pair out unless the packet is
            // linkless (a private feed, whose show each subscriber's feed can title for them) and the same title
            // and the same publish day, both present, back the GUID.
            return packageGUID == localGUID
                && (guidShowsAreCompatible(packageItem.showTitle, localItem.showTitle)
                    || (privateFeedTitlesAgree(packageItem, localItem) && publishDaysMatch(packageItem, localItem)))
                && guidDurationsAreCompatible(packageItem.durationMs, localItem.durationMs)
        }
        // A page link names an episode's audio only for a podcast packet; an article, PDF or EPUB that shares
        // the page is another work, so it never lands on the listener's audio file (#755).
        if localItem.itemType == .other, [.text, .pdf, .epub].contains(packageItem.itemType) { return false }
        guard let packageURL = packageItem.canonicalURL,
              let localURL = localItem.canonicalURL else {
            return privateFeedEpisodesAgree(packageItem, localItem)
        }
        return normalizedURL(packageURL) == normalizedURL(localURL)
    }

    /// A podcast packet from a private feed names its episode by nothing but words: #168 drops every
    /// link, and a GUID that is itself a link. The listener who pastes their own feed adds that
    /// episode (#454), so with no link or GUID on the packet, the same title backed by the same show
    /// or the same publish day is the same episode. A day or a length that disagrees rules it out.
    /// A show title that differs does not: subscribers' feeds can title the show for each of them.
    static func privateFeedEpisodesAgree(_ packageItem: SharedItemIdentity, _ localItem: SharedItemIdentity) -> Bool {
        guard hasNoLinks(packageItem), isBlank(packageItem.episodeGUID),
              privateFeedTitlesAgree(packageItem, localItem) else { return false }
        guard LinkedEpisode.lengthsAgree(packageItem.durationMs, localItem.durationMs) else { return false }
        var corroborated = false
        if let packageDay = publishDay(packageItem.publishedAt), let localDay = publishDay(localItem.publishedAt) {
            guard packageDay == localDay else { return false }
            corroborated = true
        }
        if let packageShow = foldedShowTitle(packageItem.showTitle), let localShow = foldedShowTitle(localItem.showTitle),
           packageShow == localShow {
            corroborated = true
        }
        return corroborated
    }

    /// A packet whose podcast had no link the recipient could open, and the same non-blank title on both sides.
    private static func privateFeedTitlesAgree(_ packageItem: SharedItemIdentity, _ localItem: SharedItemIdentity) -> Bool {
        guard packageItem.itemType == .podcast, localItem.itemType == .podcast, hasNoLinks(packageItem) else { return false }
        let title = comparableTitle(packageItem.title)
        return !title.isEmpty && title == comparableTitle(localItem.title)
    }

    /// Both sides name a publish day, and it is the same day.
    private static func publishDaysMatch(_ packageItem: SharedItemIdentity, _ localItem: SharedItemIdentity) -> Bool {
        guard let packageDay = publishDay(packageItem.publishedAt), let localDay = publishDay(localItem.publishedAt) else { return false }
        return packageDay == localDay
    }

    private static func hasNoLinks(_ item: SharedItemIdentity) -> Bool {
        [item.canonicalURL, item.originalURL, item.enclosureURL, item.source?.canonicalURL].allSatisfy(isBlank)
    }

    private static func isBlank(_ value: String?) -> Bool {
        (value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    private static func comparableTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// The UTC calendar day an ISO 8601 or RSS timestamp names; nil when it is neither, which neither agrees nor disagrees.
    private static func publishDay(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rss = DateFormatter()
        rss.locale = Locale(identifier: "en_US_POSIX")
        rss.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let date = plain.date(from: trimmed) ?? fractional.date(from: trimmed) ?? rss.date(from: trimmed) {
            return String(plain.string(from: date).prefix(10))
        }
        let parts = trimmed.split(separator: "-")
        guard trimmed.count == 10, parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return trimmed
    }

    /// A GUID names an episode, but some feeds reuse one for a trailer or a different cut (#177).
    /// Dynamically inserted ads change an episode's length by minutes, so only a length more than
    /// 20% apart rejects the match; placement inside the episode is the audio evidence's job.
    /// An unknown length on either side keeps the GUID match.
    /// GUIDs are unique only within a feed; some feeds use short ones like "42". When both sides
    /// know the show, a different show rules the match out. Import paths clean a feed's title
    /// differently (Following drops tags and decodes `&amp;`; a direct RSS add keeps CDATA text as
    /// written), so both titles get the same cleanup before they're compared.
    static func guidShowsAreCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = foldedShowTitle(lhs), let rhs = foldedShowTitle(rhs) else { return true }
        return lhs == rhs
    }

    /// A show title with entities decoded, tags and extra spaces dropped, and case and accents folded;
    /// nil when nothing is left.
    static func foldedShowTitle(_ value: String?) -> String? {
        // Entities first, then tags, so `&lt;b&gt;` and an already decoded `<b>` end up alike.
        let cleaned = value?
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return cleaned?.isEmpty == false ? cleaned : nil
    }

    static func guidDurationsAreCompatible(_ lhs: Int?, _ rhs: Int?) -> Bool {
        LinkedEpisode.lengthsAgree(lhs, rhs)
    }

    private static func normalizedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var result = components.string ?? value
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
