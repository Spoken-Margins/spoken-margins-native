import Foundation

/// The daily Substack format canary (#2027): what a live post page plainly holds, what the app's parser and
/// lookup made of it, and the verdict. The network side is in the `substack-canary` executable; this part is
/// pure, so its rules are host-tested. #2024 is the case it exists for: Substack moved `window._preloads` into a
/// JSON script tag, and the app's parser found no publisher voice on any Substack page, silently.
public enum SubstackCanary {
    /// One completed audio item as the raw page text shows it.
    public struct RawAudioItem: Equatable, Sendable {
        public let type: String
        public let postID: Int?

        public init(type: String, postID: Int?) {
            self.type = type
            self.postID = postID
        }
    }

    /// What a post page plainly says, read without the app's parser: completed audio items with an https
    /// address anywhere in the page, whether it escapes its JSON inside a string literal (Substack's old
    /// `JSON.parse("…")`) or not (the `preloads-json` tag). A different reading from the parser's on purpose, so
    /// a change that breaks the parser doesn't also blind this check.
    public struct RawPage: Equatable, Sendable {
        public let completedItems: [RawAudioItem]
        /// Substack serves its scripts and images from substackcdn.com. A page without it is a block page or a
        /// challenge, not a post, and isn't evidence either way.
        public let isSubstackPage: Bool

        public init(html: String) {
            isSubstackPage = html.contains("substackcdn.com")
            let text = html.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\/", with: "/")
            var items: [RawAudioItem] = []
            for list in Self.matches(#""audio_items"\s*:\s*\[([^\]]*)\]"#, in: text) {
                for object in Self.matches(#"\{([^{}]*)\}"#, in: list) {
                    guard Self.first(#""status"\s*:\s*"completed""#, in: object) != nil,
                          Self.first(#""audio_url"\s*:\s*"https://"#, in: object) != nil else { continue }
                    let type = Self.first(#""type"\s*:\s*"([A-Za-z_]+)""#, in: object) ?? "unknown"
                    let postID = Self.first(#""post_id"\s*:\s*(\d+)"#, in: object).flatMap { Int($0) }
                    items.append(RawAudioItem(type: type, postID: postID))
                }
            }
            completedItems = items
        }

        private static func matches(_ pattern: String, in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }

        private static func first(_ pattern: String, in text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
            let group = match.numberOfRanges > 1 ? 1 : 0
            return Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    /// What the app made of one post.
    public struct AppReading: Equatable, Sendable {
        /// `voiceover` or `generated_voice` when `PublisherNarrationEvidence` read one from the page, else nil.
        public let parserVoice: String?
        /// `PublisherNarrationEvidence.absence(inPostPage:)`: why the parser found none.
        public let absence: String
        /// `voiceover` or `generated_voice` when the app's whole lookup (`publisherAudioEntry`) kept one, else nil.
        public let appVoice: String?
        /// The feed entry's word count, which gates the app's lookup.
        public let bodyWordCount: Int?
        /// The feed entry's platform, which gates the app's lookup (`substack`).
        public let publisherPlatform: String?

        public init(parserVoice: String?, absence: String, appVoice: String?, bodyWordCount: Int?, publisherPlatform: String?) {
            self.parserVoice = parserVoice
            self.absence = absence
            self.appVoice = appVoice
            self.bodyWordCount = bodyWordCount
            self.publisherPlatform = publisherPlatform
        }
    }

    public enum PostVerdict: Equatable, Sendable {
        /// The app kept the publisher's voice.
        case voice(String)
        /// The page says the post has no voice the app should play (paywalled, still processing, none made).
        case noneOffered(String)
        /// The page holds a voice, or post data, the app's parser didn't read: the #2024 class.
        case parserMissed(String)
        /// The parser read a voice, but the app's lookup dropped it (a gate or the address check).
        case appDropped(String)
        /// The page couldn't be read (network, block page). Not evidence about the parser.
        case couldNotCheck(String)

        public var isFailure: Bool {
            switch self {
            case .parserMissed, .appDropped: true
            default: false
            }
        }
    }

    /// Absence tokens the parser may honestly give while the page holds a completed audio item: an author's
    /// voiceover with Substack's flag off, and a podcast post (its audio is the episode, not narration).
    static let honestAbsencesBesideCompletedAudio: Set<String> = ["voiceover_flag_off", "podcast_post"]

    public static func verdict(raw: RawPage, app: AppReading, minimumBodyWords: Int) -> PostVerdict {
        if let voice = app.appVoice { return .voice(voice) }
        if let voice = app.parserVoice {
            if (app.bodyWordCount ?? 0) < minimumBodyWords {
                return .noneOffered("short_post:\(app.bodyWordCount.map(String.init) ?? "unknown")_words")
            }
            return .appDropped("parser read a \(voice) but the app's lookup kept none "
                + "(platform \(app.publisherPlatform ?? "none"), \(app.bodyWordCount.map(String.init) ?? "unknown") words)")
        }
        guard raw.isSubstackPage else { return .couldNotCheck("not a Substack page (blocked or a challenge page)") }
        let held = raw.completedItems.map(\.type)
        let heldText = held.isEmpty ? "no completed audio item" : "a completed \(Set(held).sorted().joined(separator: " and ")) item"
        if app.absence == "no_preloads" || app.absence == "no_post" {
            return .parserMissed("the parser read no post data from a Substack page (\(app.absence)); the page holds \(heldText)")
        }
        if !held.isEmpty, !honestAbsencesBesideCompletedAudio.contains(app.absence) {
            return .parserMissed("the page holds \(heldText) but the parser says \(app.absence)")
        }
        return .noneOffered(app.absence)
    }

    public enum FeedVerdict: Equatable, Sendable {
        case voice
        case noneOffered
        case failed
        case couldNotCheck
    }

    /// A feed fails when any checked post does; passes on a voice; passes as "none offered" when every page it
    /// could read honestly said so; and is "could not check" when no page could be read.
    public static func feedVerdict(_ posts: [PostVerdict]) -> FeedVerdict {
        if posts.contains(where: \.isFailure) { return .failed }
        if posts.contains(where: { if case .voice = $0 { true } else { false } }) { return .voice }
        if posts.contains(where: { if case .noneOffered = $0 { true } else { false } }) { return .noneOffered }
        return .couldNotCheck
    }

    /// The run's exit status: 0 passed; 1 the parser missed something, or no feed gave a voice although every
    /// feed was read (these feeds usually have one, so the audio went somewhere neither reading looks); 3 no
    /// voice and at least one feed couldn't be read, which is not evidence about the parser; 5 no feed could be
    /// checked at all (or there were none), so the run tested nothing and must not look green (#2596).
    public static let nothingCheckedStatus: Int32 = 5

    public static func exitStatus(_ feeds: [FeedVerdict]) -> Int32 {
        if feeds.contains(.failed) { return 1 }
        if feeds.allSatisfy({ $0 == .couldNotCheck }) { return nothingCheckedStatus }
        if feeds.contains(.voice) { return 0 }
        return feeds.contains(.couldNotCheck) ? 3 : 1
    }
}
