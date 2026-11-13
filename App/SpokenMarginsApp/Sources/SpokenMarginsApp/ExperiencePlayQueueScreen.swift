import Combine
import SessionKit
import SwiftUI
import UIKit

/// The play queue (#1990): what plays next, in order. Tap a row to play it now, drag to reorder (Edit), swipe to remove,
/// Clear to empty it. It opens from the Library's "Play queue" row, which only shows while something is queued.
///
/// This view hands the sheet its rows and what its buttons do. It does not watch `Gate1AppModel`, which publishes many
/// times a second while audio plays: it holds the model only to run the buttons, and a `PlayQueueRowsFeed` tells it when
/// the rows change. Redrawn on every model publish, the list in Edit mode kept restarting its edit transition, so the
/// rows hopped and the remove icons flickered (#3891). The sheet is also `.equatable()`, a second guard in case the
/// Library redraws this screen. A hosted run showed the sheet drawn once per publish with SwiftUI never asking its `==`
/// (#4033), so the first guard is that nothing here is invalidated by a model publish at all.
///
/// The Library presents it with `playQueueSheet(isPresented:model:)`, never a plain `.sheet`: see `PlayQueueSheetHost`,
/// which hands it to UIKit so the Library's redraws and environment cannot reach it.
struct ExperiencePlayQueueScreen: View {
    let model: Gate1AppModel
    @StateObject private var feed: PlayQueueRowsFeed
    /// Closes the sheet; the presenter's own flag, so calling it from an older copy of the sheet still closes it.
    let close: () -> Void

    init(model: Gate1AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        #if DEBUG
        PlayQueueSheetProbe.screenInits += 1
        #endif
        _feed = StateObject(wrappedValue: PlayQueueRowsFeed(model: model))
    }

    var body: some View {
        PlayQueueSheet(
            rows: feed.rows,
            actions: PlayQueueSheetActions(
                load: { model.loadPlayQueue() },
                close: close,
                playNow: { model.playQueuedItemNow(itemId: $0) },
                remove: { model.removeFromQueue(itemId: $0) },
                move: { model.moveInQueue(fromOffsets: $0, toOffset: $1) },
                clear: { model.clearPlayQueue() }
            )
        )
        .equatable()
        .onAppear { PlayQueueSheetTally.opened() }
        .onDisappear { model.recordDeveloperDiagnostic("playQueue.closed", PlayQueueSheetTally.closedRecord()) }
    }
}

/// What the queue sheet did while it was open, recorded to diagnostics when it closes (#3891). A phone check that
/// still shows the rows hopping can then say whether the sheet itself was redrawing (draws far above row changes) or
/// stayed still while the list reset under it, which is the question two simulator-only fixes could not answer.
@MainActor
enum PlayQueueSheetTally {
    static var sheetDraws = 0
    static var rowChanges = 0
    static var editEntries = 0
    private static var openedAt = Date()

    static func opened() {
        sheetDraws = 0
        rowChanges = 0
        editEntries = 0
        openedAt = Date()
    }

    static func closedRecord() -> [String: String] {
        [
            "sheetDraws": String(sheetDraws),
            "rowChanges": String(rowChanges),
            "editEntries": String(editEntries),
            "openMs": String(Int(Date().timeIntervalSince(openedAt) * 1000)),
            "presenter": "uikit",
        ]
    }
}

extension View {
    /// Presents the play queue from a view that redraws on every model publish, as the Library does while audio plays.
    func playQueueSheet(isPresented: Binding<Bool>, model: Gate1AppModel) -> some View {
        background {
            PlayQueueSheetHost(model: model, isPresented: isPresented).equatable()
        }
    }
}

/// Presents the queue sheet through UIKit, so nothing in the Library can reach it once it is up (#3891, third report).
///
/// Two earlier fixes kept SwiftUI's `.sheet` and blocked one path each: the sheet stopped watching the model (#3976,
/// #4033), then the presentation moved into a host the Library's redraws skip (#4036). Both passed in a test simulator
/// and the owner's phone (build 37, audio playing at 1.5x) still showed the rows leaving Edit mode at once and fading
/// back in about every 0.54 s, with the Edit button holding its active checkmark. So SwiftUI's Edit mode stayed on while
/// the list itself kept resetting. A `.sheet` also hands its content the presenter's environment, which `.equatable()`
/// does not stop, and the hosted tests never changed it. Rather than guess which path is left, the sheet is now a
/// `UIHostingController` presented by UIKit: its root view is set once, it has its own environment, and the Library's
/// redraws, environment and presentation updates have no way in. Only the rows feed and the sheet's own state redraw it.
private struct PlayQueueSheetHost: View, Equatable {
    let model: Gate1AppModel
    @Binding var isPresented: Bool

