import Foundation

/// Which voice reads an item once the phone made the chosen voice step aside (#1786).
///
/// Owner's call (2026-10-15): "As long as we aren't bouncing back and forth". On the owner's warm phone (10-17 export)
/// narration went Kitten → Supertonic → iOS voice → Supertonic → Kitten in twelve minutes: a resume released Kitten
/// because the phone had cooled to `fair`, a background seam then found Supertonic's next chunk unrendered and gave the
/// passage to the iOS voice, and the app coming to the front gave it back to Supertonic. Each of those was a separate
/// rule letting go of the voice at a separate moment.
///
/// This is the one place a stand-in voice's hold is let go. A stand-in that takes an item keeps it to the end of that
/// item, whatever the temperature does and however often the listener pauses and plays. Only these release it:
/// - a play of another item (a new item starts with the chosen voice);
/// - the item playing to its end;
/// - a saved Supertonic run long enough under `SavedVoiceRunRule`, at a seam (#1680);
/// - the listener asking for the chosen voice again.
/// When the hold is let go during an item (a saved run), the chosen voice keeps the item from there; the bundled voice
/// takes it again only if the phone still refuses the chosen voice when the run ends.
public struct NarrationVoiceHold: Equatable, Sendable {
    public enum Voice: String, Sendable {
        /// The listener's chosen on-device voice (Supertonic).
        case chosen
        /// The bundled Kitten voice (#849).
        case bundled
        /// The iOS voice: the last resort.
        case system
    }

    /// Why a hold was let go, as the diagnostics line `voice.restored` names it.
    public enum Release: String, Sendable {
        case newItem = "new_item"
        case itemEnded = "item_ended"
        case savedRun = "saved_run"
        case listener = "listener"
    }

    public private(set) var item: String?
    /// The stand-in holding `item`; `.chosen` when nothing holds.
    public private(set) var holder: Voice = .chosen

    public init() {}

    /// The voice holding `item`, or `.chosen` when no stand-in holds it.
    public func voice(for item: String) -> Voice {
        self.item == item ? holder : .chosen
    }

    public func holds(_ item: String) -> Bool {
        voice(for: item) != .chosen
    }

    /// A stand-in voice started reading `item`. It keeps the item from here on. The iOS voice replaces a bundled voice
    /// that failed; the bundled voice never replaces the iOS voice inside an item, since that would be a second change.
    public mutating func standInTookOver(_ voice: Voice, item: String) {
        guard voice != .chosen else { return }
        if self.item == item, holder == .system, voice == .bundled { return }
        self.item = item
        holder = voice
    }

    /// The listener plays `item` (a resume, a seek, the play after an interruption, a new item). Only another item
    /// lets the hold go; cooling down, an interruption ending and the app coming to the front never do.
    @discardableResult
    public mutating func play(item: String) -> Release? {
        guard let held = self.item, held != item else { return nil }
        return release(.newItem)
    }

    /// `item` played to its end.
    @discardableResult
    public mutating func itemEnded(_ item: String) -> Release? {
        guard self.item == item else { return nil }
        return release(.itemEnded)
    }

    /// A saved Supertonic run long enough under `SavedVoiceRunRule` starts at a seam of `item` (#1680).
    @discardableResult
    public mutating func savedRunStarted(item: String) -> Release? {
        guard self.item == item, holder == .bundled else { return nil }
        return release(.savedRun)
    }

    /// The listener asked for the chosen voice again (Retry, or a new voice in Settings).
    @discardableResult
    public mutating func listenerChoseVoice() -> Release? {
        release(.listener)
    }

    /// The voice for the next chunk of `item`: the stand-in holding it, else the chosen voice when it may render, else
    /// the bundled voice when there is one, else the iOS voice.
    public func nextChunkVoice(item: String, chosenMayRender: Bool, bundledVoiceAvailable: Bool) -> Voice {
        let held = voice(for: item)
        if held != .chosen { return held }
        if chosenMayRender { return .chosen }
        return bundledVoiceAvailable ? .bundled : .system
    }

    /// The stand-in for a seam with the app in the background and the next chunk not rendered (#1673): the bundled
    /// voice whenever there is one (it holds the item from then on, or already did), the iOS voice only without it.
    /// The iOS voice already holding the item keeps it.
    public func backgroundGapStandIn(item: String, bundledVoiceAvailable: Bool) -> Voice {
        if voice(for: item) == .system { return .system }
        return bundledVoiceAvailable ? .bundled : .system
    }

    private mutating func release(_ reason: Release) -> Release? {
        guard item != nil else { return nil }
        item = nil
        holder = .chosen
        return reason
    }
}
