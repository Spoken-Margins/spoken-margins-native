import CryptoKit
import Foundation
import SessionKit
import ZIPFoundation
#if canImport(AudioToolbox)
import AudioToolbox
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
    case invalidAudio(String)
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
        case .invalidAudio(let path): return "An interjection audio file is unreadable: \(path)."
        case .audioTooLarge(let path): return "An interjection audio file is too large: \(path)."
        case .audioTooLong(let path): return "An interjection audio file is longer than 10 minutes: \(path)."
        case .excessiveCompression(let path): return "The package has an unsafe compression ratio: \(path)."
        }
    }
}

/// A package value that can only be created by a successful archive read. Public
/// consumers can inspect it, but cannot forge the verification boundary.
public struct VerifiedInterjectionPackage: Sendable {
    public let manifest: InterjectionPackageManifest
    public let extractedAudioURLs: [String: URL]

    init(manifest: InterjectionPackageManifest, extractedAudioURLs: [String: URL]) {
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
        let previewData = Data(previewMarkdown(manifest).utf8)
        manifest.contentDigest = try digest(
            manifest: manifest,
            previewData: previewData,
            audioData: audioData
        )
        let manifestData = try encodeManifest(manifest)
        guard manifestData.count <= maximumManifestBytes else {
            throw InterjectionPackageArchiveError.manifestTooLarge
        }
        let parentDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        let stagedURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).export-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let archive = try Archive(url: stagedURL, accessMode: .create)
        try add(manifestData, path: "manifest.json", to: archive, compression: .deflate)
        try add(previewData, path: "preview.md", to: archive, compression: .deflate)
        for path in audioData.keys.sorted() {
            guard let data = audioData[path] else { continue }
            try add(data, path: path, to: archive, compression: .none)
        }
        let fileSize = try stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard UInt64(max(0, fileSize)) <= maximumPackageBytes else {
            throw InterjectionPackageArchiveError.packageTooLarge
        }
        try commitStagedItem(stagedURL, to: destinationURL)
        return manifest
    }

    public static func read(
        from packageURL: URL,
        extractingAudioTo destinationDirectory: URL
    ) throws -> VerifiedInterjectionPackage {
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
            let (nextTotal, overflowed) = totalUncompressed.addingReportingOverflow(entry.uncompressedSize)
            guard !overflowed, nextTotal <= maximumPackageBytes else {
                throw InterjectionPackageArchiveError.packageTooLarge
            }
            totalUncompressed = nextTotal
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
        guard let previewData = entryData["preview.md"] else {
            throw InterjectionPackageArchiveError.invalidManifest("preview is absent")
        }
        guard manifest.contentDigest == (try digest(
            manifest: manifest,
            previewData: previewData,
            audioData: audioData
        )) else {
            throw InterjectionPackageArchiveError.invalidDigest
        }
        guard previewData == Data(previewMarkdown(manifest).utf8) else {
            throw InterjectionPackageArchiveError.invalidManifest("preview does not match manifest")
        }

        let parentDirectory = destinationDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let stagedDirectory = parentDirectory.appendingPathComponent(
            ".\(destinationDirectory.lastPathComponent).import-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: stagedDirectory) }
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        for path in actualAudioPaths.sorted() {
            guard let data = audioData[path] else { continue }
            let stagedAudio = stagedDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try data.write(to: stagedAudio, options: [.atomic])
            try validateAudio(at: stagedAudio, archivePath: path)
        }
        try commitStagedItem(stagedDirectory, to: destinationDirectory)
        let audioURLs = Dictionary(uniqueKeysWithValues: actualAudioPaths.map { path in
            (path, destinationDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent))
        })
        return VerifiedInterjectionPackage(manifest: manifest, extractedAudioURLs: audioURLs)
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
            try validateAudio(at: url, archivePath: path)
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
              !manifest.interjections.isEmpty,
              manifest.interjections.count <= maximumInterjections else {
            throw InterjectionPackageArchiveError.invalidManifest("required package fields are absent or out of bounds")
        }
        if let digest = manifest.contentDigest, !isSHA256(digest) {
            throw InterjectionPackageArchiveError.invalidManifest("content digest is invalid")
        }
        if let senderDisplayLabel = manifest.senderDisplayLabel, senderDisplayLabel.count > 120 {
            throw InterjectionPackageArchiveError.invalidManifest("sender display label is out of bounds")
        }
        let source = manifest.source
        guard validHTTPSURL(source.canonicalURL),
              source.originalURL.map(validHTTPSURL) ?? true,
              source.enclosureURL.map(validHTTPSURL) ?? true,
              (1...500).contains(source.title.count),
              !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              optionalLength(source.author, maximum: 300),
              optionalLength(source.publisher, maximum: 300),
              optionalLength(source.showTitle, maximum: 500),
              optionalLength(source.episodeGUID, maximum: 1_000),
              optionalLength(source.publishedAt, maximum: 100),
              source.durationMs.map({ $0 >= 0 }) ?? true else {
            throw InterjectionPackageArchiveError.invalidManifest("source fields are absent or out of bounds")
        }
        guard manifest.redactions.provesDefaultMinimization else {
            throw InterjectionPackageArchiveError.invalidManifest("required redactions are not asserted")
        }
        if requireDigest, !isSHA256(manifest.contentDigest) {
            throw InterjectionPackageArchiveError.invalidManifest("content digest is absent")
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
            let anchor = record.anchor
            guard (1...200).contains(record.packageScopedId.count),
                  !representation.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  representation.approvedTranscript.count <= 50_000,
                  optionalNonnegative(anchor.startChar),
                  optionalNonnegative(anchor.endChar),
                  validCharacterRange(start: anchor.startChar, end: anchor.endChar),
                  optionalLength(anchor.exactText, maximum: BoundedAnchorContext.maximumExactTextCharacters),
                  optionalLength(anchor.prefix, maximum: BoundedAnchorContext.maximumCharactersPerSide),
                  optionalLength(anchor.suffix, maximum: BoundedAnchorContext.maximumCharactersPerSide),
                  optionalNonnegative(anchor.mediaTimeMs),
                  anchor.roughPercent.map({ (0...100).contains($0) }) ?? true,
                  optionalLength(anchor.transcriptSegmentId, maximum: 300),
                  optionalLength(anchor.chapterTitle, maximum: 500) else {
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
            allowed: ["schemaVersion", "packageId", "createdAt", "contentDigest", "source", "interjections", "senderDisplayLabel", "suggestedRevealMode", "redactions"],
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
        previewData: Data,
        audioData: [String: Data]
    ) throws -> String {
        var unsigned = manifest
        unsigned.contentDigest = nil
        var hasher = SHA256()
        hasher.update(data: try encodeManifest(unsigned))
        updateDigest(&hasher, path: "preview.md", data: previewData)
        for path in audioData.keys.sorted() {
            guard let data = audioData[path] else { continue }
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

    private static func commitStagedItem(_ stagedURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    private static func validateAudio(at url: URL, archivePath: String) throws {
        #if canImport(AudioToolbox)
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
              let audioFile else {
            throw InterjectionPackageArchiveError.invalidAudio(archivePath)
        }
        defer { AudioFileClose(audioFile) }
        var fileType: AudioFileTypeID = 0
        var fileTypeSize = UInt32(MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyFileFormat,
            &fileTypeSize,
            &fileType
        ) == noErr,
              fileType == kAudioFileM4AType || fileType == kAudioFileMPEG4Type else {
            throw InterjectionPackageArchiveError.invalidAudio(archivePath)
        }
        var duration = 0.0
        var propertySize = UInt32(MemoryLayout<Double>.size)
        guard AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyEstimatedDuration,
            &propertySize,
            &duration
        ) == noErr,
              duration.isFinite,
              duration > 0 else {
            throw InterjectionPackageArchiveError.invalidAudio(archivePath)
        }
        guard duration <= 600 else {
            throw InterjectionPackageArchiveError.audioTooLong(archivePath)
        }
        #else
        let prefix = try Data(contentsOf: url, options: [.mappedIfSafe]).prefix(12)
        guard prefix.count == 12,
              String(decoding: prefix.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp" else {
            throw InterjectionPackageArchiveError.invalidAudio(archivePath)
        }
        #endif
    }

    private static func validHTTPSURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return components.scheme?.lowercased() == "https"
            && !(components.host?.isEmpty ?? true)
            && components.user == nil
            && components.password == nil
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && !value.contains("<")
            && !value.contains(">")
    }

    private static func optionalLength(_ value: String?, maximum: Int) -> Bool {
        value.map { $0.count <= maximum } ?? true
    }

    private static func optionalNonnegative(_ value: Int?) -> Bool {
        value.map { $0 >= 0 } ?? true
    }

    private static func validCharacterRange(start: Int?, end: Int?) -> Bool {
        guard let start, let end else { return true }
        return end >= start
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
            (UInt32(65)...UInt32(90)).contains($0.value)
                || (UInt32(97)...UInt32(122)).contains($0.value)
                || (UInt32(48)...UInt32(57)).contains($0.value)
                || "._-".unicodeScalars.contains($0)
        }
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public static func previewMarkdown(_ manifest: InterjectionPackageManifest) -> String {
        let sender = manifest.senderDisplayLabel?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var lines = [
            "# Spoken Margins",
            "",
            "\(markdownEscaped(sender?.isEmpty == false ? sender! : "Someone")) shared \(manifest.interjections.count) reviewed interjection\(manifest.interjections.count == 1 ? "" : "s") about **\(markdownEscaped(manifest.source.title))**.",
            "",
            "<\(manifest.source.canonicalURL)>",
            "",
            "The source text or source audio is not included.",
            ""
        ]
        for (index, interjection) in manifest.interjections.enumerated() {
            lines.append("## Interjection \(index + 1)")
            lines.append("")
            lines.append(markdownEscaped(interjection.representation.approvedTranscript))
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