    nonisolated static func == (lhs: PlayQueueSheetHost, rhs: PlayQueueSheetHost) -> Bool {
        lhs.model === rhs.model && lhs.isPresented == rhs.isPresented
    }

    var body: some View {
        #if DEBUG
        let _ = PlayQueueSheetProbe.hostRuns += 1
        #endif
        PlayQueueUIKitPresenter(model: model, isPresented: $isPresented)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

private struct PlayQueueUIKitPresenter: UIViewControllerRepresentable {
    let model: Gate1AppModel
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let anchor = UIViewController()
        anchor.view.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchor = anchor
        // The binding writes the presenter's own flag, so an older copy of it still closes the sheet.
        let flag = $isPresented
        coordinator.setPresented = { flag.wrappedValue = $0 }
        coordinator.model = model
        coordinator.sync(wantsSheet: isPresented)
    }

    static func dismantleUIViewController(_ anchor: UIViewController, coordinator: Coordinator) {
        coordinator.sheet?.dismiss(animated: false)
        coordinator.sheet = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var anchor: UIViewController?
        weak var model: Gate1AppModel?
        var setPresented: (Bool) -> Void = { _ in }
        var sheet: UIViewController?
        private var wantsSheet = false
        private var retryScheduled = false

        func sync(wantsSheet: Bool) {
            self.wantsSheet = wantsSheet
            if wantsSheet, sheet == nil {
                present()
            } else if !wantsSheet, let sheet {
                self.sheet = nil
                sheet.dismiss(animated: true)
            }
        }

        private func present() {
            guard let anchor, let model else { return }
            guard anchor.view.window != nil, !anchor.isBeingPresented else {
                // Not in a window yet (the first update can come before the view is attached): try again next turn.
                guard !retryScheduled else { return }
                retryScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.retryScheduled = false
                    if self.wantsSheet, self.sheet == nil { self.present() }
                }
                return
            }
            var presenter: UIViewController = anchor
            while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
            let close: () -> Void = { [weak self] in self?.setPresented(false) }
            let hosting = UIHostingController(rootView: ExperiencePlayQueueScreen(model: model, close: close)
                .tint(AppColors.evergreen))
            hosting.modalPresentationStyle = .pageSheet
            hosting.presentationController?.delegate = self
            sheet = hosting
            presenter.present(hosting, animated: true)
        }

        /// A swipe down closed it: tell the presenter, whose flag would otherwise still say open.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            sheet = nil
            wantsSheet = false
            setPresented(false)
        }
    }
}

/// The queue sheet's rows, published only when they differ from the last ones. It follows the queue's ids and the
/// Library's items, not the model's every publish, so a screen that watches it is redrawn only when a row would change.
@MainActor
final class PlayQueueRowsFeed: ObservableObject {
    @Published private(set) var rows: [PlayQueueRow]
    private var subscription: AnyCancellable?

    init(model: Gate1AppModel, state: PlayQueueState = .shared) {
        rows = PlayQueueRows.rows(for: PlayQueue(itemIds: state.itemIds), items: model.libraryItems)
        // `@Published` hands subscribers the new value before the property holds it, so the rows are built from the values
        // the publishers carry, not from the model.
        subscription = state.$itemIds.combineLatest(model.$libraryItems)
            .map { ids, items in PlayQueueRows.rows(for: PlayQueue(itemIds: ids), items: items) }
            .removeDuplicates()
            .sink { [weak self] rows in
                PlayQueueSheetTally.rowChanges += 1
                self?.rows = rows
            }
    }
}

/// What the queue sheet's buttons do. Not part of the sheet's equality: they only reach the model, which does not change.
struct PlayQueueSheetActions {
    let load: () -> Void
    let close: () -> Void
    let playNow: (String) -> Void
    let remove: (String) -> Void
    let move: (IndexSet, Int) -> Void
    let clear: () -> Void
}

#if DEBUG
/// Counts how often the queue sheet's body and its rows' bodies run, and how SwiftUI's equality check on the sheet came
/// out, so a test can tell a redraw from a skipped one and a failure says which kind it was (#3891, #3999). `==` is not
/// main-actor, so its two counters are not either; SwiftUI calls it on the main thread.
@MainActor
enum PlayQueueSheetProbe {
    static var bodyRuns = 0
    static var rowRuns = 0
    static var hostRuns = 0
    /// How often the queue screen was built: once per presentation under the host, once per presenter redraw under a plain `.sheet`.
    static var screenInits = 0
    /// Sets the sheet's Edit mode as its Edit button does, so a test can enter Edit mode once the sheet is on screen.
    static var setEditMode: ((EditMode) -> Void)?
    /// The sheet's own Edit mode as SwiftUI holds it, the truth a test compares the list's UIKit flag with.
    static var editMode: EditMode = .inactive
    nonisolated(unsafe) static var comparisons = 0
    nonisolated(unsafe) static var unequalComparisons = 0
}
#endif

