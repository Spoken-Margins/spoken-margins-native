import Foundation

/// The Settings "Import Inbox" row's trailing value, from counts the model already holds (#4781).
/// Failed shares need the listener; waiting links import on their own once the connection is back.
public struct ImportInboxSummary: Equatable, Sendable {
    public let failedCount: Int
    public let waitingCount: Int

    /// Counts below zero are treated as zero.
    public init(failedCount: Int, waitingCount: Int) {
        self.failedCount = max(0, failedCount)
        self.waitingCount = max(0, waitingCount)
    }

    /// True when a failed share waits for Retry or Delete.
    public var needsAttention: Bool { failedCount > 0 }

    /// "2 failed", "3 waiting", "1 failed · 1 waiting", or nil when the inbox is empty.
    public var trailingText: String? {
        let parts = [
            failedCount > 0 ? "\(failedCount) failed" : nil,
            waitingCount > 0 ? "\(waitingCount) waiting" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A warning triangle when anything failed; otherwise `wifi.slash` while links wait; nil when empty.
    public var symbolName: String? {
        if failedCount > 0 { return "exclamationmark.triangle" }
        if waitingCount > 0 { return "wifi.slash" }
        return nil
    }

    /// The VoiceOver value: "1 failed share, 3 links waiting for a connection", or "Empty".
    public var accessibilityValue: String {
        let parts = [
            failedCount > 0 ? "\(failedCount) failed share\(failedCount == 1 ? "" : "s")" : nil,
            PendingHandoffRetryPolicy.waitingLine(count: waitingCount),
        ].compactMap { $0 }
        return parts.isEmpty ? "Empty" : parts.joined(separator: ", ")
    }
}
