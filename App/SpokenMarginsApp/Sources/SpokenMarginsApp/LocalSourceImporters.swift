import AVFoundation
import CryptoKit
import Foundation
import SessionKit
import SessionKitEPUB

enum LocalSourceImportError: Error, LocalizedError, Equatable {
    case unsupportedType
    case protectedContent
    case zeroDuration
    case duplicate
    case interruptedCopy

    var errorDescription: String? {
        switch self {
        case .unsupportedType: return "Choose a DRM-free EPUB, MP3, M4A, M4B, or audio-bearing MP4 file."
        case .protectedContent: return "This file is protected and cannot be imported."
        case .zeroDuration: return "This audio file has no playable duration."
        case .duplicate: return "This audio file is already in the library."
        case .interruptedCopy: return "The file copy was interrupted before it could be published."
        }
    }
}

actor LocalSourceImporter {
    private let repository: any SessionRepository
    private let ledger: OfflineStorageLedger
    private let applicationSupportDirectory: URL
    private let fileManager: FileManager

    init(
        repository: any SessionRepository,
        ledger: OfflineStorageLedger,
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.ledger = ledger
        self.applicationSupportDirectory = applicationSupportDirectory
        self.fileManager = fileManager
    }

    func importEPUB(from sourceURL: URL) async throws -> Item {
        guard sourceURL.pathExtension.lowercased() == "epub" else { throw LocalSourceImportError.unsupportedType }
        let size = try fileSize(sourceURL)
        let reservation = try await ledger.reserve(ownerId: "epub-import-\(UUID().uuidString)", byteCount: size)
        let itemId = "epub-\(UUID().uuidString.lowercased())"
        let directory = applicationSupportDirectory.appending(path: "SourceDocuments", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(itemId).epub")
        let temporary = directory.appending(path: ".\(itemId).\(UUID().uuidString).tmp.epub")
        do {
            try copySecurityScoped(sourceURL, to: temporary)
            let parser = EPUBParser()
            let parsed = try parser.parse(url: temporary, itemId: itemId, sourceDocumentId: "document-\(itemId)")
            try fileManager.moveItem(at: temporary, to: destination)
            let checksum = try fingerprint(destination)
            let item = Item(
                id: itemId,
                title: parsed.package.title,
                mediaType: "epub",
                text: parsed.text,
                externalReference: destination.absoluteString,
                status: "ready",
                externalReferenceType: "epub",
                author: parsed.package.author,
                sourceTitle: parsed.package.title,
                createdAt: Date()
            )
            let owned = OwnedOfflineAsset(
                id: "source-asset-\(itemId)",
                itemId: itemId,
                category: .sourceDocument,
                relativePath: "SourceDocuments/\(destination.lastPathComponent)",
                byteCount: size,
                checksumSHA256: checksum,
                isReproducible: false
            )
            try repository.publishImportedSource(item: item, canonicalSource: parsed.package, audioAsset: nil, ownedAsset: owned)
            try await ledger.release(reservationId: reservation.id)
            return item
        } catch {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: destination)
            try? await ledger.release(reservationId: reservation.id)
            throw error
        }
    }

    func importAudiobook(from sourceURL: URL) async throws -> Item {
        let allowed = ["mp3", "m4a", "m4b", "mp4"]
        let ext = sourceURL.pathExtension.lowercased()
        guard allowed.contains(ext) else { throw LocalSourceImportError.unsupportedType }
        let size = try fileSize(sourceURL)
        let reservation = try await ledger.reserve(ownerId: "audiobook-import-\(UUID().uuidString)", byteCount: size)
        let itemId = "audiobook-\(UUID().uuidString.lowercased())"
        let directory = applicationSupportDirectory.appending(path: "Audiobooks", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(itemId).\(ext)")
        let temporary = directory.appending(path: ".\(itemId).\(UUID().uuidString).tmp.\(ext)")
        do {
            try copySecurityScoped(sourceURL, to: temporary)
            let checksum = try fingerprint(temporary)
            guard !(try repository.loadOwnedOfflineAssets()).contains(where: { $0.category == .audiobook && $0.checksumSHA256 == checksum }) else {
                throw LocalSourceImportError.duplicate
            }
            let asset = AVURLAsset(url: temporary)
            let protected = try await asset.load(.hasProtectedContent)
            guard !protected else { throw LocalSourceImportError.protectedContent }
            let duration = try await asset.load(.duration)
            let durationMs = Int((duration.seconds * 1_000).rounded())
            guard durationMs > 0, duration.isNumeric else { throw LocalSourceImportError.zeroDuration }
            let metadata = try await asset.load(.commonMetadata)
            let title = try await metadataValue(.commonKeyTitle, in: metadata) ?? sourceURL.deletingPathExtension().lastPathComponent
            let artist = try await metadataValue(.commonKeyArtist, in: metadata)
            let author: String?
            if let artist {
                author = artist
            } else {
                author = try await metadataValue(.commonKeyAuthor, in: metadata)
            }
            let chapters = embeddedChapters(asset: asset)
            try fileManager.moveItem(at: temporary, to: destination)
            let item = Item(
                id: itemId,
                title: title,
                mediaType: "audiobook",
                text: nil,
                externalReference: destination.absoluteString,
                status: "ready",
                externalReferenceType: "audiobook",
                media: ItemMedia(sourceType: .nativeMediaFile, url: destination.absoluteString, durationMs: durationMs, nativeMediaId: "audiobook-audio-\(itemId)"),
                author: author,
                sourceTitle: title,
                createdAt: Date()
            )
            let audio = AudioAsset(
                id: "audiobook-audio-\(itemId)",
                itemId: itemId,
                audioSourceType: .nativeMediaFile,
                availability: .localPhone,
                url: destination.absoluteString,
                durationMs: durationMs,
                title: title,
                subtitle: author,
                chapters: chapters
            )
            let owned = OwnedOfflineAsset(
                id: "audiobook-owned-\(itemId)",
                itemId: itemId,
                category: .audiobook,
                relativePath: "Audiobooks/\(destination.lastPathComponent)",
                byteCount: size,
                checksumSHA256: checksum,
                isReproducible: false,
                protections: [.importedAudiobook]
            )
            try repository.publishImportedSource(item: item, canonicalSource: nil, audioAsset: audio, ownedAsset: owned)
            try await ledger.release(reservationId: reservation.id)
            return item
        } catch {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: destination)
            try? await ledger.release(reservationId: reservation.id)
            throw error
        }
    }

    private func embeddedChapters(asset: AVAsset) -> [AudioAssetChapter] {
        let locales = asset.availableChapterLocales
        guard let locale = locales.first else { return [] }
        return asset.chapterMetadataGroups(
            withTitleLocale: locale,
            containingItemsWithCommonKeys: [.commonKeyTitle]
        ).enumerated().map { index, group in
            let title = AVMetadataItem.metadataItems(from: group.items, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common).first?.stringValue
                ?? "Chapter \(index + 1)"
            return AudioAssetChapter(
                id: "embedded-chapter-\(index + 1)",
                title: title,
                startMs: Int((group.timeRange.start.seconds * 1_000).rounded()),
                endMs: Int((group.timeRange.end.seconds * 1_000).rounded())
            )
        }
    }

    private func metadataValue(_ key: AVMetadataKey, in metadata: [AVMetadataItem]) async throws -> String? {
        try await AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first?.load(.stringValue)
    }

    private func copySecurityScoped(_ source: URL, to destination: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try fileManager.copyItem(at: source, to: destination)
        guard fileManager.fileExists(atPath: destination.path) else { throw LocalSourceImportError.interruptedCopy }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private func fingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
