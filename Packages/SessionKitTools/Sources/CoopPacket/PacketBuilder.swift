import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio
import SessionKitSharing

/// A synthetic listener's packet, as written by Claude or Codex. Paths are relative to the plan.
struct PacketPlan: Decodable {
    struct ParentRef: Decodable {
        /// The packet the parent Margin was shared in. Defaults to `base`.
        let packet: String?
        let margin: String
    }

    struct Margin: Decodable {
        let id: String
        let text: String
        /// The Margin this one answers.
        let replyTo: ParentRef?
        /// Where it sits, in milliseconds into the item. Without it, a reply sits at its parent's place.
        let atMs: Int?
        /// Added to the parent's place (or to `atMs`). A small offset tests placement that isn't exact.
        let offsetMs: Int?
        /// For an article: the words the Margin is anchored to.
        let quote: String?
        /// The full anchor, used as is. For adversarial packets.
        let anchor: PortableAnchorEvidence?
        /// False sends text only. Defaults to true: the Margin is spoken in the plan's voice.
        let spoken: Bool?
        let voice: String?
        /// Overrides the plan's `createdAt` for this Margin.
        let createdAt: Date?
    }

    /// Shown to the listener as the sender. Keep "synthetic" or "test" in it.
    let sender: String
    /// A macOS voice (`say -v '?'` lists them).
    let voice: String?
    let packageId: String?
    let createdAt: Date?
    /// The packet this one answers: the item, its fingerprint spine and acoustic evidence come from it.
    let base: String?
    /// The item, when there's no base packet.
    let item: SharedItemIdentity?
    /// The article text to embed, when the item travels as embedded text.
    let embeddedText: String?
    /// A downloaded copy of the episode. Each Margin placed by time then carries acoustic evidence
    /// made from it, as the app makes on the sender's phone, so it lands right on a copy with
    /// different ads.
    let episodeAudio: String?
    let fileName: String?
    let margins: [Margin]
}

enum PacketBuilder {
    struct Built {
        let url: URL
        let digest: String
        let marginCount: Int
        let replyCount: Int
        let byteCount: Int
    }

    enum PlanError: Error, CustomStringConvertible {
        case noItem
        case missingParent(String, String)
        case noPlace(String)
        case voiceFailed(String)
        case embeddedTextIsEmpty
        case embeddedTextForPodcast
        case embeddedTextKeepsALink

        var description: String {
            switch self {
            case .embeddedTextIsEmpty: return "embeddedText has no words to embed"
            case .embeddedTextForPodcast: return "embeddedText can't stand in for a podcast: the reader only accepts embedded text for a text, pdf, epub or other item"
            case .embeddedTextKeepsALink: return "an item with embeddedText must have no canonicalURL: the reader takes embedded text only from an item with no link"
            case .noItem: return "the plan needs a base packet or an item"
            case .missingParent(let packet, let margin): return "\(packet) has no Margin \(margin)"
            case .noPlace(let id): return "Margin \(id) has no place: give atMs, quote, anchor or replyTo"
            case .voiceFailed(let detail): return "could not speak a Margin: \(detail)"
            }
        }
    }

