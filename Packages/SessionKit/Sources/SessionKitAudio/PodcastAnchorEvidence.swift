import CryptoKit
import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(ShazamKit)
import ShazamKit
#endif

public struct GeneratedPodcastAnchorEvidence: Equatable, Sendable {
    public let id: String
    public let archivePath: String
    public let fileURL: URL
    public let durationMs: Int
    public let anchorOffsetMs: Int

    public init(
        id: String,
        archivePath: String,
        fileURL: URL,
        durationMs: Int,
        anchorOffsetMs: Int
    ) {
        self.id = id
        self.archivePath = archivePath
        self.fileURL = fileURL
        self.durationMs = durationMs
        self.anchorOffsetMs = anchorOffsetMs
    }
}

public struct PodcastAcousticEvidenceQuery: Sendable {
    public let id: String
    public let signatureData: Data
    public let anchorOffsetMs: Int

    public init(id: String, signatureData: Data, anchorOffsetMs: Int) {
        self.id = id
        self.signatureData = signatureData
        self.anchorOffsetMs = anchorOffsetMs
    }
}

public struct PodcastPortableAnchorQuery: Sendable {
    public let packageScopedId: String
    public let senderMediaTimeMs: Int?
    public let evidence: [PodcastAcousticEvidenceQuery]
    public let evidenceWasDeclared: Bool

    public init(
        packageScopedId: String,
        senderMediaTimeMs: Int?,
        evidence: [PodcastAcousticEvidenceQuery],
        evidenceWasDeclared: Bool? = nil
    ) {
        self.packageScopedId = packageScopedId
        self.senderMediaTimeMs = senderMediaTimeMs
        self.evidence = evidence
        self.evidenceWasDeclared = evidenceWasDeclared ?? !evidence.isEmpty
    }
}

public enum PodcastAnchorEvidenceError: Error, Equatable, LocalizedError {
    case unsupported
    case invalidSourceDuration
    case audioTrackMissing
    case insufficientEvidenceWindow
    case signatureGenerationFailed
    case invalidSignature(String)
    case referenceGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Acoustic anchor evidence is unavailable on this device."
        case .invalidSourceDuration: return "The podcast duration could not be read."
        case .audioTrackMissing: return "The podcast has no readable audio track."
        case .insufficientEvidenceWindow: return "There is not enough audio around this Margin to create anchor evidence."
        case .signatureGenerationFailed: return "The acoustic anchor signature could not be generated."
        case .invalidSignature(let id): return "Acoustic anchor evidence \(id) is invalid."
        case .referenceGenerationFailed: return "The downloaded podcast could not be prepared for anchor matching."
        }
    }
}

/// Generates small, non-reversible ShazamKit signatures from the exact local
/// podcast edition heard by the sender. The podcast audio itself never enters
/// the package.
public enum PodcastAnchorEvidenceGenerator {
    public static let flankDurationMs = 12_000
    public static let anchorGapMs = 500
    public static let minimumEvidenceDurationMs = 3_000

