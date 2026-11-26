import Foundation

/// A tidy version of a spoken Margin, ready to show its author (#4339). Never stored: the author's answer is.
public struct MarginTidyProposal: Equatable, Sendable {
    /// Where the text came from, which the card's caption says.
    public enum Source: String, Equatable, Sendable {
        /// `MarginTidy.fillerOnly`: fillers, a repeated word and a spoken run-up removed. Every iPhone can offer it.
        case fillers
        /// The on-device model's rewrite, which passed `MarginTidyGuard`.
        case onDeviceAI
    }

    public let text: String
    public let source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }
}

/// One request to the on-device model for a tidy (#4339): the session's instructions, the prompt, the passage that went
/// into it and the reply cap. Built here, not in the app, so a host test holds the wording and the app only sends it.
public struct MarginTidyRequest: Equatable, Sendable {
    public let instructions: String
    public let prompt: String
    public let context: BoundedAnchorContext
    public let maximumResponseTokens: Int
}

/// The words the on-device model is asked to tidy a spoken Margin with (#4339).
///
/// Tuned on Apple's on-device model with `tidy-eval` and `fixtures/margin-tidy` (2026-11-24; the prompt history and the
/// scores are on #4339). What the eval showed, and why the wording is what it is:
/// - The task goes in the session's instructions and only the Margin and its passage go in the prompt: Apple's model
///   follows its instructions over its prompt, and nothing the listener said can then act as an instruction.
/// - "Copy editor" and a light edit, not a rewrite: asked to rewrite, the model brought in names from the passage and
///   turned "this reminds me of what he said" into a claim.
/// - Three short examples and an "Edited:" cue: they took the share of Margins it tidied well from 20 of 33 to 25.
///   Long examples get copied: on a Margin of about 950 words it answered with the examples themselves.
/// - Asking it to keep numbers "as said" made it spell out digits, so the guard compares numbers by value instead.
/// - The passage stays at up to 500 characters a side. More of it (1,000 to 2,000 characters before) gained nothing and
///   cost up to half a second; it is kept because it is what the card's caption promises and it lets the model
///   understand "this" and "he".
public enum MarginTidyPrompt {
    /// The date of the wording, for the record on #4339.
    public static let version = "2026-11-24"

    public static let instructions = """
        You are a careful copy editor. A listener spoke a short note while listening to a text. Turn the note into clean written text.

        Remove filler words (um, uh, you know), false starts and words said twice. Fix punctuation and capitals.
        Keep the speaker's own words, meaning, person and language. Keep every number, name, quotation, question and "not".
        Never add anything the speaker did not say. A short note stays short. Reply with the edited note only.

        Examples:
        Note: um so this is is wrong
        Edited: This is wrong.
        Note: I don't, I don't think uh 40 percent is right, you know
        Edited: I don't think 40 percent is right.
        Note: wait, is this, uh, is this per year
        Edited: Is this per year?
        """

    public static func request(transcript: String, before: String, after: String) -> MarginTidyRequest {
        let context = BoundedAnchorContext.select(before: before, after: after)
        let note = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if context.before.isEmpty && context.after.isEmpty {
            prompt = "Note: \(note)\nEdited:"
        } else {
            prompt = "Text around the note, for reference only:\n\(context.before) … \(context.after)\n\nNote: \(note)\nEdited:"
        }
        // A cap only against a runaway reply (Apple: a tight cap cuts replies off mid-sentence): about three tokens a word.
        let words = note.split(whereSeparator: \.isWhitespace).count
        return MarginTidyRequest(
            instructions: instructions,
            prompt: prompt,
            context: context,
            maximumResponseTokens: min(1_500, max(64, words * 3))
        )
    }
}

/// How a long spoken Margin is cut for the on-device model (#4339). On Apple's model a Margin of about 700 words came back
/// with a third of it missing and one of about 950 words came back as the prompt's examples, well inside the 4,096-token
/// window; up to about 450 words it stayed whole. So a Margin over `maximumWords` is tidied a piece at a time, each piece
/// in a session of its own, cut at sentence ends. Past `maximumPieces` (about 2,400 words, more than a 10-minute imported
/// voice Margin usually holds) the model is not asked at all: that many requests would take most of a minute.
public enum MarginTidyChunks {
    public static let maximumWords = 200
    public static let maximumPieces = 12

    /// `transcript` in pieces of at most `maximumWords` words, cut after a full stop, question mark or exclamation mark,
    /// else after a comma, else between words. One piece when it is short enough. The pieces joined with spaces are the
    /// transcript's words in order.
    public static func split(_ transcript: String, maximumWords: Int = maximumWords) -> [String] {
        let limit = max(1, maximumWords)
        let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > limit else { return words.isEmpty ? [] : [words.joined(separator: " ")] }
        func ends(_ word: String, with marks: String) -> Bool {
            guard let last = word.last(where: { !"\"'”’)]".contains($0) }) else { return false }
            return marks.contains(last)
        }
        // Units no longer than the limit: sentences, a long sentence cut at commas, a long clause cut between words.
        var units: [[String]] = []
        var sentence: [String] = []
        func addSentence() {
            guard !sentence.isEmpty else { return }
            if sentence.count <= limit { units.append(sentence); sentence = []; return }
            var clause: [String] = []
            for word in sentence {
                clause.append(word)
                if clause.count == limit || ends(word, with: ",;:") { units.append(clause); clause = [] }
            }
            if !clause.isEmpty { units.append(clause) }
            sentence = []
        }
        for word in words {
            sentence.append(word)
            if ends(word, with: ".?!") { addSentence() }
        }
        addSentence()
        var pieces: [[String]] = []
        for unit in units {
            if let last = pieces.last, last.count + unit.count <= limit {
                pieces[pieces.count - 1] = last + unit
            } else {
                pieces.append(unit)
            }
        }
        return pieces.map { $0.joined(separator: " ") }
    }
}

