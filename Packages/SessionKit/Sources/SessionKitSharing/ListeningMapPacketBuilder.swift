import Foundation
import SessionKit

/// Writes the pieces of a map-only `.spokenmargins` packet (#1471). It runs on the Mac (`coop-packet map`) and
/// anywhere a map is exported later; nothing in the app's import path depends on it.
public enum ListeningMapPacketBuilder {
    public struct Scene: Equatable, Sendable {
        public var title: String
        public var summary: String
        /// Character offsets into the source text, in the same units as `Chapter.startChar`.
        public var startChar: Int
        public var endChar: Int

        public init(title: String, summary: String, startChar: Int, endChar: Int) {
            self.title = title
            self.summary = summary
            self.startChar = startChar
            self.endChar = endChar
        }
    }

    public enum BuildError: Error, Equatable, CustomStringConvertible {
        case noScenes
        case tooManyScenes(Int)
        case sceneOutsideText(String)
        case scenesOutOfOrder(String)
        case itemNotShareable
        case sceneCannotBePlaced(String)
        case contractViolation(String)

        public var description: String {
            switch self {
            case .noScenes: return "the map has no scenes"
            case .tooManyScenes(let count): return "the map has \(count) scenes; a packet carries at most \(ListeningMapPacket.maximumScenes)"
            case .sceneOutsideText(let title): return "scene \"\(title)\" lies outside the source text"
            case .scenesOutOfOrder(let title): return "scene \"\(title)\" starts before the scene ahead of it"
            case .itemNotShareable: return "a map packet needs a text, PDF or EPUB item with a title"
            case .sceneCannotBePlaced(let title): return "the first words of scene \"\(title)\" appear more than once, so a listener's copy couldn't tell where it starts"
            case .contractViolation(let detail): return "the map breaks the share rules: \(detail)"
            }
        }
    }

