import SessionKitPersistence
import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// Verification of #1990, Done when 1 and 2: the play queue's Library entry and its sheet show their text whole at the
/// default and the largest text size, and the Library's place in the list holds when the entry comes and goes.
///
/// Each mounted screen is drawn into an attachment (`keepAlways`), so a run's result bundle holds the screenshots.
@MainActor
final class PlayQueueLayoutTests: XCTestCase {
    /// The phone the Test Desk uses: 393 pt wide. The Library's rows sit 16 pt in from each edge.
    private static let windowSize = CGSize(width: 393, height: 852)
    private static let libraryRowWidth: CGFloat = 393 - 2 * 16
    /// The least a queue sheet row keeps from its label: a 16 pt margin on each side. Measured at a width no narrower
    /// than the label really gets, the height its text needs can only come out at or under the real need, so a row
    /// shorter than that is cut off.
    private static let sheetRowInsets: CGFloat = 32
    private static let sizes: [DynamicTypeSize] = [.large, .accessibility5]
    private static let shortTitle = "Morning brief"
    private static let longTitle = "Are Prediction Markets Gambling? A Lot Rides on the Answer."

    override func setUp() async throws {
        try await super.setUp()
        UIPasteboard.general.items = [] // a copied link would add its card above the rows mid-test
    }

