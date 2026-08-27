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

    public static func resolve(
        anchor: PortableAnchorEvidence,
        in sourceText: String,
        expectedExactEditionSHA256: String?
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
        return ImportedAnchorResolution(
            evidenceClass: normalizedMatches.isEmpty ? .unresolved : .ambiguous,
            isAmbiguous: normalizedMatches.count > 1
        )
    }

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

public enum ImportedSourceResolver {
    public static func pending(
        package: InterjectionPackageManifest
    ) -> ImportedPackageSourceResolution {
        result(
            status: .pending,
            package: package,
            evidenceClass: .unresolved
        )
    }

    public static func resolve(
        package: InterjectionPackageManifest,
        against localSource: SharedSourceIdentity,
        sourceText: String?
    ) -> ImportedPackageSourceResolution {
        guard sourcesCanRepresentSameWork(package.source, localSource) else {
            return result(status: .wrongSource, package: package, evidenceClass: .unresolved)
        }
        guard package.source.sourceType == .article, let sourceText else {
            return result(status: .contextOnly, package: package, evidenceClass: .unresolved)
        }
        let resolutions = Dictionary(uniqueKeysWithValues: package.interjections.map { record in
            (record.packageScopedId, PortableArticleAnchorResolver.resolve(
                anchor: record.anchor,
                in: sourceText,
                expectedExactEditionSHA256: package.source.exactEditionSHA256
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
        package: InterjectionPackageManifest,
        evidenceClass: AnchorResolutionEvidenceClass
    ) -> ImportedPackageSourceResolution {
        ImportedPackageSourceResolution(
            status: status,
            anchorsByPackageScopedId: Dictionary(uniqueKeysWithValues: package.interjections.map {
                ($0.packageScopedId, ImportedAnchorResolution(evidenceClass: evidenceClass))
            })
        )
    }

    private static func sourcesCanRepresentSameWork(
        _ packageSource: SharedSourceIdentity,
        _ localSource: SharedSourceIdentity
    ) -> Bool {
        guard packageSource.sourceType == localSource.sourceType else { return false }
        if let packageEdition = packageSource.exactEditionSHA256,
           let localEdition = localSource.exactEditionSHA256,
           packageEdition == localEdition {
            return true
        }
        if let packageContent = packageSource.normalizedContentSHA256,
           let localContent = localSource.normalizedContentSHA256,
           packageContent == localContent {
            return true
        }
        if packageSource.sourceType == .podcast,
           let packageGUID = packageSource.episodeGUID,
           let localGUID = localSource.episodeGUID {
            return packageGUID == localGUID
        }
        return normalizedURL(packageSource.canonicalURL) == normalizedURL(localSource.canonicalURL)
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
