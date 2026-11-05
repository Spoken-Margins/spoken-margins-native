import Foundation

/// A friend's written Margin is heard, not shown (owner, 2026-11-02, #3365): a tone, then the iPhone's voice reads the
/// words, introduced as the sender's so a synthetic voice never passes for the sender's own. This file holds what is
/// decidable on the host: which imported Margins count as written, and the words that are read.

/// The stand-in words a voice Margin travels with when it has none of its own (`SharedMarginPlaceholder`, #3027).
/// They say what the Margin is, not what the sender wrote, so they are never read aloud as the sender's words.
public enum SharedMarginPlaceholderWords {
    private static let months = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec"
    // The shape `SharedMarginPlaceholder.words` and the web app's `voicePlaceholder` both write: every part after
    // "Voice Margin" is optional, and the whole text must match, so a note that merely begins that way is still a note.
    private static let shape = try? NSRegularExpression(
        pattern: "^Voice Margin(?: at \\d+:\\d{2}(?::\\d{2})?)?(?: in “[^\\n]*”)?(?:, recorded \\d{1,2} (?:\(months)) \\d{4})?$"
    )

    /// Whether these words are a voice Margin's placeholder. Whitespace at the ends and the composed or decomposed form
    /// of a title's letters make no difference.
    public static func matches(_ words: String) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return shape?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

extension ImportedCommentaryInterjection {
    /// A written Margin: the sender typed it, so it has words and no recording. A Margin with a recording (even one
    /// this copy has lost), with blank words, or with only a voice Margin's placeholder words is not written, so the
    /// reading never says "Cole wrote: Voice Margin at 12:34". Words the voice has nothing to say for (only emoji, say)
    /// are not written either: the listener would hear "Cole wrote:" and silence, and the Margin would count as heard.
    public var isWritten: Bool {
        audioPath == nil
            && !approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !SharedMarginPlaceholderWords.matches(approvedTranscript)
            && WrittenMarginSpeech.isReadable(approvedTranscript)
    }
}

/// The words the voice reads for a note, decided once for the offer and the render alike (#3365). A friend's note is plain
/// words, not an article, so it does not go through the article cleaning (`SpeechTextNormalizer.projectForSystemSpeech`),
/// which drops the combining marks Hindi and Thai are written with and reads "Great point.Totally agree" as a web
/// address. Only links and emoji are removed; every other script, mark and punctuation mark stays. A note is readable
/// when words remain. Whether the phone has a voice for its language is `WrittenMarginReader`'s answer at render time.
public enum WrittenMarginSpeech {
    /// How much of a note is looked at when deciding whether it is readable, so the cost stays flat for a sender's
    /// 50,000-character note that the main thread would otherwise scan every time a card is built.
    static let examinedCharacters = 1_000
    nonisolated(unsafe) private static let answers = NSCache<NSString, NSNumber>() // NSCache is thread-safe
    private static let link = try? NSRegularExpression(pattern: #"(?i)\b(?:https?://|www\.)[^\s<>()]+"#)

    /// The note with links and emoji removed and whitespace collapsed.
    public static func speakable(_ words: String) -> String {
        var text = words
        if let link { text = link.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") }
        var kept = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned, .enclosingMark:
                kept.append(" ")
            default:
                if scalar.properties.isEmoji, scalar.value > 0x7F, !scalar.properties.isAlphabetic { continue }
                kept.append(scalar)
            }
        }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func isReadable(_ words: String) -> Bool {
        let sample = String(words.prefix(examinedCharacters))
        let key = sample as NSString
        if let known = answers.object(forKey: key) { return known.boolValue }
        let answer = speakable(sample).contains { $0.isLetter || $0.isNumber }
        answers.setObject(NSNumber(value: answer), forKey: key)
        return answer
    }
}

/// What the voice says for a written Margin: who wrote it, then the words. Held apart from any one Margin (text, spoken
/// intro) so the later reading of an episode's quote before a Margin (owner, 2026-11-02) can use the same reader.
public struct WrittenMarginReading: Sendable, Equatable {
    /// "Cole wrote:", or "Your friend wrote:" when the sender gave no name.
    public let intro: String
    public let text: String

    /// What the voice is given: the intro, then the note without its links and emoji. Worked out once, here.
    public let spokenText: String

    /// The item the note is on. It names the rendered file, so everything rendered for an item can be removed when the
    /// item is deleted for good (a friend's words must not outlive the item they were on).
    public let itemId: String

    public init(intro: String, text: String, itemId: String = "") {
        self.itemId = itemId
        self.intro = intro
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        spokenText = "\(intro) \(WrittenMarginSpeech.speakable(self.text))"
    }

    /// The same words as the web page's `writtenIntro` (`Web/src/app/logic/arrival.ts`): the sender's name as they wrote
    /// it, and "Your friend" for no name or for the name import stores when the sender gave none.
    public static func intro(senderName: String?) -> String {
        let name = SharedPacketArrival.senderName(senderName) ?? "" // the stand-ins for no name are no name (#3247)
        let isAnonymous = name.isEmpty || name.lowercased() == "your friend"
        return "\(isAnonymous ? "Your friend" : name) wrote:"
    }

    /// A note longer than this is rendered when the listener asks for it, not ahead of time when the item opens: about
    /// 40 seconds of speech, so the work and the storage are not spent on a Margin that may never be played.
    public static let preRenderCharacterLimit = 600

    public var isShortEnoughToRenderAhead: Bool { text.count <= Self.preRenderCharacterLimit }

    /// The reading for a friend's Margin, or nil when it has a recording to play instead. The one place that builds it.
    public static func of(_ margin: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> WrittenMarginReading? {
        guard margin.isWritten else { return nil }
        return WrittenMarginReading(intro: intro(senderName: layer.displayLabel), text: margin.approvedTranscript, itemId: layer.itemId ?? "")
    }
}

extension SharedMarginReview.Entry {
    /// The reading for this Margin, or nil when it has a recording to play instead.
    public var writtenReading: WrittenMarginReading? {
        WrittenMarginReading.of(interjection, in: layer)
    }
}
