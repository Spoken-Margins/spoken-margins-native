import Foundation

/// Writes a written Margin's text to its journal when typing pauses, and straight away when the app is about to
/// leave the screen (#1970). Each keystroke would otherwise rewrite the file; this keeps one write per pause.
///
/// The file work runs on a serial utility queue, not the main actor (#2510): the call is queued at once and in order,
/// so a write is never overtaken by a later discard, and the screen never waits on the disk.
@MainActor
public final class WrittenMarginDraftSaver {
    private let journal: WrittenMarginDraftJournal?
    private let pause: Duration
    private let now: () -> Date
    private let onFailure: (String) -> Void
    private var pending: Task<Void, Never>?
    private let writer = DispatchQueue(label: "SessionKit.WrittenMarginDraftSaver.writer", qos: .utility)

    /// - Parameter journal: nil when the app has no folder to keep drafts in; every call then does nothing.
    public init(
        journal: WrittenMarginDraftJournal?,
        pause: Duration = .seconds(1),
        now: @escaping () -> Date = Date.init,
        onFailure: @escaping (String) -> Void = { _ in }
    ) {
        self.journal = journal
        self.pause = pause
        self.now = now
        self.onFailure = onFailure
    }

    /// The listener typed: the latest text is written once typing has been quiet for the pause.
    public func textChanged(_ text: String, capture: WrittenInterjectionCapture) {
        pending?.cancel()
        pending = Task { [pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            write(text, capture: capture)
        }
    }

    /// The app is going to the background or closing: write now.
    public func flush(_ text: String, capture: WrittenInterjectionCapture) {
        pending?.cancel()
        pending = nil
        write(text, capture: capture)
    }

    /// The Margin was saved or discarded: nothing is left to recover.
    public func discard(captureId: String) {
        pending?.cancel()
        pending = nil
        guard let journal else { return }
        writer.async { [weak self] in
            do { try journal.remove(id: captureId) } catch { self?.failed("remove:\(error.localizedDescription)") }
        }
    }

    private func write(_ text: String, capture: WrittenInterjectionCapture) {
        guard let journal else { return }
        let record = WrittenMarginDraftRecord(capture: capture, text: text, updatedAt: now())
        writer.async { [weak self] in
            do { try journal.write(record) } catch { self?.failed("write:\(error.localizedDescription)") }
        }
    }

    /// Reports a failed file call on the main actor, where `onFailure` lives.
    private nonisolated func failed(_ detail: String) {
        Task { @MainActor [weak self] in self?.onFailure(detail) }
    }

    /// Returns once every queued write and removal has landed. For tests.
    func waitForWrites() { writer.sync {} }
}
