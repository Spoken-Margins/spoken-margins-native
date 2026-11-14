import Foundation
import SessionKit

/// The screens' view of the hidden-senders list (#2846): the rules and the file are `HiddenSendersKeeper` in SessionKit
/// and host-tested; this publishes `current` so the screens redraw, and keeps the keeper's calls so callers read as
/// before. The app model holds one and hands `current` to the loaders that build the screens' Margins
/// (`ItemDetailLoader`, `MarginRowsReading`). Hiding and showing again change the list; the model then reloads what is
/// on screen.
@MainActor
final class HiddenSendersController: ObservableObject {
    @Published private(set) var current: HiddenSenders
    private var keeper: HiddenSendersKeeper

    /// `directory` is where the file lives; nil keeps the list in memory only (a test, or no writable folder).
    init(directory: URL?) {
        let keeper = HiddenSendersKeeper(directory: directory)
        self.keeper = keeper
        current = keeper.current
    }

    static func defaultDirectory() -> URL? { HiddenSendersKeeper.defaultDirectory() }

    static func phoneSenderID() -> String? { HiddenSendersKeeper.phoneSenderID() }

    var isEmpty: Bool { keeper.isEmpty }

    func isHidden(_ senderId: String?) -> Bool { keeper.isHidden(senderId) }

    @discardableResult
    func hide(_ senderId: String?, displayLabel: String?, at date: Date = Date()) -> Bool {
        defer { publish() }
        return keeper.hide(senderId, displayLabel: displayLabel, at: date)
    }

    func unhide(_ senderId: String) {
        keeper.unhide(senderId)
        publish()
    }

    func isMarginHidden(_ marginId: String) -> Bool { keeper.isMarginHidden(marginId) }

    @discardableResult
    func hideMargin(_ marginId: String, senderLabel: String?, text: String, at date: Date = Date()) -> Bool {
        defer { publish() }
        return keeper.hideMargin(marginId, senderLabel: senderLabel, text: text, at: date)
    }

    func unhideMargin(_ marginId: String) {
        keeper.unhideMargin(marginId)
        publish()
    }

    private func publish() {
        if current != keeper.current { current = keeper.current }
    }
}
