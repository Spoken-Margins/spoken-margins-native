#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit

enum AddMarginShortcutError: Error, Equatable, LocalizedError {
    case emptyText
    case nothingRunning
    case writingInProgress
    case libraryUnavailable
    case itemNotFound
    case itemNotStarted
    case notSaved(String?)

    init(_ failure: StoredSessionMargin.Failure) {
        switch failure {
        case .emptyText: self = .emptyText
        case .itemNotFound: self = .itemNotFound
        case .noSession: self = .itemNotStarted
        }
    }

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return SiriMarginRoute.emptyText
        case .nothingRunning:
            return SiriMarginRoute.nothingRunningMessage
        case .writingInProgress:
            return SiriMarginRoute.writingInProgress
        case .libraryUnavailable:
            return "Spoken Margins could not open its Library. Try the shortcut again."
        case .itemNotFound:
            return "That episode, article or PDF isn't in your Spoken Margins Library any more. Pick another and run the shortcut again."
        case .itemNotStarted:
            return "Start this once before adding a Margin to it."
        case .notSaved(let reason):
            return reason ?? SiriMarginRoute.notSaved
        }
    }
}

/// Saves a written Margin on the playing item through the same begin/save path the in-app
/// "Write a Margin" button uses, so the anchor, the listening-signals bookkeeping and the
/// resume-after-saving behaviour are the ones listeners already get. Given another Library item it
/// writes on that item's saved session instead (#1073) and leaves the playing item alone.
@MainActor
enum AddMarginShortcutAction {
    /// Saves the Margin on `itemId`'s item, or on the playing item when `itemId` is nil or is the item playing.
    /// An item that isn't playing takes it at its saved place, on its most recent session; nothing is started and
    /// whatever is playing carries on. Returns the title of the item that received the Margin.
    static func addWrittenMargin(text: String, toItemId itemId: String?, in model: Gate1AppModel) throws -> String {
        guard let itemId, !(model.hasActiveSession && model.snapshot.itemId == itemId) else {
            return try addWrittenMargin(text: text, to: model)
        }
        guard model.store != nil else { throw AddMarginShortcutError.libraryUnavailable }
        do {
            return try model.addWrittenMarginToStoredItem(id: itemId, text: text)
        } catch let failure as StoredSessionMargin.Failure {
            throw AddMarginShortcutError(failure)
        } catch {
            throw AddMarginShortcutError.notSaved(ListenerErrorText.message(for: error))
        }
    }

    /// Where Siri's Margin goes (#3880): a Library item chosen in a Shortcut, else the running live session (a written
    /// Margin at this moment, whatever is in the player), else the item in the player, else a quick session in the
    /// Library. Returns what Siri says it went to: the item's title or the session's name.
    static func perform(
        text: String, toItemId itemId: String?, in model: Gate1AppModel,
        files: LiveSessionFileWorker = .shared, now: Date = Date()
    ) async throws -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw AddMarginShortcutError.emptyText }
        let route = SiriMarginRoute.decide(.init(
            choseItem: itemId != nil, runningSession: await files.runningSession(), playerHasSession: model.hasActiveSession
        ))
        switch route {
        case .chosenItem, .playerItem:
            return try addWrittenMargin(text: words, toItemId: itemId, in: model)
        case let .liveSession(name):
            guard await files.addWrittenMargin(text: words, markedAt: now) != nil else {
                throw AddMarginShortcutError.notSaved(nil)
            }
            // The open session screen takes it in, the Library's Live row and the Watch's board redraw.
            NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
            LiveSessionBoard.shared.refresh()
            WatchMarginReceiver.shared.processInbox()
            return name
        case .quickSession:
            // Nothing runs: the Margin is kept in a quick session, where the Library's Live row shows it (#3880).
            guard let session = await files.fileWrittenMarginAsQuick(text: words, markedAt: now, now: now) else {
                throw AddMarginShortcutError.notSaved(nil)
            }
            NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
            LiveSessionBoard.shared.refresh()
            WatchMarginReceiver.shared.processInbox()
            return SiriMarginRoute.filedName(session)
        }
    }

    /// Returns the title of the item that received the Margin. Throws before touching playback when
    /// the text is empty, nothing is playing, or a Margin is already being written; a Margin is
    /// created only if it was saved.
    static func addWrittenMargin(text: String, to model: Gate1AppModel) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AddMarginShortcutError.emptyText }
        guard model.hasActiveSession else { throw AddMarginShortcutError.nothingRunning }
        guard !model.recordingNavigationIsLocked else { throw AddMarginShortcutError.writingInProgress }

        model.beginWrittenMargin()
        guard let draft = model.writtenMarginDraft else {
            throw AddMarginShortcutError.notSaved(model.lastError)
        }
        model.saveWrittenMargin(text: text)
        guard model.writtenMarginDraft == nil else {
            // The save failed and kept the draft open; close it so the next shortcut run (or the
            // listener) starts clean, and say why.
            let reason = model.lastError
            model.cancelWrittenMargin()
            throw AddMarginShortcutError.notSaved(reason)
        }
        return draft.itemTitle
    }
}

struct AddMarginToSpokenMarginsIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Margin"
    static let description = IntentDescription(
        "Writes a text Margin in Spoken Margins: into your running live session if there is one, else on whatever is playing, at the current place, and playback carries on; with neither, into a quick session in your Library. Choose something else from your Library to write on it instead, at the place where you left it, without starting it."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Text",
        description: "What the Margin says.",
        requestValueDialog: "What should the Margin say?"
    )
    var text: String

    @Parameter(
        title: "Source",
        description: "The episode, article or PDF to write on, at the place where you left it. Leave empty to write on what's playing."
    )
    var item: LibraryItemEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add Margin \(\.$text) to what's playing") { \.$item }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The same weak reference the Listening Edition action uses; the app sets it at launch,
        // including when a shortcut launches the app in the background.
        guard let model = ListeningEditionShortcutBridge.model else {
            throw AddMarginShortcutError.libraryUnavailable
        }
        let name = try await AddMarginShortcutAction.perform(text: text, toItemId: item?.id, in: model)
        return .result(dialog: IntentDialog(stringLiteral: SiriMarginRoute.confirmation(named: name)))
    }
}
#endif
