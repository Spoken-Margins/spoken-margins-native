import SessionKit
import SwiftUI

/// The play queue (#1990): what plays next, in order. Tap a row to play it now, drag to reorder (Edit), swipe to remove,
/// Clear to empty it. It opens from the Library's "Play queue" row, which only shows while something is queued.
///
/// This view only reads the queue and the Library, and hands the sheet its rows and what its buttons do. It watches
/// `Gate1AppModel`, which publishes many times a second while audio plays, and the sheet is `.equatable()`: a model
/// publish that leaves the rows as they were does not redraw the sheet. Redrawn on every publish, the list in Edit mode
/// kept restarting its edit transition, so the rows hopped and the remove icons flickered (#3891).
///
/// Nothing in the sheet reads `dismiss` either: the Library redraws on every publish and hands the sheet a new one each
/// time, so the rows reading it redrew, and in Edit mode faded their remove icons in again (#3891, reopened).
struct ExperiencePlayQueueScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var state = PlayQueueState.shared
    /// Closes the sheet; the presenter's own flag, so calling it from an older copy of the sheet still closes it.
    let close: () -> Void
    /// Where Edit mode starts. Only a test starts it elsewhere than off.
    var startingEditMode: EditMode = .inactive

    var body: some View {
        PlayQueueSheet(
            rows: PlayQueueRows.rows(for: PlayQueue(itemIds: state.itemIds), items: model.libraryItems),
            actions: PlayQueueSheetActions(
                load: { model.loadPlayQueue() },
                close: close,
                playNow: { model.playQueuedItemNow(itemId: $0) },
                remove: { model.removeFromQueue(itemId: $0) },
                move: { model.moveInQueue(fromOffsets: $0, toOffset: $1) },
                clear: { model.clearPlayQueue() }
            ),
            editMode: startingEditMode
        )
        .equatable()
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
    nonisolated(unsafe) static var comparisons = 0
    nonisolated(unsafe) static var unequalComparisons = 0
}
#endif

struct PlayQueueSheet: View, Equatable {
    let rows: [PlayQueueRow]
    let actions: PlayQueueSheetActions

    @State private var isConfirmingClear = false
    /// Held here, not left to the navigation stack, so Edit mode is the sheet's own and a redraw cannot reset it.
    @State private var editMode: EditMode

    init(rows: [PlayQueueRow], actions: PlayQueueSheetActions, editMode: EditMode = .inactive) {
        self.rows = rows
        self.actions = actions
        _editMode = State(initialValue: editMode)
    }

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
            .onAppear { actions.load() }
            .onChange(of: rows.isEmpty) { _, isEmpty in
                // With nothing left there is no Edit button to leave Edit mode with.
                if isEmpty { editMode = .inactive }
            }
        }
        .environment(\.editMode, $editMode)
        .accessibilityIdentifier("playQueue.screen")
    }
}

/// A queued row as a button. Its own view so a test can count its redraws: a row redrawn in Edit mode fades its remove
/// icon and handle in again (#3891).
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
