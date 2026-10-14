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
    /// Substack's automatic narration (`audio_items` of type `tts`, the "Listen" button on a post whose
    /// author recorded nothing) is not a voiceover: `has_voiceover` stays false for it.
    public static func voiceover(inPostPage html: String) -> PostVoiceover? {
        guard let post = post(inPostPage: html),
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

    /// Why a post page gives no voiceover, as a short token for diagnostics (#810), so "the post had none"
    /// can be told from "the page wasn't read". The owner's post (2026-10-05) offered only Substack's own
    /// automatic narration, `generated_voice_only`, which the Substack app also shows as listenable.
    /// Meant for a page `voiceover(inPostPage:)` gave nothing for; for a page that does give one it returns
    /// `voiceover_unreadable`.
    public static func absence(inPostPage html: String) -> String {
        guard let root = preloads(in: html) else { return "no_preloads" }
        guard let post = root["post"] as? [String: Any] else { return "no_post" }
        guard let type = post["type"] as? String else { return "not_a_newsletter_post" }
        guard type == "newsletter" else { return type == "podcast" ? "podcast_post" : "not_a_newsletter_post" }
        let recordings = post["audio_items"] as? [[String: Any]] ?? []
        let postID = post["id"] as? Int
        func status(_ item: [String: Any]) -> String {
            // Page text goes into a diagnostic: keep it short and plain.
            let token = String((item["status"] as? String ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(32))
            return token.isEmpty ? "unknown" : token
        }
        let voiceovers = recordings.filter { $0["type"] as? String == "voiceover" && $0["post_id"] as? Int == postID }
        if let completed = voiceovers.first(where: { status($0) == "completed" }) {
            if post["has_voiceover"] as? Bool != true { return "voiceover_flag_off" }
            return completed["audio_url"] is String ? "voiceover_unreadable" : "no_audio_url"
        }
        if let unfinished = voiceovers.first { return "voiceover_\(status(unfinished))" }
        if let generated = recordings.first(where: { $0["type"] as? String == "tts" }) {
            return status(generated) == "completed" ? "generated_voice_only" : "generated_voice_\(status(generated))"
        }
        return post["has_voiceover"] as? Bool == true ? "no_recording_listed" : "no_recording"
    }

    /// `window._preloads` as a dictionary, decoded as data (publisher scripts never run).
    private static func preloads(in html: String) -> [String: Any]? {
        let pattern = #"window\._preloads\s*=\s*JSON\.parse\((\"(?:\\.|[^\"\\])*\")\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html),
              let json = try? JSONDecoder().decode(String.self, from: Data(html[range].utf8)) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    private static func post(inPostPage html: String) -> [String: Any]? {
        preloads(in: html)?["post"] as? [String: Any]
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

    /// `absence(inPostPage:)`, plus `other_post` for a page whose voiceover belongs to a different address
    /// than the one it ended at.
    public static func absence(postPage html: String, finalURL: URL) -> String {
        if let voiceover = voiceover(inPostPage: html), let canonical = URL(string: voiceover.canonicalURL),
           !samePage(canonical, finalURL) { return "other_post" }
        return absence(inPostPage: html)
    }

    /// Whether a shared link's page is worth one fetch to look for a voiceover: an HTTPS Substack address
    /// (`substack.com` or a publication's `<name>.substack.com`), or an HTTPS post address `/p/<slug>` on any
    /// host. Publications on their own domain (`www.platformer.news/p/<slug>`) keep Substack's post path, and the
    /// Substack app shares that address, not a `substack.com` one (#810, owner's phone 2026-10-05). The page only
    /// counts when its `_preloads` name a completed voiceover of that same post.
    public static func mayHaveVoiceover(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host == "substack.com" || host.hasSuffix(".substack.com") || isPostPath(url.path)
    }

    /// Whether a page the link resolver already read declares Substack's `_preloads`, so it can be read for a
    /// voiceover whatever its address. Reading costs no request.
    public static func declaresPreloads(_ page: Data) -> Bool {
        page.range(of: Data("window._preloads".utf8)) != nil
    }

    /// `/p/<slug>`, with an optional trailing slash: Substack's post path on every publication's domain.
    private static func isPostPath(_ path: String) -> Bool {
        var segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if segments.last == "" { segments.removeLast() }
        return segments.count == 3 && segments[0].isEmpty && segments[1] == "p" && !segments[2].isEmpty
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
