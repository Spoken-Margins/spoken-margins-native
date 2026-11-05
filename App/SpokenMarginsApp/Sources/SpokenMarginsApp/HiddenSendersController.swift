import Foundation
import SessionKit

/// The senders this listener has hidden (#2846), kept on this device in `hidden-senders.json` beside the other app
/// files and never sent anywhere. The list lives outside the library database on purpose: the database stays exactly
/// as the last build wrote it, and a damaged or missing file only shows a sender again, it loses no Margin.
///
/// The app model holds one of these and hands `current` to the loaders that build the screens' Margins, so a hidden
/// sender's layers never reach a screen (`ItemDetailLoader`, `MarginRowsReading`). Hiding and showing again change
/// the list; the model then reloads what is on screen. Nothing in the library is deleted.
@MainActor
final class HiddenSendersController: ObservableObject {
    @Published private(set) var current: HiddenSenders
    private let store: SenderIdentityFileStore<HiddenSenders>?

    /// `directory` is where the file lives; nil keeps the list in memory only (a test, or no writable folder).
    init(directory: URL?) {
        let store = directory.map { SenderIdentityFileStore<HiddenSenders>.hiddenSenders(in: $0) }
        self.store = store
        current = store?.load() ?? HiddenSenders()
    }

    /// Beside the other app files, in a folder of its own. Nil when the phone gives no such folder.
    static func defaultDirectory() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "SpokenMargins/Senders", directoryHint: .isDirectory)
    }

    /// The random id this phone puts in every packet it shares (one per phone, #2846). Nil when the phone gives no
    /// way to keep it (no folder, a file that cannot be read or written), so the packet goes out without one rather than
    /// with an id that changes every time.
    static func phoneSenderID() -> String? {
        defaultDirectory().flatMap { SenderIdentityFileStore<SenderIDLedger>.ledger(in: $0).phoneSenderID() }
    }

    var isEmpty: Bool { current.entries.isEmpty }

    func isHidden(_ senderId: String?) -> Bool { current.isHidden(senderId) }

    /// Hides `senderId`. False when it isn't a sender id (a layer from a build that sends none), so no button offers it.
    @discardableResult
    func hide(_ senderId: String?, displayLabel: String?, at date: Date = Date()) -> Bool {
        var next = current
        guard next.hide(senderId, displayLabel: displayLabel, at: date) else { return false }
        apply(next)
        return true
    }

    func unhide(_ senderId: String) {
        var next = current
        next.unhide(senderId)
        apply(next)
    }

    private func apply(_ next: HiddenSenders) {
        guard next != current else { return }
        current = next
        // A file that can't be written leaves the sender hidden until the app closes; the next launch shows them again.
        try? store?.save(next)
    }
}
