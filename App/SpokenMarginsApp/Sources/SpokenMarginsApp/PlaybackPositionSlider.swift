import SwiftUI
import UIKit

/// Editing belongs to UIKit's accepted touch tracking, not SwiftUI's synthetic
/// editing callbacks, which the device trace shows can reopen after a seek.
struct PlaybackPositionSlider: UIViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> TrackingPlaybackSlider {
        let slider = TrackingPlaybackSlider()
        slider.minimumTrackTintColor = UIColor(AppColors.accent)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateUIView(_ slider: TrackingPlaybackSlider, context: Context) {
        slider.onValue = { value = $0 }
        slider.onEditing = onEditingChanged
        slider.isEnabled = isEnabled
        if slider.minimumValue != Float(range.lowerBound) {
            slider.minimumValue = Float(range.lowerBound)
        }
        if slider.maximumValue != Float(range.upperBound) {
            slider.maximumValue = Float(range.upperBound)
        }
        if !slider.isTracking, !slider.gestureActive {
            slider.setValue(Float(value), animated: false)
        }
    }

    static func dismantleUIView(_ slider: TrackingPlaybackSlider, coordinator: ()) {
        slider.onValue = nil
        slider.onEditing = nil
    }
}

final class TrackingPlaybackSlider: UISlider {
    var onValue: ((Double) -> Void)?
    var onEditing: ((Bool) -> Void)?
    private(set) var gestureActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        let touch = UILongPressGestureRecognizer(target: self, action: #selector(trackTouch(_:)))
        touch.minimumPressDuration = 0
        touch.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(touch)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Own one touch lifecycle instead of combining UISlider's internally
    // synthesized tracking callbacks with SwiftUI publication during a seek.
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { false }

    @objc private func trackTouch(_ touch: UILongPressGestureRecognizer) {
        guard isEnabled else { return }
        switch touch.state {
        case .began:
            gestureActive = true
            isHighlighted = true
            onEditing?(true)
            updatePosition(at: touch.location(in: self))
        case .changed:
            guard gestureActive else { return }
            updatePosition(at: touch.location(in: self))
        case .ended:
            guard gestureActive else { return }
            updatePosition(at: touch.location(in: self))
            finishGesture()
        case .cancelled, .failed:
            finishGesture()
        default:
            break
        }
    }

    private func updatePosition(at point: CGPoint) {
        let track = trackRect(forBounds: bounds)
        let lower = thumbRect(forBounds: bounds, trackRect: track, value: minimumValue).midX
        let upper = thumbRect(forBounds: bounds, trackRect: track, value: maximumValue).midX
        guard upper > lower else { return }
        let fraction = min(1, max(0, (point.x - lower) / (upper - lower)))
        setValue(minimumValue + Float(fraction) * (maximumValue - minimumValue), animated: false)
        onValue?(Double(value))
    }

    private func finishGesture() {
        guard gestureActive else { return }
        gestureActive = false
        isHighlighted = false
        onEditing?(false)
    }

    override func accessibilityIncrement() { accessibilityStep(1) }
    override func accessibilityDecrement() { accessibilityStep(-1) }
    private func accessibilityStep(_ direction: Float) {
        guard isEnabled else { return }
        onEditing?(true)
        value = min(maximumValue, max(minimumValue, value + direction * (maximumValue - minimumValue) * 0.01))
        onValue?(Double(value))
        onEditing?(false)
    }
}
