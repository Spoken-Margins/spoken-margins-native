import Foundation

/// Where an on-device voice that plays rendered chunks says the listener is, as a source offset (#4310). The Supertonic
/// client answers `currentCharOffset()` with this whenever its own voice (not the iOS fallback) has the text, so the
/// host tests read what the real client reports in each state.
///
/// `stop()` leaves no player and no chunk duration, but keeps the projection and the last chunk's start. The place is
/// then that start: the client keeps reporting where its last speech began after a stop, which the engine must not take
/// for the listener's place after a refused start (#4199).
public struct RenderedSpeechPlace: Equatable, Sendable {
    /// The prepared text, spoken characters to source offsets.
    public var projection: NormalizedSpeechText
    /// Where the playing (or last) chunk starts, in spoken characters.
    public var chunkStart: Int
    /// The chunk's length in spoken characters.
    public var chunkLength: Int
    /// Where the listener asked to start inside the chunk, in spoken characters; nil once speech moves past it.
    public var requestedStart: Int?
    /// The chunk's audio length, in seconds; 0 with no audio loaded.
    public var chunkDuration: TimeInterval

    public init(
        projection: NormalizedSpeechText, chunkStart: Int, chunkLength: Int, requestedStart: Int?,
        chunkDuration: TimeInterval
    ) {
        self.projection = projection
        self.chunkStart = chunkStart
        self.chunkLength = chunkLength
        self.requestedStart = requestedStart
        self.chunkDuration = chunkDuration
    }

    /// The source offset at `playerTime` seconds into the chunk: the chunk's spoken characters are spread evenly over its
    /// audio, and never before where the listener asked to start. With no audio to read, the chunk's own start.
    public func sourceOffset(playerTime: TimeInterval) -> Int? {
        let floor = max(chunkStart, requestedStart ?? chunkStart)
        guard chunkDuration > 0, chunkLength > 0, playerTime.isFinite else {
            return projection.sourceOffset(atSpokenCharacterOffset: floor)
        }
        let fraction = max(0, min(1, playerTime / chunkDuration))
        let spokenOffset = max(chunkStart + Int((Double(chunkLength) * fraction).rounded(.down)), floor)
        return projection.sourceOffset(atSpokenCharacterOffset: spokenOffset)
    }
}
