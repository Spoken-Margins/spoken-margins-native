import Foundation
import SessionKit
import SessionKitSharing

struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

/// A packet read through the current reader, kept with the folder its assets were extracted to.
struct OpenedPacket {
    let url: URL
    let contents: VerifiedSpokenMarginsPackage
    let assetFolder: URL

    var digest: String { contents.manifest.contentDigest ?? "" }
    var margins: [SharedInterjectionPackageRecord] { contents.commentaryLayers.first?.interjections ?? [] }

    static func open(_ url: URL) throws -> OpenedPacket {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("coop-packet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return OpenedPacket(url: url, contents: try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: folder), assetFolder: folder)
    }
}

enum PacketInspector {
    struct Report: Encodable {
        struct Margin: Encodable {
            let packageScopedId: String
            let createdAt: Date
            let at: String?
            let anchor: PortableAnchorEvidence
            let transcript: String
            let voiceSeconds: Double?
            let repliesTo: [MarginReplyLink]?
        }

        let file: String
        let digest: String
        let packageId: String
        let sender: String?
        let createdAt: Date
        let item: SharedItemIdentity
        let itemTransport: String
        let artifacts: [String]
        let acousticSignatures: Int
        let margins: [Margin]
    }

    static func inspect(_ url: URL) throws -> Report {
        let packet = try OpenedPacket.open(url)
        defer { try? FileManager.default.removeItem(at: packet.assetFolder) }
        let manifest = packet.contents.manifest
        let links = packet.contents.conversations.first?.linksByPackageScopedId ?? [:]
        return Report(
            file: url.lastPathComponent,
            digest: packet.digest,
            packageId: manifest.packageId,
            sender: manifest.senderDisplayLabel,
            createdAt: manifest.createdAt,
            item: manifest.item,
            itemTransport: manifest.itemTransport.kind.rawValue,
            artifacts: manifest.artifacts.map(\.kind),
            acousticSignatures: manifest.assets.filter { $0.role == SpokenMarginsAssetRole.acousticSignature }.count,
            margins: packet.margins.map { record in
                let representation = record.defaultRepresentation
                let voice = representation?.assetId.flatMap { id in manifest.assets.first { $0.id == id } }
                return Report.Margin(
                    packageScopedId: record.packageScopedId,
                    createdAt: record.createdAt,
                    at: record.anchor.mediaTimeMs.map(clock),
                    anchor: record.anchor,
                    transcript: representation?.approvedTranscript ?? "",
                    voiceSeconds: voice?.durationMs.map { Double($0) / 1000 },
                    repliesTo: links[record.packageScopedId]
                )
            }
        )
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func clock(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
