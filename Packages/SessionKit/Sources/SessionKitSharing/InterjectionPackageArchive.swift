import CryptoKit
import Foundation
import SessionKit
import ZIPFoundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(ShazamKit)
import ShazamKit
#endif

public enum SpokenMarginsPackageArchiveError: Error, Equatable, LocalizedError {
    case malformedArchive
    case packageTooLarge
    case invalidEntry(String)
    case duplicateEntry(String)
    case manifestMissing
    case manifestTooLarge
    case unsupportedSchema(String)
    case unsupportedRequiredCapability(String)
    case invalidManifest(String)
    case invalidDigest
    case invalidAsset(String)
    case audioTooLarge(String)
    case audioTooLong(String)
    case excessiveCompression(String)

    public var errorDescription: String? {
        switch self {
        case .malformedArchive: return "This is not a readable Spoken Margins package."
        case .packageTooLarge: return "This Spoken Margins file is larger than 100 MB."
        case .invalidEntry(let path): return "The package contains an unsafe entry: \(path)."
        case .duplicateEntry(let path): return "The package contains a duplicate entry: \(path)."
        case .manifestMissing: return "The package has no manifest."
        case .manifestTooLarge: return "The package manifest is too large."
        case .unsupportedSchema(let schema): return "This package version is not supported: \(schema)."
        case .unsupportedRequiredCapability(let capability): return "This package requires an unsupported capability: \(capability)."
        case .invalidManifest(let reason): return "The package manifest is invalid: \(reason)."
        case .invalidDigest: return "The package changed after it was exported."
        case .invalidAsset(let path): return "A package asset is unreadable: \(path)."
        case .audioTooLarge(let path): return "A voice asset is too large: \(path)."
        case .audioTooLong(let path): return "A voice asset is longer than 10 minutes: \(path)."
        case .excessiveCompression(let path): return "The package has an unsafe compression ratio: \(path)."
        }
    }
}

/// A package value that can only be created by a successful archive read.
public struct VerifiedSpokenMarginsPackage: Sendable {
    public let manifest: SpokenMarginsPackageManifest
    public let commentaryLayers: [SharedCommentaryLayerArtifact]
    public let listeningMapProposals: [PortableListeningMapProposalArtifact]
    public let extractedAssetURLs: [String: URL]

    init(
        manifest: SpokenMarginsPackageManifest,
        commentaryLayers: [SharedCommentaryLayerArtifact],
        listeningMapProposals: [PortableListeningMapProposalArtifact],
        extractedAssetURLs: [String: URL]
    ) {
        self.manifest = manifest
        self.commentaryLayers = commentaryLayers
        self.listeningMapProposals = listeningMapProposals
        self.extractedAssetURLs = extractedAssetURLs
    }
}

public enum SpokenMarginsPackageArchive {
    public static let fileExtension = "spokenmargins"
    public static let uniformTypeIdentifier = "com.spokenmargins.package"
    public static let mimeType = "application/vnd.spokenmargins.package+zip"
    public static let schemaVersion = "spoken-margins.package.v1"

    private static let maximumPackageBytes: UInt64 = 100 * 1_024 * 1_024
    private static let maximumManifestBytes: UInt64 = 1 * 1_024 * 1_024
    private static let maximumArtifactBytes: UInt64 = 5 * 1_024 * 1_024
    private static let maximumAudioBytes: UInt64 = 20 * 1_024 * 1_024
    private static let maximumEvidenceBytes: UInt64 = 1 * 1_024 * 1_024
    private static let maximumInterjections = 50
    private static let maximumCompressionRatio: UInt64 = 100
    private static let fixedArchiveDate = Date(timeIntervalSince1970: 315_532_800)
    private static let supportedRequiredCapabilities: Set<String> = [SharedCommentaryLayerArtifact.schemaVersion]

