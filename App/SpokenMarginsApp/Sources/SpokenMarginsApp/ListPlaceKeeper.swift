import SessionKit
import SwiftUI
import UIKit

/// Holds a list's place on screen while rows above the visible ones come and go (#1990). A list keeps its offset when
/// a row is added above what is on screen, so every row on screen slides down by the new row's height. SwiftUI's
/// `scrollTo` can only put a row at an edge, and a `List` has no anchor of its own, so this works on the UIKit list.
///
/// Two things make the place hold, and neither depends on when the list takes the change:
/// - **The place is read from `body`.** The new row only reaches the list through what that `body` returns, so the list
///   there still shows the rows it had. An `onChange` runs too late: the lane found the list already holding the new row.
/// - **The row is named by its distance from the end of the list** (`ListPlace`), which rows added above don't change.
///
/// The list then grows in steps (a new row first takes an estimated height, rows coming into view below are measured)
/// and can set its own offset as it finishes an update, so for a short while the row is put back on every change and
/// on every frame. A finger on the list ends that. Nothing runs, and nothing is observed, between holds.
///
/// Put `anchor` in the list's background, and call `rowsAboveWillShow(_:holding:)` at the top of `body`.
@MainActor
final class ListPlaceKeeper {
    /// How long the place is held after a change: long enough for the list to measure the new row.
    private static let holdDuration: TimeInterval = 0.6

    private weak var anchorView: UIView?
    private weak var list: UICollectionView?
    private var rowsShown: AnyHashable?
    private var place: ListPlace?
    private var holdEnds = Date.distantPast
    private var observations: [NSKeyValueObservation] = []
    private var frameLink: CADisplayLink?
    private var isShifting = false

    var anchor: some View { ListPlaceAnchor(keeper: self) }

    /// Tells the keeper what the rows above show now; when that differs from the last call, the place is held. Only
    /// reads the list, so it is safe in `body`. At the very top of the list it holds nothing, so the listener sees the
    /// new row arrive. `holding` false notes the rows and holds nothing.
    func rowsAboveWillShow(_ rows: some Hashable, holding: Bool) {
        let rows = AnyHashable(rows)
        defer { rowsShown = rows }
        guard let shown = rowsShown, shown != rows, holding else { return }
        holdPlace()
    }

    fileprivate func noteAnchor(_ view: UIView) {
        anchorView = view
    }

    private func holdPlace() {
        if list?.window == nil, let anchorView { list = Self.nearestList(from: anchorView) }
        guard let list, !list.isTracking, !list.isDragging, !list.isDecelerating else { return }
        // The frames can stop with a hold still set, in the background; what it read is no place to go back to.
        if Date() >= holdEnds { endHold() }
        // A second change during a hold keeps the place the first one read: the list may be part way through that one.
        if place == nil {
            guard let read = Self.readPlace(of: list) else { return }
            place = read
        }
        holdEnds = Date().addingTimeInterval(Self.holdDuration)
        guard observations.isEmpty else { return }
        observations = [
            list.observe(\.contentSize) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.keepPlaceNowAndNextTurn() }
            },
            list.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.keepPlaceNowAndNextTurn() }
            },
        ]
        let link = CADisplayLink(target: FrameTarget { [weak self] in
            guard let self, place != nil else { return false }
            keepPlace()
            return true
        }, selector: #selector(FrameTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    /// Now, so the frame that shows the change shows the row in place; a turn later, in case the list sets its own
    /// offset as it finishes the update.
    private func keepPlaceNowAndNextTurn() {
        guard !isShifting else { return }
        keepPlace()
        DispatchQueue.main.async { [weak self] in self?.keepPlace() }
    }

    private func keepPlace() {
        guard let place, let list else { return endHold() }
        // A finger on the list owns the place.
        guard Date() < holdEnds, !list.isTracking, !list.isDragging, !list.isDecelerating else { return endHold() }
        // Mid-update the layout can still hold the old rows' frames; the next pass reads the new ones.
        guard !isShifting, !list.hasUncommittedUpdates else { return }
        guard let row = place.rowIndex(inListOf: Self.rowCount(of: list)),
              let path = Self.indexPath(atFlat: row, in: list),
              let frame = list.layoutAttributesForItem(at: path)?.frame else { return }
        let insets = list.adjustedContentInset
        let target = place.offset(keepingRowAt: frame.minY,
                                  lowest: -insets.top,
                                  highest: list.contentSize.height - list.bounds.height + insets.bottom)
        guard abs(target - list.contentOffset.y) > 0.5 else { return }
        isShifting = true
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: target), animated: false)
        isShifting = false
    }

    private func endHold() {
        place = nil
        observations = []
        frameLink?.invalidate()
        frameLink = nil
    }

    // MARK: - Reading the list

    /// Reads the cells on screen as they stand: this runs in `body`, where asking the layout for a frame could make the
    /// list lay itself out in the middle of a SwiftUI update.
    private static func readPlace(of list: UICollectionView) -> ListPlace? {
        let offset = list.contentOffset.y
        let insets = list.adjustedContentInset
        let visible = list.visibleCells.compactMap { cell -> ListPlace.VisibleRow? in
            guard let path = list.indexPath(for: cell) else { return nil }
            return ListPlace.VisibleRow(index: flatIndex(of: path, in: list), top: cell.frame.minY, bottom: cell.frame.maxY)
        }
        return ListPlace.reading(visibleRows: visible, rowCount: rowCount(of: list), offset: offset,
                                 viewTop: offset + insets.top, viewBottom: offset + list.bounds.height - insets.bottom)
    }

    private static func rowCount(of list: UICollectionView) -> Int {
        (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
    }

    private static func flatIndex(of path: IndexPath, in list: UICollectionView) -> Int {
        (0..<path.section).reduce(0) { $0 + list.numberOfItems(inSection: $1) } + path.item
    }

    private static func indexPath(atFlat index: Int, in list: UICollectionView) -> IndexPath? {
        var rest = index
        for section in 0..<list.numberOfSections {
            let count = list.numberOfItems(inSection: section)
            if rest < count { return IndexPath(item: rest, section: section) }
            rest -= count
        }
        return nil
    }

    /// The list beside the anchor: the first collection view under the anchor's nearest ancestor that has one.
    private static func nearestList(from anchor: UIView) -> UICollectionView? {
        var ancestor = anchor.superview
        while let view = ancestor {
            if let list = firstList(in: view) { return list }
            ancestor = view.superview
        }
        return nil
    }

    private static func firstList(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews {
            if let list = firstList(in: child) { return list }
        }
        return nil
    }
}

/// The display link's target: the link holds it strongly, and it holds the keeper only through its closure's weak
/// reference, so the keeper can go while a link runs; the link stops when the keeper has gone or its hold has ended.
@MainActor
private final class FrameTarget: NSObject {
    let onFrame: () -> Bool

    init(onFrame: @escaping () -> Bool) {
        self.onFrame = onFrame
    }

    @objc func tick(_ link: CADisplayLink) {
        if !onFrame() { link.invalidate() }
    }
}

private struct ListPlaceAnchor: UIViewRepresentable {
    let keeper: ListPlaceKeeper

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        keeper.noteAnchor(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        keeper.noteAnchor(view)
    }
}
