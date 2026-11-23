import Foundation

/// The words that say whose audio is reading an article (#4640): the line under the title on the Now pane, and the
/// "Reading voice" row in Listening options. Pure, so every string is host-tested.
public enum PublisherAudioAttribution {
    public enum VoiceRowButton: Equatable, Sendable {
        case useAppVoice
        case playPublisherAudio

        public var label: String {
            switch self {
            case .useAppVoice: return "Use the App's Voice"
            case .playPublisherAudio: return "Play Publisher's Audio"
            }
        }

        public var systemImage: String {
            switch self {
            case .useAppVoice: return "waveform"
            case .playPublisherAudio: return "person.wave.2"
            }
        }
    }

    public struct VoiceRow: Equatable, Sendable {
        public let title: String
        public let value: String
        public let subtitle: String
        public let button: VoiceRowButton
    }

    /// The site named in the line: the article's host, lower-cased, without a leading `www.`. Nil with no usable link.
    public static func siteName(fromOriginalLink link: String?) -> String? {
        guard let link, let host = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The line under the title while the publisher's audio reads, by the record's `detectedFrom`; nil for the app's
    /// voice or a source this build doesn't know.
    public static func headerLine(source: String?, siteHost: String?) -> String? {
        guard let source = source.flatMap(PublisherAudioSource.init(rawValue:)) else { return nil }
        switch source {
        case .typeIIIAudioNarration:
            return "Narration by Type III Audio"
        case .feedEnclosure, .substackPostVoiceover, .substackPostGeneratedVoice, .articleFeedEnclosure:
            guard let site = siteHost.map(cleanHost), !site.isEmpty else { return "Publisher's audio" }
            return "Publisher's audio · \(site)"
        }
    }

    /// The Reading voice row. `playingSource` is the recording reading now (nil: the app's voice reads). The row shows
    /// state A while the recording reads, state B when this item has a recording with a ready map that isn't reading
    /// (the listener chose the app's voice, or the stream failed), and is hidden otherwise.
    public static func voiceRow(playingSource: String?, recordSource: String?, siteHost: String?, hasReadyMap: Bool) -> VoiceRow? {
        if let playingSource, let value = headerLine(source: playingSource, siteHost: siteHost) {
            return VoiceRow(title: "Reading voice", value: value,
                            subtitle: "Your Margins stay on the article's words.", button: .useAppVoice)
        }
        guard hasReadyMap, let recordSource, headerLine(source: recordSource, siteHost: siteHost) != nil else { return nil }
        return VoiceRow(title: "Reading voice", value: "The app's voice",
                        subtitle: "This article also has the publisher's audio.", button: .playPublisherAudio)
    }

    private static func cleanHost(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }
}