    /// The item identity a map packet names its source by. The link is kept only when the caller supplies a public
    /// one; a PDF the sender holds as a file has none, and the listener is asked to supply it.
    public static func identity(
        itemType: SharedItemType,
        title: String,
        canonicalURL: String?,
        text: String,
        author: String? = nil,
        languageCode: String? = nil
    ) -> SharedItemIdentity {
        // A link that holds an access secret never leaves the device, as for every other packet (#168).
        // Only an https link travels; the writer refuses any other, so an http source is shared like a file with none.
        let link = SharedItemIdentityBuilder.normalizedSharingURL(ShareableLinkPolicy.shareableLink(canonicalURL))
        return SharedItemIdentity(
            itemType: itemType,
            canonicalURL: link,
            originalURL: link,
            title: title,
            author: author,
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text),
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text),
            languageCode: languageCode
        )
    }

    /// The scenes of a Listening Edition, as character ranges of its text.
    public static func scenes(of edition: ListeningEdition) -> [Scene] {
        let blocks = ListeningEdition.blocks(in: edition.text)
        return edition.scenes.map { scene in
            Scene(title: scene.title, summary: scene.summary,
                  startChar: blocks[scene.startBlock - 1].startChar, endChar: blocks[scene.endBlock - 1].endChar)
        }
    }

    public static func proposal(
        id: String,
        generator: String,
        languageCode: String?,
        createdAt: Date,
        scenes: [Scene],
        text: String
    ) throws -> PortableListeningMapProposalArtifact {
        guard !scenes.isEmpty else { throw BuildError.noScenes }
        guard scenes.count <= ListeningMapPacket.maximumScenes else { throw BuildError.tooManyScenes(scenes.count) }
        let characters = Array(text)
        var previousStart = -1
        var records: [PortableListeningMapScene] = []
        for (index, scene) in scenes.enumerated() {
            guard scene.startChar >= 0, scene.endChar > scene.startChar, scene.endChar <= characters.count else {
                throw BuildError.sceneOutsideText(scene.title)
            }
            guard scene.startChar > previousStart else { throw BuildError.scenesOutOfOrder(scene.title) }
            previousStart = scene.startChar
            guard let start = startAnchor(at: scene.startChar, in: characters),
                  let end = endAnchor(at: scene.endChar, in: characters) else {
                throw BuildError.sceneOutsideText(scene.title)
            }
            let summary = scene.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            records.append(PortableListeningMapScene(
                id: "scene-\(index + 1)", order: index, title: scene.title,
                summaryText: summary.isEmpty ? nil : summary,
                summaryProvenance: summary.isEmpty ? nil : .senderAuthored,
                eligibility: summary.isEmpty ? .excluded : .eligible,
                eligibilityReason: summary.isEmpty ? "The sender supplied no summary for this chapter." : nil,
                startAnchor: start, endAnchor: end
            ))
        }
        let proposal = PortableListeningMapProposalArtifact(
            id: id, languageCode: languageCode, createdAt: createdAt, generator: String(generator.prefix(200)), scenes: records
        )
        if let violation = PortableListeningMapContract.violations(in: proposal, itemText: text).first {
            throw BuildError.contractViolation(violation.description)
        }
        // The packet carries none of the text: a quotation the share contract would strip must never be written.
        if PortableListeningMapContract.withoutLongAnchorQuotations(proposal) != proposal {
            throw BuildError.contractViolation("an anchor quotes \(PortableListeningMapContract.verbatimRunWords) or more words of the text")
        }
        // A listener's copy is only as good at finding a scene as the builder's own: check on the sender's text.
        for (index, record) in records.enumerated() {
            let resolution = PortableArticleAnchorResolver.resolve(
                anchor: PortableAnchorEvidence(
                    anchorType: .text, exactText: record.startAnchor.exactText,
                    prefix: record.startAnchor.prefix, suffix: record.startAnchor.suffix
                ),
                in: text, expectedExactEditionSHA256: nil
            )
            guard resolution.localStartChar == record.startAnchor.startChar, !resolution.isAmbiguous else {
                throw BuildError.sceneCannotBePlaced(scenes[index].title)
            }
        }
        return proposal
    }

    public static func prepare(
        packageId: String,
        createdAt: Date,
        item: SharedItemIdentity,
        proposal: PortableListeningMapProposalArtifact,
        senderDisplayLabel: String?
    ) throws -> PreparedSpokenMarginsPackage {
        guard ListeningMapPacket.itemTypes.contains(item.itemType),
              !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuildError.itemNotShareable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        // The empty layer is what lets earlier builds reach the capability check and refuse in their usual words.
        let layer = SharedCommentaryLayerArtifact(id: "commentary-layer", interjections: [])
        let layerPath = "artifacts/commentary-layer.json"
        let proposalPath = "artifacts/listening-map-proposal-0001.json"
        let artifacts = [
            SpokenMarginsArtifactDescriptor(
                id: layer.id, kind: SpokenMarginsArtifactKind.commentaryLayer,
                schemaVersion: layer.schemaVersion, path: layerPath, required: true
            ),
            SpokenMarginsArtifactDescriptor(
                id: proposal.id, kind: SpokenMarginsArtifactKind.listeningMapProposal,
                schemaVersion: proposal.schemaVersion, path: proposalPath, required: true
            )
        ]
        return PreparedSpokenMarginsPackage(
            manifest: SpokenMarginsPackageManifest(
                packageId: packageId,
                createdAt: createdAt,
                item: item,
                itemTransport: SharedItemTransport(kind: item.canonicalURL == nil ? .recipientSupplied : .reference),
                senderDisplayLabel: senderDisplayLabel,
                requiredCapabilities: [SharedCommentaryLayerArtifact.schemaVersion, ListeningMapPacket.capability],
                artifacts: artifacts
            ),
            artifactData: [layerPath: try encoder.encode(layer), proposalPath: try encoder.encode(proposal)],
            assetFiles: [:]
        )
    }

    // MARK: Quotations

    private static func startAnchor(at start: Int, in characters: [Character]) -> PortableAnchorEvidence? {
        var first = start
        while first < characters.count, characters[first].isWhitespace { first += 1 }
        guard first < characters.count else { return nil }
        // The share contract counts words more finely than whitespace ("father's" is two), so shrink the context
        // and then the quotation until the whole anchor stays under its ten-word limit.
        for (quoted, context) in wordBudgets() {
            let quoteEnd = endOfWords(quoted, from: first, in: characters)
            let contextStart = context > 0 ? startOfWords(context, before: first, in: characters) : first
            let anchor = PortableAnchorEvidence(
                anchorType: .text, startChar: first, endChar: quoteEnd,
                exactText: String(characters[first..<quoteEnd]),
                prefix: contextStart < first ? String(characters[contextStart..<first]) : nil
            ).bounded()
            if PortableListeningMapContract.quotedWordCount(of: anchor) < PortableListeningMapContract.verbatimRunWords { return anchor }
        }
        return nil
    }

    private static func endAnchor(at end: Int, in characters: [Character]) -> PortableAnchorEvidence? {
        var last = end
        while last > 0, characters[last - 1].isWhitespace { last -= 1 }
        guard last > 0 else { return nil }
        for (quoted, _) in wordBudgets() {
            let first = startOfWords(quoted, before: last, in: characters)
            let anchor = PortableAnchorEvidence(
                anchorType: .text, startChar: first, endChar: last, exactText: String(characters[first..<last])
            ).bounded()
            if PortableListeningMapContract.quotedWordCount(of: anchor) < PortableListeningMapContract.verbatimRunWords { return anchor }
        }
        return nil
    }

    /// Quoted and context word counts to try, most generous first.
    private static func wordBudgets() -> [(quoted: Int, context: Int)] {
        var budgets: [(Int, Int)] = []
        for quoted in stride(from: ListeningMapPacket.quotedWords, through: 3, by: -1) {
            for context in stride(from: ListeningMapPacket.contextWords, through: 0, by: -1) { budgets.append((quoted, context)) }
        }
        return budgets
    }

    /// The index just past the `count`th word at or after `index`, or the end of the text.
    private static func endOfWords(_ count: Int, from index: Int, in characters: [Character]) -> Int {
        var cursor = index
        for _ in 0..<count {
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count else { break }
            while cursor < characters.count, !characters[cursor].isWhitespace { cursor += 1 }
        }
        return cursor
    }

    /// The index of the first character of the `count`th word before `index`, or the start of the text.
    private static func startOfWords(_ count: Int, before index: Int, in characters: [Character]) -> Int {
        var cursor = index
        for _ in 0..<count {
            while cursor > 0, characters[cursor - 1].isWhitespace { cursor -= 1 }
            guard cursor > 0 else { break }
            while cursor > 0, !characters[cursor - 1].isWhitespace { cursor -= 1 }
        }
        return cursor
    }
}
