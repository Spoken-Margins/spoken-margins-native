import Foundation
import SessionKit

/// Selects the episode a shared podcast packet refers to without performing lookup or persistence.
public enum SharedPodcastResolutionPolicy {
    public static func hasReference(_ item: SharedItemIdentity) -> Bool {
        guard let canonicalURL = item.canonicalURL,
              SharedItemIdentityBuilder.normalizedSharingURL(canonicalURL) != nil else { return false }
        return true
    }

    public static func packageReferenceResolution(
        item: SharedItemIdentity,
        request: LinkResolutionRequest
    ) -> LinkResolutionResult? {
        guard item.itemType == .podcast,
              let canonicalURL = item.canonicalURL,
              SharedItemIdentityBuilder.normalizedSharingURL(canonicalURL) != nil,
              let enclosureURL = item.enclosureURL,
              SharedItemIdentityBuilder.normalizedSharingURL(enclosureURL) != nil,
              !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sourceLink = SourceLink(
            url: canonicalURL, provider: "shared_package", title: item.title,
            role: "package_reference"
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: sourceLink,
            title: item.title,
            showTitle: item.showTitle,
            durationMs: item.durationMs,
            publishedAt: item.publishedAt,
            audioURL: enclosureURL,
            confidence: 1
        )
        return LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: sourceLink,
            selectedCandidate: candidate,
            candidates: [candidate]
        )
    }

    /// Keeps lookup metadata when selecting a candidate; only the package fallback replaces the result.
    public static func settle(
        _ result: LinkResolutionResult,
        item: SharedItemIdentity,
        request: LinkResolutionRequest
    ) throws -> (result: LinkResolutionResult, diagnostic: String?) {
        var result = result
        var diagnostic: String?
        if result.status == .needsReview {
            // Enclosures match by the file behind their tracking redirects. Duration only breaks ties: shows with
            // dynamic ads report different lengths for the same episode.
            let exactEnclosureMatches = result.candidates.filter {
                PodcastEnclosureIdentity.sameFile($0.audioURL, item.enclosureURL)
            }
            let titleMatches = result.candidates.filter {
                $0.audioURL != nil
                    && $0.title.compare(item.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            let titleDurationMatches = titleMatches.filter { durationIsCompatible($0.durationMs, item.durationMs) }
            let selected = exactEnclosureMatches.count == 1 ? exactEnclosureMatches.first
                : titleMatches.count == 1 ? titleMatches.first
                : titleDurationMatches.count == 1 ? titleDurationMatches.first
                : nil
            if let selected {
                result.status = .playable
                result.selectedCandidate = selected
            } else if !result.candidates.contains(where: { $0.audioURL != nil }),
                      let packageResult = packageReferenceResolution(item: item, request: request) {
                // The lookup found the page but no audio at all, so there is nothing to confuse the packet's own
                // enclosure with. Placement still needs recipient evidence.
                diagnostic = "package_reference_after_lookup_without_audio"
                result = packageResult
            } else {
                throw SessionKitError.persistenceFailed("shared_podcast_item_is_ambiguous")
            }
        }
        if result.status == .playable {
            result = namingTheEpisodeAsThePacketDoes(result, item: item)
        }
        return (result, diagnostic)
    }

    /// A packet whose page link is the audio file itself resolves as a bare file, and the resolver names that item
    /// after the file ("hpr4736"). The sender's title is the episode's name, so it replaces a title that is only
    /// the name of a file the packet points at; a title read from a feed or a page is kept (#3262).
    static func namingTheEpisodeAsThePacketDoes(_ result: LinkResolutionResult, item: SharedItemIdentity) -> LinkResolutionResult {
        let packetTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.itemType == .podcast, !packetTitle.isEmpty else { return result }
        let packetFiles = [item.canonicalURL, item.enclosureURL].compactMap { $0 }
        func isFileName(_ title: String?, provider: String?, audioURL: String?) -> Bool {
            if provider == "direct_audio" { return true }
            guard let title else { return false }
            let key = fileNameKey(title)
            guard !key.isEmpty else { return false }
            return (packetFiles + [audioURL].compactMap { $0 }).contains { fileNameKey(fileStem(of: $0)) == key }
        }
        func renamed(_ link: SourceLink, audioURL: String?) -> SourceLink {
            guard isFileName(link.title, provider: link.provider, audioURL: audioURL) else { return link }
            var link = link
            link.title = packetTitle
            return link
        }
        func renamed(_ candidate: LinkResolutionCandidate) -> LinkResolutionCandidate {
            guard isFileName(candidate.title, provider: candidate.sourceLink.provider, audioURL: candidate.audioURL) else { return candidate }
            var candidate = candidate
            candidate.title = packetTitle
            candidate.sourceLink = renamed(candidate.sourceLink, audioURL: candidate.audioURL)
            if candidate.showTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                candidate.showTitle = item.showTitle
            }
            return candidate
        }
        var result = result
        result.originalLink = renamed(result.originalLink, audioURL: result.selectedCandidate?.audioURL)
        result.selectedCandidate = result.selectedCandidate.map(renamed)
        result.candidates = result.candidates.map(renamed)
        return result
    }

    private static func fileStem(of urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Case, spaces, hyphens and underscores don't tell one file name from another ("hpr 4736" and "HPR4736").
    private static func fileNameKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func durationIsCompatible(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs - rhs) <= max(2_000, Int((Double(rhs) * 0.005).rounded()))
    }
}
