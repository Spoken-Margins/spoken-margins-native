import Foundation
import SessionKit

/// Type III Audio's narrations of LessWrong and EA Forum posts (#3438). Type III Audio told the owner on 2026-11-05
/// that one find call when a listener opens a post, streaming from `dl.type3.audio`, and a link back to the post is
/// fine (docs/decisions.md, 2026-11-05).
///
/// The rules this type keeps:
/// - The call is made for a LessWrong or EA Forum post address and for no other address. `postURL(for:)` is the one
///   gate; anything it refuses never leaves the phone.
/// - The call is Type III's `find`, a GET that only reads. The app never asks Type III to make a narration.
/// - Only the post's address is sent: scheme, host and path. Tracking parameters and fragments are dropped.
/// - Nothing from `dl.type3.audio` is saved. The record keeps the address of the recording to stream.
/// - It runs only on the listener's action (opening, playing or sharing the post). The callers are the same
///   listener-gated entry points the Substack voiceover lookup uses (#2368).
public enum TypeIIIAudioNarration {
    /// Where a recording's record says it came from.
    public static let detectedFrom = "type3_audio_narration"
    public static let findEndpoint = "https://api.type3.audio/narration/find"
    /// A longer address is not a post address.
    public static let maximumAddressLength = 2_048
    public static let maximumResponseBytes = 256 * 1_024

    /// Performs a GET and returns the body and the HTTP status. Any status is returned (404 means "no narration").
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    public enum Outcome: Equatable, Sendable {
        /// The address is not a LessWrong or EA Forum post. Nothing was sent.
        case notCovered
        case failed(String)
        /// Type III answered and has no recording to play. `reason` is a short token for Diagnostics.
        case noNarration(reason: String)
        case found(PublisherAudio)
    }

    // MARK: - Which addresses

    /// The address Type III is asked about for `url`: `https://www.lesswrong.com/posts/<id>[/<slug>]` or
    /// `https://forum.effectivealtruism.org/posts/<id>[/<slug>]`, with the host in lower case and no query,
    /// fragment or trailing slash. Nil for every other address: other hosts and lookalikes, other subdomains, `http`,
    /// a port or sign-in part, another path, an over-long address.
    public static func postURL(for url: URL) -> URL? {
        guard url.absoluteString.count <= maximumAddressLength,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased() else { return nil }
        let canonicalHost: String
        switch host {
        case "lesswrong.com", "www.lesswrong.com": canonicalHost = "www.lesswrong.com"
        case "forum.effectivealtruism.org": canonicalHost = "forum.effectivealtruism.org"
        default: return nil
        }
        // `components.path` is decoded; the encoded path is what is compared and sent.
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.last == "" { segments.removeLast() }
        guard (3...4).contains(segments.count), segments[0].isEmpty, segments[1] == "posts", isPostID(segments[2]) else { return nil }
        // The slug goes into a query string: only the plain characters the forums' slugs use, so `+`, `&`, `%2F` and
        // the like can never change what Type III is asked about.
        if segments.count == 4, !isSlug(segments[3]) { return nil }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = canonicalHost
        canonical.percentEncodedPath = segments.joined(separator: "/")
        return canonical.url
    }

    /// The forums' post ids are 17 letters and digits; a shorter or odder id is not a post.
    private static func isPostID(_ segment: String) -> Bool {
        (6...32).contains(segment.count) && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isSlug(_ segment: String) -> Bool {
        !segment.isEmpty && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.~".contains($0)) }
    }

    /// The `find` request for a post.
    public static func findURL(for postURL: URL) -> URL? {
        var components = URLComponents(string: findEndpoint)
        components?.queryItems = [URLQueryItem(name: "url", value: postURL.absoluteString)]
        return components?.url
    }

    // MARK: - The lookup

    /// Looks for Type III's narration of the post at `url`, with one `find` call and none for an address
    /// `postURL(for:)` refuses. A recording is returned only when it is finished, is of this post, and streams over
    /// HTTPS from a `type3.audio` host.
    public static func find(url: URL, itemId: String, fetch: Fetch) async -> Outcome {
        guard let post = postURL(for: url), let request = findURL(for: post) else { return .notCovered }
        let data: Data, status: Int
        do {
            (data, status) = try await fetch(request)
        } catch {
            return .failed(error.localizedDescription)
        }
        return interpret(data: data, status: status, post: post, itemId: itemId)
    }

    /// Reads a `find` answer. Kept apart from the network so the answers can be tested from fixtures.
    public static func interpret(data: Data, status: Int, post: URL, itemId: String) -> Outcome {
        if status == 404 { return .noNarration(reason: "type3_no_narration") }
        // A busy or failing Type III is tried again after a wait, like a narration still being made. Any other refusal
        // is final for the launch, so a post is not asked about on every open.
        if status == 408 || status == 429 || (500..<600).contains(status) { return .noNarration(reason: "type3_busy") }
        guard (200..<300).contains(status) else { return .noNarration(reason: "type3_http_\(status)") }
        guard data.count <= maximumResponseBytes,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("unreadable_answer")
        }
        let state = token(body["status"])
        guard state == "Succeeded" || state == "Uploaded" else {
            return .noNarration(reason: "type3_\(state.isEmpty ? "unknown" : state.lowercased())")
        }
        // A narration the answer names for another address is not this post's.
        if let source = body["source_url"] as? String, let sourceURL = URL(string: source),
           let sourcePost = postURL(for: sourceURL), sourcePost != post { return .noNarration(reason: "type3_other_post") }
        guard let audio = body["mp3_url"] as? String, let audioURL = URL(string: audio),
              audioURL.scheme?.lowercased() == "https", let host = audioURL.host?.lowercased(),
              host == "type3.audio" || host.hasSuffix(".type3.audio"), audioURL.port == nil, audioURL.user == nil else {
            return .noNarration(reason: "type3_no_audio_address")
        }
        var durationMs: Int?
        if let seconds = (body["duration"] as? Double) ?? (body["duration"] as? Int).map(Double.init), seconds.isFinite, seconds > 0,
           seconds < Double(Int.max / 1_000) { durationMs = Int(seconds * 1_000) }
        return .found(PublisherAudio(itemId: itemId, audioURL: audioURL.absoluteString, durationMs: durationMs, detectedFrom: detectedFrom))
    }

    /// Whether a no-narration reason says Type III has not finished it, so looking again later may find it. A
    /// narration that is `NotStarted`, `Running` or in review is on its way, and a busy Type III (408, 429, 5xx) may recover; `Failed`, `Skipped` and too-long ones
    /// are final for the launch.
    public static func isNotYet(reason: String) -> Bool {
        guard reason.hasPrefix("type3_") else { return false }
        return ["busy", "notstarted", "running", "gettinghtml", "processinghtml", "reviewqueued", "reviewing"]
            .contains(String(reason.dropFirst("type3_".count)))
    }

    /// A status word as a short plain token, since it ends up in Diagnostics.
    private static func token(_ value: Any?) -> String {
        String((value as? String ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(32))
    }
}
