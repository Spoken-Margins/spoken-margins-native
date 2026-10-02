import Foundation
import SessionKit

/// Substack explicitly labels the current post's narration. RSS enclosure URLs and transcript
/// lengths do not carry that distinction. Decode data only; never execute publisher scripts.
public enum PublisherNarrationEvidence {
    public static func confirmedEntry(_ entry: FeedEntry, html: String) -> FeedEntry? {
        let pattern = #"window\._preloads\s*=\s*JSON\.parse\((\"(?:\\.|[^\"\\])*\")\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html),
              let json = try? JSONDecoder().decode(String.self, from: Data(html[range].utf8)),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let post = root["post"] as? [String: Any],
              post["type"] as? String == "newsletter", post["has_voiceover"] as? Bool == true,
              post["canonical_url"] as? String == entry.canonicalURL,
              let postID = post["id"] as? Int,
              let recordings = post["audio_items"] as? [[String: Any]],
              let recording = recordings.first(where: {
                  $0["type"] as? String == "voiceover" && $0["status"] as? String == "completed"
                      && $0["post_id"] as? Int == postID
              }),
              let audio = recording["audio_url"] as? String,
              let url = URL(string: audio), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        var confirmed = entry
        confirmed.publisherNarrationConfirmed = true
        confirmed.audioURL = audio
        if let seconds = recording["duration"] as? Double, seconds.isFinite, seconds >= 0,
           seconds < Double(Int.max / 1_000) { confirmed.audioDurationMs = Int(seconds * 1_000) }
        return confirmed
    }
}
