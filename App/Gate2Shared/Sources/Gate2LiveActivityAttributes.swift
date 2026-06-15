import Foundation

#if canImport(ActivityKit)
import ActivityKit

public struct Gate2LiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var chapterTitle: String
        public var status: String
        public var phase: String
        public var progressPercent: Int
        public var isRecording: Bool

        public init(
            title: String,
            chapterTitle: String,
            status: String,
            phase: String,
            progressPercent: Int,
            isRecording: Bool
        ) {
            self.title = title
            self.chapterTitle = chapterTitle
            self.status = status
            self.phase = phase
            self.progressPercent = progressPercent
            self.isRecording = isRecording
        }
    }

    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
#endif
