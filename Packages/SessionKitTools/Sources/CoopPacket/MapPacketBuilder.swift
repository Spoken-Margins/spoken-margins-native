import Foundation
import SessionKit
import SessionKitSharing

/// Writes a map-only `.spokenmargins` packet from a Listening Edition (#1471): the edition's text and scenes become
/// a skim-ready Listening Map for an article or a PDF, with each chapter placed by a few of its first words, so the
/// packet carries none of the text. Earlier builds refuse it by their "unsupported capability" message.
enum MapPacketBuilder {
    struct Built {
        let url: URL
        let digest: String
        let sceneCount: Int
        let byteCount: Int
    }

    enum PlanError: Error, CustomStringConvertible {
        case badType(String)

        var description: String {
            switch self {
            case .badType(let value): return "--type must be text, pdf or epub, not \(value)"
            }
        }
    }

    /// `canonicalURL`: nil takes the edition's source link, and an empty string sends no link (the listener is
    /// asked for the item, as for a PDF the sender holds only as a file).
    static func build(
        editionURL: URL,
        itemType: String,
        canonicalURL: String?,
        sender: String?,
        fileName: String?,
        outDirectory: URL?
    ) throws -> Built {
        guard let type = SharedItemType(rawValue: itemType), ListeningMapPacket.itemTypes.contains(type) else {
            throw PlanError.badType(itemType)
        }
        let edition = try ListeningEdition.decode(Data(contentsOf: editionURL))
        let link = canonicalURL ?? edition.sourceURL
        let identity = ListeningMapPacketBuilder.identity(
            itemType: type, title: edition.title, canonicalURL: (link?.isEmpty ?? true) ? nil : link, text: edition.text)
        let tag = String(edition.revision.prefix(24))
        let proposal = try ListeningMapPacketBuilder.proposal(
            id: "map-\(tag)", generator: edition.generator, languageCode: nil, createdAt: Date(),
            scenes: ListeningMapPacketBuilder.scenes(of: edition), text: edition.text)
        let prepared = try ListeningMapPacketBuilder.prepare(
            packageId: "map-packet-\(tag)", createdAt: Date(), item: identity, proposal: proposal, senderDisplayLabel: sender)
        let folder = outDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let name = fileName ?? slug(edition.title)
        let url = folder.appendingPathComponent("\(name).\(SpokenMarginsPackageArchive.fileExtension)")
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
        let opened = try OpenedPacket.open(url)
        defer { try? FileManager.default.removeItem(at: opened.assetFolder) }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Built(url: url, digest: opened.digest, sceneCount: proposal.scenes.count, byteCount: bytes)
    }

    private static func slug(_ title: String) -> String {
        let folded = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(folded).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "listening-map" : String(joined.prefix(60))
    }
}
