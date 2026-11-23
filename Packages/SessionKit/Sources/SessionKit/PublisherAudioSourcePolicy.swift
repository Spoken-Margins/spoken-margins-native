import Foundation

/// Where a publisher recording may come from, and why the app may stream it (#4640).
///
/// Every new `publisher_audio` record passes `PublisherAudioAdmission.admit(_:)`, which checks it against its source's
/// rule here. A source joins this list only with a permission recorded in `docs/decisions.md`; `docs/publisher-audio.md`
/// says how. The raw values are stored strings: never change one.
public enum PublisherAudioSource: String, CaseIterable, Sendable {
    /// Legacy: records that early builds saved for Substack posts (`Build29DatabaseFixtureTests`).
    case feedEnclosure = "feed_enclosure"
    case substackPostVoiceover = "substack_post_voiceover"
    case substackPostGeneratedVoice = "substack_post_generated_voice"
    case typeIIIAudioNarration = "type3_audio_narration"
    /// The article's own public feed lists this page with an audio enclosure.
    case articleFeedEnclosure = "article_feed_enclosure"

    public enum HostRule: Equatable, Sendable {
        case anyHTTPS
        /// The host or any of its subdomains.
        case host(String)

        func allows(_ host: String) -> Bool {
            switch self {
            case .anyHTTPS: return true
            case .host(let allowed): return host == allowed || host.hasSuffix("." + allowed)
            }
        }
    }

    /// Why the app may stream this source's audio, with the date of the decision behind it.
    public var rightsBasis: String {
        switch self {
        case .feedEnclosure, .substackPostVoiceover, .substackPostGeneratedVoice:
            return "Substack: the publisher's own voiceover, played if it is available and allowed (decisions, 2026-10-14)."
        case .typeIIIAudioNarration:
            return "Type III Audio: permission by email to stream from dl.type3.audio with a link back (decisions, 2026-11-05)."
        case .articleFeedEnclosure:
            return "The publisher listed this audio in its public feed for podcast apps, the basis on which every podcast plays (decisions, 2026-11-22, #4640)."
        }
    }

    public var audioHostRule: HostRule {
        switch self {
        case .typeIIIAudioNarration: return .host("type3.audio")
        default: return .anyHTTPS
        }
    }

    /// Whether an address carrying signing or expiry parameters is refused. Substack's shipped records keep their
    /// `token=` addresses, so only the generic route refuses them.
    public var refusesSignedURLs: Bool { self == .articleFeedEnclosure }
}

/// Why a candidate recording was not saved. The raw value goes to Diagnostics as `refused:<token>`.
public enum PublisherAudioRefusal: String, Error, Equatable, Sendable {
    case unknownSource = "unknown_source"
    case notHTTPS = "not_https"
    case userinfo
    case port
    case hostNotAllowed = "host_not_allowed"
    case signedURL = "signed_url"
}

/// The one gate every new publisher-audio record passes (#4640).
public enum PublisherAudioAdmission {
    /// Query keys that mark an address as signed or expiring, compared case-insensitively.
    public static let signedQueryKeys: Set<String> = [
        "expires", "x-amz-expires", "x-amz-signature", "signature", "policy", "key-pair-id", "token", "exp", "hdnts", "sig",
    ]

    public static func admit(_ audio: PublisherAudio) -> Result<PublisherAudio, PublisherAudioRefusal> {
        guard let source = PublisherAudioSource(rawValue: audio.detectedFrom) else { return .failure(.unknownSource) }
        guard let components = URLComponents(string: audio.audioURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return .failure(.notHTTPS) }
        if components.user != nil || components.password != nil { return .failure(.userinfo) }
        if components.port != nil { return .failure(.port) }
        guard source.audioHostRule.allows(host) else { return .failure(.hostNotAllowed) }
        if source.refusesSignedURLs, isSigned(components) { return .failure(.signedURL) }
        return .success(audio)
    }

    /// Whether the address carries a signing or expiry query key.
    public static func isSigned(_ components: URLComponents) -> Bool {
        (components.queryItems ?? []).contains { signedQueryKeys.contains($0.name.lowercased()) }
    }

    public static func isSigned(_ address: String) -> Bool {
        URLComponents(string: address).map(isSigned) ?? false
    }
}

/// Whether a recording's size fits a narration of the article, so the app never transcribes an hour-long episode for
/// a short page (#4640). Narration runs at about 150 words a minute.
public enum PublisherAudioNarrationFit {
    public static let wordsPerMinute = 150.0
    public static let shortestFactor = 0.4
    public static let longestFactor = 2.0
    public static let maximumBytes = 150 * 1_024 * 1_024

    public enum Verdict: String, Equatable, Sendable {
        case fits
        case tooLong = "too_long"
        case tooShort = "too_short"
    }

    /// With a duration and a word count, the duration must fall between 0.4× and 2× the reading time. Otherwise a
    /// length over 0 fits up to 150 MB. With neither, nil: no verdict.
    public static func verdict(durationMs: Int?, lengthBytes: Int?, wordCount: Int?) -> Verdict? {
        if let durationMs, durationMs > 0, let wordCount, wordCount > 0 {
            let readingMs = Double(wordCount) / wordsPerMinute * 60_000
            let duration = Double(durationMs)
            if duration < readingMs * shortestFactor { return .tooShort }
            if duration > readingMs * longestFactor { return .tooLong }
            return .fits
        }
        if let lengthBytes, lengthBytes > 0 {
            return lengthBytes <= maximumBytes ? .fits : .tooLong
        }
        return nil
    }
}
