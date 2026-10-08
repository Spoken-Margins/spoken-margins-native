import Foundation

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
            sharedMarginSenderLabel: String? = nil
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
        }
    }

    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
#endif