    public static func write(
        _ prepared: PreparedSpokenMarginsPackage,
        to destinationURL: URL
    ) throws -> SpokenMarginsPackageManifest {
        var manifest = prepared.manifest
        manifest.contentDigest = nil
        try validateDescriptorInputs(
            manifest: manifest,
            artifactData: prepared.artifactData,
            assetPaths: Set(prepared.assetFiles.keys)
        )
        let assetData = try loadExportAssets(manifest: manifest, assetFiles: prepared.assetFiles)
        for index in manifest.artifacts.indices {
            let path = manifest.artifacts[index].path
            guard let data = prepared.artifactData[path] else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("artifact data is absent: \(path)")
            }
            manifest.artifacts[index].byteCount = data.count
            manifest.artifacts[index].sha256 = sha256(data)
        }
        for index in manifest.assets.indices {
            let path = manifest.assets[index].path
            guard let data = assetData[path] else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("asset data is absent: \(path)")
            }
            manifest.assets[index].byteCount = data.count
            manifest.assets[index].sha256 = sha256(data)
        }
        let decoded = try decodeKnownArtifacts(manifest: manifest, artifactData: prepared.artifactData)
        try validateManifestBoundary(
            manifest,
            commentaryLayers: decoded.commentary,
            proposals: decoded.proposals,
            requireDigest: false
        )
        let previewData = Data(previewMarkdown(
            manifest,
            commentaryLayers: decoded.commentary,
            listeningMapProposals: decoded.proposals
        ).utf8)
        manifest.contentDigest = try digest(
            manifest: manifest,
            previewData: previewData,
            artifactData: prepared.artifactData,
            assetData: assetData
        )
        let manifestData = try encodeManifest(manifest)
        guard manifestData.count <= maximumManifestBytes else {
            throw SpokenMarginsPackageArchiveError.manifestTooLarge
        }

        let parentDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let stagedURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).export-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let archive = try Archive(url: stagedURL, accessMode: .create)
        try add(manifestData, path: "manifest.json", to: archive, compression: .deflate)
        try add(previewData, path: "preview.md", to: archive, compression: .deflate)
        for path in prepared.artifactData.keys.sorted() {
            try add(prepared.artifactData[path]!, path: path, to: archive, compression: .deflate)
        }
        for path in assetData.keys.sorted() {
            try add(assetData[path]!, path: path, to: archive, compression: .none)
        }
        let fileSize = try stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard UInt64(max(0, fileSize)) <= maximumPackageBytes else {
            throw SpokenMarginsPackageArchiveError.packageTooLarge
        }
        try commitStagedItem(stagedURL, to: destinationURL)
        return manifest
    }

    public static func read(
        from packageURL: URL,
        extractingAssetsTo destinationDirectory: URL
    ) throws -> VerifiedSpokenMarginsPackage {
        let fileSize = try packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard UInt64(max(0, fileSize)) <= maximumPackageBytes else {
            throw SpokenMarginsPackageArchiveError.packageTooLarge
        }
        let archive: Archive
        do {
            archive = try Archive(url: packageURL, accessMode: .read)
        } catch {
            throw SpokenMarginsPackageArchiveError.malformedArchive
        }

        var seen: Set<String> = []
        var entryData: [String: Data] = [:]
        var totalUncompressed: UInt64 = 0
        for entry in archive {
            guard seen.insert(entry.path).inserted else {
                throw SpokenMarginsPackageArchiveError.duplicateEntry(entry.path)
            }
            guard entry.type == .file, isAllowedPackagePath(entry.path) else {
                throw SpokenMarginsPackageArchiveError.invalidEntry(entry.path)
            }
            let (nextTotal, overflowed) = totalUncompressed.addingReportingOverflow(entry.uncompressedSize)
            guard !overflowed, nextTotal <= maximumPackageBytes else {
                throw SpokenMarginsPackageArchiveError.packageTooLarge
            }
            totalUncompressed = nextTotal
            if entry.path == "manifest.json", entry.uncompressedSize > maximumManifestBytes {
                throw SpokenMarginsPackageArchiveError.manifestTooLarge
            }
            if entry.path.hasPrefix("artifacts/"), entry.uncompressedSize > maximumArtifactBytes {
                throw SpokenMarginsPackageArchiveError.invalidAsset(entry.path)
            }
            if entry.path.hasPrefix("assets/audio/"), entry.uncompressedSize > maximumAudioBytes {
                throw SpokenMarginsPackageArchiveError.audioTooLarge(entry.path)
            }
            if entry.path.hasPrefix("assets/evidence/"), entry.uncompressedSize > maximumEvidenceBytes {
                throw SpokenMarginsPackageArchiveError.invalidAsset(entry.path)
            }
            if entry.compressedSize > 0,
               entry.uncompressedSize / max(1, entry.compressedSize) > maximumCompressionRatio {
                throw SpokenMarginsPackageArchiveError.excessiveCompression(entry.path)
            }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                throw SpokenMarginsPackageArchiveError.malformedArchive
            }
            entryData[entry.path] = data
        }

        guard let manifestData = entryData["manifest.json"] else {
            throw SpokenMarginsPackageArchiveError.manifestMissing
        }
        let manifest: SpokenMarginsPackageManifest
        do {
            try validateManifestJSONShape(manifestData)
            manifest = try decodeManifest(manifestData)
        } catch let error as SpokenMarginsPackageArchiveError {
            throw error
        } catch {
            throw SpokenMarginsPackageArchiveError.invalidManifest(String(describing: error))
        }
        let expectedPaths = Set(["manifest.json", "preview.md"] + manifest.artifacts.map(\.path) + manifest.assets.map(\.path))
        guard expectedPaths == Set(entryData.keys) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("declared entries do not match archive")
        }
        let artifactData = Dictionary(uniqueKeysWithValues: manifest.artifacts.compactMap { descriptor in
            entryData[descriptor.path].map { (descriptor.path, $0) }
        })
        let assetData = Dictionary(uniqueKeysWithValues: manifest.assets.compactMap { descriptor in
            entryData[descriptor.path].map { (descriptor.path, $0) }
        })
        try verifyDescriptors(manifest: manifest, artifactData: artifactData, assetData: assetData)
        let decoded = try decodeKnownArtifacts(manifest: manifest, artifactData: artifactData)
        try validateManifestBoundary(
            manifest,
            commentaryLayers: decoded.commentary,
            proposals: decoded.proposals,
            requireDigest: true
        )
        guard let previewData = entryData["preview.md"] else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("preview is absent")
        }
        guard manifest.contentDigest == (try digest(
            manifest: manifest,
            previewData: previewData,
            artifactData: artifactData,
            assetData: assetData
        )) else {
            throw SpokenMarginsPackageArchiveError.invalidDigest
        }
        let expectedPreview = Data(previewMarkdown(
            manifest,
            commentaryLayers: decoded.commentary,
            listeningMapProposals: decoded.proposals
        ).utf8)
        guard previewData == expectedPreview else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("preview does not match package")
        }

        let parentDirectory = destinationDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let stagedDirectory = parentDirectory.appendingPathComponent(
            ".\(destinationDirectory.lastPathComponent).import-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: stagedDirectory) }
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        var stagedURLs: [String: URL] = [:]
        for descriptor in manifest.assets {
            guard let data = assetData[descriptor.path] else { continue }
            let extensionName = URL(fileURLWithPath: descriptor.path).pathExtension
            let stagedURL = stagedDirectory.appendingPathComponent(
                safeComponent(descriptor.id) + (extensionName.isEmpty ? "" : ".\(extensionName)")
            )
            try data.write(to: stagedURL, options: Data.WritingOptions.atomic)
            try validateExtractedAsset(descriptor, at: stagedURL)
            stagedURLs[descriptor.id] = stagedURL
        }
        try commitStagedItem(stagedDirectory, to: destinationDirectory)
        let extractedURLs = Dictionary(uniqueKeysWithValues: stagedURLs.map { id, url in
            (id, destinationDirectory.appendingPathComponent(url.lastPathComponent))
        })
        return VerifiedSpokenMarginsPackage(
            manifest: manifest,
            commentaryLayers: decoded.commentary,
            listeningMapProposals: decoded.proposals,
            extractedAssetURLs: extractedURLs
        )
    }

    public static func encodeManifest(_ manifest: SpokenMarginsPackageManifest) throws -> Data {
        try encoder().encode(manifest)
    }

    public static func decodeManifest(_ data: Data) throws -> SpokenMarginsPackageManifest {
        try decoder().decode(SpokenMarginsPackageManifest.self, from: data)
    }

    public static func encodeArtifact<T: Encodable>(_ value: T) throws -> Data {
        try encoder(usesFractionalDates: false).encode(value)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = iso8601WithFractionalSeconds.date(from: value) ?? iso8601.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
            }
            return date
        }
        return decoder
    }

    private static func encoder(usesFractionalDates: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if usesFractionalDates {
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(iso8601WithFractionalSeconds.string(from: date))
            }
        } else {
            encoder.dateEncodingStrategy = .iso8601
        }
        return encoder
    }

    private static var iso8601WithFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func validateDescriptorInputs(
        manifest: SpokenMarginsPackageManifest,
        artifactData: [String: Data],
        assetPaths: Set<String>
    ) throws {
        let artifactPaths = manifest.artifacts.map(\.path)
        let declaredAssetPaths = manifest.assets.map(\.path)
        guard Set(artifactPaths) == Set(artifactData.keys),
              Set(declaredAssetPaths) == assetPaths,
              Set(artifactPaths).count == artifactPaths.count,
              Set(declaredAssetPaths).count == declaredAssetPaths.count else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("descriptor paths do not match inputs")
        }
    }

    private static func loadExportAssets(
        manifest: SpokenMarginsPackageManifest,
        assetFiles: [String: URL]
    ) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for descriptor in manifest.assets {
            guard let url = assetFiles[descriptor.path], isAllowedPackagePath(descriptor.path) else {
                throw SpokenMarginsPackageArchiveError.invalidEntry(descriptor.path)
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw SpokenMarginsPackageArchiveError.invalidEntry(descriptor.path)
            }
            let maximum = descriptor.path.hasPrefix("assets/audio/") ? maximumAudioBytes : maximumEvidenceBytes
            guard UInt64(max(0, values.fileSize ?? 0)) <= maximum else {
                throw descriptor.path.hasPrefix("assets/audio/")
                    ? SpokenMarginsPackageArchiveError.audioTooLarge(descriptor.path)
                    : SpokenMarginsPackageArchiveError.invalidAsset(descriptor.path)
            }
            try validateExtractedAsset(descriptor, at: url)
            result[descriptor.path] = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        return result
    }

    private static func verifyDescriptors(
        manifest: SpokenMarginsPackageManifest,
        artifactData: [String: Data],
        assetData: [String: Data]
    ) throws {
        for descriptor in manifest.artifacts {
            guard let data = artifactData[descriptor.path], descriptor.byteCount == data.count, descriptor.sha256 == sha256(data) else {
                throw SpokenMarginsPackageArchiveError.invalidDigest
            }
        }
        for descriptor in manifest.assets {
            guard let data = assetData[descriptor.path], descriptor.byteCount == data.count, descriptor.sha256 == sha256(data) else {
                throw SpokenMarginsPackageArchiveError.invalidDigest
            }
        }
    }

    private static func decodeKnownArtifacts(
        manifest: SpokenMarginsPackageManifest,
        artifactData: [String: Data]
    ) throws -> (commentary: [SharedCommentaryLayerArtifact], proposals: [PortableListeningMapProposalArtifact]) {
        var commentary: [SharedCommentaryLayerArtifact] = []
        var proposals: [PortableListeningMapProposalArtifact] = []
        for descriptor in manifest.artifacts {
            guard let data = artifactData[descriptor.path] else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("artifact is absent: \(descriptor.path)")
            }
            switch descriptor.kind {
            case SpokenMarginsArtifactKind.commentaryLayer:
                guard descriptor.schemaVersion == SharedCommentaryLayerArtifact.schemaVersion else {
                    throw SpokenMarginsPackageArchiveError.unsupportedSchema(descriptor.schemaVersion)
                }
                let value = try decoder().decode(SharedCommentaryLayerArtifact.self, from: data)
                guard value.id == descriptor.id, value.schemaVersion == descriptor.schemaVersion else {
                    throw SpokenMarginsPackageArchiveError.invalidManifest("commentary descriptor does not match artifact")
                }
                commentary.append(value)
            case SpokenMarginsArtifactKind.listeningMapProposal:
                guard descriptor.schemaVersion == PortableListeningMapProposalArtifact.schemaVersion else {
                    if descriptor.required { throw SpokenMarginsPackageArchiveError.unsupportedSchema(descriptor.schemaVersion) }
                    continue
                }
                let value = try decoder().decode(PortableListeningMapProposalArtifact.self, from: data)
                guard value.id == descriptor.id, value.schemaVersion == descriptor.schemaVersion else {
                    throw SpokenMarginsPackageArchiveError.invalidManifest("map descriptor does not match artifact")
                }
                proposals.append(value)
            default:
                if descriptor.required {
                    throw SpokenMarginsPackageArchiveError.unsupportedRequiredCapability(descriptor.kind)
                }
            }
        }
        return (commentary, proposals)
    }

    private static func validateManifestBoundary(
        _ manifest: SpokenMarginsPackageManifest,
        commentaryLayers: [SharedCommentaryLayerArtifact],
        proposals: [PortableListeningMapProposalArtifact],
        requireDigest: Bool
    ) throws {
        guard manifest.schemaVersion == schemaVersion else {
            throw SpokenMarginsPackageArchiveError.unsupportedSchema(manifest.schemaVersion)
        }
        guard (1...200).contains(manifest.packageId.count), !manifest.artifacts.isEmpty, commentaryLayers.count == 1 else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("required package fields are absent or out of bounds")
        }
        for capability in manifest.requiredCapabilities where !supportedRequiredCapabilities.contains(capability) {
            throw SpokenMarginsPackageArchiveError.unsupportedRequiredCapability(capability)
        }
        if requireDigest, !isSHA256(manifest.contentDigest) {
            throw SpokenMarginsPackageArchiveError.invalidManifest("content digest is absent")
        }
        if let digest = manifest.contentDigest, !isSHA256(digest) {
            throw SpokenMarginsPackageArchiveError.invalidManifest("content digest is invalid")
        }
        guard manifest.senderDisplayLabel.map({ $0.count <= 120 }) ?? true, manifest.redactions.provesDefaultMinimization else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("sender or redaction fields are invalid")
        }
        try validateSource(manifest.source)

        let artifactIDs = manifest.artifacts.map(\.id)
        let assetIDs = manifest.assets.map(\.id)
        guard Set(artifactIDs).count == artifactIDs.count,
              Set(assetIDs).count == assetIDs.count,
              Set(manifest.artifacts.map(\.path)).count == manifest.artifacts.count,
              Set(manifest.assets.map(\.path)).count == manifest.assets.count else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("descriptor identities are not unique")
        }
        for descriptor in manifest.artifacts {
            guard validArtifactPath(descriptor.path),
                  (descriptor.byteCount.map { (0...Int(maximumArtifactBytes)).contains($0) } ?? !requireDigest),
                  (descriptor.sha256.map(isSHA256) ?? !requireDigest) else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("artifact descriptor is invalid")
            }
        }
        for descriptor in manifest.assets {
            guard validAssetPath(descriptor.path), !descriptor.role.isEmpty, !descriptor.mimeType.isEmpty,
                  descriptor.provenance.count <= 200,
                  descriptor.durationMs.map({ (0...600_000).contains($0) }) ?? true,
                  descriptor.anchorOffsetMs.map({ (-600_000...600_000).contains($0) }) ?? true,
                  (descriptor.role != SpokenMarginsAssetRole.acousticSignature || descriptor.anchorOffsetMs != nil),
                  (descriptor.byteCount.map { $0 >= 0 } ?? !requireDigest),
                  (descriptor.sha256.map(isSHA256) ?? !requireDigest) else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("asset descriptor is invalid")
            }
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id, $0) })
        let layer = commentaryLayers[0]
        guard !layer.interjections.isEmpty, layer.interjections.count <= maximumInterjections else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("commentary layer is empty or too large")
        }
        let scopedIDs = layer.interjections.map(\.packageScopedId)
        guard Set(scopedIDs).count == scopedIDs.count else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("package-scoped Margin IDs are not unique")
        }
        for record in layer.interjections { try validate(record, assetsByID: assetsByID) }
        for proposal in proposals { try validate(proposal, assetsByID: assetsByID) }
    }

    private static func validateSource(_ source: SharedSourceIdentity) throws {
        guard validHTTPSURL(source.canonicalURL),
              source.originalURL.map(validHTTPSURL) ?? true,
              source.feedURL.map(validHTTPSURL) ?? true,
              source.enclosureURL.map(validHTTPSURL) ?? true,
              (1...500).contains(source.title.count),
              !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              optionalLength(source.author, maximum: 300), optionalLength(source.publisher, maximum: 300),
              optionalLength(source.showTitle, maximum: 500), optionalLength(source.episodeGUID, maximum: 1_000),
              optionalLength(source.publishedAt, maximum: 100), optionalLength(source.languageCode, maximum: 35),
              source.durationMs.map({ $0 >= 0 }) ?? true else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("source fields are absent or out of bounds")
        }
        for digest in [source.normalizedContentSHA256, source.exactEditionSHA256].compactMap({ $0 }) where !isSHA256(digest) {
            throw SpokenMarginsPackageArchiveError.invalidManifest("source digest is invalid")
        }
    }

    private static func validate(
        _ record: SharedInterjectionPackageRecord,
        assetsByID: [String: SpokenMarginsAssetDescriptor]
    ) throws {
        let anchor = record.anchor
        guard (1...200).contains(record.packageScopedId.count), !record.representations.isEmpty,
              Set(record.representations.map(\.id)).count == record.representations.count,
              record.defaultRepresentation != nil,
              optionalNonnegative(anchor.startChar), optionalNonnegative(anchor.endChar),
              validCharacterRange(start: anchor.startChar, end: anchor.endChar),
              optionalLength(anchor.exactText, maximum: BoundedAnchorContext.maximumExactTextCharacters),
              optionalLength(anchor.prefix, maximum: BoundedAnchorContext.maximumCharactersPerSide),
              optionalLength(anchor.suffix, maximum: BoundedAnchorContext.maximumCharactersPerSide),
              optionalNonnegative(anchor.mediaTimeMs), anchor.roughPercent.map({ (0...100).contains($0) }) ?? true,
              optionalLength(anchor.transcriptSegmentId, maximum: 300), optionalLength(anchor.chapterTitle, maximum: 500) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("a Margin field is absent or out of bounds")
        }
        for evidenceID in anchor.machineEvidenceAssetIds {
            guard assetsByID[evidenceID]?.role == SpokenMarginsAssetRole.acousticSignature else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("anchor evidence asset is absent or has the wrong role")
            }
        }
        for representation in record.representations {
            guard (1...200).contains(representation.id.count),
                  !representation.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  representation.approvedTranscript.count <= 50_000 else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("a representation is empty or out of bounds")
            }
            switch representation.kind {
            case .textOnly, .summaryText:
                guard representation.assetId == nil else {
                    throw SpokenMarginsPackageArchiveError.invalidManifest("text representation references audio")
                }
            case .originalAudioAndText, .cleanedAudioAndText, .summaryAudioAndText, .ttsAudioAndText:
                guard let assetID = representation.assetId,
                      let asset = assetsByID[assetID], asset.path.hasPrefix("assets/audio/") else {
                    throw SpokenMarginsPackageArchiveError.invalidManifest("audio representation asset is absent")
                }
            }
        }
    }

    private static func validate(
        _ proposal: PortableListeningMapProposalArtifact,
        assetsByID: [String: SpokenMarginsAssetDescriptor]
    ) throws {
        guard !proposal.scenes.isEmpty, proposal.generator.count <= 200,
              Set(proposal.scenes.map(\.id)).count == proposal.scenes.count,
              proposal.scenes.map(\.order) == Array(0..<proposal.scenes.count) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Listening Map proposal order is invalid")
        }
        for scene in proposal.scenes {
            guard scene.title.map({ $0.count <= 500 }) ?? true,
                  scene.summaryText.map({ $0.count <= 10_000 }) ?? true,
                  scene.eligibilityReason.map({ $0.count <= 500 }) ?? true else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("Listening Map scene is out of bounds")
            }
            if scene.eligibility == .eligible {
                guard scene.summaryText?.isEmpty == false, scene.summaryProvenance != nil else {
                    throw SpokenMarginsPackageArchiveError.invalidManifest("eligible scene lacks a grounded summary")
                }
            }
            if let assetID = scene.summaryAssetId, assetsByID[assetID]?.role != SpokenMarginsAssetRole.summaryVoice {
                throw SpokenMarginsPackageArchiveError.invalidManifest("scene summary asset is absent or has the wrong role")
            }
        }
    }

    private static func validateManifestJSONShape(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("manifest root is not an object")
        }
        if let declaredSchema = root["schemaVersion"] as? String, declaredSchema != schemaVersion {
            throw SpokenMarginsPackageArchiveError.unsupportedSchema(declaredSchema)
        }
        try rejectUnknownKeys(
            root,
            allowed: ["schemaVersion", "packageId", "createdAt", "contentDigest", "source", "senderDisplayLabel", "suggestedRevealMode", "requiredCapabilities", "artifacts", "assets", "redactions"],
            context: "manifest"
        )
        guard let source = root["source"] as? [String: Any],
              let artifacts = root["artifacts"] as? [[String: Any]],
              let assets = root["assets"] as? [[String: Any]],
              let redactions = root["redactions"] as? [String: Any] else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("typed package fields are absent")
        }
        try rejectUnknownKeys(source, allowed: ["sourceType", "canonicalURL", "originalURL", "feedURL", "title", "author", "publisher", "showTitle", "episodeGUID", "enclosureURL", "publishedAt", "durationMs", "normalizedContentSHA256", "exactEditionSHA256", "languageCode"], context: "source")
        try rejectUnknownKeys(redactions, allowed: ["rawAudioOmitted", "rawTranscriptOmitted", "fullSourceTextOmitted", "sourceAudioOmitted", "diagnosticsOmitted", "filesystemPathsOmitted", "unrelatedTurnsOmitted", "privateRepresentationsOmitted"], context: "redactions")
        for artifact in artifacts {
            try rejectUnknownKeys(artifact, allowed: ["id", "kind", "schemaVersion", "path", "required", "byteCount", "sha256"], context: "artifact descriptor")
        }
        for asset in assets {
            try rejectUnknownKeys(asset, allowed: ["id", "role", "path", "mimeType", "durationMs", "anchorOffsetMs", "provenance", "byteCount", "sha256"], context: "asset descriptor")
        }
    }

    private static func rejectUnknownKeys(_ object: [String: Any], allowed: Set<String>, context: String) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("unknown \(context) fields: \(unknown.sorted().joined(separator: ", "))")
        }
    }

    private static func digest(
        manifest: SpokenMarginsPackageManifest,
        previewData: Data,
        artifactData: [String: Data],
        assetData: [String: Data]
    ) throws -> String {
        var unsigned = manifest
        unsigned.contentDigest = nil
        var hasher = SHA256()
        hasher.update(data: try encodeManifest(unsigned))
        updateDigest(&hasher, path: "preview.md", data: previewData)
        for path in (Array(artifactData.keys) + Array(assetData.keys)).sorted() {
            guard let data = artifactData[path] ?? assetData[path] else { continue }
            updateDigest(&hasher, path: path, data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func updateDigest(_ hasher: inout SHA256, path: String, data: Data) {
        hasher.update(data: Data(path.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(SHA256.hash(data: data)))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(String(data.count).utf8))
        hasher.update(data: Data([0]))
    }

    private static func validateExtractedAsset(_ descriptor: SpokenMarginsAssetDescriptor, at url: URL) throws {
        if descriptor.path.hasPrefix("assets/audio/") {
            try validateAudio(at: url, archivePath: descriptor.path)
            return
        }
        guard descriptor.role == SpokenMarginsAssetRole.acousticSignature,
              descriptor.mimeType == "application/vnd.apple.shazam.signature" else {
            throw SpokenMarginsPackageArchiveError.invalidAsset(descriptor.path)
        }
        #if canImport(ShazamKit)
        do {
            _ = try SHSignature(dataRepresentation: Data(contentsOf: url))
        } catch {
            throw SpokenMarginsPackageArchiveError.invalidAsset(descriptor.path)
        }
        #else
        guard (try? Data(contentsOf: url).isEmpty) == false else {
            throw SpokenMarginsPackageArchiveError.invalidAsset(descriptor.path)
        }
        #endif
    }

    private static func validateAudio(at url: URL, archivePath: String) throws {
        #if canImport(AudioToolbox)
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr, let audioFile else {
            throw SpokenMarginsPackageArchiveError.invalidAsset(archivePath)
        }
        defer { AudioFileClose(audioFile) }
        var fileType: AudioFileTypeID = 0
        var fileTypeSize = UInt32(MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &fileTypeSize, &fileType) == noErr,
              fileType == kAudioFileM4AType || fileType == kAudioFileMPEG4Type else {
            throw SpokenMarginsPackageArchiveError.invalidAsset(archivePath)
        }
        var duration = 0.0
        var propertySize = UInt32(MemoryLayout<Double>.size)
        guard AudioFileGetProperty(audioFile, kAudioFilePropertyEstimatedDuration, &propertySize, &duration) == noErr,
              duration.isFinite, duration > 0 else {
            throw SpokenMarginsPackageArchiveError.invalidAsset(archivePath)
        }
        guard duration <= 600 else { throw SpokenMarginsPackageArchiveError.audioTooLong(archivePath) }
        #else
        let prefix = try Data(contentsOf: url, options: [.mappedIfSafe]).prefix(12)
        guard prefix.count == 12, String(decoding: prefix.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp" else {
            throw SpokenMarginsPackageArchiveError.invalidAsset(archivePath)
        }
        #endif
    }

    private static func commitStagedItem(_ stagedURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    private static func add(_ data: Data, path: String, to archive: Archive, compression: CompressionMethod) throws {
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: fixedArchiveDate,
            permissions: 0o644, compressionMethod: compression
        ) { position, size in
            let start = Int(position)
            guard start < data.count else { return Data() }
            return data.subdata(in: start..<min(data.count, start + size))
        }
    }

    private static func isAllowedPackagePath(_ path: String) -> Bool {
        path == "manifest.json" || path == "preview.md" || validArtifactPath(path) || validAssetPath(path)
    }

    private static func validArtifactPath(_ path: String) -> Bool {
        validNestedPath(path, prefix: "artifacts/", allowedExtensions: ["json"])
    }

    private static func validAssetPath(_ path: String) -> Bool {
        validNestedPath(path, prefix: "assets/audio/", allowedExtensions: ["m4a"])
            || validNestedPath(path, prefix: "assets/evidence/", allowedExtensions: ["shazamsignature"])
    }

    private static func validNestedPath(_ path: String, prefix: String, allowedExtensions: Set<String>) -> Bool {
        guard path.hasPrefix(prefix), !path.contains(".."), !path.contains("\\"), !path.contains("//") else { return false }
        let component = String(path.dropFirst(prefix.count))
        guard !component.isEmpty, !component.contains("/"), allowedExtensions.contains(URL(fileURLWithPath: component).pathExtension) else { return false }
        return component.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }

    private static func validHTTPSURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return components.scheme?.lowercased() == "https" && !(components.host?.isEmpty ?? true)
            && components.user == nil && components.password == nil
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && !value.contains("<") && !value.contains(">")
    }

    private static func optionalLength(_ value: String?, maximum: Int) -> Bool { value.map { $0.count <= maximum } ?? true }
    private static func optionalNonnegative(_ value: Int?) -> Bool { value.map { $0 >= 0 } ?? true }
    private static func validCharacterRange(start: Int?, end: Int?) -> Bool {
        guard let start, let end else { return true }
        return end >= start
    }
    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func safeComponent(_ value: String) -> String {
        let mapped = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar) { return Character(String(scalar)) }
            return "-"
        }
        let result = String(mapped)
        return result.isEmpty ? UUID().uuidString.lowercased() : result
    }

    public static func previewMarkdown(
        _ manifest: SpokenMarginsPackageManifest,
        commentaryLayers: [SharedCommentaryLayerArtifact],
        listeningMapProposals: [PortableListeningMapProposalArtifact]
    ) -> String {
        let interjections = commentaryLayers.flatMap(\.interjections)
        let sender = manifest.senderDisplayLabel?.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        var lines = [
            "# Spoken Margins", "",
            "\(markdownEscaped(sender?.isEmpty == false ? sender! : "Someone")) shared \(interjections.count) reviewed Margin\(interjections.count == 1 ? "" : "s") about **\(markdownEscaped(manifest.source.title))**.",
            "", "<\(manifest.source.canonicalURL)>", "",
            "Full source audio and full source transcripts are not included.",
            "Voice assets: \(manifest.assets.filter { $0.path.hasPrefix("assets/audio/") }.count).",
            "Acoustic signatures: \(manifest.assets.filter { $0.role == SpokenMarginsAssetRole.acousticSignature }.count). These are opaque matching evidence, not source audio.",
            "Listening Map proposals: \(listeningMapProposals.count). Proposals are not activated automatically.", ""
        ]
        for (index, interjection) in interjections.enumerated() {
            lines.append("## Margin \(index + 1)")
            lines.append("")
            lines.append(markdownEscaped(interjection.defaultRepresentation?.approvedTranscript ?? "Unavailable representation"))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func markdownEscaped(_ value: String) -> String {
        let escapable = CharacterSet(charactersIn: #"\`*_{}[]<>()#+-!|>"#)
        return value.unicodeScalars.reduce(into: "") { result, scalar in
            if escapable.contains(scalar) { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
    }
}

@available(*, deprecated, renamed: "SpokenMarginsPackageArchive")
public typealias InterjectionPackageArchive = SpokenMarginsPackageArchive
@available(*, deprecated, renamed: "SpokenMarginsPackageArchiveError")
public typealias InterjectionPackageArchiveError = SpokenMarginsPackageArchiveError
@available(*, deprecated, renamed: "VerifiedSpokenMarginsPackage")
public typealias VerifiedInterjectionPackage = VerifiedSpokenMarginsPackage
