import Foundation

/// Which shared Margins are new to this listener (#469). A shared Margin is new until its voice
/// first plays, by any route; the repository records that time once
/// (`markImportedCommentaryInterjectionHeard`).
public enum SharedMarginHearing {
    /// `margin` as it reads once its voice has played at `date`: the first time sticks. The screen shows this at once;
    /// the repository records the same fact (`markImportedCommentaryInterjectionHeard`) off the main thread (#2509).
    public static func heard(_ margin: ImportedCommentaryInterjection, at date: Date) -> ImportedCommentaryInterjection {
        var margin = margin
        if margin.firstHeardAt == nil { margin.firstHeardAt = date }
        return margin
    }

    /// `records` (an item's shared Margins by layer) with `heard` in place of its older copy.
    public static func replacing(
        _ heard: ImportedCommentaryInterjection,
        in records: [String: [ImportedCommentaryInterjection]]
    ) -> [String: [ImportedCommentaryInterjection]] {
        var records = records
        records[heard.layerId] = records[heard.layerId]?.map { $0.id == heard.id ? heard : $0 }
        return records
    }

    /// Whether a Margin with no recording is something this listener can still meet on this phone (#3402): a note a voice
    /// here can read, or one reading was turned off for, whose words are met on its details sheet (#3427). A note with
    /// nothing to say (only emoji or a link), or with no voice here, has no way to be met, so it can't wait as new.
    /// Asked on every read, never stored: a voice downloaded later makes the note new again, and no "heard" fact is made.
    public static func noteCanBeMet(words: String, readAloudChoice: Bool) -> Bool {
        WrittenMarginSpeech.isNote(words) && (!readAloudChoice || WrittenMarginSpeech.hasVoice(for: words))
    }
}

extension ImportedCommentaryInterjection {
    /// Whether screens call this Margin new. `isNewToListener` is the stored fact (not heard yet); this is that fact,
    /// less a Margin the listener has no way to meet (#3402). The Library's SQL count applies the same rule
    /// (`SQLiteSessionStore.loadSharedMarginTallies`) through `noteCanBeMet`.
    public var showsAsNew: Bool {
        isNewToListener && (audioPath != nil || SharedMarginHearing.noteCanBeMet(words: approvedTranscript, readAloudChoice: readAloudChoice))
    }
}
