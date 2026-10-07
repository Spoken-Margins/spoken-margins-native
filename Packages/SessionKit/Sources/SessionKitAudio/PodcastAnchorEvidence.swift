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
    /// Must stay under ShazamKit's 12 s query limit after frame rounding; see SparseFingerprintSchedule.
    public static let flankDurationMs = SparseFingerprintSchedule.targetDurationMs
    public static let anchorGapMs = 500
    public static let minimumEvidenceDurationMs = 3_000

    public static func exactEditionSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // FileHandle's reads are autoreleased. Release each buffer here so a synchronous digest (or
            // several exact-edition resolutions without a suspension) never retains the whole episode.
            let didRead = try autoreleasepool {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                guard !data.isEmpty else { return false }
                hasher.update(data: data)
                return true
            }
            guard didRead else { break }
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
            let signature = try await PodcastAssetSignatureGenerator.signature(from: composition)
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

    public static func generateLandmark(
        sourceURL: URL,
        sourceStartMs: Int,
        targetDurationMs: Int = SparseFingerprintSchedule.targetDurationMs,
        outputDirectory: URL,
        id: String
    ) async throws -> GeneratedPodcastAnchorEvidence {
        #if canImport(AVFoundation) && canImport(ShazamKit)
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationMs = Int((CMTimeGetSeconds(duration) * 1_000).rounded())
        guard durationMs > 0 else { throw PodcastAnchorEvidenceError.invalidSourceDuration }
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PodcastAnchorEvidenceError.audioTrackMissing
        }
        let startMs = max(0, sourceStartMs)
        let lengthMs = min(targetDurationMs, durationMs - startMs)
        guard lengthMs >= minimumEvidenceDurationMs else {
            throw PodcastAnchorEvidenceError.insufficientEvidenceWindow
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw PodcastAnchorEvidenceError.signatureGenerationFailed }
        try track.insertTimeRange(
            CMTimeRange(
                start: CMTime(value: CMTimeValue(startMs), timescale: 1_000),
                duration: CMTime(value: CMTimeValue(lengthMs), timescale: 1_000)
            ),
            of: sourceTrack,
            at: .zero
        )
        let signature = try await PodcastAssetSignatureGenerator.signature(from: composition)
        let data = signature.dataRepresentation
        guard !data.isEmpty else { throw PodcastAnchorEvidenceError.signatureGenerationFailed }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let safeID = id.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
        let fileURL = outputDirectory.appending(path: "\(safeID).shazamsignature")
        try data.write(to: fileURL, options: .atomic)
        return GeneratedPodcastAnchorEvidence(
            id: safeID,
            archivePath: "assets/evidence/\(safeID).shazamsignature",
            fileURL: fileURL,
            durationMs: max(1, Int((signature.duration * 1_000).rounded())),
            anchorOffsetMs: 0
        )
        #else
        throw PodcastAnchorEvidenceError.unsupported
        #endif
    }
}

