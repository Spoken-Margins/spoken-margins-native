/// One reading of a Margin voice's clock, and the two rules the voice pollers apply to it (#993): the voice has
/// sounded once the clock has moved off zero, and it has ended once the clock is within `endTolerance` of the
/// duration. The own-Margin and shared-Margin polls used to write these rules out separately.
public struct MarginVoiceClockReading: Equatable, Sendable {
    /// The poll ends a voice this close to its duration, because the clock of a finished item can stop short of it.
    public static let endTolerance = 0.05

    public let duration: Double
    public let current: Double

    public init(duration: Double, current: Double) {
        self.duration = duration
        self.current = current
    }

    /// The clock is a real, positive time: the voice has played, whatever its file claims. A file that fails to
    /// decode never gets here (#690).
    public var hasSounded: Bool { current.isFinite && current > 0 }

    /// The duration is known and the clock has reached it, within `endTolerance`.
    public var hasReachedEnd: Bool {
        duration.isFinite && duration > 0 && current.isFinite && current >= duration - Self.endTolerance
    }
}
