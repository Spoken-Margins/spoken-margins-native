import Foundation

/// Which on-device renderer may work for the player, and whether Library work may share Supertonic's renderer (#2695).
///
/// The Library and live narration were meant to share one serial Supertonic renderer, so they could never render at
/// once. That stops holding the moment the bundled Kitten voice stands in: Kitten has its own queue, so Supertonic's
/// queue looks free while Kitten renders flat out. On the owner's phone a Library Supertonic render then ran beside the
/// stand-in in the background and iOS stopped the app for its CPU. Once a stand-in holds the item, nothing renders
/// Supertonic for the player or the Library; saved Supertonic audio may still play under `SavedVoiceRunRule` (#1680).
public enum OnDeviceRenderAdmission {
    public enum LiveRenderer: Equatable, Sendable {
        /// The listener's chosen voice renders the next chunk.
        case chosen
        /// The bundled voice renders it and keeps the item (#849, #1786).
        case standIn
        /// Neither may: the iOS voice takes the passage.
        case none
    }

    /// Who renders live narration's next chunk. A stand-in that holds the item keeps rendering it, whatever the phone
    /// allows again, so the voice never bounces (#1680).
    public static func liveRenderer(chosenAllowed: Bool, standInHolds: Bool, standInAvailable: Bool) -> LiveRenderer {
        if standInAvailable, standInHolds || !chosenAllowed { return .standIn }
        return chosenAllowed ? .chosen : .none
    }

    /// What Supertonic's player shows right now, for `libraryMayShareRenderer`.
    public struct Live: Equatable, Sendable {
        public var isPlaying: Bool
        /// A stand-in voice (Kitten or the iOS voice) holds the item.
        public var standInHolds: Bool
        /// Playback waits for a chunk, or hasn't started.
        public var isWaiting: Bool
        /// The whole item is rendered.
        public var isFullyRendered: Bool
        /// Rendered chunks waiting one after another past the playing one, counted up to two; the end of the item
        /// counts as rendered.
        public var chunksAhead: Int

        public init(isPlaying: Bool, standInHolds: Bool, isWaiting: Bool, isFullyRendered: Bool, chunksAhead: Int) {
            self.isPlaying = isPlaying
            self.standInHolds = standInHolds
            self.isWaiting = isWaiting
            self.isFullyRendered = isFullyRendered
            self.chunksAhead = chunksAhead
        }
    }

    /// Chunks that must wait rendered past the playing one before speculative Library work may use the renderer.
    public static let chunksAheadForLibrary = 2

    /// Whether speculative Library work may share Supertonic's serial renderer. Never while a stand-in holds: its
    /// renderer runs beside Supertonic's, not in turn with it.
    public static func libraryMayShareRenderer(_ live: Live) -> Bool {
        guard live.isPlaying else { return true }
        if live.standInHolds || live.isWaiting { return false }
        return live.isFullyRendered || live.chunksAhead >= chunksAheadForLibrary
    }
}
