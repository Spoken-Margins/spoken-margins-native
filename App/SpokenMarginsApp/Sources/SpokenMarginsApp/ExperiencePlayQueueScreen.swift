import SessionKit
import SwiftUI

/// The play queue (#1990): what plays next, in order. Tap a row to play it now, drag to reorder (Edit), swipe to remove,
/// Clear to empty it. It opens from the Library's "Play queue" row, which only shows while something is queued.
struct ExperiencePlayQueueScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var state = PlayQueueState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingClear = false

    private var rows: [PlayQueueRow] {
        PlayQueueRows.rows(for: PlayQueue(itemIds: state.itemIds), items: model.libraryItems)
    }

    var body: some View {
        NavigationStack {
            let current = rows
            List {
                if current.isEmpty {
                    ContentUnavailableView(
                        "Nothing queued",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: Text("Choose Play Next or Add to Queue on an episode, article or PDF, and it plays after the one you are listening to.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(current) { row in
                            Button {
                                dismiss()
                                model.playQueuedItemNow(itemId: row.id)
                            } label: {
                                PlayQueueRowLabel(row: row)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Plays it now")
                            .accessibilityIdentifier("playQueue.row.\(row.id)")
                        }
                        .onMove { model.moveInQueue(fromOffsets: $0, toOffset: $1) }
                        .onDelete { offsets in
                            for id in offsets.map({ current[$0].id }) { model.removeFromQueue(itemId: id) }
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
                    Button("Done") { dismiss() }
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
                Button("Clear queue", role: .destructive) { model.clearPlayQueue() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything in your Library stays.")
            }
            .onAppear { model.loadPlayQueue() }
        }
        .accessibilityIdentifier("playQueue.screen")
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
