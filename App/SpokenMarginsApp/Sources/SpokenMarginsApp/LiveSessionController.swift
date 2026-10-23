import ActivityKit
import Foundation
import SessionKit

/// Drives the live session screen (#1989, #2481): Margins on a clock while something plays or is read outside
/// the app, with nothing recorded. The session is kept in Application Support so closing the app never loses
/// it; Lock Screen Marks arrive through `LiveSessionMarkQueue` and are merged in while the screen is open.
@MainActor
final class LiveSessionController: ObservableObject {
    @Published private(set) var session: LiveSession?
    @Published private(set) var now = Date()
    @Published var errorMessage: String?

    private let directory = Gate1AppModel.liveSessionDirectory
    private var pollTask: Task<Void, Never>?

    func load() {
        guard let directory else { return }
        session = LiveSessionStore.load(from: directory)
        mergeMarks()
        startPolling()
    }

    var isRunning: Bool { session != nil && session?.endedAt == nil }
    var hasEnded: Bool { session?.endedAt != nil }

    var elapsedMs: Int {
        guard let session else { return 0 }
        let end = session.endedAt ?? now
        return max(0, Int((end.timeIntervalSince(session.startedAt) * 1_000).rounded()))
    }

    /// The estimated source position now, "about 1:23:10", when the listener gave a start position.
    func predictedPosition(adjustmentMs: Int = 0) -> LiveSessionPositionMap.Position? {
        guard let session, var position = LiveSessionPositionMap.position(at: now, in: session) else { return nil }
        position.ms = max(0, position.ms + adjustmentMs)
        return position
    }

    func start(kind: ElsewhereKind, title: String, startPositionMs: Int?, startWhere: String?) {
        _ = LiveSessionMarkQueue.drain() // Marks from before this session don't belong to it.
        let started = LiveSession(
            id: "live-\(UUID().uuidString.lowercased())", kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: Date(),
            startPositionMs: startPositionMs, startWhere: startWhere
        )
        session = started
        save()
        startActivity(startedAt: started.startedAt)
    }

    /// Ends the session. Rejects an end position before the start position.
    func end(endPositionMs: Int?, endWhere: String?) -> Bool {
        do {
            try LiveSessionPositionMap.validate(startPositionMs: session?.startPositionMs, endPositionMs: endPositionMs)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        mergeMarks()
        session?.endedAt = Date()
        session?.endPositionMs = endPositionMs
        session?.endWhere = endWhere
        save()
        endActivities()
        return true
    }

    /// Adds a Margin now. `adjustmentMs` is the listener's slide of the predicted position; nonzero stores it as
    /// their own position.
    func addMargin(text: String, whereNote: String?, adjustmentMs: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, let current = session, !trimmed.isEmpty else { return }
        let markedAt = Date()
        var margin = current.margin(id: UUID().uuidString.lowercased(), text: trimmed, markedAt: markedAt, whereNote: whereNote)
        if adjustmentMs != 0, let estimate = LiveSessionPositionMap.position(at: markedAt, in: current) {
            margin.listenerPositionMs = max(0, estimate.ms + adjustmentMs)
        }
        session?.margins.append(margin)
        session?.margins.sort { $0.markedAt < $1.markedAt }
        save()
    }

    func updateText(id: String, text: String) {
        guard let index = session?.margins.firstIndex(where: { $0.id == id }) else { return }
        session?.margins[index].text = text
        save()
    }

    func removeMargin(id: String) {
        session?.margins.removeAll { $0.id == id }
        save()
    }

    /// Forgets the session and its Margins.
    func discard() {
        endActivities()
        session = nil
        if let directory { LiveSessionStore.remove(from: directory) }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.now = Date()
                self?.mergeMarks()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func mergeMarks() {
        guard isRunning else { return }
        let marks = LiveSessionMarkQueue.drain()
        guard !marks.isEmpty else { return }
        if session?.mergeMarks(marks) ?? 0 > 0 { save() }
    }

    private func save() {
        guard let directory, let session else { return }
        do {
            try LiveSessionStore.save(session, in: directory)
        } catch {
            errorMessage = "Couldn't save the live session: \(error.localizedDescription)"
        }
    }

    private func startActivity(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // The Lock Screen Mark is a convenience; the session works without it.
        _ = try? Activity<LiveSessionActivityAttributes>.request(
            attributes: LiveSessionActivityAttributes(sessionStartedAt: startedAt),
            content: ActivityContent(state: .init(markCount: 0), staleDate: nil),
            pushType: nil
        )
    }

    private func endActivities() {
        Task {
            for activity in Activity<LiveSessionActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
