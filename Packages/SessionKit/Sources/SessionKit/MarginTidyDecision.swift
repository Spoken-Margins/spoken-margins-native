import Foundation

/// What the listener chose about the tidy version of one of their own spoken Margins (#4339).
///
/// The words themselves are not stored here. An approved tidy lives in `Interjection.cleanedTranscript` and
/// `displayText`, which every reader already prefers, and the recording and `transcript` are never written. This is
/// only the answer, so "Keep mine" is not asked again, and so the card can tell "used" from "never offered".
///
/// The JSON is flat on purpose: `{"choice": "usedTidy", "source": "fillers", "decidedAt": "…"}`. Both enums have
/// String raw values and no associated values, and the field is optional on `Interjection`, so a row written with it
/// still decodes in Build 29, which ignores keys it does not know. It is local to the Margin's author: it is never in a
/// packet (a packet is built from a reviewed share revision, not from the Margin row).
public enum MarginTidyChoice: String, Codable, Equatable, Sendable {
    case usedTidy
    case keptOriginal
}

/// Where an approved tidy came from: the text rules alone, or the on-device model checked by the guard.
public enum MarginTidySource: String, Codable, Equatable, Sendable {
    case fillers
    case onDeviceAI
}

public struct MarginTidyDecision: Codable, Equatable, Sendable {
    public var choice: MarginTidyChoice
    /// Set when `choice` is `usedTidy`; a "kept mine" has no source.
    public var source: MarginTidySource?
    public var decidedAt: Date

    public init(choice: MarginTidyChoice, source: MarginTidySource? = nil, decidedAt: Date) {
        self.choice = choice
        self.source = source
        self.decidedAt = decidedAt
    }
}
