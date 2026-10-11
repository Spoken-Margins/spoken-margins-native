import SessionKit
import UIKit

/// Draws the playback bar's chapter segments and Margin diamonds into layers (#428).
///
/// `PlaybackBarLayout` decides what goes where; this only paints it. The marks are display only and ride above the
/// track, and the segments stand in for the system track only while there are chapters to show, so a source with
/// no chapters keeps the plain slider.
@MainActor
final class PlaybackBarRenderer {
    struct Geometry {
        /// The system track's rect, whose ends the first and last segments reach.
        var track: CGRect
        /// Where the thumb's centre sits at the smallest and the largest value. Chapter boundaries and diamonds
        /// are placed between these so they line up with the thumb at the same position.
        var lower: CGFloat
        var upper: CGFloat
        var thumbX: CGFloat
        var scale: CGFloat
        var fill: CGColor
    }

    /// The segments and diamonds sit in this layer, which the slider puts behind its thumb.
    let layer = CALayer()

    static let trackThickness: CGFloat = 4
    private static let gap: CGFloat = 2
    private static let diamondHalf: CGFloat = 4.5
    private static let crowdedHalf: CGFloat = 7
    private static let layerStep: CGFloat = 1.5
    private static let sharedBlue = UIColor(red: 0.45, green: 0.70, blue: 1, alpha: 1)

    private let trackLayer = CALayer()
    private let marksLayer = CALayer()
    private var segments: [CALayer] = []
    private var fills: [CALayer] = []
    private var ticks: [CALayer] = []
    private var drawnMarks: DrawnMarks?

    private struct DrawnMarks: Equatable {
        var content: PlaybackBarContent
        var lower: CGFloat
        var upper: CGFloat
        var centerY: CGFloat
    }

    init() {
        layer.name = "playback-bar"
        trackLayer.name = "playback-bar-track"
        marksLayer.name = "playback-bar-marks"
        layer.addSublayer(trackLayer)
        layer.addSublayer(marksLayer)
    }

