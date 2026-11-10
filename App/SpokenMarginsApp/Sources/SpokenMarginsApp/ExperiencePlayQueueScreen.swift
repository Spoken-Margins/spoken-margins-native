import SessionKit
import SwiftUI

/// The play queue (#1990): what plays next, in order. Tap a row to play it now, drag to reorder (Edit), swipe to remove,
/// Clear to empty it. It opens from the Library's "Play queue" row, which only shows while something is queued.
///
/// This view only reads the queue and the Library, and hands the sheet its rows and what its buttons do. It watches
/// `Gate1AppModel`, which publishes many times a second while audio plays, and the sheet is `.equatable()`: a model
/// publish that leaves the rows as they were does not redraw the sheet. Redrawn on every publish, the list in Edit mode
/// kept restarting its edit transition, so the rows hopped and the remove icons flickered (#3891).
struct ExperiencePlayQueueScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var state = PlayQueueState.shared

    var body: some View {
        PlayQueueSheet(
            rows: PlayQueueRows.rows(for: PlayQueue(itemIds: state.itemIds), items: model.libraryItems),
            actions: PlayQueueSheetActions(
                load: { model.loadPlayQueue() },
                playNow: { model.playQueuedItemNow(itemId: $0) },
                remove: { model.removeFromQueue(itemId: $0) },
                move: { model.moveInQueue(fromOffsets: $0, toOffset: $1) },
                clear: { model.clearPlayQueue() }
            )
        )
        .equatable()
    }
}

/// What the queue sheet's buttons do. Not part of the sheet's equality: they only reach the model, which does not change.
struct PlayQueueSheetActions {
    let load: () -> Void
    let playNow: (String) -> Void
    let remove: (String) -> Void
    let move: (IndexSet, Int) -> Void
    let clear: () -> Void
}

#if DEBUG
/// Counts how often the queue sheet's body runs, and how SwiftUI's equality check on the sheet came out, so a test can
/// tell a redraw from a skipped one and a failure says which kind it was (#3891, #3999). `==` is not main-actor, so its
/// two counters are not either; SwiftUI calls it on the main thread.
@MainActor
enum PlayQueueSheetProbe {
    static var bodyRuns = 0
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
                            PlayQueueDismissingButton(action: { actions.playNow(row.id) }) {
                                PlayQueueRowLabel(row: row)
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
                    PlayQueueDismissingButton(action: {}) { Text("Done") }
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

/// A button that closes the sheet, then does its action. It reads `dismiss` here, in its own small view, not in the
/// sheet: a sheet that reads an environment value is redrawn whenever SwiftUI says that value changed, whatever its
/// `==` says, and a redraw per model publish is what #3891 removed (#3999).
private struct PlayQueueDismissingButton<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            label()
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
