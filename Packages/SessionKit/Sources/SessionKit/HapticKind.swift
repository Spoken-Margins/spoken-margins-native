import Foundation

/// The small taps that tell a listener, without looking, that something happened (#1978).
///
/// Four kinds, so the same few feelings mean the same thing everywhere: `started` is the acknowledgement of a tap
/// that begins something, `saved` is a thing kept, `warning` is a thing kept or tried with a caveat or a miss, and
/// `ended` is a quiet stop (a cancel, the sleep timer). Nothing here is continuous: each is a single tap.
public enum HapticKind: String, CaseIterable, Equatable, Sendable {
    case started
    case saved
    case warning
    case ended
}

/// Where a haptic goes. The app's sink plays it on the device; a test's sink records it.
@MainActor
public protocol HapticFeedbackSink: AnyObject {
    func play(_ kind: HapticKind)
}
