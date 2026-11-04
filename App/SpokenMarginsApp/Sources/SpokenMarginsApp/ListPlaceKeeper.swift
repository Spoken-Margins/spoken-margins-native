import SwiftUI
import UIKit

/// Holds a list's place on screen while rows above the visible ones come and go (#1990). A list keeps its offset when
/// a row is added above what is on screen, so every row on screen slides down by the new row's height. SwiftUI's
/// `scrollTo` can only put a row at an edge, and the row `ListScrollTracker` calls the top may sit under the
/// navigation bar, so this works on the UIKit list itself: it shifts the offset by exactly what the content grew or
/// shrank, in the same layout pass, so no frame shows the slide.
///
/// Put `anchor` in the list's background, and call `holdPlace()` from the change that adds or removes the rows.
@MainActor
final class ListPlaceKeeper {
    private struct Place {
        let offset: CGFloat
        let height: CGFloat
    }

    private weak var anchorView: UIView?
    private weak var list: UICollectionView?
    private var sizeObservation: NSKeyValueObservation?
    /// The place before a height change seen in this run-loop turn: SwiftUI may lay out the new rows before
    /// `holdPlace()` runs.
    private var beforeRecentChange: Place?
    /// The place `holdPlace()` keeps, until the list's height next changes or the hold expires.
    private var held: (place: Place, until: Date)?

    var anchor: some View { ListPlaceAnchor(keeper: self) }

    /// Call as the rows above change. When the list lays them out, the rows on screen stay where they were.
    func holdPlace() {
        if list == nil, let anchorView { attach(near: anchorView) }
        guard let list else { return }
        if let before = beforeRecentChange {
            shift(list, from: before) // the list already laid the change out this turn
            return
        }
        let place = Place(offset: list.contentOffset.y, height: list.contentSize.height)
        guard place.offset + list.adjustedContentInset.top > 1 else { return } // at the very top, the new row shows
        held = (place, Date().addingTimeInterval(0.5))
    }

    fileprivate func attach(near anchor: UIView) {
        anchorView = anchor
        guard list == nil, let found = Self.nearestList(from: anchor) else { return }
        list = found
        sizeObservation = found.observe(\.contentSize, options: [.old]) { [weak self] list, change in
            guard let old = change.oldValue else { return }
            MainActor.assumeIsolated { self?.heightChanged(list, oldHeight: old.height) }
        }
    }

    private func heightChanged(_ list: UICollectionView, oldHeight: CGFloat) {
        if let held {
            self.held = nil
            if held.until > Date() { shift(list, from: held.place) }
            return
        }
        guard beforeRecentChange == nil else { return }
        beforeRecentChange = Place(offset: list.contentOffset.y, height: oldHeight)
        DispatchQueue.main.async { [weak self] in self?.beforeRecentChange = nil }
    }

    private func shift(_ list: UICollectionView, from place: Place) {
        let change = list.contentSize.height - place.height
        // A finger that moved the list in between owns the place, and at the very top the new row shows.
        guard change != 0, abs(list.contentOffset.y - place.offset) < 0.5,
              place.offset + list.adjustedContentInset.top > 1 else { return }
        let top = -list.adjustedContentInset.top
        let bottom = max(top, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        let offset = min(max(place.offset + change, top), bottom)
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: offset), animated: false)
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
