import Foundation

/// Spoken positions for the same stacks that the playback bar draws. No seeking or playback policy lives here.
public enum PlaybackBarAccessibility {
    public enum PositionUnit: Sendable, Equatable { case seconds, characters }

    public static func label(for stack: PlaybackBarLayout.Stack, length: Double, unit: PositionUnit) -> String {
        stack.accessibilityLabel(at: positionText(stack.front.position, length: length, unit: unit))
    }

    public static func positionText(_ position: Double, length: Double, unit: PositionUnit) -> String {
        let validLength = length.isFinite && length > 0 ? length : 0
        let bounded = position.isFinite ? min(validLength, max(0, position)) : 0
        switch unit {
        case .characters:
            let percent = validLength > 0 ? Int((bounded / validLength * 100).rounded()) : 0
            return "\(percent) percent"
        case .seconds:
            let seconds = bounded.rounded(.down)
            let remainder = seconds.truncatingRemainder(dividingBy: 3_600)
            let minutes = Int(remainder / 60)
            let finalSeconds = Int(remainder.truncatingRemainder(dividingBy: 60))
            if seconds >= 3_600 {
                // Format the hours as a Double so malformed huge positions cannot overflow an Int conversion.
                return String(format: "%.0f:%02d:%02d", (seconds / 3_600).rounded(.down), minutes, finalSeconds)
            }
            return String(format: "%d:%02d", minutes, finalSeconds)
        }
    }
}
