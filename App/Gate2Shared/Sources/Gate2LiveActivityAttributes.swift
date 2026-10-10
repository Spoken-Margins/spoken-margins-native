import Foundation

/// Skim's destination as the playback screen and the Lock Screen both say it (#115).
public enum SkimDestinationLabel {
    /// "18:42", or "1:05:09" past an hour.
    public static func time(_ destinationMs: Int) -> String {
        let seconds = max(0, destinationMs / 1_000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The playback screen's button title: "Skim to 18:42" / "Back to 12:05".
    public static func title(destinationMs: Int?, backward: Bool) -> String {
        guard let destinationMs else { return backward ? "Skim Back" : "Skim Forward" }
        return (backward ? "Back to " : "Skim to ") + time(destinationMs)
    }

    /// What VoiceOver reads for a Lock Screen Skim button.
    public static func accessibilityLabel(destinationMs: Int?, backward: Bool) -> String {
        guard let destinationMs else {
            return backward ? "Skim backward by scene summary" : "Skim forward by scene summary"
        }
        return (backward ? "Skim back to " : "Skim forward to ") + time(destinationMs)
    }
}

/// Whether the microphone is really taking in sound while a spoken Margin records (#937). The Live
/// Activity says "REC" only for `capturing`.
public enum Gate2LiveActivityMicrophone: String, Codable, Hashable, Sendable {
    case capturing
    case starting
    case stopped
}

#if canImport(ActivityKit)
import ActivityKit

public enum Gate2LiveActivityNavigationKind: String, Codable, Hashable, Sendable {
    case sourceChapter = "source_chapter"
    case sharedMargin = "shared_margin"
}

public struct Gate2LiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var chapterTitle: String
        public var nextChapterTitle: String?
        public var nextChapterId: String?
        public var nextNavigationKind: Gate2LiveActivityNavigationKind?
        public var status: String
        public var phase: String
        public var progressPercent: Int
        public var isRecording: Bool
        /// Meaningful only while `isRecording`. Older payloads decode as `capturing`.
        public var microphone: Gate2LiveActivityMicrophone
        public var availableCommands: [String]
        public var sharedMarginSenderLabel: String?
        /// Where the Skim buttons land (#115); nil when that Skim isn't offered.
        public var skimForwardDestinationMs: Int?
        public var skimBackwardDestinationMs: Int?

        private enum CodingKeys: String, CodingKey {
            case title
            case chapterTitle
            case nextChapterTitle
            case nextChapterId
            case nextNavigationKind
            case status
            case phase
            case progressPercent
            case isRecording
            case microphone
            case availableCommands
            case sharedMarginSenderLabel
            case skimForwardDestinationMs
            case skimBackwardDestinationMs
        }

        public init(
            title: String,
            chapterTitle: String,
            nextChapterTitle: String? = nil,
            nextChapterId: String? = nil,
            nextNavigationKind: Gate2LiveActivityNavigationKind? = nil,
            status: String,
            phase: String,
            progressPercent: Int,
            isRecording: Bool,
            microphone: Gate2LiveActivityMicrophone = .capturing,
            availableCommands: [String] = [],
            sharedMarginSenderLabel: String? = nil,
            skimForwardDestinationMs: Int? = nil,
            skimBackwardDestinationMs: Int? = nil
        ) {
            self.title = title
            self.chapterTitle = chapterTitle
            self.nextChapterTitle = nextChapterTitle
            self.nextChapterId = nextChapterId
            self.nextNavigationKind = nextNavigationKind
            self.status = status
            self.phase = phase
            self.progressPercent = progressPercent
            self.isRecording = isRecording
            self.microphone = microphone
            self.availableCommands = availableCommands
            self.sharedMarginSenderLabel = sharedMarginSenderLabel
            self.skimForwardDestinationMs = skimForwardDestinationMs
            self.skimBackwardDestinationMs = skimBackwardDestinationMs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            chapterTitle = try container.decode(String.self, forKey: .chapterTitle)
            nextChapterTitle = try container.decodeIfPresent(String.self, forKey: .nextChapterTitle)
            nextChapterId = try container.decodeIfPresent(String.self, forKey: .nextChapterId)
            nextNavigationKind = try container.decodeIfPresent(Gate2LiveActivityNavigationKind.self, forKey: .nextNavigationKind)
            status = try container.decode(String.self, forKey: .status)
            phase = try container.decode(String.self, forKey: .phase)
            progressPercent = try container.decode(Int.self, forKey: .progressPercent)
            isRecording = try container.decode(Bool.self, forKey: .isRecording)
            microphone = try container.decodeIfPresent(Gate2LiveActivityMicrophone.self, forKey: .microphone) ?? .capturing
            availableCommands = try container.decodeIfPresent([String].self, forKey: .availableCommands) ?? []
            sharedMarginSenderLabel = try container.decodeIfPresent(String.self, forKey: .sharedMarginSenderLabel)
            skimForwardDestinationMs = try container.decodeIfPresent(Int.self, forKey: .skimForwardDestinationMs)
            skimBackwardDestinationMs = try container.decodeIfPresent(Int.self, forKey: .skimBackwardDestinationMs)
        }
    }

    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
#endif
