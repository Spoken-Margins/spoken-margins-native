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

    /// Writes a text-only packet with the shipped build's exporter, from its manifest and artifact files as
    /// JSON. Tests use it for a packet a Build 29 sender could make that the current exporter refuses (#480).
    public static func writePacket(manifestJSON: Data, artifacts: [String: Data], to packetURL: URL) throws {
        let manifest = try SpokenMarginsPackageArchive.decodeManifest(manifestJSON)
        _ = try SpokenMarginsPackageArchive.write(
            PreparedSpokenMarginsPackage(manifest: manifest, artifactData: artifacts, assetFiles: [:]),
            to: packetURL
        )
    }
}
