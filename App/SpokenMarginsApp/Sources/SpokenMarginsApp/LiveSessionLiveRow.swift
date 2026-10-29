import SessionKit
import SwiftUI
import UIKit

/// The sessions the Library's Live row shows (#2487 slice 1a): the running session, and sessions not yet saved,
/// quick ones included, read from the session store off the main thread. A Margin from the Watch or the Lock Screen
/// always lands in one of these, so it is always one tap from the Library.
@MainActor
final class LiveSessionBoard: ObservableObject {
    static let shared = LiveSessionBoard(files: .shared)

    @Published private(set) var rows: [LiveSessionFileWorker.Summary] = []
    let files: LiveSessionFileWorker
    private var observers: [NSObjectProtocol] = []
    private var latest = 0
    private var applied = 0

    init(files: LiveSessionFileWorker) {
        self.files = files
        let center = NotificationCenter.default
        for name in [LiveSessionSpokenMargins.changedOnDisk, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        Task { await refreshNow() }
    }

    /// Reads the rows now. A read that finishes after a newer read has been applied is dropped; one that is merely
    /// overtaken by a newer read still in flight is applied, so on return the rows are at least as fresh as this read.
    func refreshNow() async {
        await LiveSessionActivities.endExpired() // an "Ended · Resume" card whose window closed while the app was away
        latest += 1
        let ticket = latest
        let summaries = await files.summaries()
        guard ticket > applied else { return }
        applied = ticket
        if summaries != rows { rows = summaries }
    }
}

/// The Live row at the top of the Library: one line per unsaved session, the running one first. Tapping a line opens
/// that session's screen. Slice 1a keeps it simple; grouping a day's Mark-only quick sessions comes later.
struct LiveSessionLiveRows: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var board = LiveSessionBoard.shared
    @State private var opened: Opened?

    private struct Opened: Identifiable {
        var id: String
    }

    private static let shownRows = 3

    var body: some View {
        if !board.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(board.rows.prefix(Self.shownRows)) { row in
                    HStack(spacing: 8) {
                        Button { opened = Opened(id: row.id) } label: { line(row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.liveRow.\(row.id)")
                        if let until = row.resumableUntil { resumeButton(row, until: until) }
                    }
                }
                if board.rows.count > Self.shownRows {
                    Text("\(board.rows.count - Self.shownRows) more not yet saved")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .fullScreenCover(item: $opened) { opened in
                LiveSessionView(sessionId: opened.id).environmentObject(model)
            }
        }
    }

    /// Resume for the 10 minutes after End (#2883): the same rules as the Watch's, and it goes when the window closes.
    private func resumeButton(_ row: LiveSessionFileWorker.Summary, until: Date) -> some View {
        TimelineView(.explicit([min(Date.now, until), until])) { context in
            if context.date < until {
                Button {
                    Task {
                        // A refusal leaves the row as it was; the refresh drops the button that offered it.
                        if await LiveSessionResumer.resume(id: row.id) == nil {
                            NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
                        }
                    }
                } label: {
                    Label("Resume", systemImage: "play.circle").frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.liveRow.resume.\(row.id)")
            }
        }
    }

    private func line(_ row: LiveSessionFileWorker.Summary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.isRunning ? "record.circle" : (row.isQuick ? "bolt" : "stop.circle"))
                .font(.title3)
                .foregroundStyle(row.isRunning ? AppColors.accent : AppColors.secondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.isRunning ? "Live · \(row.title)" : row.title)
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .lineLimit(1)
                Text(detail(row))
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(minHeight: 44)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the session.")
    }

    private func detail(_ row: LiveSessionFileWorker.Summary) -> String {
        let count = "\(row.marginCount) Margin\(row.marginCount == 1 ? "" : "s")"
        let started = row.startedAt.formatted(date: .omitted, time: .shortened)
        if row.isRunning { return "Running since \(started) · \(count)" }
        let ended = (row.endedAt ?? row.startedAt).formatted(date: .abbreviated, time: .shortened)
        return row.isQuick ? "\(count) · last at \(ended)" : "Ended \(ended) · \(count) · not saved yet"
    }
}
