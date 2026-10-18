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
    /// author recorded nothing) is not a voiceover: `has_voiceover` stays false for it. See `generatedVoice`.
    public static func voiceover(inPostPage html: String) -> PostVoiceover? {
        completedRecording(inPostPage: html, type: "voiceover", requiresVoiceoverFlag: true)
    }

    /// The post's completed automatic narration, which Substack makes for a post whose author recorded nothing
    /// (owner's call, 2026-10-14: a shared post plays it, after the author's voiceover if there is one). Nil for
    /// a paywalled one (status `paywalled`, no audio address), one still processing, or a page that isn't a post.
    public static func generatedVoice(inPostPage html: String) -> PostVoiceover? {
        completedRecording(inPostPage: html, type: "tts", requiresVoiceoverFlag: false)
    }

    private static func completedRecording(inPostPage html: String, type: String, requiresVoiceoverFlag: Bool) -> PostVoiceover? {
        guard let post = post(inPostPage: html),
              post["type"] as? String == "newsletter",
              !requiresVoiceoverFlag || post["has_voiceover"] as? Bool == true,
              let canonicalURL = post["canonical_url"] as? String,
              let postID = post["id"] as? Int,
              let recordings = post["audio_items"] as? [[String: Any]],
              let recording = recordings.first(where: {
                  $0["type"] as? String == type && $0["status"] as? String == "completed"
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
    /// can be told from "the page wasn't read".
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
            return status(generated) == "completed" ? "generated_voice_unreadable" : "generated_voice_\(status(generated))"
        }
        return post["has_voiceover"] as? Bool == true ? "no_recording_listed" : "no_recording"
    }

    /// `window._preloads` as a dictionary, decoded as data (publisher scripts never run). Substack has served it two
    /// ways: as a string literal, `window._preloads = JSON.parse("…")`, and, since October 2026, as a JSON script tag,
    /// `<script type="application/json" id="preloads-json">{…}</script>`, that an inline script parses (#2024).
    private static func preloads(in html: String) -> [String: Any]? {
        let json: Data
        if let literal = firstCapture(#"window\._preloads\s*=\s*JSON\.parse\((\"(?:\\.|[^\"\\])*\")\)"#, in: html),
           let decoded = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)) {
            json = Data(decoded.utf8)
        } else if let tag = firstCapture(#"<script\b[^>]*\bid\s*=\s*(["']?)preloads-json\1(?=[\s/>])[^>]*>([\s\S]*?)</script\s*>"#, group: 2, in: html) {
            json = Data(tag.utf8)
        } else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    }

    private static func firstCapture(_ pattern: String, group: Int = 1, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: group), in: html) else { return nil }
        return String(html[range])
    }

    private static func post(inPostPage html: String) -> [String: Any]? {
        preloads(in: html)?["post"] as? [String: Any]
    }

    /// A followed post (#1616): `entry` with the page's completed voiceover of that same post, else its completed
    /// automatic narration (marked as generated). Nil when the page gives neither, or is another post's.
    public static func confirmedEntry(_ entry: FeedEntry, html: String) -> FeedEntry? {
        let recording: PostVoiceover, generated: Bool
        if let voiceover = voiceover(inPostPage: html) {
            (recording, generated) = (voiceover, false)
        } else if let voice = generatedVoice(inPostPage: html) {
            (recording, generated) = (voice, true)
        } else {
            return nil
        }
        guard recording.canonicalURL == entry.canonicalURL else { return nil }
        var confirmed = entry
        confirmed.publisherNarrationConfirmed = true
        confirmed.publisherNarrationGenerated = generated ? true : nil
        confirmed.audioURL = recording.audioURL
        if let durationMs = recording.durationMs { confirmed.audioDurationMs = durationMs }
        return confirmed
    }

    /// A post shared as a link (#810): the record to keep beside the article imported from it, when the page
    /// has a completed voiceover of that same post, else its completed automatic narration. `finalURL` is where
    /// the page ended up after redirects, since a shared `open.substack.com/pub/<name>/p/<slug>` link redirects
    /// to the post's canonical address.
    public static func publisherAudio(postPage html: String, finalURL: URL, itemId: String) -> PublisherAudio? {
        let recording: (PostVoiceover, String)
        if let voiceover = voiceover(inPostPage: html) {
            recording = (voiceover, PublisherAudioDetector.detectedFromPublisherNarration)
        } else if let generated = generatedVoice(inPostPage: html) {
            recording = (generated, PublisherAudioDetector.detectedFromGeneratedNarration)
        } else {
            return nil
        }
        guard let canonical = URL(string: recording.0.canonicalURL), samePage(canonical, finalURL) else { return nil }
        return PublisherAudio(
            itemId: itemId, audioURL: recording.0.audioURL, durationMs: recording.0.durationMs, detectedFrom: recording.1
        )
    }

    /// `absence(inPostPage:)`, plus `other_post` for a page whose voiceover belongs to a different address
    /// than the one it ended at.
    public static func absence(postPage html: String, finalURL: URL) -> String {
        if let found = voiceover(inPostPage: html) ?? generatedVoice(inPostPage: html), let canonical = URL(string: found.canonicalURL),
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
        page.range(of: Data("window._preloads".utf8)) != nil || page.range(of: Data("preloads-json".utf8)) != nil
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
