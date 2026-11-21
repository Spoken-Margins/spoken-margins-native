import Foundation

/// What became of one tap on a Margin's play button, logged once per tap as `margin.tap` (#4447).
///
/// The owner's export of 2026-11-17 had a line for every Skim press and every seek, but none for a tap on a Margin in
/// the Margins tab. A tap that did nothing left no trace, so nobody could tell a dead button from a dropped result.
/// Every way a tap can end without playing now has a reason, and the reason is the `reason` field in Diagnostics.
public enum MarginTapOutcome: Equatable, Sendable {
    /// The Margin's moment started.
    case started
    /// The tap is kept and plays by itself when the Margin's reading is made.
    case waiting(MarginTapReason)
    /// The tap was turned down at once, and the listener was told why.
    case refused(MarginTapReason)
    /// The tap was taken, but its result was thrown away before it played, because things had moved on.
    case dropped(MarginTapReason)

    /// The `outcome` field.
    public var name: String {
        switch self {
        case .started: return "started"
        case .waiting: return "waiting"
        case .refused: return "refused"
        case .dropped: return "dropped"
        }
    }

    public var reason: MarginTapReason? {
        switch self {
        case .started: return nil
        case .waiting(let reason), .refused(let reason), .dropped(let reason): return reason
        }
    }

    /// The fields of the `margin.tap` Diagnostics event. Only the origin, outcome and reason: never a Margin's words,
    /// its id or the item it belongs to.
    public func diagnosticFields(origin: MarginTapOrigin) -> [String: String] {
        var fields = ["origin": origin.rawValue, "outcome": name]
        if let reason { fields["reason"] = reason.rawValue }
        return fields
    }
}

/// Whose Margin was tapped. The raw value is the `origin` field.
public enum MarginTapOrigin: String, Equatable, Sendable {
    case own
    case shared
}

/// Why a tap did not play. The raw value is the `reason` field in Diagnostics.
public enum MarginTapReason: String, CaseIterable, Equatable, Sendable {
    /// A Margin is being recorded, and a tap must not leave its listening position.
    case recordingInProgress = "recording_in_progress"
    /// The Library could not be opened.
    case storeUnavailable = "store_unavailable"
    /// The Margin's session or its item could not be read (deleted, or no longer active).
    case marginUnavailable = "margin_unavailable"
    /// A friend's Margin whose source is not in the Library.
    case sourceNotInLibrary = "source_not_in_library"
    /// A friend's Margin with no position in the episode.
    case noPosition = "no_position"
    /// A friend's Margin with no recording and no reading to play.
    case noAudio = "no_audio"
    /// A written Margin whose reading is still being made; the tap plays when it is ready.
    case readingNotReady = "reading_not_ready"
    /// The Margin's item did not become the open item, so there was nowhere to seek.
    case itemDidNotOpen = "item_did_not_open"
    /// Playing the Margin's position failed after the reads (the engine refused it).
    case playFailed = "play_failed"
    /// The listener went to another screen or tab while the tap's reads ran.
    case leftScreen = "left_screen"
    /// A newer open replaced this tap's while its reads ran.
    case openSuperseded = "open_superseded"
    /// Other playback began while the tap's reads ran: another item, session or Margin moment.
    case playbackMoved = "playback_moved"
    /// The tap was cancelled while its reads ran.
    case cancelled = "cancelled"
    /// The tap was kept for a reading, and the listener left that item before it was ready.
    case leftItem = "left_item"
    /// Something else took the sound while a written Margin's reading was made; the listener was asked to tap again.
    case soundTaken = "sound_taken"
    /// A written Margin's reading could not be made.
    case readingFailed = "reading_failed"
}

/// Why a tap whose reads have finished must not play, checked in this order (`cancelled` after the open, see below). Nil: nothing moved, so it plays.
public enum MarginTapLateResult {
    public static func dropReason(
        cancelled: Bool,
        openIsCurrent: Bool,
        stillOnTheScreenTheTapCameFrom: Bool,
        playbackIsWhatTheTapSaw: Bool,
        recordingLocked: Bool
    ) -> MarginTapReason? {
        // A newer open cancels this tap's task too, so the open is checked first or `cancelled` would hide why.
        if !openIsCurrent { return .openSuperseded }
        if cancelled { return .cancelled }
        if !stillOnTheScreenTheTapCameFrom { return .leftScreen }
        if !playbackIsWhatTheTapSaw { return .playbackMoved }
        if recordingLocked { return .recordingInProgress }
        return nil
    }
}