/// Resolves every Margin against one locally downloaded recipient edition. The
/// full reference signature is generated once and remains on the recipient.
public enum PodcastAcousticAnchorResolver {
    public static let maximumFusionSpreadMs = 1_500
    public static let minimumPartialFlankConfidence = 0.9
    public static let minimumRepeatConfidenceRatio = 0.5

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
        if queries.allSatisfy({ $0.evidence.isEmpty }) {
            return Dictionary(uniqueKeysWithValues: queries.map { query in
                (query.packageScopedId, resolveCandidates(
                    [],
                    query: query,
                    senderDurationMs: senderDurationMs,
                    recipientDurationMs: nil,
                    strongSourceIdentity: strongSourceIdentity,
                    exactDigestContradiction: senderExactEditionSHA256 != nil
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
            session = SHSession(catalog: try await chunkedReferenceCatalog(
                recipientAudioURL: recipientAudioURL,
                durationMs: recipientDurationMs
            ))
        }

        var resolutions: [String: ImportedAnchorResolution] = [:]
        var flankAnswers: [EditionFlankAnswer] = []
        var repeatProbe: RepeatedAudioProbe?
        var repeatProbeTried = false
        for query in queries {
            var candidates: [(timeMs: Int, confidence: Double)] = []
            var matchedAnchorOffsets: [Int] = []
            var matchedRepeatedAudio = false
            for evidence in query.evidence {
                let signature: SHSignature
                do {
                    signature = try SHSignature(dataRepresentation: evidence.signatureData)
                } catch {
                    continue // One unreadable variant must not discard the other flanks.
                }
                guard let session else { continue }
                switch await session.result(from: signature) {
                case .match(let match):
                    guard let item = match.mediaItems.first else { continue }
                    flankAnswers.append(EditionFlankAnswer(
                        marginId: query.packageScopedId, anchorOffsetMs: evidence.anchorOffsetMs, matched: true
                    ))
                    let matchedStartMs = absoluteStartMs(of: item)
                    let confidence = matchConfidence(of: item)
                    // A flank whose audio also plays elsewhere in this edition (a theme, sting or bumper) can match
                    // the wrong copy, and two flanks can agree on it (#331). Look for another copy before trusting it.
                    if !matchedRepeatedAudio {
                        if !repeatProbeTried {
                            repeatProbeTried = true
                            repeatProbe = await RepeatedAudioProbe(
                                recipientAudioURL: recipientAudioURL,
                                durationMs: recipientDurationMs
                            )
                        }
                        let probed = await repeatProbe?.otherMatches(of: signature, matchedStartMs: matchedStartMs) ?? []
                        matchedRepeatedAudio = (Array(match.mediaItems.dropFirst()) + probed).contains {
                            isAnotherCopy($0, matchedStartMs: matchedStartMs, matchedConfidence: confidence)
                        }
                    }
                    candidates.append((matchedStartMs + evidence.anchorOffsetMs, confidence))
                    matchedAnchorOffsets.append(evidence.anchorOffsetMs)
                case .noMatch:
                    flankAnswers.append(EditionFlankAnswer(
                        marginId: query.packageScopedId, anchorOffsetMs: evidence.anchorOffsetMs, matched: false
                    ))
                case .error:
                    continue // Not an answer about this edition: pre-Build 29 evidence (12 s) always errors.
                }
            }
            resolutions[query.packageScopedId] = resolveCandidates(
                candidates,
                query: query,
                senderDurationMs: senderDurationMs,
                recipientDurationMs: recipientDurationMs,
                strongSourceIdentity: strongSourceIdentity,
                exactDigestContradiction: senderExactEditionSHA256 != nil,
                matchedAnchorOffsets: matchedAnchorOffsets,
                matchedRepeatedAudio: matchedRepeatedAudio
            )
        }
        let flanks = editionFlankCounts(flankAnswers)
        return requiringEditionConfirmation(
            corroboratePartialFlanks(queries: queries, resolutions: resolutions),
            matchedFlanks: flanks.matched,
            answeredFlanks: flanks.answered
        )
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

    #if canImport(AVFoundation) && canImport(ShazamKit)
    /// One reference signature for a whole episode stops matching partway in: on a 63-minute episode, queries at
    /// 5:00 and 18:30 matched but 36:44 and 55:00 never did, although the reference covered the full file. The
    /// recipient edition is signed in overlapping chunks instead; each match adds its chunk's start time.
    static let referenceChunkMs = 900_000
    static let referenceChunkOverlapMs = 60_000
    static let referenceChunkStartKey = SHMediaItemProperty("spokenMarginsReferenceChunkStartMs")

    static func chunkedReferenceCatalog(recipientAudioURL: URL, durationMs: Int?) async throws -> SHCustomCatalog {
        let asset = AVURLAsset(url: recipientAudioURL)
        let catalog = SHCustomCatalog()
        guard let durationMs, durationMs > 0,
              let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            // Unknown length: fall back to a single reference for the whole file.
            do {
                let reference = try await PodcastAssetSignatureGenerator.signature(from: asset)
                try catalog.addReferenceSignature(reference, representing: [SHMediaItem(properties: [
                    .title: "Spoken Margins recipient edition", referenceChunkStartKey: NSNumber(value: 0)
                ])])
                return catalog
            } catch {
                throw PodcastAnchorEvidenceError.referenceGenerationFailed
            }
        }
        for chunk in try await signedChunks(
            of: sourceTrack,
            durationMs: durationMs,
            chunkMs: referenceChunkMs,
            overlapMs: referenceChunkOverlapMs
        ) {
            do {
                try catalog.addReferenceSignature(chunk.signature, representing: [SHMediaItem(properties: [
                    .title: "Spoken Margins recipient edition", referenceChunkStartKey: NSNumber(value: chunk.startMs)
                ])])
            } catch {
                throw PodcastAnchorEvidenceError.referenceGenerationFailed
            }
        }
        return catalog
    }

    /// Signs the edition in overlapping chunks, so that any span no longer than `overlapMs` lies wholly inside one.
    static func signedChunks(
        of sourceTrack: AVAssetTrack,
        durationMs: Int,
        chunkMs: Int,
        overlapMs: Int
    ) async throws -> [(startMs: Int, lengthMs: Int, signature: SHSignature)] {
        var chunks: [(startMs: Int, lengthMs: Int, signature: SHSignature)] = []
        var startMs = 0
        while startMs < durationMs {
            let lengthMs = min(chunkMs, durationMs - startMs)
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw PodcastAnchorEvidenceError.referenceGenerationFailed
            }
            do {
                try track.insertTimeRange(
                    CMTimeRange(
                        start: CMTime(value: CMTimeValue(startMs), timescale: 1_000),
                        duration: CMTime(value: CMTimeValue(lengthMs), timescale: 1_000)
                    ),
                    of: sourceTrack,
                    at: .zero
                )
                let signature = try await PodcastAssetSignatureGenerator.signature(from: composition)
                chunks.append((startMs, lengthMs, signature))
            } catch {
                throw PodcastAnchorEvidenceError.referenceGenerationFailed
            }
            if startMs + lengthMs >= durationMs { break }
            startMs += chunkMs - overlapMs
        }
        return chunks
    }

    static func absoluteStartMs(of item: SHMatchedMediaItem) -> Int {
        let chunkStartMs = (item[referenceChunkStartKey] as? NSNumber)?.intValue ?? 0
        return chunkStartMs + Int((item.matchOffset * 1_000).rounded())
    }

    static func matchConfidence(of item: SHMatchedMediaItem) -> Double {
        if #available(iOS 18.4, macOS 15.4, *) {
            return Double(item.confidence)
        }
        return 0.9
    }

    /// A match elsewhere counts as another copy only when it is at least half as strong as the matched one. A
    /// wrong copy can only win the first match when the real one is about as strong, so a much weaker match
    /// elsewhere is incidental likeness, not a repeat.
    static func isAnotherCopy(_ item: SHMatchedMediaItem, matchedStartMs: Int, matchedConfidence: Double) -> Bool {
        abs(absoluteStartMs(of: item) - matchedStartMs) > maximumFusionSpreadMs
            && matchConfidence(of: item) >= matchedConfidence * minimumRepeatConfidenceRatio
    }

    /// Finds whether a flank's audio plays a second time in the recipient edition (#331).
    ///
    /// ShazamKit reports one match per reference, so the main catalog can't show a second copy inside the same
    /// 15-minute chunk. The probe signs the edition again in short chunks, then asks the flank once more against
    /// only the chunks that don't touch the span it already matched. A strong enough match there is another
    /// copy (`isAnotherCopy`).
    ///
    /// Built once per resolve, and only when some flank matched. A copy within about one probe chunk of the
    /// matched span can be excluded with it and go unseen. When the probe can't be built, only the main
    /// catalog's extra matches are checked, as before.
    struct RepeatedAudioProbe {
        static let chunkMs = 40_000
        /// At least one flank (11 s) plus room for frame rounding, so every flank fits wholly inside one chunk.
        static let chunkOverlapMs = 13_000

        let chunks: [(startMs: Int, lengthMs: Int, signature: SHSignature)]

        /// Nil when the edition can't be signed in chunks; the resolver then keeps its single-match behaviour.
        init?(recipientAudioURL: URL, durationMs: Int?) async {
            // Hold the asset while its track is read: a track whose asset has been released fails to sign
            // (AVFoundation -11800 / -12780), and the probe would silently never run.
            let asset = AVURLAsset(url: recipientAudioURL)
            guard let durationMs, durationMs > 0,
                  let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let chunks = try? await PodcastAcousticAnchorResolver.signedChunks(
                      of: sourceTrack,
                      durationMs: durationMs,
                      chunkMs: Self.chunkMs,
                      overlapMs: Self.chunkOverlapMs
                  ) else { return nil }
            self.chunks = chunks
            withExtendedLifetime(asset) {}
        }

        /// The flank's matches outside the span it already matched (with a margin of the fusion spread).
        func otherMatches(of signature: SHSignature, matchedStartMs: Int) async -> [SHMatchedMediaItem] {
            let spread = PodcastAcousticAnchorResolver.maximumFusionSpreadMs
            let excludedStartMs = matchedStartMs - spread
            let excludedEndMs = matchedStartMs + Int((signature.duration * 1_000).rounded()) + spread
            let catalog = SHCustomCatalog()
            var added = 0
            for chunk in chunks where chunk.startMs >= excludedEndMs || chunk.startMs + chunk.lengthMs <= excludedStartMs {
                do {
                    try catalog.addReferenceSignature(chunk.signature, representing: [SHMediaItem(properties: [
                        .title: "Spoken Margins repeat probe",
                        PodcastAcousticAnchorResolver.referenceChunkStartKey: NSNumber(value: chunk.startMs)
                    ])])
                    added += 1
                } catch {
                    continue
                }
            }
            guard added > 0,
                  case .match(let match) = await SHSession(catalog: catalog).result(from: signature) else { return [] }
            return match.mediaItems
        }
    }
    #endif

    static func resolveCandidates(
        _ candidates: [(timeMs: Int, confidence: Double)],
        query: PodcastPortableAnchorQuery,
        senderDurationMs: Int?,
        recipientDurationMs: Int?,
        strongSourceIdentity: Bool,
        exactDigestContradiction: Bool,
        matchedAnchorOffsets: [Int] = [],
        matchedRepeatedAudio: Bool = false
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
                evidenceClass: .unresolved,
                algorithmVersion: "podcast-anchor.v1"
            )
        }
        // A flank that also matches another copy of its audio may have matched the wrong one, and the other
        // flank can't overrule it: both may sit in the repeat. Ask the listener to confirm instead (#331).
        guard !matchedRepeatedAudio else {
            return ImportedAnchorResolution(
                evidenceClass: .ambiguous,
                isAmbiguous: true,
                algorithmVersion: "podcast-anchor-repeated-audio.v1"
            )
        }
        // Redundant signature variants need not all match, but both temporal
        // flanks must agree. The spread check below still rejects conflicts.
        let matchedBothFlanks = matchedAnchorOffsets.contains { $0 > 0 }
            && matchedAnchorOffsets.contains { $0 < 0 }
            && candidates.allSatisfy { $0.confidence >= minimumPartialFlankConfidence }
        guard query.evidence.count <= 1 || candidates.count == query.evidence.count || matchedBothFlanks else {
            let strongest = candidates.max { lhs, rhs in lhs.confidence < rhs.confidence }
            if candidates.count == 1,
               query.evidence.count == 2,
               strongSourceIdentity,
               let strongest,
               strongest.confidence >= minimumPartialFlankConfidence {
                return ImportedAnchorResolution(
                    evidenceClass: .acousticVerified,
                    localMediaTimeMs: max(0, strongest.timeMs),
                    confidence: strongest.confidence * 0.9,
                    algorithmVersion: "podcast-anchor-partial-flank.v2"
                )
            }
            return ImportedAnchorResolution(
                evidenceClass: .ambiguous,
                localMediaTimeMs: strongest.map { max(0, $0.timeMs) },
                confidence: strongest?.confidence,
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

    /// A different episode of the same show can share the sender's intro or outro. A Margin there matches
    /// perfectly, on both flanks, although nothing else in the packet does (#456). So a placement counts only
    /// when more than half of the packet's evidence found this edition. Below that, the edition is unconfirmed
    /// and nothing is placed. Only flanks ShazamKit answered count (a match or no match): an unreadable
    /// signature or a query error says nothing about the edition. The rule needs at least one match, the
    /// shared audio it guards against; with none, other evidence (the transcript) decides as before. A packet
    /// with fewer answered flanks than `minimumFlanksForEditionCheck` (two Margins) is left as it is.
    static let minimumFlanksForEditionCheck = 4
    public static let editionUnconfirmedAlgorithmVersion = "podcast-anchor-edition-unconfirmed.v1"
    static let editionRejection = ImportedAnchorResolution(
        evidenceClass: .unresolved,
        algorithmVersion: editionUnconfirmedAlgorithmVersion
    )

    /// The packet-level verdict that the recipient has a different edition. Fusion and the app's
    /// re-resolution keep it (`PodcastAnchorFusionResolver.enforcingEditionRejection`).
    public static func isEditionRejection(_ resolution: ImportedAnchorResolution) -> Bool {
        resolution.evidenceClass == .unresolved && resolution.algorithmVersion == editionUnconfirmedAlgorithmVersion
    }

    /// ShazamKit's answer for one signature variant of one Margin's flank.
    struct EditionFlankAnswer: Equatable, Sendable {
        let marginId: String
        let anchorOffsetMs: Int
        let matched: Bool
    }

    /// Counts the packet's answered and matched flanks for the edition check. A Margin has a flank before its
    /// anchor (positive offset) and one after (negative), and each flank can carry more than one signature
    /// variant: one captured during playback and one cut from the source window. The variants are one piece of
    /// evidence, so a flank counts once: answered when any variant was answered, matched when any variant
    /// matched. Counting variants separately let one Margin whose playback pair matched and whose source pair
    /// didn't withdraw its own placement (Codex audit on d00dd82).
    static func editionFlankCounts(_ answers: [EditionFlankAnswer]) -> (answered: Int, matched: Int) {
        struct Flank: Hashable {
            let marginId: String
            let side: Int
        }
        var answered = Set<Flank>()
        var matched = Set<Flank>()
        for answer in answers {
            let flank = Flank(marginId: answer.marginId, side: answer.anchorOffsetMs.signum())
            answered.insert(flank)
            if answer.matched { matched.insert(flank) }
        }
        return (answered.count, matched.count)
    }

    static func requiringEditionConfirmation(
        _ resolutions: [String: ImportedAnchorResolution],
        matchedFlanks: Int,
        answeredFlanks: Int
    ) -> [String: ImportedAnchorResolution] {
        guard answeredFlanks >= minimumFlanksForEditionCheck, matchedFlanks >= 1,
              matchedFlanks * 2 <= answeredFlanks else {
            return resolutions
        }
        // Every Margin carries the verdict, placed, ambiguous or not, so neither other evidence (a transcript of
        // the shared intro) nor an earlier placement on this edition puts one back.
        return resolutions.mapValues { _ in editionRejection }
    }

    /// A high-confidence single flank remains useful direct evidence, but it
    /// is not independently verified until neighboring direct landmarks show
    /// the same local edition offset. This preserves partial-flank recovery
    /// without confidently placing a Margin inside a deleted passage.
    static func corroboratePartialFlanks(
        queries: [PodcastPortableAnchorQuery],
        resolutions: [String: ImportedAnchorResolution]
    ) -> [String: ImportedAnchorResolution] {
        let ordered = queries.compactMap { query -> (id: String, sender: Int)? in
            guard let sender = query.senderMediaTimeMs else { return nil }
            return (query.packageScopedId, sender)
        }.sorted { lhs, rhs in
            lhs.sender == rhs.sender ? lhs.id < rhs.id : lhs.sender < rhs.sender
        }
        var result = resolutions
        for (index, query) in ordered.enumerated() {
            guard let partial = result[query.id],
                  partial.algorithmVersion == "podcast-anchor-partial-flank.v2",
                  let partialTime = partial.localMediaTimeMs else { continue }
            let lower = ordered[..<index].reversed().first { candidate in
                guard let resolution = resolutions[candidate.id] else { return false }
                return resolution.algorithmVersion != "podcast-anchor-partial-flank.v2"
                    && resolution.localMediaTimeMs != nil
                    && !resolution.isAmbiguous
            }
            let upper = ordered[ordered.index(after: index)...].first { candidate in
                guard let resolution = resolutions[candidate.id] else { return false }
                return resolution.algorithmVersion != "podcast-anchor-partial-flank.v2"
                    && resolution.localMediaTimeMs != nil
                    && !resolution.isAmbiguous
            }
            guard let lower, let upper,
                  let lowerTime = resolutions[lower.id]?.localMediaTimeMs,
                  let upperTime = resolutions[upper.id]?.localMediaTimeMs,
                  lowerTime < partialTime, partialTime < upperTime else {
                result[query.id] = ImportedAnchorResolution(
                    evidenceClass: .unresolved,
                    algorithmVersion: "podcast-anchor-partial-flank-unconfirmed.v3"
                )
                continue
            }
            let lowerOffset = lowerTime - lower.sender
            let upperOffset = upperTime - upper.sender
            let partialOffset = partialTime - query.sender
            let offsetTolerance = maximumFusionSpreadMs
            guard abs(lowerOffset - upperOffset) <= offsetTolerance,
                  abs(partialOffset - lowerOffset) <= offsetTolerance,
                  abs(partialOffset - upperOffset) <= offsetTolerance else {
                result[query.id] = ImportedAnchorResolution(
                    evidenceClass: .unresolved,
                    algorithmVersion: "podcast-anchor-partial-flank-unconfirmed.v3"
                )
                continue
            }
            result[query.id] = ImportedAnchorResolution(
                evidenceClass: .acousticVerified,
                localMediaTimeMs: partialTime,
                confidence: partial.confidence,
                algorithmVersion: "podcast-anchor-partial-flank-neighbor-corroborated.v3"
            )
        }
        return result
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
    public static let minimumTokenSimilarity = 0.72
    public static let minimumUniquenessGap = 0.08

    private struct TimedToken {
        let value: String
        let startMs: Int
        let endMs: Int
    }

    private struct FuzzyMatch {
        let range: Range<Int>
        let similarity: Double
    }

    private enum MatchSelection {
        case none
        case unique(FuzzyMatch)
        case ambiguous
    }

    public static func hasUsableContext(_ anchor: PortableAnchorEvidence) -> Bool {
        normalizedTokens(anchor.prefix ?? "").count >= minimumContextTokenCount
            || normalizedTokens(anchor.suffix ?? "").count >= minimumContextTokenCount
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

        let prefixMatches = hasPrefix ? fuzzyMatches(prefix, in: recipientTokens) : []
        let suffixMatches = hasSuffix ? fuzzyMatches(suffix, in: recipientTokens) : []
        if hasPrefix, hasSuffix {
            let pairs = prefixMatches.flatMap { prefixMatch in
                suffixMatches.compactMap { suffixMatch -> (prefix: FuzzyMatch, suffix: FuzzyMatch, score: Double, timeMs: Int)? in
                    let prefixEnd = recipientTokens[prefixMatch.range.upperBound - 1].endMs
                    let suffixStart = recipientTokens[suffixMatch.range.lowerBound].startMs
                    guard suffixStart >= prefixEnd,
                          suffixStart - prefixEnd <= maximumBoundarySpreadMs else { return nil }
                    return (
                        prefixMatch,
                        suffixMatch,
                        (prefixMatch.similarity + suffixMatch.similarity) / 2,
                        (prefixEnd + suffixStart) / 2
                    )
                }
            }.sorted { lhs, rhs in lhs.score > rhs.score }
            if let best = pairs.first {
                if let runnerUp = pairs.dropFirst().first,
                   runnerUp.score >= best.score - minimumUniquenessGap,
                   abs(runnerUp.timeMs - best.timeMs) > maximumBoundarySpreadMs {
                    return ambiguousTranscriptResolution()
                }
                return ImportedAnchorResolution(
                    evidenceClass: .transcriptVerified,
                    localMediaTimeMs: best.timeMs,
                    confidence: transcriptConfidence(similarity: best.score, usesBothSides: true),
                    algorithmVersion: "podcast-transcript-anchor.v2"
                )
            }
            if !prefixMatches.isEmpty || !suffixMatches.isEmpty {
                return ambiguousTranscriptResolution()
            }
            return ImportedAnchorResolution(
                evidenceClass: .unresolved,
                algorithmVersion: "podcast-transcript-anchor.v2"
            )
        }

        let matches = hasPrefix ? prefixMatches : suffixMatches
        switch selectUniqueMatch(matches, tokenCount: hasPrefix ? prefix.count : suffix.count) {
        case .none:
            return ImportedAnchorResolution(
                evidenceClass: .unresolved,
                algorithmVersion: "podcast-transcript-anchor.v2"
            )
        case .ambiguous:
            return ambiguousTranscriptResolution()
        case .unique(let match):
            let timeMs = hasPrefix
                ? recipientTokens[match.range.upperBound - 1].endMs
                : recipientTokens[match.range.lowerBound].startMs
            return ImportedAnchorResolution(
                evidenceClass: .transcriptVerified,
                localMediaTimeMs: timeMs,
                confidence: transcriptConfidence(similarity: match.similarity, usesBothSides: false),
                algorithmVersion: "podcast-transcript-anchor.v2"
            )
        }
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

    private static func fuzzyMatches(
        _ needle: [String],
        in haystack: [TimedToken]
    ) -> [FuzzyMatch] {
        guard !needle.isEmpty else { return [] }
        let minimumLength = max(minimumContextTokenCount, needle.count - 2)
        let maximumLength = needle.count + 2
        var candidates: [FuzzyMatch] = []
        for start in haystack.indices {
            for length in minimumLength...maximumLength where start + length <= haystack.count {
                let values = haystack[start..<(start + length)].map(\.value)
                let similarity = tokenSimilarity(needle, values)
                if similarity >= minimumTokenSimilarity {
                    candidates.append(FuzzyMatch(range: start..<(start + length), similarity: similarity))
                }
            }
        }
        var clustered: [FuzzyMatch] = []
        for candidate in candidates.sorted(by: { $0.similarity > $1.similarity }) {
            let midpoint = (candidate.range.lowerBound + candidate.range.upperBound) / 2
            let overlapsExisting = clustered.contains { existing in
                let existingMidpoint = (existing.range.lowerBound + existing.range.upperBound) / 2
                return candidate.range.overlaps(existing.range)
                    || abs(midpoint - existingMidpoint) <= max(2, needle.count / 2)
            }
            if !overlapsExisting { clustered.append(candidate) }
        }
        return clustered.sorted { lhs, rhs in
            lhs.similarity == rhs.similarity
                ? lhs.range.lowerBound < rhs.range.lowerBound
                : lhs.similarity > rhs.similarity
        }
    }

    private static func selectUniqueMatch(
        _ matches: [FuzzyMatch],
        tokenCount: Int
    ) -> MatchSelection {
        guard let best = matches.first else { return .none }
        if let runnerUp = matches.dropFirst().first,
           runnerUp.similarity >= best.similarity - minimumUniquenessGap,
           abs(runnerUp.range.lowerBound - best.range.lowerBound) > tokenCount {
            return .ambiguous
        }
        return .unique(best)
    }

    private static func tokenSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsToken) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = lhsIndex + 1
            for (rhsIndex, rhsToken) in rhs.enumerated() {
                current[rhsIndex + 1] = min(
                    current[rhsIndex] + 1,
                    previous[rhsIndex + 1] + 1,
                    previous[rhsIndex] + (lhsToken == rhsToken ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
    }

    private static func transcriptConfidence(similarity: Double, usesBothSides: Bool) -> Double {
        min(0.98, max(0.7, similarity * (usesBothSides ? 0.96 : 0.86)))
    }

    private static func ambiguousTranscriptResolution() -> ImportedAnchorResolution {
        ImportedAnchorResolution(
            evidenceClass: .ambiguous,
            isAmbiguous: true,
            algorithmVersion: "podcast-transcript-anchor.v2"
        )
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
    public static let maximumInterpolationSpanMs = 600_000
    public static let permittedInterpolationRate = 0.5...1.5

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
            guard acoustic.evidenceClass != .ambiguous else { return ambiguous() }
            return ImportedAnchorResolution(
                evidenceClass: .transcriptVerified,
                localMediaTimeMs: transcriptTime,
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

    /// When the acoustic pass found the packet on a different edition (#456), nothing places a Margin on it:
    /// not a transcript match of the shared intro, and not interpolation. Apply to the final resolutions.
    public static func enforcingEditionRejection(
        acoustic: [String: ImportedAnchorResolution],
        resolutions: [String: ImportedAnchorResolution]
    ) -> [String: ImportedAnchorResolution] {
        guard acoustic.values.contains(where: PodcastAcousticAnchorResolver.isEditionRejection) else {
            return resolutions
        }
        return resolutions.mapValues { _ in PodcastAcousticAnchorResolver.editionRejection }
    }

    /// The resolution a re-resolution stores: a verified placement on the same recipient edition survives a
    /// weaker result, so a pass without a transcript doesn't undo one with it. An edition rejection (#456)
    /// isn't weaker: it withdraws the machine placements it finds. A listener's own confirmation stays.
    /// A stored rejection survives a later pass on the same edition too, unless that pass confirms the edition
    /// itself (`confirmsEdition`). The packet and the file are the same, so a pass that disagrees has lost
    /// evidence: its acoustic step failed, leaving the shared intro's transcript (Codex audit on 75b32ad), or
    /// only the intro's flanks were answered, too few for the edition check (Codex audit on 2e6228e).
    public static func preservingVerifiedPlacement(
        previous: ImportedAnchorResolution, proposed: ImportedAnchorResolution,
        previousEdition: String?, currentEdition: String?, hasTranscript: Bool
    ) -> ImportedAnchorResolution {
        let sameEdition = currentEdition != nil && currentEdition == previousEdition
        if PodcastAcousticAnchorResolver.isEditionRejection(proposed) {
            return sameEdition && previous.evidenceClass == .recipientConfirmed ? previous : proposed
        }
        if sameEdition, PodcastAcousticAnchorResolver.isEditionRejection(previous), !confirmsEdition(proposed) {
            return previous
        }
        let verified = isInlinePlacement(previous)
            && previous.evidenceClass != .timestampFallback && previous.evidenceClass != .mapInterpolated
        let weaker = proposed.evidenceClass == .unresolved || proposed.evidenceClass == .absentFromRecipientEdition
            || (!hasTranscript && proposed.evidenceClass == .ambiguous
                && (previous.evidenceClass == .transcriptVerified || previous.evidenceClass == .fused))
        return sameEdition && verified && weaker ? previous : proposed
    }

    /// Whether a resolution is evidence about the edition itself, enough to lift an edition rejection: the
    /// sender's exact file or the listener's own confirmation. A single Margin's transcript or acoustic match
    /// isn't: the shared intro matches on either episode, in words and in audio.
    static func confirmsEdition(_ resolution: ImportedAnchorResolution) -> Bool {
        switch resolution.evidenceClass {
        case .exactEdition, .recipientConfirmed:
            return resolution.localMediaTimeMs != nil
        case .transcriptVerified, .acousticVerified, .fused, .articleTextVerified, .mapInterpolated,
             .timestampFallback, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return false
        }
    }

    /// Whether a podcast Margin plays inline at a recipient position.
    public static func isInlinePlacement(_ resolution: ImportedAnchorResolution) -> Bool {
        guard resolution.localMediaTimeMs != nil else { return false }
        switch resolution.evidenceClass {
        case .exactEdition, .transcriptVerified, .acousticVerified, .fused,
             .mapInterpolated, .timestampFallback, .recipientConfirmed:
            return true
        case .articleTextVerified, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return false
        }
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

    /// Projects an unresolved or acoustically absent margin only when direct
    /// anchors bracket it in both sender and recipient time. Dynamic podcast
    /// editions behave like piecewise timing offsets around inserted/replaced
    /// segments, so the nearest direct anchor supplies the offset. The result
    /// remains bounded by the direct anchors and never extrapolates.
    public static func interpolatingBetweenVerifiedAnchors(
        queries: [PodcastPortableAnchorQuery],
        resolutions: [String: ImportedAnchorResolution]
    ) -> [String: ImportedAnchorResolution] {
        let ordered = queries.compactMap { query -> (id: String, sender: Int)? in
            guard let sender = query.senderMediaTimeMs else { return nil }
            return (query.packageScopedId, sender)
        }.sorted { lhs, rhs in
            lhs.sender == rhs.sender ? lhs.id < rhs.id : lhs.sender < rhs.sender
        }
        let verified = ordered.compactMap { query -> (id: String, sender: Int, recipient: Int, confidence: Double)? in
            guard let resolution = resolutions[query.id],
                  isDirectlyVerified(resolution),
                  let recipient = resolution.localMediaTimeMs else { return nil }
            return (query.id, query.sender, recipient, resolution.confidence ?? 0.9)
        }
        guard verified.count >= 2 else { return resolutions }

        var result = resolutions
        for query in ordered {
            guard let currentEvidenceClass = result[query.id]?.evidenceClass,
                  currentEvidenceClass == .unresolved || currentEvidenceClass == .absentFromRecipientEdition,
                  let lower = verified.last(where: { $0.sender < query.sender }),
                  let upper = verified.first(where: { $0.sender > query.sender }) else { continue }
            let senderSpan = upper.sender - lower.sender
            let recipientSpan = upper.recipient - lower.recipient
            guard senderSpan > 0,
                  senderSpan <= maximumInterpolationSpanMs,
                  recipientSpan > 0 else { continue }
            let rate = Double(recipientSpan) / Double(senderSpan)
            guard permittedInterpolationRate.contains(rate) else { continue }
            let lowerDistance = query.sender - lower.sender
            let upperDistance = upper.sender - query.sender
            let nearest = lowerDistance <= upperDistance ? lower : upper
            let recipient = query.sender + (nearest.recipient - nearest.sender)
            guard recipient > lower.recipient, recipient < upper.recipient else { continue }
            result[query.id] = ImportedAnchorResolution(
                evidenceClass: .mapInterpolated,
                localMediaTimeMs: recipient,
                confidence: min(lower.confidence, upper.confidence) * 0.7,
                algorithmVersion: "podcast-anchor-piecewise-offset.v2"
            )
        }
        return result
    }

    private static func isDirectlyVerified(_ resolution: ImportedAnchorResolution) -> Bool {
        guard !resolution.isAmbiguous else { return false }
        switch resolution.evidenceClass {
        case .exactEdition, .transcriptVerified, .acousticVerified, .fused, .recipientConfirmed:
            return true
        case .articleTextVerified, .mapInterpolated, .timestampFallback, .ambiguous,
             .absentFromRecipientEdition, .unresolved:
            return false
        }
    }

    private static func ambiguous() -> ImportedAnchorResolution {
        ImportedAnchorResolution(
            evidenceClass: .ambiguous,
            isAmbiguous: true,
            algorithmVersion: "podcast-anchor-fusion.v1"
        )
    }
}
