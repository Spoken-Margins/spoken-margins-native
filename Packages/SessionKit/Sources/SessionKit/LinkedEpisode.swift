import Foundation

/// The podcast episode a listener says an imported audio file is (#755). A packet shared by link names
/// its episode by feed GUID and page link, never by the bytes of the sender's copy, so the listener's own
/// file can only be found for it when the listener says which episode the file is. The app never guesses
/// this from the title or the length.
public struct LinkedEpisode: Codable, Equatable, Sendable {
    public var guid: String?
    public var title: String
    public var showTitle: String?
    public var publishedAt: String?
    /// The episode page or feed link the listener gave.
    public var pageURL: String?
    public var enclosureURL: String?
    public var durationMs: Int?

    public init(
        guid: String? = nil,
        title: String,
        showTitle: String? = nil,
        publishedAt: String? = nil,
        pageURL: String? = nil,
        enclosureURL: String? = nil,
        durationMs: Int? = nil
    ) {
        self.guid = guid
        self.title = title
        self.showTitle = showTitle
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.enclosureURL = enclosureURL
        self.durationMs = durationMs
    }

    /// Lengths further apart than this share of the longer one are different cuts, not one episode with
    /// inserted ads. An unknown length on either side agrees.
    public static let lengthTolerance = 0.2

    public static func lengthsAgree(_ first: Int?, _ second: Int?) -> Bool {
        guard let first, let second, first > 0, second > 0 else { return true }
        return Double(abs(first - second)) <= lengthTolerance * Double(max(first, second))
    }
}

/// Attaches the episode the listener chose to an audio file they imported, or refuses.
public enum ImportedFileEpisodeLink {
    public enum Refusal: Error, Equatable, Sendable {
        /// Only an audio file the listener imported can be linked; a streamed episode already has its identity.
        case notAnImportedAudioFile
        /// The episode gave nothing a packet could be matched on: no GUID, page link or audio link.
        case noEpisodeIdentity
        /// The file and the episode differ in length by more than the 20% inserted ads explain.
        case lengthsDisagree
        /// The link did not resolve to an episode.
        case couldNotReadLink
        /// The link resolved only by guessing, as a show's feed does by taking its first episode.
        case notOneEpisode
    }

    /// A resolution below this is the resolver's guess among several episodes, not the episode the link names.
    public static let minimumConfidence = 0.9

    /// The imported file, linked to the episode the pasted `pageURL` resolved to. A link that names a whole
    /// show resolves to its first episode with a lower confidence; that is refused, because linking must
    /// never guess which episode a file is.
    public static func link(_ item: Item, resolution result: LinkResolutionResult, pageURL: String) throws -> Item {
        guard result.status == .playable, let candidate = result.selectedCandidate else { throw Refusal.couldNotReadLink }
        guard candidate.confidence >= minimumConfidence else { throw Refusal.notOneEpisode }
        return try link(item, to: candidate, pageURL: pageURL)
    }

    /// The imported file, linked to the episode the listener chose. `pageURL` is the link they gave.
    public static func link(
        _ item: Item,
        to candidate: LinkResolutionCandidate,
        pageURL: String?
    ) throws -> Item {
        guard item.mediaType == "audiobook", item.media?.sourceType == .nativeMediaFile else {
            throw Refusal.notAnImportedAudioFile
        }
        let episode = LinkedEpisode(
            guid: nonEmpty(candidate.episodeGUID),
            title: candidate.title.trimmingCharacters(in: .whitespacesAndNewlines),
            showTitle: nonEmpty(candidate.showTitle),
            publishedAt: nonEmpty(candidate.publishedAt),
            pageURL: nonEmpty(pageURL),
            enclosureURL: nonEmpty(candidate.audioURL),
            durationMs: candidate.durationMs
        )
        guard episode.guid != nil || episode.pageURL != nil || episode.enclosureURL != nil else {
            throw Refusal.noEpisodeIdentity
        }
        guard LinkedEpisode.lengthsAgree(item.media?.durationMs, episode.durationMs) else {
            throw Refusal.lengthsDisagree
        }
        var linked = item
        linked.linkedEpisode = episode
        return linked
    }

    /// The imported file with its episode link removed. The file, its Margins and its checksum are untouched.
    public static func unlink(_ item: Item) -> Item {
        var unlinked = item
        unlinked.linkedEpisode = nil
        return unlinked
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension ImportedFileEpisodeLink.Refusal: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAnImportedAudioFile: "Only an audio file you imported can be linked to an episode."
        case .noEpisodeIdentity: "That link doesn't say which episode it is, so Margins can't be matched to this file."
        case .lengthsDisagree: "This file is a very different length from that episode, so it is probably not the same recording. Check the link and try again."
        case .couldNotReadLink: "Couldn't read that link. Paste the link to the episode itself."
        case .notOneEpisode: "That link is for a whole show, not one episode. Paste the link to the episode itself."
        }
    }
}
