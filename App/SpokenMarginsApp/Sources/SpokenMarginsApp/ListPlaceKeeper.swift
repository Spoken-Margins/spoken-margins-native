import SwiftUI
import UIKit

/// Holds a list's place on screen while rows above the visible ones come and go (#1990). A list keeps its offset when
/// a row is added above what is on screen, so every row on screen slides down by the new row's height. SwiftUI's
/// `scrollTo` can only put a row at an edge, and the row `ListScrollTracker` calls the top may sit under the
/// navigation bar, so this works on the UIKit list itself.
///
/// It keeps one row on screen where it was: a row fully in view, found by its place in the list and moved along by
/// the rows added above it. A single shift by what the content grew was not enough: the list grows in steps (a new
/// row first takes an estimated height, rows coming into view below are measured) and can set its own offset at the
/// end of an update, so the place is re-applied on every change for a short while, and on every frame: the second T3
/// showed the list taking a new row with the offset left where it was and no change the keeper heard of after it.
///
/// Put `anchor` in the list's background, and call `holdPlace(rowsAddedAbove:)` from the change that adds or removes
/// the rows.
@MainActor
final class ListPlaceKeeper {
    private struct Place {
        let offset: CGFloat
        let height: CGFloat
        let rowCount: Int
        /// The row kept in place, counted across sections, and its top edge's distance below the offset.
        let row: Int
        let rowTop: CGFloat
    }

    private struct Hold {
        let place: Place
        /// Rows added above since `place`, and the count before the latest change, which the list may not have taken.
        let rowsAdded: Int
        let rowsAddedBefore: Int
        let until: Date
        let generation: Int
    }

    /// How long the place is held after a change: long enough for the list to measure the new row.
    private static let holdDuration: TimeInterval = 0.6

    private weak var anchorView: UIView?
    private weak var list: UICollectionView?
    private var observations: [NSKeyValueObservation] = []
    /// The place as of the last run-loop turn with no change, and the one before it. SwiftUI may lay the new rows out
    /// before `holdPlace(rowsAddedAbove:)` runs, so the place is read a turn after the list moves, never in the same
    /// turn; if the list took the change a turn earlier still, the place before it is the one to keep.
    private var settled: Place?
    private var previousSettled: Place?
    private var rowCountSettledAt: Date?
    private var settleScheduled = false
    private var held: Hold?
    private var holdGeneration = 0
    private var reapplyScheduled = false
    private var isShifting = false
    private var frameLink: CADisplayLink?

    #if DEBUG
    /// What the keepers decided lately, newest last, for a layout test's failure message.
    static var trace: [String] = []
    #endif

    var anchor: some View { ListPlaceAnchor(keeper: self) }