struct PlayQueueSheet: View, Equatable {
    let rows: [PlayQueueRow]
    let actions: PlayQueueSheetActions

    @State private var isConfirmingClear = false
    /// Held here, not left to the navigation stack, so Edit mode is the sheet's own and a redraw cannot reset it.
    @State private var editMode: EditMode = .inactive

    nonisolated static func == (lhs: PlayQueueSheet, rhs: PlayQueueSheet) -> Bool {
        let same = lhs.rows == rhs.rows
        #if DEBUG
        PlayQueueSheetProbe.comparisons += 1
        if !same { PlayQueueSheetProbe.unequalComparisons += 1 }
        #endif
        return same
    }

    var body: some View {
        #if DEBUG
        let _ = PlayQueueSheetProbe.bodyRuns += 1
        #endif
        let _ = PlayQueueSheetTally.sheetDraws += 1
        NavigationStack {
            List {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "Nothing queued",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: Text("Choose Play Next or Add to Queue on an episode, article or PDF, and it plays after the one you are listening to.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(rows) { row in
                            PlayQueueRowButton(row: row) {
                                actions.close()
                                actions.playNow(row.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Plays it now")
                            .accessibilityIdentifier("playQueue.row.\(row.id)")
                        }
                        .onMove { actions.move($0, $1) }
                        .onDelete { offsets in
                            for id in offsets.map({ rows[$0].id }) { actions.remove(id) }
                        }
                    } header: {
                        Text("Plays in this order")
                    } footer: {
                        Text("When what you are listening to ends, the first one here starts. A sleep timer stops the whole run.")
                    }
                }
            }
            .navigationTitle("Play queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: actions.close)
                        .accessibilityIdentifier("playQueue.done.button")
                }
                if !rows.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton().accessibilityIdentifier("playQueue.edit.button")
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear queue", role: .destructive) { isConfirmingClear = true }
                            .accessibilityHint("Empties the queue. Everything in your Library stays.")
                            .accessibilityIdentifier("playQueue.clear.button")
                    }
                }
            }
            .confirmationDialog("Clear the play queue?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                Button("Clear queue", role: .destructive) { actions.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything in your Library stays.")
            }
            .onAppear {
                actions.load()
                #if DEBUG
                PlayQueueSheetProbe.setEditMode = { editMode = $0 }
                PlayQueueSheetProbe.editMode = editMode
                #endif
            }
            .onChange(of: editMode) { _, mode in
                if mode == .active { PlayQueueSheetTally.editEntries += 1 }
                #if DEBUG
                PlayQueueSheetProbe.editMode = mode
                #endif
            }
            .onChange(of: rows.isEmpty) { _, isEmpty in
                // With nothing left there is no Edit button to leave Edit mode with.
                if isEmpty { editMode = .inactive }
            }
        }
        .environment(\.editMode, $editMode)
        .accessibilityIdentifier("playQueue.screen")
    }
}

/// A queued row as a button. Its own view so a test can count its redraws, and tell a redrawn row from an Edit mode
/// the presentation upset (#3891).
private struct PlayQueueRowButton: View {
    let row: PlayQueueRow
    let action: () -> Void

    var body: some View {
        #if DEBUG
        let _ = PlayQueueSheetProbe.rowRuns += 1
        #endif
        Button(action: action) {
            PlayQueueRowLabel(row: row)
        }
    }
}

struct PlayQueueRowLabel: View {
    let row: PlayQueueRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .foregroundStyle(AppColors.ochreText)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .multilineTextAlignment(.leading)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Library's entry to the queue, shown only while something is queued, so a listener who never queues sees nothing new.
struct PlayQueueSummaryRow: View {
    let rows: [PlayQueueRow]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ExperienceSurface(tint: AppColors.ochre.opacity(0.65)) {
                HStack(spacing: 12) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.title3)
                        .foregroundStyle(AppColors.ochreText)
                        .frame(width: 40, height: 40)
                        .background(AppColors.ochre.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Play queue · \(PlayQueueRows.countLine(rows.count))")
                            .font(.headline)
                        if let next = PlayQueueRows.nextLine(rows) {
                            // Wraps rather than stopping at one line: cut short, a long title read "Next: Are Prediction…"
                            // at every text size (#1990).
                            Text(next)
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.playQueue.button")
    }
}
