import Foundation

/// What the Export and Export Sessions screens call each choice, and what they say about it (#4956).
///
/// The screens used internal names ("AI Handoff Markdown", "Full JSON Archive", "Scope", "AI Turns") with no
/// caption, so a listener couldn't tell which format their notes app reads or what a toggle adds. Every word the
/// screens show lives here so a host test pins it; the views only lay these out.
///
/// Nothing here changes a saved value, a tag or what an export contains. The tags are the UserDefaults values the
/// app already stores and the engine reads (`SessionEngine.scopedExportInterjections`, `scopedExportTurns`).

/// The Format picker: Markdown or JSON.
public enum ExportFormatChoice: String, CaseIterable, Sendable {
    case markdown
    case json

    public static let heading = "Format"

    /// `"json"` is JSON; any other stored value is Markdown, as the renderer treats it.
    public init(storedFormat: String) {
        self = storedFormat == ExportFormatChoice.json.rawValue ? .json : .markdown
    }

    public var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .json: return "JSON"
        }
    }

    public var caption: String {
        switch self {
        case .markdown:
            return "A text file with headings, for notes apps such as Obsidian, or to paste into an AI chat."
        case .json:
            // Not called a backup: no app code reads an export back in, and no recording goes in it.
            return "Structured data for scripts and developer tools. Spoken Margins can't import it back."
        }
    }
}

/// The Contents picker (stored as `exportScope`).
public enum ExportContents: CaseIterable, Sendable {
    case noMargins
    case myMargins
    case everything

    public static let heading = "Contents"

    /// The value the picker writes when the listener picks this choice.
    public var tag: String {
        switch self {
        case .noMargins: return "original"
        case .myMargins: return "source_interjections"
        case .everything: return "full_session"
        }
    }

    /// How a saved scope is shown. The engine treats `original`/`source_only` alike, and
    /// `source_interjections`/`original_with_interjections` alike; anything else exports everything.
    public init(storedScope: String) {
        switch storedScope {
        case "original", "source_only": self = .noMargins
        case "source_interjections", "original_with_interjections": self = .myMargins
        default: self = .everything
        }
    }

    public var label: String {
        switch self {
        case .noMargins: return "No Margins"
        case .myMargins: return "My Margins"
        case .everything: return "Everything"
        }
    }

    public var caption: String {
        switch self {
        case .noMargins:
            return "The source's details, without your Margins or Reflect on this session."
        case .myMargins:
            return "Your Margins on the source, each with what you were hearing. Leaves out Reflect on this session and Margins on it."
        case .everything:
            return "Your Margins, plus summaries and AI replies from Reflect on this session, with any Margins on them."
        }
    }

    /// The engine drops every Margin for this choice, whatever the Margins toggle says.
    public var leavesOutMargins: Bool { self == .noMargins }

    /// The engine drops every summary and AI reply (and Margins on them), whatever their toggle says.
    public var leavesOutReflections: Bool { self != .everything }
}

/// The toggles under the Contents picker.
public enum ExportToggle: CaseIterable, Sendable {
    case sourceText
    case spokenNoteText
    case sourceLink
    case listeningMap
    case margins
    case reflections

    public var title: String {
        switch self {
        case .sourceText: return "Source Text"
        case .spokenNoteText: return "Spoken Note Text"
        case .sourceLink: return "Source Link"
        case .listeningMap: return "Listening Map"
        case .margins: return "Margins"
        case .reflections: return "Summaries and AI Replies"
        }
    }

    public var caption: String {
        switch self {
        case .sourceText: return "The full text of the article, PDF or document."
        case .spokenNoteText: return "Your note's own words, from each recording."
        case .sourceLink: return "The web address, and a PDF's citation, so you can find the original."
        case .listeningMap: return "The source's overview and chapters."
        case .margins: return "What you said or wrote, each with what you were hearing."
        case .reflections: return "Summaries and pasted AI answers from Reflect on this session."
        }
    }

    /// Source Text's caption when the item is a podcast or audio file, whose full transcript never exports.
    public static let sourceTextUnavailableCaption =
        "Podcasts and audio files don't export their full transcript. Each Margin still brings a short stretch of what you were hearing, when there is a transcript."

    /// The caption shown instead of `caption` when `contents` leaves this toggle's material out; nil when it doesn't.
    public func overriddenCaption(by contents: ExportContents) -> String? {
        switch self {
        case .margins where contents.leavesOutMargins:
            return "Left out by No Margins above."
        case .reflections where contents.leavesOutReflections:
            return "Only Everything includes these."
        default:
            return nil
        }
    }

    /// Whether the toggle shows on. An overridden toggle shows off without changing the stored value, so picking
    /// Everything again shows the listener's own setting.
    public func shownOn(stored: Bool, contents: ExportContents) -> Bool {
        stored && overriddenCaption(by: contents) == nil
    }
}

/// Other words on the Export Sessions screen.
public enum ExportScreenWords {
    public static let batchHeading = "What to Include"
    public static let batchJumpHint = "Jumps to What to Include and the Export button."
}
