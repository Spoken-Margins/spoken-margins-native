import Foundation

/// What a spoken note is called (#3663): a useful title made for it, and the rules for a title the listener types.
///
/// A new note is named for the day it was made (`Spoken note, Nov 8, 2:18 PM`), and once its words arrive, for the day and
/// the first words it holds (`Nov 8 · Buy milk and call the dentist`). That made-up title follows the transcript only while
/// it is still exactly what this type would make from the stored row: the row itself says whether the listener has
/// renamed it, so nothing new is stored and the previous build reads the title as plain text. A note that exists today
/// keeps the title it has (`Spoken note`, or one the listener typed) because that is not what this type would make.
public enum SpokenNoteTitle {
    /// The longest title a listener can keep, in characters. A longer one is cut, never refused.
    public static let maxLength = 120
    /// The most words of the transcript that go into a made-up title, and the most characters those words may take.
    static let maxWords = 6
    static let maxWordCharacters = 48

    /// The title made for a note: its day and first words once it has words, its day and time before that.
    /// - Parameters:
    ///   - createdAt: When the note was made. Without it (an item with no date) the title is the plain `Spoken note`.
    ///   - text: The note's transcript so far, if any.
    public static func automatic(
        createdAt: Date?,
        text: String?,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        guard let createdAt else { return SpokenNoteItem.defaultTitle }
        func formatted(_ template: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.calendar = calendar
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: createdAt)
        }
        if let words = firstWords(of: text) {
            return "\(formatted("MMMd")) · \(words)"
        }
        return "\(SpokenNoteItem.defaultTitle), \(formatted("MMMdjm"))"
    }

    /// The first few words of a transcript for a title: whitespace (and line breaks) collapsed, at most `maxWords` words and
    /// `maxWordCharacters` characters, cut at a word, with the punctuation that ends a phrase taken off the end. Nil when there are
    /// no words to speak of (empty, or only punctuation).
    public static func firstWords(of text: String?) -> String? {
        guard let text else { return nil }
        var taken: [Substring] = []
        var length = 0
        for word in text.split(whereSeparator: \.isWhitespace).prefix(maxWords) {
            let total = length + (taken.isEmpty ? 0 : 1) + word.count
            if total > maxWordCharacters {
                // One very long word on its own is cut rather than dropped, so the title still says something.
                if taken.isEmpty { taken.append(word.prefix(maxWordCharacters)) }
                break
            }
            taken.append(word)
            length = total
        }
        // Only what ends a phrase comes off the end; a quote or bracket that is open stays, so it still closes.
        let phraseEnd = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?…-–—"))
        let phrase = taken.joined(separator: " ").trimmingCharacters(in: phraseEnd)
        return phrase.isEmpty ? nil : phrase
    }

    /// A title as the listener typed it, made fit to keep: line breaks, tabs and other control or space characters become one
    /// space, runs of spaces collapse, the text-direction overrides that can make a title read backwards are dropped, and
    /// it is cut to `maxLength` characters. Letters of every script, emoji and punctuation are kept as typed. Nil when
    /// nothing is left (blank, or only spaces): the caller then goes back to the made-up title.
    public static func normalized(_ input: String) -> String? {
        let scalars = input.unicodeScalars.compactMap { scalar -> Character? in
            if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { return nil }
            if scalar.properties.generalCategory == .control || scalar.properties.isWhitespace { return " " }
            return Character(scalar)
        }
        let collapsed = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let cut = String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }

    /// Whether an item's title is the made-up one for its day and words, so it may follow the transcript.
    public static func isAutomatic(_ item: Item) -> Bool {
        item.title == automatic(createdAt: item.createdAt, text: item.text)
    }

    /// The row after the listener renames it, or nil when nothing changes (it already has that title) or the row is not a
    /// note that can be renamed (not a spoken note, or in Recently Deleted). A blank title goes back to the made-up one,
    /// which follows the transcript again. Only the title changes: the audio, the transcript and the Margins are not on
    /// the row's title, and nothing else on the row is touched.
    public static func renamed(_ item: Item, to input: String) -> Item? {
        guard SpokenNoteItem.isSpokenNote(mediaType: item.mediaType), item.deletedAt == nil else { return nil }
        // Saving a title that reads the same as the one it has is no rename. The prompt starts with the current title, and the
        // made-up one can hold spaces that `normalized` turns into plain ones (the narrow space before "PM"), so that tap
        // must not turn a title that follows the words into one that has stopped following them.
        if input == item.title { return nil }
        let typed = normalized(input)
        if let typed, typed == normalized(item.title) { return nil }
        let title = typed ?? automatic(createdAt: item.createdAt, text: item.text)
        guard title != item.title else { return nil }
        var row = item
        row.title = title
        return row
    }
}
