import Foundation
import SessionKit

/// The Send sheet's starting point (D4, #785): which Margins go, in which voice, under whose
/// name, and one plain line saying what leaves the phone.
///
/// A value built from the candidate Margins, so the sheet only shows it. Nothing here changes
/// the packet: the moments become today's `ReviewedInterjectionSelection`s, and Build 29 reads
/// the result.
public struct ShareDraft: Equatable, Sendable {
    /// Where the listener tapped Share.
    public enum Scope: Equatable, Sendable {
        /// A Margin's Share: just that one.
        case margin(id: String)
        /// An item's Share: the starred Margins if any are starred, otherwise all of them.
        case item
    }

    /// Which Margins the sheet offers, as its Moments row names them.
    public enum Selection: Equatable, Sendable {
        case thisOne
        case starred
        case all
    }

    /// The version of a Margin that goes out.
    public enum Voice: Equatable, Sendable {
        case cleaned
        case original
        case textOnly
    }

    /// The recordings a Margin has on the phone right now.
    public struct Audio: Equatable, Sendable {
        public var hasOriginal: Bool
        public var hasCleaned: Bool

        public static let none = Audio(hasOriginal: false, hasCleaned: false)
        public static let original = Audio(hasOriginal: true, hasCleaned: false)
        public static let originalAndCleaned = Audio(hasOriginal: true, hasCleaned: true)

        public init(hasOriginal: Bool, hasCleaned: Bool) {
            self.hasOriginal = hasOriginal
            self.hasCleaned = hasCleaned
        }
    }

    public struct Moment: Equatable, Sendable, Identifiable {
        public var marginID: String
        public var voice: Voice
        /// The bounded source text either side, which travels as the Margin's quote.
        public var quote: BoundedAnchorContext

        public var id: String { marginID }
        public var hasQuote: Bool { !quote.before.isEmpty || !quote.after.isEmpty }
    }

    public var selection: Selection
    /// The Margins that go, in the order they were given.
    public var moments: [Moment]
    /// The remembered sender name, or nil when there is none yet.
    public var senderName: String?
    /// The listener's link to the item, or nil when there is none or it carries a private-feed secret.
    public var itemLink: String?
    /// Whether matching data (the podcast's acoustic anchor evidence) exists for these Margins.
    public var hasMatchingData: Bool
    /// Whether it goes. On by default, and one tap from off on the Includes page.
    public var includesMatchingData: Bool

    /// No name is saved, so the sheet asks for one once.
    public var needsSenderName: Bool { senderName == nil }

    /// Builds the defaults.
    /// - Parameters:
    ///   - candidates: the item's Margins. Only active Margins on the item itself can go.
    ///   - audio: the recordings on the phone per Margin id. A Margin missing here is text only.
    ///   - savedSenderName: `sharingSenderDisplayLabel`.
    ///   - itemLink: the link the item was opened from, checked by `ShareableLinkPolicy`.
    ///   - hasMatchingData: whether acoustic anchor evidence was captured for these Margins.
    public init(
        scope: Scope,
        candidates: [Interjection],
        audio: [String: Audio] = [:],
        savedSenderName: String? = nil,
        itemLink: String? = nil,
        hasMatchingData: Bool = false
    ) {
        let eligible = candidates.filter { $0.status == "active" && $0.targetType == .item }
        let chosen: [Interjection]
        switch scope {
        case .margin(let id):
            selection = .thisOne
            chosen = eligible.filter { $0.id == id }
        case .item:
            let starred = eligible.filter { $0.isStarredForSharing == true }
            selection = starred.isEmpty ? .all : .starred
            chosen = starred.isEmpty ? eligible : starred
        }
        moments = chosen.map { margin in
            Moment(
                marginID: margin.id,
                voice: Self.defaultVoice(for: audio[margin.id] ?? .none),
                quote: ExcerptCapRule.select(
                    before: margin.anchor.anchorBefore,
                    after: margin.anchor.anchorAfter,
                    commentLength: ExcerptCapRule.commentLength(transcript: SharedMarginTextRequirement.initialReviewedText(for: margin))
                )
            )
        }
        let name = savedSenderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        senderName = (name?.isEmpty ?? true) ? nil : name
        self.itemLink = ShareableLinkPolicy.shareableLink(itemLink)
        self.hasMatchingData = hasMatchingData
        includesMatchingData = hasMatchingData
    }

    /// Cleaned when a cleaned version exists, otherwise the original, and text only without audio.
    public static func defaultVoice(for audio: Audio) -> Voice {
        if audio.hasCleaned { return .cleaned }
        if audio.hasOriginal { return .original }
        return .textOnly
    }

    /// The Includes line: "Your voice, 3 short quotes, matching data". Names only what goes.
    public var includesLine: String {
        guard !moments.isEmpty else { return "Nothing yet" }
        var parts = [moments.contains { $0.voice != .textOnly } ? "Your voice" : "Your words"]
        let quotes = moments.filter(\.hasQuote).count
        if quotes > 0 { parts.append(quotes == 1 ? "1 short quote" : "\(quotes) short quotes") }
        if hasMatchingData, includesMatchingData { parts.append("matching data") }
        return parts.joined(separator: ", ")
    }
}

extension ShareDraft {
    /// The files the app holds for one Margin when the listener taps Send.
    public struct Files: Equatable, Sendable {
        public var originalURL: URL?
        public var originalDurationMs: Int?
        public var cleanedURL: URL?

        public init(originalURL: URL? = nil, originalDurationMs: Int? = nil, cleanedURL: URL? = nil) {
            self.originalURL = originalURL
            self.originalDurationMs = originalDurationMs
            self.cleanedURL = cleanedURL
        }
    }

    /// Settles each moment's voice to what its files can send, so the Includes line and the
    /// packet agree. Call it before showing the Includes line or building. A Margin missing from
    /// `files` has no files.
    public mutating func settleVoices(_ files: [String: Files]) {
        for index in moments.indices {
            moments[index].voice = moments[index].effectiveVoice(files[moments[index].marginID] ?? Files())
        }
    }
}

extension ShareDraft.Moment {
    /// The voice these files can send. A voice whose file is missing falls back to the next one,
    /// as the default would.
    public func effectiveVoice(_ files: ShareDraft.Files) -> ShareDraft.Voice {
        if voice == .cleaned, files.cleanedURL != nil { return .cleaned }
        if voice != .textOnly, files.originalURL != nil, files.originalDurationMs != nil { return .original }
        return .textOnly
    }

    /// The builder's representation for this moment's voice, from the files the app holds.
    public func representation(_ files: ShareDraft.Files) -> ReviewedRepresentationSelection {
        switch effectiveVoice(files) {
        case .cleaned:
            if let url = files.cleanedURL { return .cleanedAudio(sourceURL: url) }
        case .original:
            if let url = files.originalURL, let ms = files.originalDurationMs { return .originalAudio(sourceURL: url, durationMs: ms) }
        case .textOnly:
            break
        }
        return .textOnly
    }

    public func representation(originalURL: URL?, originalDurationMs: Int?, cleanedURL: URL?) -> ReviewedRepresentationSelection {
        representation(ShareDraft.Files(originalURL: originalURL, originalDurationMs: originalDurationMs, cleanedURL: cleanedURL))
    }
}
