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
              let host = components.host, isPublicInternetHost(host) else { return nil }
        return link
    }

    /// How long a check is trusted. A page that was free when it was checked can be behind a paywall a week later, so
    /// after this the mark stops counting and the next listener action checks again (#3449).
    public static let markLifetime: TimeInterval = 7 * 24 * 3600

    /// Whether the source's model-written scene text may leave the device.
    public static func allowsModelText(of item: Item, now: Date = Date()) -> Bool {
        guard let mark = item.publicSourceMark, let address = checkableAddress(of: item), mark.url == address else { return false }
        return now.timeIntervalSince(mark.checkedAt) <= markLifetime
    }

    /// A name anyone on the internet can look up. Not `localhost`, a bare name, an IP address, or a name that only an
    /// office, campus or home network answers: a request that succeeds there proves nothing about the public (#3449).
    /// The check is on the spelling of the name. A private name written like a public one (`wiki.example.com` on a VPN)
    /// cannot be told apart from here, and its page must still match the listener's copy to earn the mark.
    public static func isPublicInternetHost(_ value: String) -> Bool {
        var host = value.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard host.contains("."), !host.hasPrefix("["), !host.contains(":") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return false }
        // IPv4 literal, with or without the odd shorthand forms.
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) || $0.hasPrefix("0x") }) { return false }
        let privateEndings = ["local", "localhost", "internal", "intranet", "corp", "lan", "home", "private", "test",
                              "invalid", "example", "onion", "arpa", "localdomain", "home.arpa", "box", "router"]
        guard let last = labels.last.map(String.init), !privateEndings.contains(last) else { return false }
        return last.count >= 2 && last.allSatisfy(\.isLetter) || last.hasPrefix("xn--")
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

    /// How many scenes of these proposals `proposals(_:for:)` would reduce to bare starts, so the share preview (next PR) can say
    /// that scene summaries stay on this phone and its map count matches what is sent.
    public static func withheldSceneCount(_ proposals: [PortableListeningMapProposalArtifact], for item: Item) -> Int {
        guard !allowsModelText(of: item) else { return 0 }
        return proposals.reduce(0) { $0 + $1.scenes.filter(writtenByModel).count }
    }

    /// The share review's note, in plain words, or nil when nothing is held back (#3449).
    public static func withheldNote(sceneCount: Int) -> String? {
        guard sceneCount > 0 else { return nil }
        let scenes = sceneCount == 1 ? "1 scene" : "\(sceneCount) scenes"
        return "Scene summaries stay on this phone. Your Margins and the scene starts are shared. "
            + "The titles and summaries the on-device model wrote for \(scenes) are left out, because this source is not marked public."
    }

    private static func writtenByModel(_ scene: PortableListeningMapScene) -> Bool {
        switch scene.summaryProvenance {
        case .publisherSupplied, .senderAuthored, .deterministic: false
        // A scene with no provenance and a title is treated as the model's: a publisher chapter title the map builder
        // copied into a scene cannot be told apart from a label it wrote, so the safe side wins (#3449).
        case .modelGenerated, nil: scene.title != nil || scene.summaryText != nil || scene.summaryAssetId != nil
            || scene.eligibilityReason != nil || scene.eligibility == .eligible
            || scene.startAnchor.chapterTitle != nil || scene.endAnchor.chapterTitle != nil
        }
    }

    private static func withoutModelText(_ scene: PortableListeningMapScene) -> PortableListeningMapScene {
        guard writtenByModel(scene) else { return scene }
        // The map builder writes the model's label into both anchors' chapter titles too, so those go with the title.
        return PortableListeningMapScene(
            id: scene.id, order: scene.order, title: nil, summaryText: nil, summaryAssetId: nil, summaryProvenance: nil,
            eligibility: .unknown, eligibilityReason: nil,
            startAnchor: withoutChapterTitle(scene.startAnchor), endAnchor: withoutChapterTitle(scene.endAnchor)
        )
    }

    private static func withoutChapterTitle(_ anchor: PortableAnchorEvidence) -> PortableAnchorEvidence {
        guard anchor.chapterTitle != nil else { return anchor }
        return PortableAnchorEvidence(
            anchorType: anchor.anchorType, startChar: anchor.startChar, endChar: anchor.endChar,
            exactText: anchor.exactText, prefix: anchor.prefix, suffix: anchor.suffix,
            mediaTimeMs: anchor.mediaTimeMs, roughPercent: anchor.roughPercent,
            transcriptSegmentId: anchor.transcriptSegmentId, chapterTitle: nil,
            machineEvidenceAssetIds: anchor.machineEvidenceAssetIds
        )
    }
}
