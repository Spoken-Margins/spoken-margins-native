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

/// The words the on-device model is asked to tidy a spoken Margin with (#4339). Kept here, not in the app, so a host test
/// holds the wording and the app only sends it.
public enum MarginTidyPrompt {
    public static func text(transcript: String, before: String, after: String) -> String {
        """
        Rewrite the spoken note below as clear written sentences in the speaker's own voice and person. Keep every claim, number, name, quotation and negation. Remove filler words, false starts and repetition. Do not add facts, opinions or words from the passage; the passage is only there so you understand what the note refers to. Reply with the rewritten note only.

        Passage before: \(before)
        Passage after: \(after)
        Spoken note: \(transcript)
        """
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
            let reply: String?
            do {
                reply = try await model(transcript, context.before, context.after)
            } catch {
                reply = nil
            }
            if Task.isCancelled { return nil }
            if let reply {
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                let passage = [context.before, context.after].filter { !$0.isEmpty }.joined(separator: " ")
                if !Self.sameWords(text, transcript),
                   MarginTidyGuard.accepts(original: transcript, proposal: text, passage: passage) {
                    let proposal = MarginTidyProposal(text: text, source: .onDeviceAI)
                    remembered[key] = proposal
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