    static func build(planURL: URL, outDirectory: URL?) async throws -> Built {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan = try decoder.decode(PacketPlan.self, from: Data(contentsOf: planURL))
        let planFolder = planURL.deletingLastPathComponent()
        func resolve(_ path: String) -> URL { URL(fileURLWithPath: path, relativeTo: planFolder).standardizedFileURL }

        var opened: [String: OpenedPacket] = [:]
        defer { opened.values.forEach { try? FileManager.default.removeItem(at: $0.assetFolder) } }
        func packet(_ path: String) throws -> OpenedPacket {
            let key = resolve(path).path
            if let packet = opened[key] { return packet }
            let packet = try OpenedPacket.open(resolve(path))
            opened[key] = packet
            return packet
        }

        let base = try plan.base.map(packet)
        guard let planItem = plan.item ?? base?.contents.manifest.item else { throw PlanError.noItem }
        let embedding = try plan.embeddedText.map { try embedded($0, in: planItem) }
        let item = embedding?.item ?? planItem
        let createdAt = plan.createdAt ?? Date()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("coop-packet-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var selections: [ReviewedInterjectionSelection] = []
        var generatedEvidence: [ReviewedMachineEvidenceAsset] = []
        for margin in plan.margins {
            var replyTo: MarginReplyLink?
            var parentAnchor: PortableAnchorEvidence?
            if let ref = margin.replyTo {
                guard let path = ref.packet ?? plan.base else { throw PlanError.missingParent("(no packet)", ref.margin) }
                let parentPacket = try packet(path)
                guard let parent = parentPacket.margins.first(where: { $0.packageScopedId == ref.margin }) else {
                    throw PlanError.missingParent(path, ref.margin)
                }
                // A reply to a reply stays in its parent's conversation, as the app does (#472).
                let parentConversation = parentPacket.contents.conversations.first?
                    .linksByPackageScopedId[ref.margin]?.first?.conversationId
                replyTo = MarginReplyLink.replying(
                    to: MarginPacketIdentity(packageDigest: parentPacket.digest, packageScopedId: ref.margin),
                    parentConversationId: parentConversation
                )
                parentAnchor = parent.anchor
            }
            var anchor = try place(margin, parentAnchor: parentAnchor, item: item, baseHasEvidence: base != nil)
            if let episode = plan.episodeAudio, let ms = anchor.mediaTimeMs, anchor.machineEvidenceAssetIds.isEmpty {
                let evidence = try await PodcastAnchorEvidenceGenerator.generate(
                    sourceURL: resolve(episode), anchorMediaTimeMs: ms,
                    outputDirectory: scratch, idPrefix: "anchor-synthetic-\(margin.id)"
                )
                generatedEvidence += evidence.map {
                    ReviewedMachineEvidenceAsset(
                        id: $0.id, path: $0.archivePath, sourceURL: $0.fileURL,
                        durationMs: $0.durationMs, anchorOffsetMs: $0.anchorOffsetMs
                    )
                }
                anchor = anchor.withEvidence(evidence.map(\.id))
            }
            let representation: ReviewedRepresentationSelection
            if margin.spoken ?? true {
                let voice = try speak(margin.text, voice: margin.voice ?? plan.voice, name: margin.id, in: scratch)
                representation = .originalAudio(sourceURL: voice.url, durationMs: voice.durationMs)
            } else {
                representation = .textOnly
            }
            selections.append(ReviewedInterjectionSelection(
                packageScopedId: margin.id,
                revision: InterjectionShareRevision(
                    id: "revision-\(margin.id)", interjectionId: margin.id, itemId: "synthetic",
                    sessionId: "synthetic", createdAt: margin.createdAt ?? createdAt, approvedTranscript: margin.text,
                    anchorBefore: anchor.prefix ?? "", anchorAfter: anchor.suffix ?? "", status: .senderApproved
                ),
                anchor: anchor,
                representation: representation,
                replyTo: replyTo
            ))
        }

        // A friend replying on their copy of the episode sends the same matching evidence the
        // parent's packet carried, so the reply can be placed on any copy.
        let referencedEvidence = Set(selections.flatMap(\.anchor.machineEvidenceAssetIds))
        let spines = base?.contents.editionFingerprintSpines ?? []
        let spineEvidence = Set(spines.flatMap(\.landmarks).map(\.signatureAssetId))
        var copiedEvidence: [String: ReviewedMachineEvidenceAsset] = [:]
        for source in [base].compactMap({ $0 }) + Array(opened.values) {
            for asset in source.contents.manifest.assets where asset.role == SpokenMarginsAssetRole.acousticSignature {
                let wanted = referencedEvidence.contains(asset.id) || (source.url == base?.url && spineEvidence.contains(asset.id))
                guard wanted, copiedEvidence[asset.id] == nil,
                      let url = source.contents.extractedAssetURLs[asset.id],
                      let offset = asset.anchorOffsetMs else { continue }
                copiedEvidence[asset.id] = ReviewedMachineEvidenceAsset(
                    id: asset.id, path: asset.path, sourceURL: url,
                    durationMs: asset.durationMs ?? 0, anchorOffsetMs: offset, provenance: asset.provenance
                )
            }
        }
        let machineEvidence = copiedEvidence.values.sorted { $0.id < $1.id }

        let transport: ReviewedItemTransportSelection
        if let embedding {
            transport = embedding.transport
        } else if base?.contents.manifest.itemTransport.kind == .recipientSupplied {
            transport = .recipientSupplied
        } else {
            transport = .reference
        }
        let packageId = plan.packageId ?? "package-synthetic-\(UUID().uuidString.lowercased())"
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: packageId,
            createdAt: createdAt,
            item: item,
            itemTransportSelection: transport,
            selections: selections,
            fingerprintSpines: spines,
            machineEvidence: machineEvidence + generatedEvidence,
            senderDisplayLabel: plan.sender,
            suggestedRevealMode: .companion
        )
        let folder = outDirectory ?? planFolder
        let name = plan.fileName ?? planURL.deletingPathExtension().lastPathComponent
        let url = folder.appendingPathComponent("\(name).\(SpokenMarginsPackageArchive.fileExtension)")
        let manifest = try SpokenMarginsPackageArchive.write(prepared, to: url)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Built(
            url: url,
            digest: manifest.contentDigest ?? "",
            marginCount: selections.count,
            replyCount: selections.filter { $0.replyTo != nil }.count,
            byteCount: bytes
        )
    }

