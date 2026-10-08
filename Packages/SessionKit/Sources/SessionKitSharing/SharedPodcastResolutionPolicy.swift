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
        return (result, diagnostic)
    }

    private static func durationIsCompatible(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs - rhs) <= max(2_000, Int((Double(rhs) * 0.005).rounded()))
    }
}
