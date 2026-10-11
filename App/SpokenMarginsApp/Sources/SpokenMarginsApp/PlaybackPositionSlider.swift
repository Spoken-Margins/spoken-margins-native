import SessionKit
import SwiftUI
import UIKit

/// Editing belongs to UIKit's accepted touch tracking, not SwiftUI's synthetic
/// editing callbacks, which the device trace shows can reopen after a seek.
struct PlaybackPositionSlider: UIViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void
    var preparedFraction: Double? = nil
    /// Chapters and Margins to draw on the bar (#428). Display only; nil draws the plain slider.
    var barContent: PlaybackBarContent? = nil
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
        slider.preparedFraction = preparedFraction
        slider.barContent = barContent
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
    var preparedFraction: Double? { didSet { if oldValue != preparedFraction { setNeedsLayout() } } }
    private let preparedTrack = CALayer()
    var barContent: PlaybackBarContent? { didSet { if oldValue != barContent { setNeedsLayout() } } }
    private let bar = PlaybackBarRenderer()
    private var systemTrackHidden = false

    override var value: Float { didSet { if barContent != nil { setNeedsLayout() } } }
    override var minimumValue: Float { didSet { if barContent != nil { setNeedsLayout() } } }
    override var maximumValue: Float { didSet { if barContent != nil { setNeedsLayout() } } }

    override func setValue(_ value: Float, animated: Bool) {
        super.setValue(value, animated: animated)
        if barContent != nil { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let track = trackRect(forBounds: bounds)
        let thumb = thumbRect(forBounds: bounds, trackRect: track, value: value)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preparedTrack.isHidden = preparedFraction == nil
        preparedTrack.backgroundColor = UIColor.systemTeal.cgColor
        preparedTrack.frame = CGRect(x: track.minX, y: max(track.maxY, thumb.maxY) + 3, width: track.width * CGFloat(min(1, max(0, preparedFraction ?? 0))), height: 3)
        preparedTrack.cornerRadius = 1.5
        CATransaction.commit()
        layoutBar(track: track)
    }

    /// Paints the chapter segments and Margin diamonds, and hides the system track while the segments stand in for it.
    private func layoutBar(track: CGRect) {
        let geometry = PlaybackBarRenderer.Geometry(
            track: track,
            lower: thumbRect(forBounds: bounds, trackRect: track, value: minimumValue).midX,
            upper: thumbRect(forBounds: bounds, trackRect: track, value: maximumValue).midX,
            thumbX: thumbRect(forBounds: bounds, trackRect: track, value: value).midX,
            scale: max(1, traitCollection.displayScale),
            fill: (minimumTrackTintColor ?? tintColor).resolvedColor(with: traitCollection).cgColor
        )
        let replacesTrack = bar.update(content: barContent, value: Double(value), geometry: geometry)
        guard replacesTrack != systemTrackHidden else { return }
        systemTrackHidden = replacesTrack
        let image = replacesTrack ? Self.clearTrackImage : nil
        setMinimumTrackImage(image, for: .normal)
        setMaximumTrackImage(image, for: .normal)
    }

    /// A transparent track as tall as the segments, so hiding the system track doesn't change the slider's metrics.
    private static let clearTrackImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: PlaybackBarRenderer.trackThickness)).image { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        preparedTrack.name = "prepared-audio-track"
        layer.addSublayer(preparedTrack)
        bar.layer.zPosition = -1
        layer.addSublayer(bar.layer)
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