    public static func exactEditionSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func generate(
        sourceURL: URL,
        anchorMediaTimeMs: Int,
        outputDirectory: URL,
        idPrefix: String
    ) async throws -> [GeneratedPodcastAnchorEvidence] {
        #if canImport(AVFoundation) && canImport(ShazamKit)
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw PodcastAnchorEvidenceError.invalidSourceDuration
        }
        let durationMs = max(1, Int((durationSeconds * 1_000).rounded()))
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PodcastAnchorEvidenceError.audioTrackMissing
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let boundedAnchor = min(durationMs, max(0, anchorMediaTimeMs))
        let proposedWindows: [(label: String, startMs: Int, endMs: Int)] = [
            (
                "pre",
                max(0, boundedAnchor - anchorGapMs - flankDurationMs),
                max(0, boundedAnchor - anchorGapMs)
            ),
            (
                "post",
                min(durationMs, boundedAnchor + anchorGapMs),
                min(durationMs, boundedAnchor + anchorGapMs + flankDurationMs)
            )
        ]
        var generated: [GeneratedPodcastAnchorEvidence] = []
        for window in proposedWindows where window.endMs - window.startMs >= minimumEvidenceDurationMs {
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw PodcastAnchorEvidenceError.signatureGenerationFailed
            }
            let range = CMTimeRange(
                start: CMTime(value: CMTimeValue(window.startMs), timescale: 1_000),
                duration: CMTime(value: CMTimeValue(window.endMs - window.startMs), timescale: 1_000)
            )
            try track.insertTimeRange(range, of: sourceTrack, at: .zero)
            let signature = try await SHSignatureGenerator.signature(from: composition)
            let data = signature.dataRepresentation
            guard !data.isEmpty else { throw PodcastAnchorEvidenceError.signatureGenerationFailed }
            let safePrefix = idPrefix.replacingOccurrences(
                of: #"[^A-Za-z0-9._-]"#,
                with: "-",
                options: .regularExpression
            )
            let id = "\(safePrefix)-\(window.label)"
            let archivePath = "assets/evidence/\(id).shazamsignature"
            let fileURL = outputDirectory.appending(path: "\(id).shazamsignature")
            try data.write(to: fileURL, options: .atomic)
            generated.append(GeneratedPodcastAnchorEvidence(
                id: id,
                archivePath: archivePath,
                fileURL: fileURL,
                durationMs: max(1, Int((signature.duration * 1_000).rounded())),
                anchorOffsetMs: boundedAnchor - window.startMs
            ))
        }
        guard !generated.isEmpty else { throw PodcastAnchorEvidenceError.insufficientEvidenceWindow }
        return generated
        #else
        throw PodcastAnchorEvidenceError.unsupported
        #endif
    }
}

/// Resolves every Margin against one locally downloaded recipient edition. The
/// full reference signature is generated once and remains on the recipient.
public enum PodcastAcousticAnchorResolver {
    public static let maximumFusionSpreadMs = 1_500

    public static func resolve(
        queries: [PodcastPortableAnchorQuery],
        recipientAudioURL: URL,
        senderExactEditionSHA256: String?,
        senderDurationMs: Int?,
        strongSourceIdentity: Bool
    ) async throws -> [String: ImportedAnchorResolution] {
        let recipientDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: recipientAudioURL)
        if let senderExactEditionSHA256, senderExactEditionSHA256 == recipientDigest {
            return Dictionary(uniqueKeysWithValues: queries.map { query in
                guard let senderMediaTimeMs = query.senderMediaTimeMs else {
                    return (query.packageScopedId, ImportedAnchorResolution(
                        evidenceClass: .unresolved,
                        algorithmVersion: "podcast-anchor.v1"
                    ))
                }
                return (query.packageScopedId, ImportedAnchorResolution(
                    evidenceClass: .exactEdition,
                    localMediaTimeMs: senderMediaTimeMs,
                    confidence: 1,
                    algorithmVersion: "podcast-anchor.v1"
                ))
            })
        }

        #if canImport(AVFoundation) && canImport(ShazamKit)
        let recipientDurationMs = try await durationMs(of: recipientAudioURL)
        let evidenceQueries = queries.flatMap(\.evidence)
        let session: SHSession?
        if evidenceQueries.isEmpty {
            session = nil
        } else {
            let reference: SHSignature
            do {
                reference = try await SHSignatureGenerator.signature(from: AVURLAsset(url: recipientAudioURL))
            } catch {
                throw PodcastAnchorEvidenceError.referenceGenerationFailed
            }
            let catalog = SHCustomCatalog()
            let item = SHMediaItem(properties: [.title: "Spoken Margins recipient edition"])
            try catalog.addReferenceSignature(reference, representing: [item])
            session = SHSession(catalog: catalog)
        }

