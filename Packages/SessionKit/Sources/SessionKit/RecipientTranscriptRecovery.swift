import Foundation

/// Private, local recovery state. This is deliberately not part of a share
/// package or the source transcript used for an authored Listening Map.
public struct RecipientTranscriptRecoveryJob: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Window: Codable, Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int
        public var timeline: TranscriptTimeline?

        public init(startMs: Int, endMs: Int, timeline: TranscriptTimeline? = nil) {
            self.startMs = startMs
            self.endMs = endMs
            self.timeline = timeline
        }
    }

    public enum Status: String, Codable, Sendable {
        case pending, suspended, complete, budgetExhausted
    }

    public let id: String
    public let itemId: String
    public let editionSHA256: String
    public let version: Int
    public let durationMs: Int
    public let localSourcePath: String
    public var windows: [Window]
    public var status: Status
    public var failureReason: String?

    public init(itemId: String, editionSHA256: String, durationMs: Int,
                localSourcePath: String, windows: [Window]) {
        id = UUID().uuidString
        self.itemId = itemId
        self.editionSHA256 = editionSHA256
        version = Self.currentVersion
        self.durationMs = durationMs
        self.localSourcePath = localSourcePath
        self.windows = windows
        status = .pending
    }

    public func matches(editionSHA256: String, durationMs: Int) -> Bool {
        version == Self.currentVersion && self.editionSHA256 == editionSHA256
            && self.durationMs == durationMs && isValid
    }

    /// Validate persisted bounds before completed work can count as coverage.
    public var isValid: Bool {
        version == Self.currentVersion && !itemId.isEmpty && !id.isEmpty
            && editionSHA256.count == 64 && editionSHA256.allSatisfy { $0.isHexDigit }
            && durationMs > 0 && !windows.isEmpty && windows.count <= 44
            && windows.allSatisfy { window in
                window.startMs >= 0 && window.endMs > window.startMs
                    && window.endMs <= durationMs
            }
    }
}
