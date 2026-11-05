import Foundation

/// A record that the listener's own action found a source publicly available: an anonymous request to its address
/// succeeded and the response matched the source (#3449). It names the address it checked, so a source whose address
/// later changes is unmarked again. Local only; it never travels in a packet or an export.
public struct PublicSourceMark: Codable, Equatable, Sendable {
    public var url: String
    public var checkedAt: Date

    public init(url: String, checkedAt: Date) {
        self.url = url
        self.checkedAt = checkedAt
    }
}

/// What model-written Listening Map text may leave the device (#3449, owner 2026-11-05, until the lawyer answers).
///
/// The on-device model reads every source. Its scene titles and summaries leave the phone, in a packet, an export,
/// a batch export or a share link, only when the source carries a valid `PublicSourceMark`. Scene starts, publisher
/// chapters, a sender's own words, deterministic labels and Margins all travel either way. Every path that carries a
/// proposal or a scene title goes through `proposal(_:for:)` / `proposals(_:for:)`; `SharedMarginExport` and
/// `ListeningMapExportResolver` do, and `scripts/tests/test_map_text_gate.py` fails when a new path does not.
public enum MapTextDisclosure {
    /// The address a source can be checked at, or nil when it has none to check. Only an item added from a web
    /// address (an article, or an episode from a feed or link) has a public copy to compare; a file from Files, an
    /// EPUB, an audiobook, imported audio, pasted text and a spoken note do not, and can never earn the mark.
    public static func checkableAddress(of item: Item) -> String? {
        guard item.externalReferenceType == "url",
              let link = ShareableLinkPolicy.shareableLink(item.externalReference),
              let components = URLComponents(string: link),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty else { return nil }
        return link
    }

    /// Whether the source's model-written scene text may leave the device.
    public static func allowsModelText(of item: Item) -> Bool {
        guard let mark = item.publicSourceMark, let address = checkableAddress(of: item) else { return false }
        return mark.url == address
    }

    /// The proposal as it may leave the device for `item`: unchanged when the source is marked public, otherwise
    /// each scene whose words the model wrote becomes a bare scene start (unknown eligibility, no title, summary or
    /// eligibility reason). Scenes whose summary is the publisher's, the sender's or deterministic keep everything.
    /// A scene with no provenance counts as model-written, because the contract rejects an eligible scene without one.
    public static func proposal(_ proposal: PortableListeningMapProposalArtifact, for item: Item) -> PortableListeningMapProposalArtifact {
        guard !allowsModelText(of: item) else { return proposal }
        return PortableListeningMapProposalArtifact(
            id: proposal.id, schemaVersion: proposal.schemaVersion, languageCode: proposal.languageCode,
            createdAt: proposal.createdAt, generator: proposal.generator,
            scenes: proposal.scenes.map(withoutModelText)
        )
    }

    public static func proposals(_ proposals: [PortableListeningMapProposalArtifact], for item: Item) -> [PortableListeningMapProposalArtifact] {
        proposals.map { proposal($0, for: item) }
    }

    /// How many scenes of these proposals `proposals(_:for:)` would reduce to bare starts, so the share preview can say
    /// that scene summaries stay on this phone and its map count matches what is sent.
    public static func withheldSceneCount(_ proposals: [PortableListeningMapProposalArtifact], for item: Item) -> Int {
        guard !allowsModelText(of: item) else { return 0 }
        return proposals.reduce(0) { $0 + $1.scenes.filter(writtenByModel).count }
    }

    private static func writtenByModel(_ scene: PortableListeningMapScene) -> Bool {
        switch scene.summaryProvenance {
        case .publisherSupplied, .senderAuthored, .deterministic: false
        case .modelGenerated, nil: scene.title != nil || scene.summaryText != nil || scene.summaryAssetId != nil
            || scene.eligibilityReason != nil || scene.eligibility == .eligible
        }
    }

    private static func withoutModelText(_ scene: PortableListeningMapScene) -> PortableListeningMapScene {
        guard writtenByModel(scene) else { return scene }
        return PortableListeningMapScene(
            id: scene.id, order: scene.order, title: nil, summaryText: nil, summaryAssetId: nil, summaryProvenance: nil,
            eligibility: .unknown, eligibilityReason: nil, startAnchor: scene.startAnchor, endAnchor: scene.endAnchor
        )
    }
}