        var resolutions: [String: ImportedAnchorResolution] = [:]
        for query in queries {
            var candidates: [(timeMs: Int, confidence: Double)] = []
            for evidence in query.evidence {
                let signature: SHSignature
                do {
                    signature = try SHSignature(dataRepresentation: evidence.signatureData)
                } catch {
                    throw PodcastAnchorEvidenceError.invalidSignature(evidence.id)
                }
                guard let session else { continue }
                switch await session.result(from: signature) {
                case .match(let match):
                    guard let item = match.mediaItems.first else { continue }
                    let matchedStartMs = Int((item.matchOffset * 1_000).rounded())
                    let confidence: Double
                    if #available(iOS 18.4, macOS 15.4, *) {
                        confidence = Double(item.confidence)
                    } else {
                        confidence = 0.9
                    }
                    candidates.append((matchedStartMs + evidence.anchorOffsetMs, confidence))
                case .noMatch, .error:
                    continue
                }
            }
            resolutions[query.packageScopedId] = resolveCandidates(
                candidates,
                query: query,
                senderDurationMs: senderDurationMs,
                recipientDurationMs: recipientDurationMs,
                strongSourceIdentity: strongSourceIdentity,
                exactDigestContradiction: senderExactEditionSHA256 != nil
            )
        }
        return resolutions
        #else
        return Dictionary(uniqueKeysWithValues: queries.map { query in
            (query.packageScopedId, timestampFallback(
                query: query,
                senderDurationMs: senderDurationMs,
                recipientDurationMs: nil,
                strongSourceIdentity: strongSourceIdentity,
                exactDigestContradiction: senderExactEditionSHA256 != nil
            ))
        })
        #endif
    }

    static func resolveCandidates(
        _ candidates: [(timeMs: Int, confidence: Double)],
        query: PodcastPortableAnchorQuery,
        senderDurationMs: Int?,
        recipientDurationMs: Int?,
        strongSourceIdentity: Bool,
        exactDigestContradiction: Bool
    ) -> ImportedAnchorResolution {
        guard !candidates.isEmpty else {
            if !query.evidenceWasDeclared {
                return timestampFallback(
                    query: query,
                    senderDurationMs: senderDurationMs,
                    recipientDurationMs: recipientDurationMs,
                    strongSourceIdentity: strongSourceIdentity,
                    exactDigestContradiction: exactDigestContradiction
                )
            }
            return ImportedAnchorResolution(
                evidenceClass: .absentFromRecipientEdition,
                algorithmVersion: "podcast-anchor.v1"
            )
        }
        guard query.evidence.count <= 1 || candidates.count == query.evidence.count else {
            return ImportedAnchorResolution(
                evidenceClass: .ambiguous,
                isAmbiguous: true,
                algorithmVersion: "podcast-anchor.v1"
            )
        }
        let sorted = candidates.sorted { $0.timeMs < $1.timeMs }
        let spread = sorted.last!.timeMs - sorted.first!.timeMs
        guard spread <= maximumFusionSpreadMs else {
            return ImportedAnchorResolution(
                evidenceClass: .ambiguous,
                isAmbiguous: true,
                algorithmVersion: "podcast-anchor.v1"
            )
        }
        let median = sorted[sorted.count / 2].timeMs
        let confidence = candidates.map(\.confidence).reduce(0, +) / Double(candidates.count)
        return ImportedAnchorResolution(
            evidenceClass: candidates.count > 1 ? .fused : .acousticVerified,
            localMediaTimeMs: max(0, median),
            confidence: confidence,
            algorithmVersion: "podcast-anchor.v1"
        )
    }

    private static func timestampFallback(
        query: PodcastPortableAnchorQuery,
        senderDurationMs: Int?,
        recipientDurationMs: Int?,
        strongSourceIdentity: Bool,
        exactDigestContradiction: Bool
    ) -> ImportedAnchorResolution {
        // The held-out corpus falsified duration-only guards: equal total
        // duration can conceal offsetting local insertions and deletions. Keep
        // the sender timestamp as retained evidence, never an inline position.
        _ = (query, senderDurationMs, recipientDurationMs, strongSourceIdentity, exactDigestContradiction)
        return ImportedAnchorResolution(
            evidenceClass: .unresolved,
            algorithmVersion: "podcast-anchor.v1"
        )
    }

    #if canImport(AVFoundation)
    private static func durationMs(of url: URL) async throws -> Int {
        let duration = try await AVURLAsset(url: url).load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw PodcastAnchorEvidenceError.invalidSourceDuration }
        return max(1, Int((seconds * 1_000).rounded()))
    }
    #endif
}

