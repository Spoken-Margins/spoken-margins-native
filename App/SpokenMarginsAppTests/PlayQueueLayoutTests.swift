import Combine
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
    /// Less than any entry takes in the Library: its circle alone is 40 pt tall.
    private static let leastEntryHeight: CGFloat = 40
    private static let sizes: [DynamicTypeSize] = [.large, .accessibility5]
    private static let shortTitle = "Morning brief"
    private static let longTitle = "Are Prediction Markets Gambling? A Lot Rides on the Answer."

    override func setUp() async throws {
        try await super.setUp()
        UIPasteboard.general.items = [] // a copied link would add its card above the rows mid-test
        PlayQueueSheetProbe.setEditMode = nil
        PlayQueueSheetProbe.editMode = .inactive
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
            let mounted = try mount(AnyView(ExperiencePlayQueueScreen(model: model, close: {})), size: size)
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
            let queued = try await settledList(in: mounted) { $0.totalItems >= 6 }
            let withEntry = try firstRowHeight(in: queued)
            attachScreenshot(of: mounted, name: "library-with-queue-\(size)")
            model.clearPlayQueue()
            // The entry is part of the list's first row, so the row is shorter by the entry once it goes.
            let cleared = try await settledList(in: mounted) { (try? self.firstRowHeight(in: $0)) != withEntry }
            let withoutEntry = try firstRowHeight(in: cleared)
            XCTAssertEqual(cleared.totalItems, queued.totalItems, "\(size): clearing the queue should add or remove no row")
            XCTAssertGreaterThan(withEntry - withoutEntry, Self.leastEntryHeight,
                                 "\(size): clearing the queue should remove its entry (\(withEntry) to \(withoutEntry) pt)")
        }
    }

    // MARK: - #3891: the sheet holds still while audio plays

    /// The model publishes many times a second while audio plays. Redrawn on each publish, the sheet's list in Edit mode
    /// kept restarting its edit transition (rows hopped, remove icons flickered). A publish that leaves the queue as it
    /// was must not run the sheet's body; a real change to the queue still must.
    func testTheQueueSheetIsNotRedrawnByModelPublishesThatLeaveTheQueueAsItWas() async throws {
        let model = try makeModel(itemCount: 3)
        for id in Self.itemIds(3) { model.queueAppend(itemId: id) }
        let mounted = try mount(AnyView(ExperiencePlayQueueScreen(model: model, close: {})), size: .large)
        defer { mounted.close() }
        let settled = try await settledList(in: mounted) { $0.totalItems >= 3 }
        // The list's shape settles before the sheet stops drawing: the first rows' own async work (#3999: this failed on
        // its first run and passed on retry in three hosted runs) can draw the sheet once more after it. That draw is
        // not a publish leaving the queue as it was, so count from when the sheet has gone quiet, not from when the rows
        // stopped moving.
        let runsBefore = try await bodyRunsOnceTheSheetIsQuiet()
        let comparedBefore = PlayQueueSheetProbe.comparisons
        let unequalBefore = PlayQueueSheetProbe.unequalComparisons

        for _ in 0..<20 { // fixed-count ok: it makes 20 changes 20 ms apart, not waiting for anything
            model.objectWillChange.send()
            // A real change to a published property the screen follows, leaving every row as it was (#4033): the rows
            // feed must absorb it, not pass it on to the sheet.
            model.libraryItems = model.libraryItems
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await settledList(in: mounted) { _ in true }
        // A failure says which kind of redraw it was: SwiftUI found the rows different (unequal), found them the same and
        // drew anyway (compared minus unequal, drawn more often than that means something else invalidated the sheet), or
        // never asked (compared 0).
        XCTAssertEqual(PlayQueueSheetProbe.bodyRuns, runsBefore,
                       "20 model publishes with the queue unchanged redrew the sheet \(PlayQueueSheetProbe.bodyRuns - runsBefore) times; "
                           + "SwiftUI compared the sheet \(PlayQueueSheetProbe.comparisons - comparedBefore) times, "
                           + "\(PlayQueueSheetProbe.unequalComparisons - unequalBefore) of them unequal")

        model.removeFromQueue(itemId: Self.itemIds(3)[0])
        let afterRemoving = try await settledList(in: mounted) { $0.totalItems < settled.totalItems }
        XCTAssertGreaterThan(PlayQueueSheetProbe.bodyRuns, runsBefore, "Removing a queued item should redraw the sheet")
        XCTAssertEqual(afterRemoving.totalItems, settled.totalItems - 1, "The removed item's row should be gone")
    }

    /// #3891, reopened: with the sheet no longer redrawn, the owner's phone still showed the remove icon and handle fading
    /// between full and half strength in Edit mode, row text still. The Library redraws on every model publish, and a
    /// `.sheet` on it re-ran the presentation each time. Presented the way the Library presents it, in Edit mode, nothing
    /// in the sheet may redraw, Edit mode must hold, and nothing in a row may be animating while nobody touches the screen.
    /// Edit mode comes on once the sheet is up, as the owner's tap on Edit did, and is read from SwiftUI's own state; the
    /// list's UIKit flag did not follow it in the hosted run that failed (#4036), so it counts only if it ever does.
    /// The control below runs the same steps against a plain `.sheet` and must show the fault this one guards.
    func testInEditModeTheQueueRowsHoldStillWhileTheirPresenterRedrawsOnEveryPublish() async throws {
        let model = try makeModel(itemCount: 3)
        for id in Self.itemIds(3) { model.queueAppend(itemId: id) }
        let mounted = try mount(AnyView(QueueSheetPresenter(model: model)), size: .large)
        defer { mounted.close() }
        _ = try await settledList(in: mounted) { $0.totalItems >= 3 }
        let settled = try await enterEditMode(in: mounted)
        let sheetBefore = try await bodyRunsOnceTheSheetIsQuiet()
        let rowsBefore = try await rowRunsOnceTheRowsAreQuiet()
        let hostBefore = PlayQueueSheetProbe.hostRuns
        let screensBefore = PlayQueueSheetProbe.screenInits
        try await waitForTheRowsToStopAnimating(in: settled.view)

        let idle = try await editModeWhilePublishing(model, list: settled.view)

        XCTAssertEqual(PlayQueueSheetProbe.hostRuns, hostBefore,
                       "20 model publishes redrew the sheet's presentation \(PlayQueueSheetProbe.hostRuns - hostBefore) times")
        XCTAssertEqual(PlayQueueSheetProbe.screenInits, screensBefore,
                       "20 model publishes re-ran the presentation, building the queue screen \(PlayQueueSheetProbe.screenInits - screensBefore) more times")
        XCTAssertEqual(PlayQueueSheetProbe.bodyRuns, sheetBefore,
                       "20 model publishes with the queue unchanged redrew the sheet \(PlayQueueSheetProbe.bodyRuns - sheetBefore) times")
        XCTAssertEqual(PlayQueueSheetProbe.rowRuns, rowsBefore,
                       "20 model publishes with the queue unchanged redrew the rows \(PlayQueueSheetProbe.rowRuns - rowsBefore) times")
        XCTAssertEqual(idle.notEditing, 0, "Edit mode went off in \(idle.notEditing) of \(idle.looks) looks with nothing touched; "
                           + "after: \(Self.editState(of: settled.view))")
        XCTAssertTrue(idle.animating.isEmpty, "Rows were animating with nothing touched: \(idle.animating.sorted())")

        // A real change still lands, and Edit mode survives it.
        model.removeFromQueue(itemId: Self.itemIds(3)[0])
        let afterRemoving = try await settledList(in: mounted) { $0.totalItems < settled.totalItems }
        XCTAssertEqual(afterRemoving.totalItems, settled.totalItems - 1, "The removed item's row should be gone")
        XCTAssertEqual(PlayQueueSheetProbe.editMode, .active, "Removing a row should leave Edit mode on: \(Self.editState(of: afterRemoving.view))")
        if listFlagFollowsEditMode {
            XCTAssertTrue(afterRemoving.view.isEditing, "Removing a row took the list out of Edit mode: \(Self.editState(of: afterRemoving.view))")
        }
    }

    /// The control for the test above, run against the plain `.sheet` the Library had. The test above only means something
    /// if this presenter shows the fault it guards: with a plain `.sheet`, a publish that changes nothing must re-run the
    /// presentation (its content closure), which the host's test says never happens, or knock Edit mode off, or set a row
    /// animating. If none of these shows, the test above no longer reproduces the owner's recording and its pass proves
    /// nothing. The failure message gives all four counts.
    func testWithAPlainSheetOnTheWatchingPresenterEditModeFlickersOnEveryPublish() async throws {
        let model = try makeModel(itemCount: 3)
        for id in Self.itemIds(3) { model.queueAppend(itemId: id) }
        let mounted = try mount(AnyView(PlainSheetQueuePresenter(model: model)), size: .large)
        defer { mounted.close() }
        _ = try await settledList(in: mounted) { $0.totalItems >= 3 }
        let settled = try await enterEditMode(in: mounted)
        try await waitForTheRowsToStopAnimating(in: settled.view)
        let buildsBefore = PlayQueueSheetProbe.screenInits

        let idle = try await editModeWhilePublishing(model, list: settled.view)

        let rebuilt = PlayQueueSheetProbe.screenInits - buildsBefore
        XCTAssertGreaterThan(rebuilt, 0, "Plain sheet: the queue screen was built \(rebuilt) times, Edit mode off in \(idle.notEditing) of \(idle.looks) looks, "
                                         + "rows animating: \(idle.animating.sorted())")
    }

    /// #4033: the sheet's rows are published only when they differ, so a screen watching them is not invalidated by
    /// the model's other publishes at all, whatever SwiftUI does with the sheet's `==`.
    func testTheRowsFeedPublishesOnlyWhenTheRowsChange() throws {
        let model = try makeModel(itemCount: 3)
        for id in Self.itemIds(3) { model.queueAppend(itemId: id) }
        let feed = PlayQueueRowsFeed(model: model)
        XCTAssertEqual(feed.rows.map(\.id), Self.itemIds(3))

        var publishes = 0
        let watch = feed.objectWillChange.sink { publishes += 1 }
        defer { watch.cancel() }
        for _ in 0..<20 {
            model.objectWillChange.send()
            model.libraryItems = model.libraryItems
            PlayQueueController.update(model) { _ in } // the queue's ids set again to what they were
        }
        XCTAssertEqual(publishes, 0, "Publishes that leave every row as it was reached the screen \(publishes) times")

        model.removeFromQueue(itemId: Self.itemIds(3)[0])
        XCTAssertEqual(publishes, 1, "Removing a queued item should publish the new rows once")
        XCTAssertEqual(feed.rows.map(\.id), Array(Self.itemIds(3).dropFirst()))
    }

    // MARK: - Done when 2: the place in the list holds

    /// A new row above what is on screen pushed every row down by the entry's height, so adding an item to the queue
    /// from its menu, partway down the Library, moved the rows under the listener. The row that was at the top must stay
    /// at the top as the entry comes, and again as it goes. No row count changes, so going back to the top is what shows
    /// the entry really came and really went: without that, a list that never took the change would pass.
    func testTheRowAtTheTopStaysThereWhenTheQueueEntryComesAndGoes() async throws {
        let model = try makeModel(itemCount: 40)
        let mounted = try mount(libraryScreen(model), size: .large)
        defer { mounted.close() }
        var list = try await settledList(in: mounted) { $0.totalItems >= 40 && $0.view.contentSize.height > 2_000 }
        let rows = list.totalItems
        let heightWithoutEntry = try firstRowHeight(in: list)
        let topIndex = rows / 2

        var before = try await scrollPartWayDown(to: topIndex, in: mounted, from: list)
        attachScreenshot(of: mounted, name: "library-scrolled-before-queue")
        model.queueAppend(itemId: Self.itemIds(1)[0])
        list = try await listAfterAChangeOffScreen(in: mounted)
        attachScreenshot(of: mounted, name: "library-scrolled-after-queue")
        let afterAdding = try offsetFromTop(of: topIndex, in: list)
        XCTAssertEqual(afterAdding, before, accuracy: 6,
                       "The row at the top moved \(afterAdding - before) pt when the queue entry appeared above it "
                           + "(list after: \(Self.shape(of: list)))")

        list = try await scrollBackToTheTop(in: mounted, from: list)
        let heightWithEntry = try firstRowHeight(in: list)
        XCTAssertEqual(list.totalItems, rows, "The entry should add no row")
        XCTAssertGreaterThan(heightWithEntry - heightWithoutEntry, Self.leastEntryHeight,
                             "The entry never came: the first row went from \(heightWithoutEntry) to \(heightWithEntry) pt")

        before = try await scrollPartWayDown(to: topIndex, in: mounted, from: list)
        model.removeFromQueue(itemId: Self.itemIds(1)[0])
        list = try await listAfterAChangeOffScreen(in: mounted)
        let afterRemoving = try offsetFromTop(of: topIndex, in: list)
        XCTAssertEqual(afterRemoving, before, accuracy: 6,
                       "The row at the top moved \(afterRemoving - before) pt when the queue entry went away "
                           + "(list after: \(Self.shape(of: list)))")

        list = try await scrollBackToTheTop(in: mounted, from: list)
        XCTAssertEqual(try firstRowHeight(in: list), heightWithoutEntry, accuracy: 1,
                       "The entry never went: the first row should be back to the height it had")
    }

    /// The control: a plain list with a row that comes and goes above the rest. Its rows slide by the new row's height,
    /// so the measure above can see a jump, and keeping the entry in a row that is always there is what holds the place.
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
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
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
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
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

    /// The sheet's body-run count once it has not moved for 10 polls (0.4 s).
    private func bodyRunsOnceTheSheetIsQuiet() async throws -> Int {
        var last = PlayQueueSheetProbe.bodyRuns
        var quiet = 0
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            try await Task.sleep(for: .milliseconds(40))
            let now = PlayQueueSheetProbe.bodyRuns
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 10 { return now }
        }
        XCTFail("The sheet kept drawing with nothing changing (\(last) body runs)")
        throw NotSettled()
    }

    /// The queue rows' body-run count once it has not moved for 10 polls (0.4 s).
    private func rowRunsOnceTheRowsAreQuiet() async throws -> Int {
        var last = PlayQueueSheetProbe.rowRuns
        var quiet = 0
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            try await Task.sleep(for: .milliseconds(40))
            let now = PlayQueueSheetProbe.rowRuns
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 10 { return now }
        }
        XCTFail("The rows kept drawing with nothing changing (\(last) body runs)")
        throw NotSettled()
    }

    /// Waits until no row layer has animated for 10 polls (0.4 s), so the sheet's arrival is over before idle counts.
    private func waitForTheRowsToStopAnimating(in list: UICollectionView) async throws {
        var quiet = 0
        var seen: Set<String> = []
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            try await Task.sleep(for: .milliseconds(40))
            seen = Self.animatingLayers(in: list.visibleCells)
            quiet = seen.isEmpty ? quiet + 1 : 0
            if quiet >= 10 { return }
        }
        XCTFail("The rows kept animating with nothing changing: \(seen.sorted())")
        throw NotSettled()
    }

    /// Whether the list's UIKit flag followed SwiftUI's Edit mode when it came on. A hosted run (#4036) saw the sheet's
    /// Edit mode on while `UICollectionView.isEditing` stayed false, so the flag only counts when it did follow.
    private var listFlagFollowsEditMode = false
    /// How Edit mode was turned on, for a failure message.
    private var editModeHow = "not tried"

    /// Turns Edit mode on the way a tap on Edit does: through the Edit button's accessibility activation, and, if no such
    /// button is found or it changes nothing, through the sheet's own setter. Waits until SwiftUI's Edit mode has held
    /// for 3 looks running, then gives the list's UIKit flag two seconds to follow.
    private func enterEditMode(in mounted: Mounted) async throws -> ListState {
        let setEditMode = try XCTUnwrap(PlayQueueSheetProbe.setEditMode, "The queue sheet never appeared")
        var visited = Set<ObjectIdentifier>()
        let button = Self.accessibilityElement(withIdentifier: "playQueue.edit.button", in: mounted.window, visited: &visited)
        if let button, button.accessibilityActivate() {
            editModeHow = "the Edit button's activation"
            if try await editModeHeld(in: mounted, within: .seconds(2)) == nil { editModeHow = "the setter, after the button changed nothing" }
        } else {
            editModeHow = button == nil ? "the setter, no Edit button found" : "the setter, the Edit button refused activation"
        }
        if PlayQueueSheetProbe.editMode != .active {
            withAnimation { setEditMode(.active) }
        }
        guard let list = try await editModeHeld(in: mounted, within: .seconds(30)) else {
            XCTFail("Edit mode never held for 3 looks (turned on by \(editModeHow)): SwiftUI's Edit mode is "
                    + "\(PlayQueueSheetProbe.editMode == .active ? "active" : "inactive"), "
                    + "\(Self.collectionView(in: mounted.window).map(Self.editState) ?? "no list")")
            throw NotSettled()
        }
        let how = XCTAttachment(string: "Edit mode turned on by \(editModeHow)")
        how.lifetime = .keepAlways
        add(how)
        // "No" is an expected answer here (#4036: the flag stays false on a hosted run), so the wait is short on purpose.
        try await pollUntil(timeout: .seconds(2), pollEvery: .milliseconds(40)) { list.isEditing }
        if list.isEditing { listFlagFollowsEditMode = true }
        let paths = (0..<list.numberOfSections).flatMap { section in
            (0..<list.numberOfItems(inSection: section)).map { IndexPath(item: $0, section: section) }
        }
        return ListState(view: list, paths: paths)
    }

    /// The list once SwiftUI's Edit mode has been active for 3 looks running (40 ms each), or nil once `limit` has passed.
    /// The probe after a tap on Edit passes a short limit because "no" is a normal answer there; the wait after the setter
    /// passes a long one because that is a wait for real work.
    private func editModeHeld(in mounted: Mounted, within limit: Duration) async throws -> UICollectionView? {
        var steady = 0
        let pollDeadline = ContinuousClock.now + limit
        while ContinuousClock.now < pollDeadline {
            try await Task.sleep(for: .milliseconds(40))
            mounted.window.layoutIfNeeded()
            if PlayQueueSheetProbe.editMode == .active, let list = Self.collectionView(in: mounted.window) {
                steady += 1
                if steady >= 3 { return list }
            } else {
                steady = 0
            }
        }
        return nil
    }

    /// The first element at or under `root` whose accessibility identifier is `identifier`, looking through views and
    /// accessibility containers the way a UI test does.
    private static func accessibilityElement(withIdentifier identifier: String, in root: NSObject, visited: inout Set<ObjectIdentifier>) -> NSObject? {
        guard visited.insert(ObjectIdentifier(root)).inserted else { return nil }
        if (root as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier { return root }
        var children: [NSObject] = []
        if let view = root as? UIView {
            children += (view.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            children += view.subviews
        }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            children += (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        for child in children {
            if let found = accessibilityElement(withIdentifier: identifier, in: child, visited: &visited) { return found }
        }
        return nil
    }

    /// What a failure needs to tell Edit mode on from off: the list's own flag, and how many rows show a reorder handle.
    private static func editState(of list: UICollectionView) -> String {
        func handles(in view: UIView) -> Int {
            let own = "\(type(of: view))".contains("ReorderControl") && !view.isHidden && view.alpha > 0.5 ? 1 : 0
            return view.subviews.reduce(own) { $0 + handles(in: $1) }
        }
        let cells = list.visibleCells
        return "isEditing \(list.isEditing), \(cells.filter { handles(in: $0) > 0 }.count) of \(cells.count) rows show a reorder handle"
    }

    /// Sends 20 model publishes that change nothing, looking twice after each: how often the sheet's Edit mode (and the list's
    /// flag, when it follows it) was off,
    /// and every row layer seen animating, including in the 0.3 s after the last.
    private func editModeWhilePublishing(_ model: Gate1AppModel, list: UICollectionView) async throws
        -> (notEditing: Int, looks: Int, animating: Set<String>) {
        var notEditing = 0
        var looks = 0
        var animating: Set<String> = []
        for _ in 0..<20 { // fixed-count ok: it makes 20 changes, not waiting for anything
            model.objectWillChange.send()
            for _ in 0..<2 { // fixed-count ok: it takes two looks per change, not waiting for anything
                try await Task.sleep(for: .milliseconds(20))
                looks += 1
                if PlayQueueSheetProbe.editMode != .active || (listFlagFollowsEditMode && !list.isEditing) { notEditing += 1 }
                animating.formUnion(Self.animatingLayers(in: list.visibleCells))
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        animating.formUnion(Self.animatingLayers(in: list.visibleCells))
        return (notEditing, looks, animating)
    }

    /// Each layer in the cells with an animation running, as "layer's class (its view's class): animation keys".
    private static func animatingLayers(in cells: [UICollectionViewCell]) -> Set<String> {
        var found: Set<String> = []
        func visit(_ layer: CALayer) {
            if let keys = layer.animationKeys(), !keys.isEmpty {
                let owner = (layer.delegate as? UIView).map { " (\(type(of: $0)))" } ?? ""
                found.insert("\(type(of: layer))\(owner): \(keys.sorted().joined(separator: ","))")
            }
            layer.sublayers?.forEach(visit)
        }
        cells.forEach { visit($0.layer) }
        return found
    }

    /// Where the row's top edge sits relative to the top of the visible list: 0 at the edge, negative above it.
    private func offsetFromTop(of index: Int, in list: ListState) throws -> CGFloat {
        let frame = try XCTUnwrap(list.view.layoutAttributesForItem(at: list.paths[index])?.frame)
        return frame.minY - (list.view.contentOffset.y + list.view.adjustedContentInset.top)
    }

    /// The first row holds the Library's controls and, while something is queued, the queue's entry.
    private func firstRowHeight(in list: ListState) throws -> CGFloat {
        try XCTUnwrap(list.view.layoutAttributesForItem(at: list.paths[0])?.frame.height)
    }

    /// Scrolls so a row partway down sits 4 pt past the top edge, as a finger leaves it, and says where it settled.
    private func scrollPartWayDown(to index: Int, in mounted: Mounted, from list: ListState) async throws -> CGFloat {
        let frame = try XCTUnwrap(list.view.layoutAttributesForItem(at: list.paths[index])?.frame)
        list.view.setContentOffset(CGPoint(x: 0, y: frame.minY - list.view.adjustedContentInset.top + 4), animated: false)
        try await Task.sleep(for: .milliseconds(500)) // the list's place settles for 150 ms before it counts
        return try offsetFromTop(of: index, in: try await settledList(in: mounted) { _ in true })
    }

    private func scrollBackToTheTop(in mounted: Mounted, from list: ListState) async throws -> ListState {
        list.view.setContentOffset(CGPoint(x: 0, y: -list.view.adjustedContentInset.top), animated: false)
        try await Task.sleep(for: .milliseconds(300)) // the first row measures itself as it comes into view
        return try await settledList(in: mounted) { _ in true }
    }

    /// A change off screen shows in nothing `settledList` could wait for, so this gives the list time to take it first.
    private func listAfterAChangeOffScreen(in mounted: Mounted) async throws -> ListState {
        try await Task.sleep(for: .milliseconds(500))
        return try await settledList(in: mounted) { _ in true }
    }

    /// The list's offset, content height, top inset and row count, for a failure message: an offset that moved by the
    /// content's change means the place was kept and the measure is off; one that stayed means nothing kept it.
    private static func shape(of list: ListState) -> String {
        let view = list.view
        return "offset \(view.contentOffset.y), content \(view.contentSize.height), inset \(view.adjustedContentInset.top), "
            + "\(list.totalItems) rows"
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

/// The Library's shape around the queue sheet: a presenter that watches the model, so every publish redraws it, and
/// presents the sheet the way the Library does.
private struct QueueSheetPresenter: View {
    @ObservedObject var model: Gate1AppModel
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .playQueueSheet(isPresented: $isPresented, model: model)
    }
}

/// The same presenter with a plain `.sheet`, as the Library had before #3891 was reopened.
private struct PlainSheetQueuePresenter: View {
    @ObservedObject var model: Gate1AppModel
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                ExperiencePlayQueueScreen(model: model, close: { isPresented = false })
            }
    }
}