    override func tearDown() async throws {
        PlayQueueController.update(Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())) { $0.clear() }
        try await super.tearDown()
    }

    // MARK: - Done when 1: no clipped text

    /// The entry's "Next:" line stopped at one line, so a long title read "Next: Are Prediction…" at every size. Cut
    /// short, a long title and a short one make entries of the same height.
    func testTheLibraryEntryShowsTheWholeNextTitleAtDefaultAndLargestText() throws {
        for size in Self.sizes {
            let short = summaryHeight(nextTitle: Self.shortTitle, size: size)
            let long = summaryHeight(nextTitle: Self.longTitle, size: size)
            XCTAssertGreaterThan(long, short + 10, "\(size): the long Next title was cut short (\(long) vs \(short) pt)")
        }
    }

    /// The queue sheet's rows are as tall as their whole title and subtitle need, at the width the list gives them.
    func testTheQueueSheetRowsHoldTheirWholeTitleAtDefaultAndLargestText() async throws {
        let model = try makeModel(itemCount: 3, longFirstTitle: true)
        for id in Self.itemIds(3) { model.queueAppend(itemId: id) }
        let rows = PlayQueueRows.rows(for: PlayQueueController.current(model), items: model.libraryItems)
        XCTAssertEqual(rows.count, 3)

        for size in Self.sizes {
            let mounted = try mount(AnyView(ExperiencePlayQueueScreen().environmentObject(model)), size: size)
            defer { mounted.close() }
            let list = try await settledList(in: mounted) { $0.totalItems >= 1 }
            attachScreenshot(of: mounted, name: "play-queue-sheet-\(size)")
            // The long title's row is the tallest; a section header, if the list draws it as a cell, is shorter.
            let tallest = try XCTUnwrap(list.view.visibleCells.max { $0.bounds.height < $1.bounds.height },
                                        "\(size): no queue row is on screen")
            let needed = UIHostingController(rootView: PlayQueueRowLabel(row: rows[0]).environment(\.dynamicTypeSize, size))
                .sizeThatFits(in: CGSize(width: tallest.bounds.width - Self.sheetRowInsets, height: 4_000)).height
            XCTAssertGreaterThanOrEqual(tallest.bounds.height + 0.5, needed,
                                        "\(size): the long title's row is \(tallest.bounds.height) pt; its text needs \(needed) pt")
        }
    }

    /// The fixture Library with three items queued, at both sizes: the entry is there while something is queued and
    /// goes when the queue is cleared. The screenshots are the record of how it looks.
    func testTheLibraryShowsTheEntryOnlyWhileSomethingIsQueuedAtDefaultAndLargestText() async throws {
        let model = try makeModel(itemCount: 6, longFirstTitle: true)
        for size in Self.sizes {
            for id in Self.itemIds(3) { model.queueAppend(itemId: id) }
            let mounted = try mount(libraryScreen(model), size: size)
            defer { mounted.close() }
            let queued = try await settledList(in: mounted) { $0.totalItems >= 7 }
            attachScreenshot(of: mounted, name: "library-with-queue-\(size)")
            model.clearPlayQueue()
            let cleared = try await settledList(in: mounted) { $0.totalItems == queued.totalItems - 1 }
            XCTAssertEqual(cleared.totalItems, queued.totalItems - 1, "\(size): clearing the queue should remove its entry")
        }
    }

    // MARK: - Done when 2: the place in the list holds

    /// The list keeps its offset when a row is added above what is on screen, so adding an item to the queue from its
    /// menu, partway down the Library, pushed every row down by the entry's height under the listener. The row that
    /// was at the top must stay at the top as the entry comes, and again as it goes.
    func testTheRowAtTheTopStaysThereWhenTheQueueEntryComesAndGoes() async throws {
        let model = try makeModel(itemCount: 40)
        let mounted = try mount(libraryScreen(model), size: .large)
        defer { mounted.close() }
        var list = try await settledList(in: mounted) { $0.totalItems >= 40 && $0.view.contentSize.height > 2_000 }

        // A row partway down, scrolled to sit 4 pt past the top edge, as a finger leaves it.
        let topIndex = list.totalItems / 2
        let frame = try XCTUnwrap(list.view.layoutAttributesForItem(at: list.paths[topIndex])?.frame)
        list.view.setContentOffset(CGPoint(x: 0, y: frame.minY - list.view.adjustedContentInset.top + 4), animated: false)
        try await Task.sleep(for: .milliseconds(500)) // the list's place settles for 150 ms before it counts
        list = try await settledList(in: mounted) { _ in true }
        let before = try offsetFromTop(of: topIndex, in: list)
        let rowsBefore = list.totalItems
        attachScreenshot(of: mounted, name: "library-scrolled-before-queue")

        model.queueAppend(itemId: Self.itemIds(1)[0])
        list = try await settledList(in: mounted) { $0.totalItems == rowsBefore + 1 }
        attachScreenshot(of: mounted, name: "library-scrolled-after-queue")
        let afterAdding = try offsetFromTop(of: topIndex + 1, in: list)
        XCTAssertEqual(afterAdding, before, accuracy: 6,
                       "The row at the top moved \(afterAdding - before) pt when the queue entry appeared above it")

        try await Task.sleep(for: .milliseconds(500))
        model.removeFromQueue(itemId: Self.itemIds(1)[0])
        list = try await settledList(in: mounted) { $0.totalItems == rowsBefore }
        let afterRemoving = try offsetFromTop(of: topIndex, in: list)
        XCTAssertEqual(afterRemoving, before, accuracy: 6,
                       "The row at the top moved \(afterRemoving - before) pt when the queue entry went away")
    }

    /// The control: a plain list with a row that comes and goes above the rest, and nothing keeping the place. Its rows
    /// slide by the new row's height, so the measure above can see a jump, and the Library's fix is what holds it.
    func testWithoutKeepingThePlaceAPlainListSlidesWhenARowArrivesAbove() async throws {
        let toggle = TopRowToggle()
        let mounted = try mount(AnyView(PlainListWithTopRow(toggle: toggle)), size: .large)
        defer { mounted.close() }
        var list = try await settledList(in: mounted) { $0.totalItems >= 60 }
        let topIndex = 30
        let frame = try XCTUnwrap(list.view.layoutAttributesForItem(at: list.paths[topIndex])?.frame)
        list.view.setContentOffset(CGPoint(x: 0, y: frame.minY - list.view.adjustedContentInset.top + 4), animated: false)
        list = try await settledList(in: mounted) { _ in true }
        let before = try offsetFromTop(of: topIndex, in: list)

        toggle.showsTopRow = true
        list = try await settledList(in: mounted) { $0.totalItems == 61 }
        let after = try offsetFromTop(of: topIndex + 1, in: list)
        XCTAssertGreaterThan(after - before, 40, "A row arriving above should push a plain list's rows down by its height")
    }

    // MARK: - Fixtures

    private static func itemIds(_ count: Int) -> [String] {
        (0..<count).map { String(format: "queue-layout-%02d", $0) }
    }

    private func makeModel(itemCount: Int, longFirstTitle: Bool = false) throws -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        PlayQueueController.update(model) { $0.clear() }
        let store = try model.requireStore()
        for (index, id) in Self.itemIds(itemCount).enumerated() {
            let title = index == 0 && longFirstTitle ? Self.longTitle : "Fixture article \(index + 1)"
            try store.saveItem(Item(id: id, title: title, mediaType: "text", text: "One.\n\nTwo.", externalReference: nil,
                                    status: "Ready"))
        }
        try model.refreshLibraryRows(store: store)
        return model
    }

    private func libraryScreen(_ model: Gate1AppModel) -> AnyView {
        AnyView(ExperienceLibraryScreen(addSourceRoute: .constant(nil), scrollMemory: .constant(FollowingScrollMemory()))
            .environmentObject(model))
    }

    private func summaryHeight(nextTitle: String, size: DynamicTypeSize) -> CGFloat {
        let rows = [PlayQueueRow(id: "a", title: nextTitle, subtitle: nil, symbol: "doc.text"),
                    PlayQueueRow(id: "b", title: Self.shortTitle, subtitle: nil, symbol: "doc.text")]
        let entry = PlayQueueSummaryRow(rows: rows) {}
            .environment(\.dynamicTypeSize, size)
            .frame(width: Self.libraryRowWidth)
            .background(AppColors.bone)
        let renderer = ImageRenderer(content: entry)
        renderer.scale = 2
        if let image = renderer.uiImage {
            let attachment = XCTAttachment(image: image)
            attachment.name = "library-queue-entry-\(size)-\(nextTitle == Self.longTitle ? "long" : "short")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return UIHostingController(rootView: PlayQueueSummaryRow(rows: rows) {}.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: Self.libraryRowWidth, height: 4_000)).height
    }

    // MARK: - Mounting and measuring

    @MainActor
    private struct Mounted {
        let window: UIWindow
        let previousKeyWindow: UIWindow?

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }

    private struct ListState {
        let view: UICollectionView
        /// Every row, in list order across sections.
        let paths: [IndexPath]
        var totalItems: Int { paths.count }
    }

    private func mount(_ view: AnyView, size: DynamicTypeSize) throws -> Mounted {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(view.environment(\.dynamicTypeSize, size)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.windowSize)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }

    /// The screen's list once it meets `ready` and its offset and size have stopped changing.
    private func settledList(in mounted: Mounted, _ ready: (ListState) -> Bool) async throws -> ListState {
        var last: [CGFloat] = []
        var steady = 0
        var seen: ListState?
        for _ in 0..<150 {
            mounted.window.layoutIfNeeded()
            if let view = Self.collectionView(in: mounted.window) {
                let paths = (0..<view.numberOfSections).flatMap { section in
                    (0..<view.numberOfItems(inSection: section)).map { IndexPath(item: $0, section: section) }
                }
                let state = ListState(view: view, paths: paths)
                seen = state
                let shape = [view.contentOffset.y, view.contentSize.height, CGFloat(paths.count)]
                if ready(state), shape == last {
                    steady += 1
                    if steady >= 3 { return state }
                } else {
                    steady = 0
                }
                last = shape
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("The list never settled: \(seen.map { "\($0.totalItems) rows, offset \($0.view.contentOffset.y)" } ?? "no list")")
        throw NotSettled()
    }

    private struct NotSettled: Error {}

    /// Where the row's top edge sits relative to the top of the visible list: 0 at the edge, negative above it.
    private func offsetFromTop(of index: Int, in list: ListState) throws -> CGFloat {
        let frame = try XCTUnwrap(list.view.layoutAttributesForItem(at: list.paths[index])?.frame)
        return frame.minY - (list.view.contentOffset.y + list.view.adjustedContentInset.top)
    }

    private static func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews {
            if let list = collectionView(in: child) { return list }
        }
        return nil
    }

    private func attachScreenshot(of mounted: Mounted, name: String) {
        let window = mounted.window
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class TopRowToggle: ObservableObject {
    @Published var showsTopRow = false
}

private struct PlainListWithTopRow: View {
    @ObservedObject var toggle: TopRowToggle

    var body: some View {
        NavigationStack {
            List {
                if toggle.showsTopRow {
                    Text("A row that arrives").frame(height: 80)
                }
                ForEach(0..<60, id: \.self) { Text("Row \($0)") }
            }
            .listStyle(.plain)
        }
    }
}
