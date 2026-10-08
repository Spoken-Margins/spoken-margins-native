import Foundation
import SessionKit

/// Substack explicitly labels the current post's narration. RSS enclosure URLs and transcript
/// lengths do not carry that distinction. Decode data only; never execute publisher scripts.
public enum PublisherNarrationEvidence {
    /// Cache evidence only against the entry that was read before awaiting the provider.
    public static func cache(_ confirmed: FeedEntry, replacing original: FeedEntry, in repository: any SessionRepository) throws {
        guard let current = try repository.loadFeedEntries(subscriptionId: original.subscriptionId).first(where: { $0.id == original.id }),
              current == original else { return }
        try repository.saveFeedEntry(confirmed)
    }

    /// The current post's completed voiceover, as a Substack post page declares it.
    public struct PostVoiceover: Equatable, Sendable {
        /// The post the page is about, from `post.canonical_url`.
        public let canonicalURL: String
        public let audioURL: String
        /// Nil when the page gives no usable duration.
        public let durationMs: Int?
    }

    /// Reads `window._preloads` on a Substack post page: the post's own completed voiceover, or nil for a
    /// podcast post, a post without a voiceover, one still processing, or a page that isn't a post.
    public static func voiceover(inPostPage html: String) -> PostVoiceover? {
        let pattern = #"window\._preloads\s*=\s*JSON\.parse\((\"(?:\\.|[^\"\\])*\")\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html),
              let json = try? JSONDecoder().decode(String.self, from: Data(html[range].utf8)),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let post = root["post"] as? [String: Any],
              post["type"] as? String == "newsletter", post["has_voiceover"] as? Bool == true,
              let canonicalURL = post["canonical_url"] as? String,
              let postID = post["id"] as? Int,
              let recordings = post["audio_items"] as? [[String: Any]],
              let recording = recordings.first(where: {
                  $0["type"] as? String == "voiceover" && $0["status"] as? String == "completed"
                      && $0["post_id"] as? Int == postID
              }),
              let audio = recording["audio_url"] as? String,
              let url = URL(string: audio), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        var durationMs: Int?
        if let seconds = recording["duration"] as? Double, seconds.isFinite, seconds >= 0,
           seconds < Double(Int.max / 1_000) { durationMs = Int(seconds * 1_000) }
        return PostVoiceover(canonicalURL: canonicalURL, audioURL: audio, durationMs: durationMs)
    }

    public static func confirmedEntry(_ entry: FeedEntry, html: String) -> FeedEntry? {
        guard let voiceover = voiceover(inPostPage: html), voiceover.canonicalURL == entry.canonicalURL else { return nil }
        var confirmed = entry
        confirmed.publisherNarrationConfirmed = true
        confirmed.audioURL = voiceover.audioURL
        if let durationMs = voiceover.durationMs { confirmed.audioDurationMs = durationMs }
        return confirmed
    }

    /// A post shared as a link (#810): the record to keep beside the article imported from it, when the page
    /// has a completed voiceover of that same post. `finalURL` is where the page ended up after redirects,
    /// since a shared `open.substack.com/pub/<name>/p/<slug>` link redirects to the post's canonical address.
    public static func publisherAudio(postPage html: String, finalURL: URL, itemId: String) -> PublisherAudio? {
        guard let voiceover = voiceover(inPostPage: html),
              let canonical = URL(string: voiceover.canonicalURL),
              samePage(canonical, finalURL) else { return nil }
        return PublisherAudio(
            itemId: itemId, audioURL: voiceover.audioURL, durationMs: voiceover.durationMs,
            detectedFrom: PublisherAudioDetector.detectedFromPublisherNarration
        )
    }

    /// Whether a shared link's page is worth one fetch to look for a voiceover: an HTTPS Substack address
    /// (`substack.com` or a publication's `<name>.substack.com`). Publications on their own domain aren't
    /// recognised from the address alone.
    public static func mayHaveVoiceover(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "substack.com" || host.hasSuffix(".substack.com")
    }

    /// Same scheme, host and path, ignoring case in the host, a trailing slash, the query (`?r=…&utm_…`
    /// share tracking) and the fragment.
    private static func samePage(_ lhs: URL, _ rhs: URL) -> Bool {
        func key(_ url: URL) -> String? {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased() else { return nil }
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            return "\(scheme)://\(host)\(path)"
        }
        guard let left = key(lhs) else { return false }
        return left == key(rhs)
    }
}
