import Foundation
import SessionKit

struct UITestingAmbiguousSourceLinkResolver: LinkResolutionClient {
    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: .needsReview,
            originalLink: SourceLink(url: request.inputURL, provider: "spotify", role: "discovery"),
            candidates: [
                LinkResolutionCandidate(
                    sourceLink: SourceLink(
                        url: "https://podcasts.apple.com/ui-test/episode-one",
                        provider: "apple_podcasts",
                        role: "canonical_source"
                    ),
                    title: "Ambiguous Episode One",
                    showTitle: "UI Test Show",
                    durationMs: 1_800_000,
                    publishedAt: "2026-08-01T00:00:00Z",
                    audioURL: "https://cdn.example.com/ui-test-episode-one.mp3",
                    confidence: 0.71
                ),
                LinkResolutionCandidate(
                    sourceLink: SourceLink(
                        url: "https://podcasts.apple.com/ui-test/episode-two",
                        provider: "apple_podcasts",
                        role: "canonical_source"
                    ),
                    title: "Ambiguous Episode Two",
                    showTitle: "UI Test Show",
                    durationMs: 2_400_000,
                    publishedAt: "2026-08-02T00:00:00Z",
                    audioURL: "https://cdn.example.com/ui-test-episode-two.mp3",
                    confidence: 0.70
                )
            ],
            failureReason: "spotify_episode_match_ambiguous"
        )
    }
}