    /// Call as the rows above change, with how many rows were added (negative when rows went). When the list lays
    /// them out, the rows on screen stay where they were. At the very top of the list it does nothing, so the
    /// listener sees the new row arrive.
    func holdPlace(rowsAddedAbove rowsAdded: Int) {
        if list == nil, let anchorView { attach(near: anchorView) }
        let current = held.flatMap { $0.until > Date() ? $0 : nil }
        guard let list else { return note("hold \(rowsAdded): no list") }
        guard let place = current?.place ?? placeBefore(rowsAdded: rowsAdded, in: list) else {
            return note("hold \(rowsAdded): no place on screen")
        }
        guard place.offset + list.adjustedContentInset.top > 1 else {
            return note("hold \(rowsAdded): at the top (offset \(place.offset))")
        }
        holdGeneration += 1
        let generation = holdGeneration
        let before = current?.rowsAdded ?? 0
        held = Hold(place: place, rowsAdded: before + rowsAdded, rowsAddedBefore: before,
                    until: Date().addingTimeInterval(Self.holdDuration), generation: generation)
        note("hold \(rowsAdded): row \(place.row) of \(place.rowCount) at \(place.rowTop), offset \(place.offset); "
            + "list has \(Self.rowCount(of: list)) rows")
        keepHeldPlace(in: list)
        startFrameLink()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration) { [weak self] in
            guard let self, held?.generation == generation else { return }
            endHold()
        }
    }

    /// Where the list is before this change. When rows come or go and the list still has the rows it had when it last
    /// settled, it is read now, so a settled place gone stale (the list moved with nothing heard) can't be held. Once
    /// the list has taken the change, or when only a row's height changed and the count can't tell, the settled place,
    /// or the one before it if it was read just after the list took this very change.
    private func placeBefore(rowsAdded: Int, in list: UICollectionView) -> Place? {
        let rowCount = Self.rowCount(of: list)
        if rowsAdded != 0, let settled, let previousSettled, settled.rowCount == rowCount,
           previousSettled.rowCount == settled.rowCount - rowsAdded,
           let changed = rowCountSettledAt, Date().timeIntervalSince(changed) < 0.25 {
            return previousSettled
        }
        if rowsAdded != 0, settled == nil || settled?.rowCount == rowCount, let now = Self.place(of: list) { return now }
        return settled
    }

    private func endHold() {
        held = nil
        frameLink?.invalidate()
        frameLink = nil
        scheduleSettle()
    }

    /// Re-applies the place on every frame while it is held, after the list's own layout of the frame before.
    private func startFrameLink() {
        guard frameLink == nil else { return }
        let link = CADisplayLink(target: FrameTarget { [weak self] in
            guard let self, let list else { return false }
            if !list.hasUncommittedUpdates { applyHeldPlace(in: list) }
            return true
        }, selector: #selector(FrameTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        frameLink = link
    }

    private func note(_ line: @autoclosure () -> String) {
        #if DEBUG
        Self.trace.append(line())
        if Self.trace.count > 40 { Self.trace.removeFirst(Self.trace.count - 40) }
        #endif
    }

    fileprivate func attach(near anchor: UIView) {
        anchorView = anchor
        guard list == nil, let found = Self.nearestList(from: anchor) else { return }
        list = found
        observations = [
            found.observe(\.contentSize) { [weak self] list, _ in
                MainActor.assumeIsolated { self?.listMoved(list) }
            },
            found.observe(\.contentOffset) { [weak self] list, _ in
                MainActor.assumeIsolated { self?.listMoved(list) }
            },
        ]
        scheduleSettle()
    }

    private func listMoved(_ list: UICollectionView) {
        guard !isShifting else { return }
        if held != nil {
            keepHeldPlace(in: list)
        } else {
            scheduleSettle()
        }
    }

    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            settleScheduled = false
            guard held == nil, let list, let place = Self.place(of: list) else { return }
            if let settled, place.rowCount != settled.rowCount {
                previousSettled = settled
                rowCountSettledAt = Date()
            }
            settled = place
        }
    }

    /// Puts the kept row back at its distance below the offset, now and once more a turn later, in case the list sets
    /// its own offset as it finishes the update.
    private func keepHeldPlace(in list: UICollectionView) {
        let holding: Bool
        if list.hasUncommittedUpdates {
            // Mid-update the layout can still hold the old rows' frames; the pass a turn later reads the new ones.
            holding = held.map { $0.until > Date() } ?? false
        } else {
            holding = applyHeldPlace(in: list)
        }
        guard holding, !reapplyScheduled else { return }
        reapplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reapplyScheduled = false
            if let list = self.list { applyHeldPlace(in: list) }
        }
    }

    /// False once the hold has ended.
    @discardableResult
    private func applyHeldPlace(in list: UICollectionView) -> Bool {
        guard let held else { return false }
        // A finger on the list owns the place.
        guard held.until > Date(), !list.isTracking, !list.isDragging, !list.isDecelerating else {
            endHold()
            return false
        }
        shift(list, to: held)
        return true
    }

    private func shift(_ list: UICollectionView, to held: Hold) {
        let place = held.place
        let rowCount = Self.rowCount(of: list)
        let offset: CGFloat
        if rowCount == place.rowCount + held.rowsAdded {
            guard let kept = Self.offset(keeping: place.row + held.rowsAdded, at: place.rowTop, in: list) else {
                return note("no frame for row \(place.row + held.rowsAdded) of \(rowCount)")
            }
            offset = kept
        } else if rowCount == place.rowCount + held.rowsAddedBefore {
            return // the list hasn't taken the latest change yet
        } else {
            // Rows changed elsewhere too: keep the distance to the end of the list instead.
            offset = place.offset + list.contentSize.height - place.height
        }
        let top = -list.adjustedContentInset.top
        let bottom = max(top, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        let target = min(max(offset, top), bottom)
        guard abs(target - list.contentOffset.y) > 0.5 else { return }
        note("shift \(list.contentOffset.y) to \(target) (\(rowCount) rows, content \(list.contentSize.height))")
        isShifting = true
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: target), animated: false)
        isShifting = false
    }

    // MARK: - Reading the list

    /// The last row wholly on screen: rows below the ones that change, so moving it along by the rows added finds it.
    private static func place(of list: UICollectionView) -> Place? {
        let offset = list.contentOffset.y
        let viewTop = offset + list.adjustedContentInset.top
        let viewBottom = offset + list.bounds.height - list.adjustedContentInset.bottom
        let onScreen = list.indexPathsForVisibleItems.compactMap { path -> (row: Int, frame: CGRect)? in
            guard let frame = list.layoutAttributesForItem(at: path)?.frame else { return nil }
            return (flatIndex(of: path, in: list), frame)
        }
        let whole = onScreen.filter { $0.frame.minY >= viewTop - 0.5 && $0.frame.maxY <= viewBottom + 0.5 }
        guard let kept = (whole.isEmpty ? onScreen : whole).max(by: { $0.row < $1.row }) else { return nil }
        return Place(offset: offset, height: list.contentSize.height, rowCount: rowCount(of: list), row: kept.row,
                     rowTop: kept.frame.minY - offset)
    }

    private static func offset(keeping row: Int, at rowTop: CGFloat, in list: UICollectionView) -> CGFloat? {
        guard let path = indexPath(atFlat: row, in: list),
              let frame = list.layoutAttributesForItem(at: path)?.frame else { return nil }
        return frame.minY - rowTop
    }

    private static func rowCount(of list: UICollectionView) -> Int {
        (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
    }

    private static func flatIndex(of path: IndexPath, in list: UICollectionView) -> Int {
        (0..<path.section).reduce(0) { $0 + list.numberOfItems(inSection: $1) } + path.item
    }

    private static func indexPath(atFlat index: Int, in list: UICollectionView) -> IndexPath? {
        guard index >= 0 else { return nil }
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
/// reference, so the keeper can go while a link runs; the link stops when the keeper or its list has gone.
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

private final class ListPlaceAnchorView: UIView {
    weak var keeper: ListPlaceKeeper?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { keeper?.attach(near: self) }
    }
}

private struct ListPlaceAnchor: UIViewRepresentable {
    let keeper: ListPlaceKeeper

    func makeUIView(context: Context) -> ListPlaceAnchorView {
        let view = ListPlaceAnchorView()
        view.isUserInteractionEnabled = false
        view.keeper = keeper
        return view
    }

    func updateUIView(_ view: ListPlaceAnchorView, context: Context) {
        view.keeper = keeper
        if view.window != nil { keeper.attach(near: view) }
    }
}
