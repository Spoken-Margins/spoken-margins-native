import Foundation
internal import ShippedSessionKit
internal import ShippedSessionKitSharing

/// The last shipped build's packet reader, for tests (#317).
///
/// Packets exported by a new build must import into the last shipped build (AGENTS.md), and that build's
/// reader rejects manifest keys it doesn't know. The frozen sources next to this file are that build's
/// SessionKit and SessionKitSharing (scripts/freeze-shipped-reader.sh). This API uses Foundation types
/// only, so the frozen modules' types never meet the current SessionKit's in a test.
public enum ShippedPacketReader {
    public static let build = "Build 29 (testflight/0.1-build-29, fcc4974)"

    public struct Rejected: Error, CustomStringConvertible {
        public let description: String
    }

    /// Reads a packet and imports it into an empty in-memory Library, as the shipped build does.
    /// Returns the package-scoped IDs of the Margins it imported.
    @discardableResult
    public static func importPacket(at packetURL: URL) throws -> [String] {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "shipped-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let contents = try SpokenMarginsPackageArchive.read(from: packetURL, extractingAssetsTo: scratch)
            let disposition = try SpokenMarginsPackageImporter.importPackage(
                contents, repository: InMemorySessionRepository())
            guard case .imported = disposition else {
                throw Rejected(description: "not imported: \(disposition)")
            }
            return contents.commentaryLayers.flatMap { $0.interjections.map(\.packageScopedId) }
        } catch {
            throw Rejected(description: "\(build) could not import \(packetURL.lastPathComponent): \(error)")
        }
    }

    /// A Margin as the shipped build saved it on import.
    public struct ImportedMargin: Equatable, Sendable {
        public let packageScopedId: String
        public let approvedTranscript: String

        public init(packageScopedId: String, approvedTranscript: String) {
            self.packageScopedId = packageScopedId
            self.approvedTranscript = approvedTranscript
        }
    }

    /// Imports a packet as `importPacket(at:)` does, then reads back the Margins the shipped build saved.
    public static func importedMargins(at packetURL: URL) throws -> [ImportedMargin] {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "shipped-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let contents = try SpokenMarginsPackageArchive.read(from: packetURL, extractingAssetsTo: scratch)
            let repository = InMemorySessionRepository()
            guard case .imported(let layerId, _) = try SpokenMarginsPackageImporter.importPackage(
                contents, repository: repository) else {
                throw Rejected(description: "not imported")
            }
            return try repository.loadImportedCommentaryInterjections(layerId: layerId).map {
                ImportedMargin(packageScopedId: $0.packageScopedId, approvedTranscript: $0.approvedTranscript)
            }
        } catch {
            throw Rejected(description: "\(build) could not import \(packetURL.lastPathComponent): \(error)")
        }
    }

    /// Decodes a saved record payload with the shipped build's types and date format, as its
    /// SQLite store does on load. `kind` is the store's record kind. Returns the record's id.
    @discardableResult
    public static func decodeStoredRecord(kind: String, payload: Data) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            switch kind {
            case "item": return try decoder.decode(Item.self, from: payload).id
            case "interjection": return try decoder.decode(Interjection.self, from: payload).id
            case "imported_commentary_layer": return try decoder.decode(ImportedCommentaryLayer.self, from: payload).id
            case "imported_commentary_interjection":
                return try decoder.decode(ImportedCommentaryInterjection.self, from: payload).id
            default: throw Rejected(description: "no shipped type for record kind \(kind)")
            }
        } catch let error as Rejected {
            throw error
        } catch {
            throw Rejected(description: "\(build) could not decode a saved \(kind): \(error)")
        }
    }

    /// One written Margin for `writeTextPacket`.
    public struct TextMargin: Sendable {
        public let packageScopedId: String
        public let transcript: String
        public let exactText: String

        public init(packageScopedId: String, transcript: String, exactText: String) {
            self.packageScopedId = packageScopedId
            self.transcript = transcript
            self.exactText = exactText
        }
    }

    /// Writes a text-only packet about a public article with the shipped build's own builder and
    /// archive writer, so a test can compare the current build's output with it byte for byte.
    public static func writeTextPacket(
        to url: URL,
        packageId: String,
        createdAt: Date,
        title: String,
        canonicalURL: String,
        senderDisplayLabel: String?,
        margins: [TextMargin]
    ) throws {
        let selections = margins.map { margin in
            ReviewedInterjectionSelection(
                packageScopedId: margin.packageScopedId,
                revision: InterjectionShareRevision(
                    id: "revision-\(margin.packageScopedId)", interjectionId: margin.packageScopedId,
                    itemId: "item", sessionId: "session", createdAt: createdAt,
                    approvedTranscript: margin.transcript, anchorBefore: "", anchorAfter: "",
                    status: .senderApproved
                ),
                anchor: PortableAnchorEvidence(anchorType: .text, exactText: margin.exactText),
                representation: .textOnly
            )
        }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: packageId, createdAt: createdAt,
            item: SharedItemIdentity(itemType: .text, canonicalURL: canonicalURL, title: title),
            itemTransportSelection: .reference, selections: selections,
            senderDisplayLabel: senderDisplayLabel, suggestedRevealMode: .companion
        )
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
    }
}
