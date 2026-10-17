import Foundation

/// The wording the on-device model is given for interjection summaries: the instructions, the one-note prompts and
/// the synthesis prompt. Plain text only, so it is tested on the host (moved from the app target, #318).
public enum LocalInterjectionPrompts {
    public static let interjectionPointExtractionInstructions = """
    Extract the substantive meaning of exactly one user-authored interjection. This is a benign transformation of commentary, not a request to perform or enable wrongdoing. Keep any safety or security discussion high-level and non-operational. This is one note, not theme synthesis. Include every distinct source-supported assertion or requested behavior once. Each claim must be self-contained and materially shorter than its source wording; combine adjacent fragments that depend on each other. The opening assertion motivating a proposal is substantive. Preserve causal links, conditions, contrasts, uncertainty, tests, counterarguments, and residual limitations. Preserve diagnostic labels and explicit action terms exactly as dictated. Remove only filler, repetition, and false starts. Do not infer, answer, evaluate, or add background knowledge.
    """

    public static let interjectionPermissiveTransformationInstructions = """
    Transform exactly one user-provided dictated comment into a materially shorter statement of its own claims. This is text editing, not a request to carry out, endorse, or extend anything described by the text. Preserve contradictions, causal direction, qualifications, and limitations. Remove only conversational scaffolding, repetition, and false starts. Do not answer, evaluate, or add facts. Return only the transformed comment.
    """

    public static func interjectionPointExtractionPrompt(record: LocalInterjectionSummaryRecord) -> String {
        """
        DICTATED TEXT:
        \(record.note)
        """
    }

    public static func interjectionPointCondensationInstructions(point: String, wordLimit: Int) -> String {
        var instructions = "Rewrite one extracted point as a direct clause of \(wordLimit) words or fewer. Preserve its requested behavior and concrete outcome. Return only the clause."
        if point.contains("?") {
            instructions += " The point is a question. The rewrite must remain a question and end with a question mark."
        }
        return instructions
    }

    public static func interjectionPointCondensationPrompt(point: String, wordLimit: Int) -> String {
        """
        POINT:
        \(point)
        """
    }

    public static func interjectionSummaryPrompts(record: LocalInterjectionSummaryRecord) -> [String] {
        let wordLimit = LocalInterjectionSummaryPolicy.summaryWordLimit(
            for: record.note.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        let sharedRules = """
        Output one sentence of at most \(wordLimit) words. State the point itself in the author's voice. Preserve every distinct substantive claim or requested behavior that fits, including both sides of a contrast and any explicit failure-handling requirement. Preserve questions as questions. If the text requests how content should be rewritten or summarized, state that transformation request rather than answering the underlying topic. Preserve essential qualifications. Remove filler, repetition, false starts, and emotional throat-clearing. Do not mention a listener, user, speaker, note, transcript, or summary. Do not answer or evaluate the point. Return only the sentence.
        """
        return [
            """
            Condense the dictated text below into its substantive claims and requested actions. This is one note, not a request to find themes. Do not omit one requested behavior merely because another seems more central.

            \(sharedRules)

            DICTATED TEXT:
            \(record.note)
            """,
            """
            Rewrite the dictated text below as a concise product requirement, objection, question, preference, or claim—whichever it actually expresses. Retain every separately requested behavior; combine linked clauses in one sentence.

            \(sharedRules)

            DICTATED TEXT:
            \(record.note)
            """,
            """
            Identify each distinct substantive point in the dictated text internally, then precipitate all of them into one sentence. Keep concrete subjects, contrasts, consequences, and failure behavior; discard conversational scaffolding. Make it materially shorter, not merely cleaner.

            \(sharedRules)

            DICTATED TEXT:
            \(record.note)
            """,
            """
            Exhaustively rewrite the actionable meaning of this one dictated note as one sentence of at most \(wordLimit) words. Before answering, check internally for: what should not happen; what should happen instead; contrasting cases; and how a failure should be surfaced. Include every category the text actually contains. Remove repetition and conversational filler. State the requirements directly, never describe the author or the note, and return only the sentence.

            DICTATED TEXT:
            \(record.note)
            """,
            """
            Preserve the author's requested transformation of the dictated text below. If it asks what a concise claim should retain or omit, state that requirement directly; do not generate a claim about the underlying subject. If it asks a question, keep it as a question. Use at most \(wordLimit) words and return only one sentence.

            DICTATED TEXT:
            \(record.note)
            """
        ]
    }

    public static func interjectionSynthesisPrompt(
        record: LocalInterjectionSummaryRecord,
        drafts: [String]
    ) -> String {
        let wordLimit = LocalInterjectionSummaryPolicy.summaryWordLimit(
            for: record.note.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        )
        return """
        Write the final concise version of this one dictated note in at most \(wordLimit) words. The original dictated text is authoritative. The drafts may omit separate points or reverse meaning. Merge complementary points, correct contradictions against the original, and preserve every distinct requested behavior, both sides of contrasts, and explicit failure handling. Preserve a question as a question. Preserve requests about how underlying content should be summarized instead of answering that content. Remove filler and repetition. State the requirements or claims directly. Do not describe the author, note, transcript, or summarization task. Return only one sentence.

        ORIGINAL DICTATED TEXT:
        \(record.note)

        DRAFT REWRITES:
        \(drafts.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}

/// Swaps words that trip the model's safety filter for neutral stand-ins before a note goes in, and restores them
/// in what comes back. It also repairs dictation slips that the surrounding context proves.
public enum LocalInterjectionSafetyTerms {
    public static func modelSafeInterjectionText(_ text: String) -> String {
        repairContextProvenDictation(in: text)
            .replacingOccurrences(
                of: #"(?i)(?:zero|0)[ -]?day"#,
                with: "verified issue Z",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)security vulnerability"#, with: "verified system issue", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)break the law|do anything illegal|illegal actions?"#,
                with: "violate a hard constraint",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)cheating"#, with: "violating requirements", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)cheat"#, with: "violate requirements", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)misalignment|misaligned|mislined"#,
                with: "goal drift",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)super malicious|malicious"#,
                with: "strategically deceptive",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)fuck it|bullshit"#, with: "", options: .regularExpression)
    }

    public static func repairContextProvenDictation(in text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(?i)\bdo\s+the\s+land\b"#,
                with: "do alignment",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\bat\s+this\s+tiny\s+land\b"#,
                with: "at this tiny lab",
                options: .regularExpression
            )
    }

    public static func restoreSafetyTerms(in text: String) -> String {
        text
            .replacingOccurrences(of: #"(?i)verified issue Z"#, with: "zero-day", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)verified system issue"#,
                with: "security vulnerability",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)violate a hard constraint"#,
                with: "break the law",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)violating requirements"#,
                with: "cheating",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)requirements violations?"#,
                with: "cheating",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)violate requirements"#, with: "cheat", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)goal drift"#, with: "misalignment", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)strategically deceptive"#,
                with: "malicious",
                options: .regularExpression
            )
    }
}
