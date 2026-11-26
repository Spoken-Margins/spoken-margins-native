import Foundation

/// What the "Add Link List to Spoken Margins" Shortcuts action does with what it was given (#4683, Design section 2e).
///
/// The action runs without opening the app, so it can't import: it checks the list, saves it in the handoff folder
/// (`LinkListHandoffFolder`), and tells the listener it will be added the next time they open the app. The checking and
/// the words live here so a host test can run them; the `AppIntent` is a thin call.
public enum LinkListShortcutAction {
    /// How the action stops. `message` is what Shortcuts shows the listener.
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// Neither a file nor text was given.
        case nothingGiven
        /// What was given holds no link list.
        case notALinkList
        /// It says it is a link list but can't be taken. The message is `LinkListFile`'s and `LinkListText`'s.
        case refused(String)
        /// The handoff folder is full, the list too large, or the write failed.
        case save(LinkListHandoffFolder.SaveError)

        public var message: String {
            switch self {
            case .nothingGiven: return "Give this action a link list file or text."
            case .notALinkList:
                return "That isn't a Spoken Margins link list. Ask your AI for a \"\(LinkListFile.schemaVersion)\" list."
            case .refused(let message): return message
            case .save(let error): return error.message
            }
        }

        public var errorDescription: String? { message }
    }

    /// A list that was saved.
    public struct Saved: Equatable, Sendable {
        public var title: String?
        /// How many links the list holds, shows to follow included.
        public var linkCount: Int

        /// What Shortcuts says: the list's title when it has one, and that the app adds it when it next opens.
        public var dialog: String {
            let links = linkCount == 1 ? "1 link" : "\(linkCount) links"
            if let title, !title.isEmpty {
                return "Saved “\(title)” with \(links). Open Spoken Margins to add them."
            }
            return "Saved a list with \(links). Open Spoken Margins to add them."
        }
    }

    /// Checks the list in `file` or `text` and saves it in `folder`.
    ///
    /// - A file is tried first. A file that isn't a list, but holds text with a list in it (an AI's reply saved as a
    ///   text file), is read as text. When a file isn't usable and `text` is given, the text is tried.
    /// - Nothing is saved when the list is refused, and nothing is left behind when the save fails.
    public static func run(file: Data?, text: String?, folder: LinkListHandoffFolder) throws -> Saved {
        let hasFile = !(file?.isEmpty ?? true)
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard hasFile || !trimmedText.isEmpty else { throw Failure.nothingGiven }

        var firstRefusal: String?
        var candidates: [LinkListFile.Recognition] = []
        if let file, hasFile {
            let recognition = LinkListFile.recognize(file)
            candidates.append(recognition)
            if recognition == .notALinkList, file.count <= LinkListFile.maxFileBytes, let fileText = String(data: file, encoding: .utf8) {
                candidates.append(LinkListText.find(in: fileText))
            }
        }
        if !trimmedText.isEmpty, let text { candidates.append(LinkListText.find(in: text)) }

        for candidate in candidates {
            switch candidate {
            case .linkList(let list):
                do { try folder.save(list) } catch let error as LinkListHandoffFolder.SaveError { throw Failure.save(error) } catch { throw Failure.save(.couldNotWrite) }
                let title = list.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Saved(title: (title?.isEmpty ?? true) ? nil : title, linkCount: list.entries.count)
            case .rejected(let message): firstRefusal = firstRefusal ?? message
            case .notALinkList: break
            }
        }
        if let firstRefusal { throw Failure.refused(firstRefusal) }
        throw Failure.notALinkList
    }
}