/// Resolves bounded, human-inspectable sender transcript context against a
/// recipient-local timed transcript. No full transcript enters the package.
public enum PodcastTranscriptAnchorResolver {
    public static let contextTokenCount = 12
    public static let minimumContextTokenCount = 6
    public static let maximumBoundarySpreadMs = 10_000

    private struct TimedToken {
        let value: String
        let startMs: Int
        let endMs: Int
    }

    public static func resolve(
        anchor: PortableAnchorEvidence,
        recipientTimeline: TranscriptTimeline
    ) -> ImportedAnchorResolution {
        let recipientTokens = timedTokens(in: recipientTimeline)
        guard !recipientTokens.isEmpty else {
            return ImportedAnchorResolution(
                evidenceClass: .unresolved,
                algorithmVersion: "podcast-transcript-anchor.v1"
            )
        }
        let prefix = Array(normalizedTokens(anchor.prefix ?? "").suffix(contextTokenCount))
        let suffix = Array(normalizedTokens(anchor.suffix ?? "").prefix(contextTokenCount))
        let hasPrefix = prefix.count >= minimumContextTokenCount
        let hasSuffix = suffix.count >= minimumContextTokenCount
        guard hasPrefix || hasSuffix else {
            return ImportedAnchorResolution(
                evidenceClass: .unresolved,
                algorithmVersion: "podcast-transcript-anchor.v1"
            )
        }

        let prefixMatches = hasPrefix ? matches(prefix, in: recipientTokens) : []
        let suffixMatches = hasSuffix ? matches(suffix, in: recipientTokens) : []
        if prefixMatches.count > 1 || suffixMatches.count > 1 {
            return ImportedAnchorResolution(
                evidenceClass: .ambiguous,
                isAmbiguous: true,
                algorithmVersion: "podcast-transcript-anchor.v1"
            )
        }
        if hasPrefix && prefixMatches.count != 1 || hasSuffix && suffixMatches.count != 1 {
            return ImportedAnchorResolution(
                evidenceClass: .unresolved,
                algorithmVersion: "podcast-transcript-anchor.v1"
            )
        }

        var boundaries: [Int] = []
        if let match = prefixMatches.first {
            boundaries.append(recipientTokens[match.upperBound - 1].endMs)
        }
        if let match = suffixMatches.first {
            boundaries.append(recipientTokens[match.lowerBound].startMs)
        }
        guard let first = boundaries.min(), let last = boundaries.max() else {
            return ImportedAnchorResolution(
                evidenceClass: .unresolved,
                algorithmVersion: "podcast-transcript-anchor.v1"
            )
        }
        guard last - first <= maximumBoundarySpreadMs else {
            return ImportedAnchorResolution(
                evidenceClass: .ambiguous,
                isAmbiguous: true,
                algorithmVersion: "podcast-transcript-anchor.v1"
            )
        }
        return ImportedAnchorResolution(
            evidenceClass: .transcriptVerified,
            localMediaTimeMs: (first + last) / 2,
            confidence: boundaries.count == 2 ? 0.94 : 0.84,
            algorithmVersion: "podcast-transcript-anchor.v1"
        )
    }

    private static func timedTokens(in timeline: TranscriptTimeline) -> [TimedToken] {
        timeline.segments.sorted { $0.startMs < $1.startMs }.flatMap { segment -> [TimedToken] in
            let values = normalizedTokens(segment.text)
            guard !values.isEmpty else { return [] }
            let duration = max(1, segment.endMs - segment.startMs)
            return values.enumerated().map { index, value in
                TimedToken(
                    value: value,
                    startMs: segment.startMs + duration * index / values.count,
                    endMs: segment.startMs + duration * (index + 1) / values.count
                )
            }
        }
    }

