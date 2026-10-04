import Foundation

/// The notes-folder rule for one Margin note, and how a delivery pass reads to the listener.
/// Moved out of the app's `AutomaticMarginWriter` so it can be host-tested (#581).
///
/// A note the listener edited in their notes app (Obsidian, say) is theirs: it is never overwritten,
/// and keeping it is normal, not a failure. Editing notes is the point of delivering them.
public enum MarginNoteDelivery {
    public enum Action: Equatable, Sendable {
        /// The file already holds the intended bytes.
        case upToDate
        /// The file is missing or still holds bytes this app wrote; write the intended bytes.
        case write
        /// The file holds bytes this app never wrote; leave it alone.
        case keepListenerEdit
    }

    /// Digests: `existing` is the file on disk (nil when absent); `journalPrevious` and
    /// `journalIntended` are what the writer's journal recorded for this note, if anything.
    public static func action(
        existing: String?, intended: String, journalPrevious: String?, journalIntended: String?
    ) -> Action {
        guard let existing else { return .write }
        if existing == intended { return .upToDate }
        if existing != journalIntended && existing != journalPrevious { return .keepListenerEdit }
        return .write
    }

    public struct Summary: Equatable, Sendable {
        /// Notes now holding the intended bytes, whether written this pass or already current.
        public var saved: Int
        /// Notes the listener edited, left as they are.
        public var keptEdits: Int
        /// One message per note that could not be written.
        public var failures: [String]

        public init(saved: Int = 0, keptEdits: Int = 0, failures: [String] = []) {
            self.saved = saved
            self.keptEdits = keptEdits
            self.failures = failures
        }
    }

    /// The calm status after a pass with no failures, e.g.
    /// "1 Margin saved to Vault. 1 note you edited was left as is. Last checked 3:04 PM."
    public static func statusLine(_ summary: Summary, folderName: String, checkedAt: String) -> String {
        "\(count(summary.saved, "Margin", "Margins")) saved to \(folderName).\(keptEditsSentence(summary)) Last checked \(checkedAt)."
    }

    /// The message for a pass where some notes could not be written; nil when none failed.
    public static func failureMessage(_ summary: Summary) -> String? {
        guard let first = summary.failures.first else { return nil }
        let verb = summary.failures.count == 1 ? "needs" : "need"
        return "\(count(summary.saved, "Margin", "Margins")) delivered; \(summary.failures.count) \(verb) attention.\(keptEditsSentence(summary)) \(first)"
    }

    private static func keptEditsSentence(_ summary: Summary) -> String {
        switch summary.keptEdits {
        case 0: return ""
        case 1: return " 1 note you edited was left as is."
        default: return " \(summary.keptEdits) notes you edited were left as is."
        }
    }

    private static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }
}
