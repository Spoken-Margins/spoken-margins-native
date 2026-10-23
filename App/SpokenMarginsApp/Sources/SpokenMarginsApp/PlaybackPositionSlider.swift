import SessionKit
import SwiftUI
import UIKit

/// Editing belongs to UIKit's accepted touch tracking, not SwiftUI's synthetic
/// editing callbacks, which the device trace shows can reopen after a seek.
struct PlaybackPositionSlider: UIViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void
    /// A touch that slid far off the bar and lifted there (#1930). The position is back where it was; no seek.
    /// Left nil, a cancel ends editing the usual way, with the value restored.
    var onCancelled: (() -> Void)? = nil
    var preparedFraction: Double? = nil
    /// Chapters and Margins to draw on the bar (#428). Display only; nil draws the plain slider.
    var barContent: PlaybackBarContent? = nil
    var barPositionUnit: PlaybackBarAccessibility.PositionUnit = .seconds
    var positionAccessibilityValue: String? = nil
    var positionAccessibilityHint: String = ""
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> PlaybackBarAccessibilityView {
        let view = PlaybackBarAccessibilityView()
        view.slider.minimumTrackTintColor = UIColor(AppColors.accent)
        return view
    }

    func updateUIView(_ view: PlaybackBarAccessibilityView, context: Context) {
        let slider = view.slider
        view.positionUnit = barPositionUnit
        slider.accessibilityLabel = "Playback position"
        slider.accessibilityIdentifier = "playback.scrubber"
        slider.accessibilityValue = positionAccessibilityValue
        slider.accessibilityHint = positionAccessibilityHint
        slider.onValue = { value = $0 }
        slider.onEditing = onEditingChanged
        slider.onCancelled = onCancelled
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
        view.setNeedsLayout()
    }

    /// The bar is as tall as a 44 pt touch target (or the slider, if taller), whatever height it is offered: the dock
    /// sits in a bottom safe-area inset, so any extra height here is taken from the Now pane (#1475). The slider fills
    /// the bar and centres its track, so the extra height is room to touch, not a taller track (#430).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlaybackBarAccessibilityView, context: Context) -> CGSize? {
        Self.fittedSize(proposedWidth: proposal.width, slider: uiView.slider.intrinsicContentSize)
    }

    /// How far the bar reaches into the dock's 4 pt row gaps above and below it, so the touch height costs the dock
    /// only what the gaps can't give and never overlaps the chapter row or the transport (#430).
    static let rowGapOverlap: CGFloat = 4

    static func fittedSize(proposedWidth: CGFloat?, slider: CGSize) -> CGSize {
        let height = max(slider.height > 0 ? slider.height : 31, TapTarget.minimum)
        guard let width = proposedWidth, width.isFinite else {
            return CGSize(width: slider.width > 0 ? slider.width : 120, height: height)
        }
        return CGSize(width: max(0, width), height: height)
    }

    static func dismantleUIView(_ view: PlaybackBarAccessibilityView, coordinator: ()) {
        view.slider.onValue = nil
        view.slider.onEditing = nil
        view.slider.onCancelled = nil
        view.slider.onBarLayout = nil
    }
}

final class TrackingPlaybackSlider: UISlider {
    var onValue: ((Double) -> Void)?
    var onEditing: ((Bool) -> Void)?
    var onCancelled: (() -> Void)?
    private var valueAtTouchDown: Float = 0
    var onBarLayout: (([PlaybackBarRenderer.RenderedStack]) -> Void)?
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
        onBarLayout?(bar.renderedStacks)
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

    @objc func trackTouch(_ touch: UILongPressGestureRecognizer) {
        guard isEnabled else { return }
        switch touch.state {
        case .began:
            gestureActive = true
            isHighlighted = true
            valueAtTouchDown = value
            onEditing?(true)
            follow(touch.location(in: self))
        case .changed:
            guard gestureActive else { return }
            follow(touch.location(in: self))
        case .ended:
            guard gestureActive else { return }
            if isOffTheBar(touch.location(in: self)) {
                cancelGesture()
            } else {
                updatePosition(at: touch.location(in: self))
                finishGesture()
            }
        case .cancelled, .failed:
            cancelGesture()
        default:
            break
        }
    }

    private func isOffTheBar(_ point: CGPoint) -> Bool {
        ScrubTouchRule.outcome(verticalOffset: Double(point.y - bounds.midY)) == .cancel
    }

    /// Follows a finger near the bar; a finger far off it shows the position it will go back to.
    private func follow(_ point: CGPoint) {
        if isOffTheBar(point) {
            setValue(valueAtTouchDown, animated: false)
            onValue?(Double(value))
        } else {
            updatePosition(at: point)
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

    /// Puts the position back and ends the touch without a seek (#1930).
    private func cancelGesture() {
        guard gestureActive else { return }
        setValue(valueAtTouchDown, animated: false)
        onValue?(Double(value))
        guard let onCancelled else { return finishGesture() }
        gestureActive = false
        isHighlighted = false
        onCancelled()
    }

    private func finishGesture() {
        guard gestureActive else { return }
        gestureActive = false
        isHighlighted = false
        onEditing?(false)
    }

    /// UISlider only reports `.adjustable` once UIKit's accessibility bundle loads (VoiceOver on), so the
    /// scrubber states it itself: it now sits inside a container that lists it beside the Margin stacks.
    override var accessibilityTraits: UIAccessibilityTraits {
        get { super.accessibilityTraits.union(.adjustable) }
        set { super.accessibilityTraits = newValue }
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