/// What the device reports when a tidy proposal decides whether to ask the model. A tidy is optional, so it never costs the
/// listener battery or heat: Low Power Mode, or a phone that is serious or critically warm, gets the filler-only version.
public struct MarginTidyConditions: Equatable, Sendable {
    public var thermal: SpeechThermalLevel
    public var isLowPowerModeEnabled: Bool

    public init(thermal: SpeechThermalLevel = .nominal, isLowPowerModeEnabled: Bool = false) {
        self.thermal = thermal
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// Whether the model may be asked. Same line as automatic preparation work (`PreparationChunkGate`).
    public var allowsModel: Bool {
        PreparationChunkGate.allowsAutomaticWork(thermal: thermal, isLowPowerModeEnabled: isLowPowerModeEnabled)
    }
}

/// Offers a spoken Margin's author a tidy version of what they said (#4339).
///
/// With no model, or one that is unavailable, throws, runs while the phone is hot or in Low Power Mode, or writes
/// something the guard rejects, the proposal is `MarginTidy.fillerOnly`. With one, the proposal is the model's rewrite from
/// the Margin's words and up to 500 characters of the passage on each side, if it keeps what was said.
///
/// The model is a closure so the rules are tested on the host with a scripted one; the app passes
/// `AppleFoundationModelClient.tidyMargin`. Nothing here touches the network, and nothing is saved: a model rewrite is
/// remembered for the app's run, keyed by the Margin and its words, so reopening a Margin doesn't ask again, and a Margin
/// whose transcript changed is asked again. A filler-only answer is not remembered: it costs nothing to make, and a
/// phone that was hot may be cool next time. Two requests for the same Margin that overlap each ask the model; the card
/// makes one request per open, so the second is not worth the bookkeeping.
public actor MarginTidyProposer {
    /// The model's rewrite of `transcript`, given the passage before and after the Margin. Throws when it can't.
    public typealias Model = @Sendable (_ transcript: String, _ before: String, _ after: String) async throws -> String

    private struct Key: Hashable {
        let marginId: String
        let transcript: String
    }

    private let model: Model?
    private let conditions: @Sendable () -> MarginTidyConditions
    private var remembered: [Key: MarginTidyProposal] = [:]

    public init(
        model: Model?,
        conditions: @escaping @Sendable () -> MarginTidyConditions = { MarginTidyConditions() }
    ) {
        self.model = model
        self.conditions = conditions
    }

    /// The tidy version to offer for the Margin `marginId` that says `transcript`, or nil when there is nothing to offer:
    /// no words, a tidy that is the same words once whitespace and case are set aside, or a caller that went away
    /// (a cancelled request is dropped, never remembered).
    public func proposal(marginId: String, transcript: String, before: String = "", after: String = "") async -> MarginTidyProposal? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key = Key(marginId: marginId, transcript: transcript)
        if let kept = remembered[key] { return kept }
        if Task.isCancelled { return nil }

        if let model, conditions().allowsModel {
            let context = BoundedAnchorContext.select(before: before, after: after)
            let passage = [context.before, context.after].filter { !$0.isEmpty }.joined(separator: " ")
            let pieces = MarginTidyChunks.split(transcript)
            if pieces.count <= MarginTidyChunks.maximumPieces {
                // Each piece in its own request; a piece whose rewrite fails the guard keeps its filler-only tidy.
                var parts: [String] = []
                var rewritten = false
                var modelFailed = false
                for piece in pieces {
                    let reply: String?
                    do {
                        reply = try await model(piece, context.before, context.after)
                    } catch {
                        reply = nil
                        modelFailed = true
                    }
                    if Task.isCancelled { return nil }
                    if let reply {
                        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !Self.sameWords(text, piece), MarginTidyGuard.accepts(original: piece, proposal: text, passage: passage) {
                            parts.append(text)
                            rewritten = true
                            continue
                        }
                    }
                    parts.append(MarginTidy.fillerOnly(piece).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let text = parts.joined(separator: " ")
                if rewritten, !Self.sameWords(text, transcript),
                   MarginTidyGuard.accepts(original: transcript, proposal: text, passage: passage) {
                    let proposal = MarginTidyProposal(text: text, source: .onDeviceAI)
                    // A piece the model could not answer (the phone hot, a refusal) is tried again next time.
                    if !modelFailed { remembered[key] = proposal }
                    return proposal
                }
            }
        }

        if Task.isCancelled { return nil }
        let text = MarginTidy.fillerOnly(transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.sameWords(text, transcript) else { return nil }
        return MarginTidyProposal(text: text, source: .fillers)
    }

    /// Whether `lhs` and `rhs` are the same once the whitespace at the ends and the case are set aside.
    static func sameWords(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalized(lhs) == normalized(rhs)
    }
}
