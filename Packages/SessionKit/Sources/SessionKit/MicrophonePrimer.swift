import Foundation

/// #783: one plain line before iOS's own microphone prompt, the first time a listener records a
/// spoken Margin. It shows only while iOS hasn't asked yet; once the listener has allowed or denied
/// the microphone it never appears again. Continue goes on to the system prompt; dismissing the line
/// cancels that Margin, and the next try shows it again while the answer is still undetermined.
public struct MicrophonePrimer: Equatable, Sendable {
    public static let message = "To record your Margin, Spoken Margins needs the microphone. Recordings stay on your phone."

    /// The Margin waiting on Continue, if the line is on screen.
    public private(set) var pendingCaptureID: UUID?

    public init() {}

    public var isShowing: Bool { pendingCaptureID != nil }

    public static func isShown(for status: PermissionPromptStatus) -> Bool {
        status == .undetermined
    }

    /// Returns true when this Margin must wait for Continue before the system prompt.
    public mutating func holds(captureID: UUID, status: PermissionPromptStatus) -> Bool {
        guard Self.isShown(for: status) else {
            pendingCaptureID = nil
            return false
        }
        pendingCaptureID = captureID
        return true
    }

    /// The Margin to go on with, once: a second Continue tap returns nil.
    public mutating func continueTapped() -> UUID? {
        defer { pendingCaptureID = nil }
        return pendingCaptureID
    }

    public mutating func cancel() {
        pendingCaptureID = nil
    }
}