    /// The item and transport for a packet that carries its own text. The reader checks the embedded item
    /// against the manifest: its media type is the item's type (`text`, not `text/plain`, as the app's
    /// exporter writes it), and the item's two hashes are the text's, so they are set from `text` here
    /// whatever the plan's item says (#1849).
    static func embedded(
        _ text: String, in item: SharedItemIdentity
    ) throws -> (item: SharedItemIdentity, transport: ReviewedItemTransportSelection) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlanError.embeddedTextIsEmpty }
        guard item.itemType != .podcast else { throw PlanError.embeddedTextForPodcast }
        guard item.canonicalURL == nil else { throw PlanError.embeddedTextKeepsALink }
        let hashed = SharedItemIdentity(
            itemType: item.itemType,
            canonicalURL: nil,
            originalURL: item.originalURL,
            title: item.title,
            author: item.author,
            publisher: item.publisher,
            showTitle: item.showTitle,
            episodeGUID: item.episodeGUID,
            enclosureURL: item.enclosureURL,
            publishedAt: item.publishedAt,
            durationMs: item.durationMs,
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text),
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text),
            languageCode: item.languageCode,
            source: item.source
        )
        return (hashed, .embeddedText(text: text, originalMediaType: item.itemType.rawValue, rightsBasis: .appAuthored))
    }

    /// Where a Margin sits. A reply without its own place takes its parent's anchor, evidence and all.
    private static func place(
        _ margin: PacketPlan.Margin,
        parentAnchor: PortableAnchorEvidence?,
        item: SharedItemIdentity,
        baseHasEvidence: Bool
    ) throws -> PortableAnchorEvidence {
        if let anchor = margin.anchor { return anchor }
        let offset = margin.offsetMs ?? 0
        if let quote = margin.quote {
            return PortableAnchorEvidence(anchorType: .text, exactText: quote)
        }
        let roughPercent = { (ms: Int) in item.durationMs.map { $0 > 0 ? min(100, max(0, ms * 100 / $0)) : 0 } }
        if let at = margin.atMs {
            let ms = max(0, at + offset)
            return PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms, roughPercent: roughPercent(ms))
        }
        guard let parent = parentAnchor else { throw PlanError.noPlace(margin.id) }
        guard offset != 0, let parentMs = parent.mediaTimeMs else {
            return baseHasEvidence ? parent : parent.withoutEvidence
        }
        // Moved off the parent's place, so the parent's acoustic evidence no longer describes it.
        let ms = max(0, parentMs + offset)
        return PortableAnchorEvidence(
            anchorType: parent.anchorType, mediaTimeMs: ms, roughPercent: roughPercent(ms), chapterTitle: parent.chapterTitle
        )
    }

    /// Speaks `text` with `say` and encodes it as AAC, as a recorded Margin would be.
    private static func speak(_ text: String, voice: String?, name: String, in folder: URL) throws -> (url: URL, durationMs: Int) {
        let textURL = folder.appendingPathComponent("\(name).txt")
        let aiffURL = folder.appendingPathComponent("\(name).aiff")
        let m4aURL = folder.appendingPathComponent("\(name).m4a")
        try Data(text.utf8).write(to: textURL)
        try run("/usr/bin/say", (voice.map { ["-v", $0] } ?? []) + ["-f", textURL.path, "-o", aiffURL.path])
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "64000", aiffURL.path, m4aURL.path])
        let file = try AVAudioFile(forReading: m4aURL)
        let durationMs = Int((Double(file.length) / file.processingFormat.sampleRate * 1000).rounded())
        return (m4aURL, durationMs)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PlanError.voiceFailed("\(URL(fileURLWithPath: tool).lastPathComponent) exited \(process.terminationStatus): \(detail)")
        }
    }
}

private extension PortableAnchorEvidence {
    var withoutEvidence: PortableAnchorEvidence { withEvidence([]) }

    func withEvidence(_ ids: [String]) -> PortableAnchorEvidence {
        PortableAnchorEvidence(
            anchorType: anchorType, startChar: startChar, endChar: endChar, exactText: exactText,
            prefix: prefix, suffix: suffix, mediaTimeMs: mediaTimeMs, roughPercent: roughPercent,
            transcriptSegmentId: transcriptSegmentId, chapterTitle: chapterTitle, machineEvidenceAssetIds: ids
        )
    }
}
