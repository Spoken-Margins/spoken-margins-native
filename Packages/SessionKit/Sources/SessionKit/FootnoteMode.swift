import Foundation

/// Where a listener hears an article's footnotes (#3777). Stored as a raw string in UserDefaults under `storageKey`,
/// never in the database, so older builds are unaffected. A missing or unreadable value means `whereCited`: the default
/// needs no touch (Design, Defaults taken 1), and an existing listener gets it too, because nothing was stored.
///
/// The picker offers all three (`pickerChoices`); `chime` joined it with the chime player (Design PR 6).
public enum FootnoteMode: String, CaseIterable, Equatable, Sendable {
    /// A note is read right after the sentence that cites it, and its marker is silent.
    case whereCited
    /// A soft tone plays after the citing sentence and a card offers the note; the note itself is not read unless asked.
    case chime
    /// Today's behaviour: markers are spoken as "footnote 3" and the notes come in their chapter at the end.
    case atEnd

    public static let storageKey = "footnoteMode"
    public static let `default`: FootnoteMode = .whereCited

    public init(storedValue: String?) {
        self = storedValue.flatMap(FootnoteMode.init(rawValue:)) ?? .default
    }

    /// What Settings → Voice → Controls offers, in the order it shows them (Design, Screens).
    public static let pickerChoices: [FootnoteMode] = [.whereCited, .chime, .atEnd]

    /// The row's words in Settings → Voice → Controls (Design, Screens).
    public var pickerTitle: String {
        switch self {
        case .whereCited: "Read where cited"
        case .chime: "Chime where cited"
        case .atEnd: "Read at the end"
        }
    }

    /// The caption under the picker, for the choices it offers.
    public static let pickerCaption = "Where cited: a footnote is read right after the sentence that points to it. Chime: you hear a tone and can tap to hear the note. At the end: footnotes are read in the notes section, as before."

    /// The picker's selection for a stored value. A value the picker does not offer (text that is not a mode) shows as
    /// the default, so the row never shows nothing selected; it is not written back.
    public static func pickerSelection(storedValue: String?) -> FootnoteMode {
        let stored = FootnoteMode(storedValue: storedValue)
        return pickerChoices.contains(stored) ? stored : .default
    }

    /// Whether the article's narration plan carries the note chunks (`NarrationChunkPlanner.articlePlan(_:asides:)`).
    /// The chime mode plans the same chunks as `whereCited` and skips them at play time, so both share one prepared-audio
    /// identity.
    public var plansAsides: Bool { self != .atEnd }

    /// The `asides` flag a call site passes when it builds an article's plan. An article whose prepared audio exists
    /// under the plain (no asides) identity keeps that audio, with its notes at the end, until it is prepared again for
    /// another reason; so changing the default never re-renders a Library or drops "ready offline" (Design, Defaults
    /// taken 10). An article with no matched note has one identity either way, so this only matters for one that has.
    public func asidesForPlan(preparedAudioExistsUnderPlainIdentity: Bool) -> Bool {
        plansAsides && !preparedAudioExistsUnderPlainIdentity
    }
}