    private static func matches(
        _ needle: [String],
        in haystack: [TimedToken]
    ) -> [Range<Int>] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        return (0...(haystack.count - needle.count)).compactMap { start in
            let candidate = haystack[start..<(start + needle.count)].map(\.value)
            return candidate == needle ? start..<(start + needle.count) : nil
        }
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            return text[tokenRange].folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }
}

/// Combines independently typed evidence, then rejects any recipient positions
/// that contradict another anchor's sender/recipient order.
public enum PodcastAnchorFusionResolver {
    /// Transcript segment boundaries are coarse even when their words identify
    /// the right passage. Acoustic evidence remains the timing authority.
    public static let maximumCrossEvidenceSpreadMs = 10_000

    public static func fuse(
        transcript: ImportedAnchorResolution,
        acoustic: ImportedAnchorResolution
    ) -> ImportedAnchorResolution {
        if acoustic.evidenceClass == .exactEdition, acoustic.localMediaTimeMs != nil {
            return acoustic
        }
        let transcriptTime = transcript.localMediaTimeMs
        let acousticTime = acoustic.localMediaTimeMs
        if let transcriptTime, let acousticTime {
            guard abs(transcriptTime - acousticTime) <= maximumCrossEvidenceSpreadMs else {
                return ambiguous()
            }
            return ImportedAnchorResolution(
                evidenceClass: .fused,
                localMediaTimeMs: acousticTime,
                confidence: min(transcript.confidence ?? 0.9, acoustic.confidence ?? 0.9),
                algorithmVersion: "podcast-anchor-fusion.v1"
            )
        }
        if transcriptTime != nil {
            guard acoustic.evidenceClass != .ambiguous,
                  acoustic.evidenceClass != .absentFromRecipientEdition else { return ambiguous() }
            return ImportedAnchorResolution(
                evidenceClass: .transcriptVerified,
                confidence: transcript.confidence,
                algorithmVersion: "podcast-anchor-fusion.v1"
            )
        }
        if acousticTime != nil {
            guard transcript.evidenceClass != .ambiguous else { return ambiguous() }
            return acoustic
        }
        if transcript.evidenceClass == .ambiguous || acoustic.evidenceClass == .ambiguous {
            return ambiguous()
        }
        if acoustic.evidenceClass == .absentFromRecipientEdition {
            return acoustic
        }
        return ImportedAnchorResolution(
            evidenceClass: .unresolved,
            algorithmVersion: "podcast-anchor-fusion.v1"
        )
    }

    public static func enforcingMonotonicOrder(
        queries: [PodcastPortableAnchorQuery],
        resolutions: [String: ImportedAnchorResolution]
    ) -> [String: ImportedAnchorResolution] {
        let positioned = queries.compactMap { query -> (id: String, sender: Int, recipient: Int)? in
            guard let sender = query.senderMediaTimeMs,
                  let recipient = resolutions[query.packageScopedId]?.localMediaTimeMs else { return nil }
            return (query.packageScopedId, sender, recipient)
        }.sorted { lhs, rhs in
            lhs.sender == rhs.sender ? lhs.id < rhs.id : lhs.sender < rhs.sender
        }
        var contradicted: Set<String> = []
        for firstIndex in positioned.indices {
            for secondIndex in positioned.index(after: firstIndex)..<positioned.endIndex {
                if positioned[firstIndex].recipient >= positioned[secondIndex].recipient {
                    contradicted.insert(positioned[firstIndex].id)
                    contradicted.insert(positioned[secondIndex].id)
                }
            }
        }
        guard !contradicted.isEmpty else { return resolutions }
        return resolutions.mapValues { $0 }.merging(
            Dictionary(uniqueKeysWithValues: contradicted.map { ($0, ambiguous()) })
        ) { _, replacement in replacement }
    }

    private static func ambiguous() -> ImportedAnchorResolution {
        ImportedAnchorResolution(
            evidenceClass: .ambiguous,
            isAmbiguous: true,
            algorithmVersion: "podcast-anchor-fusion.v1"
        )
    }
}