    /// Lays the bar out for the slider's current value. Returns true when the segments replace the system track.
    @discardableResult
    func update(content: PlaybackBarContent?, value: Double, geometry: Geometry) -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let content, geometry.upper > geometry.lower else {
            layoutSegments(nil, geometry)
            layoutMarks(nil, geometry)
            return false
        }
        let track = PlaybackBarLayout.track(chapterStarts: content.chapterStarts, length: content.length, position: value)
        let replacesTrack = track.boundary != .none
        layoutSegments(replacesTrack ? track : nil, geometry)
        layoutMarks(content, geometry)
        return replacesTrack
    }

    // MARK: Chapter segments

    private func layoutSegments(_ track: PlaybackBarLayout.Track?, _ g: Geometry) {
        let drawn = track?.segments ?? []
        resize(&segments, to: drawn.count, in: trackLayer) {
            let segment = CALayer()
            segment.name = "bar-segment"
            segment.backgroundColor = UIColor.white.withAlphaComponent(0.28).cgColor
            return segment
        }
        resize(&fills, to: drawn.count, in: nil) {
            let fill = CALayer()
            fill.name = "bar-segment-fill"
            return fill
        }
        let gaps = track?.boundary == .gaps
        let span = g.upper - g.lower
        for (index, segment) in drawn.enumerated() {
            let isFirst = index == 0
            let isLast = index == drawn.count - 1
            var left = isFirst ? g.track.minX : g.lower + CGFloat(segment.start) * span
            var right = isLast ? g.track.maxX : g.lower + CGFloat(segment.end) * span
            if gaps {
                if !isFirst { left += Self.gap / 2 }
                if !isLast { right -= Self.gap / 2 }
            }
            let height = Self.trackThickness + (segment.isCurrent ? 2 : 0)
            let frame = CGRect(x: left, y: g.track.midY - height / 2, width: max(1, right - left), height: height)
            let radius = gaps ? height / 2 : 0
            segments[index].frame = frame
            segments[index].cornerRadius = radius
            let fill = fills[index]
            if fill.superlayer !== segments[index] { segments[index].addSublayer(fill) }
            fill.backgroundColor = g.fill
            fill.cornerRadius = radius
            fill.frame = CGRect(x: 0, y: 0, width: min(frame.width, max(0, g.thumbX - frame.minX)), height: height)
        }
        // A long list of chapters would eat the track with gaps, so it gets a thin tick at each boundary instead.
        let boundaries = track?.boundary == .ticks ? drawn.dropFirst().map(\.start) : []
        resize(&ticks, to: boundaries.count, in: trackLayer) {
            let tick = CALayer()
            tick.name = "bar-tick"
            tick.zPosition = 1
            tick.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
            return tick
        }
        for (index, start) in boundaries.enumerated() {
            let height = Self.trackThickness + 4
            ticks[index].frame = CGRect(x: g.lower + CGFloat(start) * span - 0.5, y: g.track.midY - height / 2, width: 1, height: height)
        }
    }

    // MARK: Margin diamonds

    private func layoutMarks(_ content: PlaybackBarContent?, _ g: Geometry) {
        let centerY = g.track.midY - Self.trackThickness / 2 - Self.diamondHalf - 2
        let key = content.map { DrawnMarks(content: $0, lower: g.lower, upper: g.upper, centerY: centerY) }
        guard key != drawnMarks else { return }
        drawnMarks = key
        marksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let content, !content.marks.isEmpty else { return }
        let stacks = PlaybackBarLayout.stacks(marks: content.marks, length: content.length, width: Double(g.upper - g.lower))
        for stack in stacks {
            let center = CGPoint(x: g.lower + CGFloat(stack.x), y: centerY)
            if stack.ghostLayers > 0 {
                for ghost in stride(from: stack.ghostLayers, through: 1, by: -1) {
                    let offset = CGFloat(ghost) * Self.layerStep
                    addDiamond(at: center, offset: offset, half: Self.crowdedHalf, style: .ghost)
                }
                addDiamond(at: center, offset: 0, half: Self.crowdedHalf, style: stack.front.kind.diamondStyle)
                if let count = stack.countLabel { addCount(count, at: center, scale: g.scale, style: stack.front.kind.diamondStyle) }
            } else {
                for (index, kind) in stack.layers.enumerated().reversed() {
                    addDiamond(at: center, offset: CGFloat(index) * Self.layerStep, half: Self.diamondHalf, style: kind.diamondStyle)
                }
            }
        }
    }

    fileprivate enum DiamondStyle { case own, shared, ghost }

    /// Solid amber for the listener's own Margin, hollow blue for a shared one; the shape and fill say which, not the colour alone.
    private func addDiamond(at center: CGPoint, offset: CGFloat, half: CGFloat, style: DiamondStyle) {
        let middle = CGPoint(x: center.x + offset, y: center.y - offset)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: middle.x, y: middle.y - half))
        path.addLine(to: CGPoint(x: middle.x + half, y: middle.y))
        path.addLine(to: CGPoint(x: middle.x, y: middle.y + half))
        path.addLine(to: CGPoint(x: middle.x - half, y: middle.y))
        path.close()
        let diamond = CAShapeLayer()
        diamond.name = "bar-diamond"
        diamond.path = path.cgPath
        let backdrop = UIColor(red: 0.09, green: 0.13, blue: 0.11, alpha: 1)
        switch style {
        case .own:
            diamond.fillColor = UIColor(red: 0.94, green: 0.72, blue: 0.32, alpha: 1).cgColor
            diamond.strokeColor = backdrop.cgColor
            diamond.lineWidth = 1
        case .shared:
            diamond.fillColor = backdrop.cgColor
            diamond.strokeColor = Self.sharedBlue.cgColor
            diamond.lineWidth = 1.5
        case .ghost:
            diamond.fillColor = backdrop.cgColor
            diamond.strokeColor = UIColor.white.withAlphaComponent(0.45).cgColor
            diamond.lineWidth = 1
        }
        marksLayer.addSublayer(diamond)
    }

    /// The count is dark on the amber of an own Margin and light blue on the dark fill of a shared one, so it reads on both.
    private func addCount(_ count: String, at center: CGPoint, scale: CGFloat, style: DiamondStyle) {
        let label = CATextLayer()
        label.name = "bar-count"
        label.string = count
        label.fontSize = 9
        label.alignmentMode = .center
        label.foregroundColor = (style == .shared ? Self.sharedBlue : UIColor.black).cgColor
        label.contentsScale = scale
        label.frame = CGRect(x: center.x - Self.crowdedHalf, y: center.y - 5.5, width: Self.crowdedHalf * 2, height: 11)
        marksLayer.addSublayer(label)
    }

    /// Grows or shrinks a pool of layers to `count`. `parent` is nil for layers a caller attaches itself.
    private func resize(_ pool: inout [CALayer], to count: Int, in parent: CALayer?, make: () -> CALayer) {
        while pool.count > count { pool.removeLast().removeFromSuperlayer() }
        while pool.count < count {
            let created = make()
            parent?.addSublayer(created)
            pool.append(created)
        }
    }
}

private extension PlaybackBarLayout.MarkKind {
    var diamondStyle: PlaybackBarRenderer.DiamondStyle { self == .own ? .own : .shared }
}
