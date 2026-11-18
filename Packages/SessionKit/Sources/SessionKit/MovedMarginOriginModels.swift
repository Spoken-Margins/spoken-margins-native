import Foundation

/// Where a Margin that was moved from a live session onto a Library item came from, and whether it has a place on that
/// item (#4233, PR 1 of the Design). It is stored as a record of its own (kind `moved_margin_origin`), keyed by the
/// Margin's session and id like the Margin, and never as a field of the Margin's payload: the previous build drops fields
/// it doesn't know when it saves a Margin, and a Margin that lost "no place" would read 0% for good
/// (`docs/workstreams/interfaces.md`). The store attaches it to the Margin on every read as `Interjection.movedOrigin`.
///
/// Nothing creates one until the Move feature lands (PR 7a), so a Library holds none today.
public struct MovedMarginOrigin: Codable, Equatable, Sendable {
    /// The item Margin this describes: `Interjection.id`.
    public var marginId: String
    public var itemId: String
    /// The item-side session that holds the Margin: `Interjection.sessionId`.
    public var sessionId: String
    /// The Margin's id in the live session it came from, so a move that was cut short can be finished or undone.
    public var liveMarginId: String
    public var fromLiveSessionId: String
    public var fromLiveSessionTitle: String
    /// What the live session said about where the Margin was in the thing it was about, as the Session pane read it
    /// ("about 1:23:10"). The listener's own words about the outside source: it is shown and never used as a place.
    public var sessionPlaceLabel: String?
    /// When the Margin was marked. It is also the Margin's `createdAt`, so the Margins tab dates the row by it.
    public var markedAt: Date
    /// The Watch's clock reading when it recorded the Margin, if the Margin came from the Watch.
    public var deviceMarkedAt: Date?
    public var movedAt: Date
    /// Whether the Margin has a place on the item. False: no playback position was stored at capture and none is
    /// invented, so the Margin says "No place" and is left out of packets.
    public var placeKnown: Bool
    /// What gave a known place: `savedRun` (the app's own record of what was playing) or `watchTarget` (the Watch's target
    /// for the same item). Nil when the place is not known. A string, so a value a later build adds still decodes.
    public var placeSource: String?
    /// The live Margin's own notes, kept for good: why it was filed where it was, what the clock said, and the recording.
    public var filingNote: String?
    public var clockNote: String?
    public var spokenOn: String?
    public var durationMs: Int?

    public init(
        marginId: String, itemId: String, sessionId: String,
        liveMarginId: String, fromLiveSessionId: String, fromLiveSessionTitle: String,
        sessionPlaceLabel: String? = nil,
        markedAt: Date, deviceMarkedAt: Date? = nil, movedAt: Date,
        placeKnown: Bool, placeSource: String? = nil,
        filingNote: String? = nil, clockNote: String? = nil, spokenOn: String? = nil, durationMs: Int? = nil
    ) {
        self.marginId = marginId
        self.itemId = itemId
        self.sessionId = sessionId
        self.liveMarginId = liveMarginId
        self.fromLiveSessionId = fromLiveSessionId
        self.fromLiveSessionTitle = fromLiveSessionTitle
        self.sessionPlaceLabel = sessionPlaceLabel
        self.markedAt = markedAt
        self.deviceMarkedAt = deviceMarkedAt
        self.movedAt = movedAt
        self.placeKnown = placeKnown
        self.placeSource = placeSource
        self.filingNote = filingNote
        self.clockNote = clockNote
        self.spokenOn = spokenOn
        self.durationMs = durationMs
    }

    public static let recordKind = "moved_margin_origin"
}

/// What `Interjection` holds that is neither stored in the Margin's row nor part of its `==`: the origin of a moved
/// Margin, attached by the store when it reads. Two reads of the same stored Margin are equal whether or not either
/// had its origin attached, so existing comparisons of Margins mean what they always did.
@propertyWrapper
public struct NotStoredOrCompared<Value: Sendable>: Equatable, Sendable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }

    public static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// The origin records of moved Margins. Defaults keep stores that don't adopt it (test doubles) compiling: they hold no
/// origins and refuse to save one rather than drop it silently.
public protocol MovedMarginOriginRepository {
    /// Saves the origin of a moved Margin, replacing an earlier one for the same Margin.
    func saveMovedMarginOrigin(_ origin: MovedMarginOrigin) throws
    /// Removes the origin of one Margin. Nothing happens when there is none.
    func deleteMovedMarginOrigin(marginId: String, sessionId: String) throws
    /// Every origin whose Margin is still active (not deleted), for finishing a move that was cut short.
    func loadMovedMarginOrigins() throws -> [MovedMarginOrigin]
    /// Removes a moved Margin's row and its origin outright. The recording file is left alone: the live session may
    /// still name it.
    func deleteMovedMargin(id: String, sessionId: String) throws
}

extension MovedMarginOriginRepository {
    public func saveMovedMarginOrigin(_ origin: MovedMarginOrigin) throws {
        throw SessionKitError.persistenceFailed("moved_margin_origin_unsupported")
    }

    public func deleteMovedMarginOrigin(marginId: String, sessionId: String) throws {}

    public func loadMovedMarginOrigins() throws -> [MovedMarginOrigin] { [] }

    public func deleteMovedMargin(id: String, sessionId: String) throws {
        throw SessionKitError.persistenceFailed("moved_margin_origin_unsupported")
    }
}
