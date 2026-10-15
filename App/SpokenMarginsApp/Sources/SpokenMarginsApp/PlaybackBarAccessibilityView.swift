import SessionKit
import UIKit

/// Keeps the adjustable scrubber and its read-only drawn Margin stacks as separate VoiceOver elements.
@MainActor
final class PlaybackBarAccessibilityView: UIView {
    let slider = TrackingPlaybackSlider()
    var positionUnit: PlaybackBarAccessibility.PositionUnit = .seconds
    private var previous: Snapshot?
    private var marks: [(members: [PlaybackBarLayout.Mark], element: UIAccessibilityElement)] = []

    private struct Snapshot: Equatable {
        var stacks: [PlaybackBarRenderer.RenderedStack]
        var length: Double
        var unit: PlaybackBarAccessibility.PositionUnit
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityElementsHidden = false
        addSubview(slider)
        accessibilityElements = [slider]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // A plain UIView hugs weakly on both axes, so SwiftUI let this container take every
        // point it was offered and the dock filled the screen (#1475). Only the width may stretch.
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        slider.onBarLayout = { [weak self] stacks in self?.updateAccessibility(stacks) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { slider.intrinsicContentSize }
    override func sizeThatFits(_ size: CGSize) -> CGSize { slider.sizeThatFits(size) }

    override func layoutSubviews() {
        super.layoutSubviews()
        slider.frame = bounds
        slider.setNeedsLayout()
        slider.layoutIfNeeded()
    }

    private func updateAccessibility(_ stacks: [PlaybackBarRenderer.RenderedStack]) {
        let snapshot = Snapshot(stacks: stacks, length: slider.barContent?.length ?? 0, unit: positionUnit)
        guard snapshot != previous else { return }
        previous = snapshot
        let oldMarks = marks
        marks = stacks.map { rendered in
            // Reuse surviving stacks so ordinary clock updates and resizing do not discard VoiceOver focus.
            let element = oldMarks.first { $0.members == rendered.stack.members }?.element
                ?? UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = PlaybackBarAccessibility.label(
                for: rendered.stack, length: snapshot.length, unit: positionUnit
            )
            element.accessibilityTraits = .staticText
            element.accessibilityFrameInContainerSpace = convert(rendered.frame, from: slider)
            return (rendered.stack.members, element)
        }
        accessibilityElements = [slider] + marks.map(\.element)
    }
}
