import CryptoKit
import Foundation
import SessionKit
import ZIPFoundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum InterjectionPackageArchiveError: Error, Equatable, LocalizedError {
    case malformedArchive
    case packageTooLarge
    case invalidEntry(String)
    case duplicateEntry(String)
    case manifestMissing
    case manifestTooLarge
    case unsupportedSchema(String)
    case invalidManifest(String)
    case invalidDigest
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
        case .invalidManifest(let reason): return "The package manifest is invalid: \(reason)."
        case .invalidDigest: return "The package changed after it was exported."
        case .audioTooLarge(let path): return "An interjection audio file is too large: \(path)."
        case .audioTooLong(let path): return "An interjection audio file is longer than 10 minutes: \(path)."
        case .excessiveCompression(let path): return "The package has an unsafe compression ratio: \(path)."
        }
    }
}

public struct InterjectionPackageArchiveContents: Sendable {
    public let manifest: InterjectionPackageManifest
    public let extractedAudioURLs: [String: URL]

    public init(manifest: InterjectionPackageManifest, extractedAudioURLs: [String: URL]) {
        self.manifest = manifest
        self.extractedAudioURLs = extractedAudioURLs
    }
}

public enum InterjectionPackageArchive {
    public static let fileExtension = "spokenmargins"
    public static let uniformTypeIdentifier = "com.spokenmargins.interjection-package"
    public static let mimeType = "application/vnd.spokenmargins.interjection-package+zip"
    public static let schemaVersion = "spoken-margins.interjection-package.v1"

    private static let maximumPackageBytes: UInt64 = 100 * 1_024 * 1_024
    private static let maximumManifestBytes: UInt64 = 1 * 1_024 * 1_024
    private static let maximumAudioBytes: UInt64 = 20 * 1_024 * 1_024
    private static let maximumInterjections = 50
    private static let maximumCompressionRatio: UInt64 = 100
    private static let fixedArchiveDate = Date(timeIntervalSince1970: 315_532_800)

