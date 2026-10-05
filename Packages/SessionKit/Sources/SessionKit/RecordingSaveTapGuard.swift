import Foundation

/// Whether a tap on the recording screen's Save & resume counts (#148). A quick double tap on Add a Margin can land
/// its second tap on Save as the recording screen appears, which would save an empty Margin. Taps inside a short
/// window after the screen appears are ignored. The window is one constant so it can be tuned on the phone; the
/// owner accepted 0.5 s to start (2026-09-30).
public struct RecordingSaveTapGuard: Equatable, Sendable {
    public static let window: TimeInterval = 0.5

    public let appearedAt: Date

    public init(appearedAt: Date) {
        self.appearedAt = appearedAt
    }

    public func accepts(tapAt date: Date) -> Bool {
        date.timeIntervalSince(appearedAt) >= Self.window
    }
}
