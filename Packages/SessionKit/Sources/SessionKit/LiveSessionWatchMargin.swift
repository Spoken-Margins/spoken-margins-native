import Foundation

// `WatchMarginTransfer` and `WatchMarginAnswer` are in WatchContract.swift (#2487 slice 1b), which the Watch app
// compiles too.

extension LiveSession {
    /// Adds a spoken Margin taken at `markedAt`, kept in time order. Returns false, changing nothing, when a Margin
    /// with this id is already there.
    @discardableResult
    public mutating func attachSpokenMargin(
        id: String, audioPath: String, markedAt: Date, durationMs: Int?, spokenOn: String, transcript: String = ""
    ) -> Bool {
        guard !margins.contains(where: { $0.id == id }) else { return false }
        var spoken = margin(id: id, text: transcript, markedAt: markedAt)
        spoken.audioPath = audioPath
        spoken.durationMs = durationMs
        spoken.spokenOn = spokenOn
        margins.append(spoken)
        margins.sort { $0.markedAt < $1.markedAt }
        return true
    }

    /// Files a Watch Margin into this session. False when it is already here.
    @discardableResult
    public mutating func attach(_ transfer: WatchMarginTransfer) -> Bool {
        attachSpokenMargin(
            id: transfer.marginId, audioPath: transfer.audioPath, markedAt: transfer.wallStart,
            durationMs: transfer.durationMs, spokenOn: "watch"
        )
    }

    /// Fills in a spoken Margin's transcript once it is ready, unless the listener has already written something.
    @discardableResult
    public mutating func setTranscript(_ text: String, forMarginId id: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = margins.firstIndex(where: { $0.id == id }),
              margins[index].isSpoken,
              margins[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        margins[index].text = trimmed
        return true
    }
}