    public static func write(
        manifest inputManifest: InterjectionPackageManifest,
        audioFiles: [String: URL],
        to destinationURL: URL
    ) throws -> InterjectionPackageManifest {
        var manifest = inputManifest
        try validateManifestBoundary(manifest, requireDigest: false)
        let audioData = try loadExportAudio(manifest: manifest, audioFiles: audioFiles)
        manifest.contentDigest = digest(manifest: manifest, audioData: audioData)
        let manifestData = try encodeManifest(manifest)
        guard manifestData.count <= maximumManifestBytes else {
            throw InterjectionPackageArchiveError.manifestTooLarge
        }
        let previewData = Data(previewMarkdown(manifest).utf8)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let archive = try Archive(url: destinationURL, accessMode: .create)
        try add(manifestData, path: "manifest.json", to: archive, compression: .deflate)
        try add(previewData, path: "preview.md", to: archive, compression: .deflate)
        for path in audioData.keys.sorted() {
            guard let data = audioData[path] else { continue }
            try add(data, path: path, to: archive, compression: .none)
        }
        let fileSize = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard UInt64(fileSize) <= maximumPackageBytes else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw InterjectionPackageArchiveError.packageTooLarge
        }
        return manifest
    }

    public static func read(
        from packageURL: URL,
        extractingAudioTo destinationDirectory: URL
    ) throws -> InterjectionPackageArchiveContents {
        let fileSize = try packageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard UInt64(max(0, fileSize)) <= maximumPackageBytes else {
            throw InterjectionPackageArchiveError.packageTooLarge
        }
        let archive: Archive
        do {
            archive = try Archive(url: packageURL, accessMode: .read)
        } catch {
            throw InterjectionPackageArchiveError.malformedArchive
        }
        var seen: Set<String> = []
        var entryData: [String: Data] = [:]
        var totalUncompressed: UInt64 = 0

        for entry in archive {
            guard seen.insert(entry.path).inserted else {
                throw InterjectionPackageArchiveError.duplicateEntry(entry.path)
            }
            guard entry.type == .file, isAllowed(path: entry.path) else {
                throw InterjectionPackageArchiveError.invalidEntry(entry.path)
            }
            totalUncompressed += entry.uncompressedSize
            guard totalUncompressed <= maximumPackageBytes else {
                throw InterjectionPackageArchiveError.packageTooLarge
            }
            if entry.path == "manifest.json", entry.uncompressedSize > maximumManifestBytes {
                throw InterjectionPackageArchiveError.manifestTooLarge
            }
            if entry.path.hasPrefix("audio/"), entry.uncompressedSize > maximumAudioBytes {
                throw InterjectionPackageArchiveError.audioTooLarge(entry.path)
            }
            if entry.compressedSize > 0,
               entry.uncompressedSize / max(1, entry.compressedSize) > maximumCompressionRatio {
                throw InterjectionPackageArchiveError.excessiveCompression(entry.path)
            }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            do {
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
            } catch {
                throw InterjectionPackageArchiveError.malformedArchive
            }
            entryData[entry.path] = data
        }

        guard let manifestData = entryData["manifest.json"] else {
            throw InterjectionPackageArchiveError.manifestMissing
        }
        let manifest: InterjectionPackageManifest
        do {
            try validateManifestJSONShape(manifestData)
            manifest = try decodeManifest(manifestData)
        } catch let error as InterjectionPackageArchiveError {
            throw error
        } catch {
            throw InterjectionPackageArchiveError.invalidManifest(String(describing: error))
        }
        try validateManifestBoundary(manifest, requireDigest: true)

        let expectedAudioPaths = Set(manifest.interjections.compactMap(\.representation.audioPath))
        let actualAudioPaths = Set(entryData.keys.filter { $0.hasPrefix("audio/") })
        guard expectedAudioPaths == actualAudioPaths else {
            throw InterjectionPackageArchiveError.invalidManifest("audio attachment list does not match archive")
        }
        let audioData = Dictionary(uniqueKeysWithValues: actualAudioPaths.compactMap { path in
            entryData[path].map { (path, $0) }
        })
        guard manifest.contentDigest == digest(manifest: manifest, audioData: audioData) else {
            throw InterjectionPackageArchiveError.invalidDigest
        }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        var audioURLs: [String: URL] = [:]
        for path in actualAudioPaths.sorted() {
            guard let data = audioData[path] else { continue }
            let destination = destinationDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try data.write(to: destination, options: [.atomic])
            #if canImport(AVFoundation)
            let measuredDuration = CMTimeGetSeconds(AVURLAsset(url: destination).duration)
            if measuredDuration.isFinite, measuredDuration > 600 {
                try? FileManager.default.removeItem(at: destination)
                throw InterjectionPackageArchiveError.audioTooLong(path)
            }
            #endif
            audioURLs[path] = destination
        }
        return InterjectionPackageArchiveContents(manifest: manifest, extractedAudioURLs: audioURLs)
    }

    public static func encodeManifest(_ manifest: InterjectionPackageManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601WithFractionalSeconds.string(from: date))
        }
        return try encoder.encode(manifest)
    }

    public static func decodeManifest(_ data: Data) throws -> InterjectionPackageManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = iso8601WithFractionalSeconds.date(from: value)
                ?? iso8601.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            return date
        }
        return try decoder.decode(InterjectionPackageManifest.self, from: data)
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

    private static func loadExportAudio(
        manifest: InterjectionPackageManifest,
        audioFiles: [String: URL]
    ) throws -> [String: Data] {
        let expected = Set(manifest.interjections.compactMap(\.representation.audioPath))
        guard expected == Set(audioFiles.keys) else {
            throw InterjectionPackageArchiveError.invalidManifest("audio attachment list does not match inputs")
        }
        var result: [String: Data] = [:]
        for path in expected.sorted() {
            guard isAllowedAudio(path: path), let url = audioFiles[path] else {
                throw InterjectionPackageArchiveError.invalidEntry(path)
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw InterjectionPackageArchiveError.invalidEntry(path)
            }
            guard UInt64(max(0, values.fileSize ?? 0)) <= maximumAudioBytes else {
                throw InterjectionPackageArchiveError.audioTooLarge(path)
            }
            result[path] = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        return result
    }

    private static func validateManifestBoundary(
        _ manifest: InterjectionPackageManifest,
        requireDigest: Bool
    ) throws {
        guard manifest.schemaVersion == schemaVersion else {
            throw InterjectionPackageArchiveError.unsupportedSchema(manifest.schemaVersion)
        }
        guard (1...200).contains(manifest.packageId.count),
              (1...200).contains(manifest.conversationId.count),
              (1...500).contains(manifest.source.title.count),
              URL(string: manifest.source.canonicalURL)?.scheme?.lowercased() == "https",
              !manifest.interjections.isEmpty,
              manifest.interjections.count <= maximumInterjections else {
            throw InterjectionPackageArchiveError.invalidManifest("required package fields are absent or out of bounds")
        }
        guard manifest.redactions.provesDefaultMinimization else {
            throw InterjectionPackageArchiveError.invalidManifest("required redactions are not asserted")
        }
        if requireDigest, !isSHA256(manifest.contentDigest) {
            throw InterjectionPackageArchiveError.invalidManifest("content digest is absent")
        }
        guard manifest.parentPackageDigests.count <= 20,
              Set(manifest.parentPackageDigests).count == manifest.parentPackageDigests.count,
              manifest.parentPackageDigests.allSatisfy({ isSHA256($0) }) else {
            throw InterjectionPackageArchiveError.invalidManifest("parent package digests are invalid")
        }
        for digest in [manifest.source.normalizedContentSHA256, manifest.source.exactEditionSHA256].compactMap({ $0 }) {
            guard isSHA256(digest) else {
                throw InterjectionPackageArchiveError.invalidManifest("source digest is invalid")
            }
        }
        let scopedIds = manifest.interjections.map(\.packageScopedId)
        guard Set(scopedIds).count == scopedIds.count else {
            throw InterjectionPackageArchiveError.invalidManifest("package-scoped interjection IDs are not unique")
        }
        for record in manifest.interjections {
            let representation = record.representation
            guard (1...200).contains(record.packageScopedId.count),
                  !representation.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  representation.approvedTranscript.count <= 50_000,
                  (record.anchor.exactText?.count ?? 0) <= BoundedAnchorContext.maximumExactTextCharacters,
                  (record.anchor.prefix?.count ?? 0) <= BoundedAnchorContext.maximumCharactersPerSide,
                  (record.anchor.suffix?.count ?? 0) <= BoundedAnchorContext.maximumCharactersPerSide else {
                throw InterjectionPackageArchiveError.invalidManifest("an interjection field is absent or out of bounds")
            }
            switch representation.kind {
            case .textOnly:
                guard representation.audioPath == nil,
                      representation.audioMimeType == nil,
                      representation.audioDurationMs == nil,
                      representation.provenance == .senderApprovedTextOnly else {
                    throw InterjectionPackageArchiveError.invalidManifest("text-only representation contains audio or invalid provenance")
                }
            case .cleanedAudioAndText:
                guard let path = representation.audioPath,
                      isAllowedAudio(path: path),
                      representation.audioMimeType == "audio/mp4",
                      let duration = representation.audioDurationMs,
                      (0...600_000).contains(duration),
                      representation.provenance == .deterministicCleanupV1SenderApproved else {
                    throw InterjectionPackageArchiveError.invalidManifest("cleaned-audio representation is incomplete")
                }
            }
        }
    }

    private static func validateManifestJSONShape(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InterjectionPackageArchiveError.invalidManifest("manifest root is not an object")
        }
        try rejectUnknownKeys(
            root,
            allowed: ["schemaVersion", "packageId", "createdAt", "conversationId", "parentPackageDigests", "contentDigest", "source", "interjections", "senderDisplayLabel", "suggestedRevealMode", "redactions"],
            context: "manifest"
        )
        guard let source = root["source"] as? [String: Any],
              let records = root["interjections"] as? [[String: Any]],
              let redactions = root["redactions"] as? [String: Any] else {
            throw InterjectionPackageArchiveError.invalidManifest("typed package fields are absent")
        }
        try rejectUnknownKeys(
            source,
            allowed: ["sourceType", "canonicalURL", "originalURL", "title", "author", "publisher", "showTitle", "episodeGUID", "enclosureURL", "publishedAt", "durationMs", "normalizedContentSHA256", "exactEditionSHA256"],
            context: "source"
        )
        try rejectUnknownKeys(
            redactions,
            allowed: ["rawAudioOmitted", "rawTranscriptOmitted", "fullSourceTextOmitted", "sourceAudioOmitted", "diagnosticsOmitted", "filesystemPathsOmitted", "unrelatedTurnsOmitted", "privateRepresentationsOmitted"],
            context: "redactions"
        )
        for record in records {
            try rejectUnknownKeys(
                record,
                allowed: ["packageScopedId", "createdAt", "anchor", "representation"],
                context: "interjection"
            )
            guard let anchor = record["anchor"] as? [String: Any],
                  let representation = record["representation"] as? [String: Any] else {
                throw InterjectionPackageArchiveError.invalidManifest("interjection fields are absent")
            }
            try rejectUnknownKeys(
                anchor,
                allowed: ["anchorType", "startChar", "endChar", "exactText", "prefix", "suffix", "mediaTimeMs", "roughPercent", "transcriptSegmentId", "chapterTitle"],
                context: "anchor"
            )
            try rejectUnknownKeys(
                representation,
                allowed: ["kind", "approvedTranscript", "audioPath", "audioMimeType", "audioDurationMs", "provenance"],
                context: "representation"
            )
        }
    }

    private static func rejectUnknownKeys(
        _ object: [String: Any],
        allowed: Set<String>,
        context: String
    ) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw InterjectionPackageArchiveError.invalidManifest(
                "unknown \(context) fields: \(unknown.sorted().joined(separator: ", "))"
            )
        }
    }

    private static func digest(
        manifest: InterjectionPackageManifest,
        audioData: [String: Data]
    ) -> String {
        var unsigned = manifest
        unsigned.contentDigest = nil
        var hasher = SHA256()
        if let data = try? encodeManifest(unsigned) {
            hasher.update(data: data)
        }
        for path in audioData.keys.sorted() {
            guard let data = audioData[path] else { continue }
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(SHA256.hash(data: data)))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(data.count).utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func add(
        _ data: Data,
        path: String,
        to archive: Archive,
        compression: CompressionMethod
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: fixedArchiveDate,
            permissions: 0o644,
            compressionMethod: compression
        ) { position, size in
            let start = Int(position)
            guard start < data.count else { return Data() }
            return data.subdata(in: start..<min(data.count, start + size))
        }
    }

    private static func isAllowed(path: String) -> Bool {
        path == "manifest.json" || path == "preview.md" || isAllowedAudio(path: path)
    }

    private static func isAllowedAudio(path: String) -> Bool {
        guard path.hasPrefix("audio/"), path.hasSuffix(".m4a"), !path.contains("..") else { return false }
        let component = String(path.dropFirst("audio/".count).dropLast(".m4a".count))
        return !component.isEmpty && component.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func previewMarkdown(_ manifest: InterjectionPackageManifest) -> String {
        let sender = manifest.senderDisplayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            "# Spoken Margins",
            "",
            "\(sender?.isEmpty == false ? sender! : "Someone") shared \(manifest.interjections.count) reviewed interjection\(manifest.interjections.count == 1 ? "" : "s") about **\(manifest.source.title)**.",
            "",
            manifest.source.canonicalURL,
            "",
            "The source text or source audio is not included.",
            ""
        ]
        for (index, interjection) in manifest.interjections.enumerated() {
            lines.append("## Interjection \(index + 1)")
            lines.append("")
            lines.append(interjection.representation.approvedTranscript)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
