import Combine
import Foundation
import SessionKit
import SessionKitPersistence

/// Whether this build's share links carry a reply box (#4675, `docs/design/reply-mailbox.md` change 3). `SM_LINK_REPLIES`
/// follows `SM_SHARE_LINK_CREATION` in project.yml, set when the app is built and never at run time (2026-10-17); it
/// does nothing unless link creation is on too. The server's `replies` switch can only turn boxes off.
enum LinkReplies {
    static var offered: Bool {
        #if SM_LINK_REPLIES && SM_SHARE_LINK_CREATION
        return true
        #else
        return false
        #endif
    }
}

/// The sender's side of the reply boxes on the phone (#4675, pieces 7 and 8): the quiet pickup when the app comes to the
/// front or Following is pulled down, banner C, and the card's Stop and Report. The rules live in SessionKit
/// (`ReplyBoxPickup`, `ReplyBoxActions`, `ReplyArrivalWords`); this type only wires them to the model, the import
/// coordinator's quiet path and the top banner. The model calls it with one line from each lifecycle hook.
@MainActor
final class ReplyBoxCoordinator: ObservableObject {
    /// The phone's reply-box records, for card D. Loaded when a card first asks, and again after each check, stop and report.
    @Published private(set) var records: [ReplyBoxRecord] = []

    private weak var model: Gate1AppModel?
    private var pickup: ReplyBoxPickup?
    /// The running check, with a number so a cancelled one that finishes late can't clear its successor.
    private var check: (id: Int, task: Task<Void, Never>)?
    private var checkCount = 0
    /// Banner C, held while a Margin is being recorded or written, shown when it ends.
    private var heldBanner: ReplyArrivalBanner?
    private var recordsRequested = false
    /// The club transport. Tests set a stand-in before the first check or tap.
    var send: ClubClient.Send = ClubTransport.send

    init(model: Gate1AppModel) {
        self.model = model
    }

    // MARK: Pickup

    /// The app came to the front. At most every two minutes (the pickup's own throttle).
    func appBecameActive() { startCheck(.becameActive) }

    /// Following's pull-to-refresh: always checks. It runs beside the feed refresh and never holds the spinner.
    func pullToRefresh() { startCheck(.pullToRefresh) }

    /// The app left the front: the check stops, every cursor where the last finished import left it.
    func appLeftFront() {
        check?.task.cancel()
        check = nil
    }

    private func startCheck(_ trigger: ReplyBoxPickup.Trigger) {
        guard check == nil, let model else { return }
        // Not before first run and the Terms are done, and only once the listener agreed to links that take answers:
        // a reply box is made only after that agreement, so before it there is nothing to collect.
        guard model.hasAcceptedCurrentTerms, !model.isTermsOfUsePresented,
              ServerSendConsent.hasConsented(to: .shareLinks, repliesOffered: true) else { return }
        let pickup = self.pickup ?? makePickup()
        self.pickup = pickup
        checkCount += 1
        let id = checkCount
        let task = Task { [weak self] in
            let result = await pickup.check(trigger)
            guard let self else { return }
            if self.check?.id == id { self.check = nil }
            if result.status == .checked { await self.reloadRecords() }
            if let banner = result.banner { self.show(banner) }
        }
        check = (id, task)
    }

    private func makePickup() -> ReplyBoxPickup {
        let importer = ReplyBoxAppImporter(
            importing: { [weak self] answer in
                // The importer reads a file: the packet goes to Caches for the length of one import, then away.
                guard let file = try? ReplyBoxAnswerFile.write(answer.packet) else { return .notNow }
                defer { ReplyBoxAnswerFile.remove(file) }
                guard let self else { return .notNow }
                return await self.importQuietly(file, record: answer.record)
            },
            checkingLayer: { [weak self] layerId in
                guard let self else { return true }
                return await self.layerIsInLibrary(layerId)
            }
        )
        return ReplyBoxPickup(
            client: ClubClient(send: send),
            store: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.openStore()
            },
            importer: importer,
            diagnostics: { [weak self] line in
                guard let self else { return }
                Task { @MainActor in self.model?.diagnostics["lastReplyBoxPickup"] = line }
            }
        )
    }

    /// The store, opened if the Library isn't yet: a check waits for it rather than read an empty list.
    private func openStore() throws -> SQLiteSessionStore {
        guard let model else { throw CancellationError() }
        model.bootstrapLibraryIfNeeded()
        return try model.requireStore()
    }

    private func importQuietly(_ file: URL, record: ReplyBoxRecord) async -> ReplyBoxImportOutcome {
        guard let model else { return .notNow }
        return await model.packageImport.stageQuietly(from: file, for: record)
    }

    private func layerIsInLibrary(_ layerId: String) async -> Bool {
        // A store or read that fails answers "still there", so the retention rule keeps the record.
        guard let store = try? openStore() else { return true }
        do {
            let layer = try await StoreReader(store).read { try $0.loadImportedCommentaryLayer(id: layerId) }
            return layer.map { $0.deletedAt == nil } ?? false
        } catch {
            return true
        }
    }

    // MARK: Banner C

    private func show(_ banner: ReplyArrivalBanner) {
        guard let model else { return }
        // The banner waits while a Margin is recorded or written (screen C, "Timing").
        guard !model.recordingNavigationIsLocked else {
            heldBanner = banner
            return
        }
        heldBanner = nil
        let destination = banner.destination
        model.reportConfirmation(banner.text, action: UserFeedbackEvent.Action(
            title: banner.openTitle,
            accessibilityLabel: "\(banner.openTitle). \(banner.text)",
            identifier: "replyBox.arrival.open",
            perform: { [weak self] in self?.open(destination) }
        ))
    }

    /// The root view calls this when the recording lock changes.
    func showHeldBannerIfReady() {
        guard let held = heldBanner, model?.recordingNavigationIsLocked == false else { return }
        show(held)
    }

    /// **Open**: the item screen for one friend on one item, starting nothing; Following otherwise.
    private func open(_ destination: ReplyArrivalBanner.Destination) {
        guard let model, !model.recordingNavigationIsLocked else { return }
        switch destination {
        case .item(let itemId):
            Task { await model.packageImport.openAnsweredItem(itemId) }
        case .following:
            model.openHome()
            model.requestedExperienceRoot = .sources
        }
    }

    /// A link was made with a box (`ShareLinkSender`): keep its record, off the main thread. A record that can't be saved
    /// leaves the link working; the box's answers are then never collected, and it ends with the link.
    func keep(_ record: ReplyBoxRecord) {
        guard let store = try? openStore() else { return }
        Task { [weak self] in
            _ = try? await StoreReader(store).read { try $0.saveReplyBox(record) }
            await self?.reloadRecords()
        }
    }

    // MARK: Card D and sheet E

    /// The box and post the layer came through, or nil when it came some other way.
    func answer(carrying layerId: String) -> (record: ReplyBoxRecord, seq: Int)? {
        ReplyBoxActions.answer(carrying: layerId, in: records)
    }

    /// A card is on screen: read the records once, off the main thread.
    func loadRecordsIfNeeded() {
        guard !recordsRequested else { return }
        recordsRequested = true
        Task { await reloadRecords() }
    }

    private func reloadRecords() async {
        guard let store = model?.store else { return } // a card only shows with the Library open
        guard let loaded = try? await StoreReader(store).read({ try $0.loadReplyBoxes() }) else { return }
        if loaded != records { records = loaded }
    }

    private var actions: ReplyBoxActions {
        ReplyBoxActions(
            send: send,
            store: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.openStore()
            },
            host: ProductServer.host
        )
    }

    /// "Stop Answers" in the confirm dialog.
    func stopAnswers(boxId: String) async {
        let result = await actions.stop(boxId: boxId)
        await reloadRecords()
        switch result {
        case .stopped: model?.reportConfirmation(ReplyArrivalWords.stopDone)
        case .failed: model?.reportFailure(ReplyArrivalWords.stopFailed)
        }
    }

    func report(
        boxId: String, seq: Int, category: ReplyReportCategory, reason: String?, alsoStop: Bool
    ) async -> ReplyBoxActions.ReportResult {
        let result = await actions.report(boxId: boxId, seq: seq, category: category, reason: reason, alsoStop: alsoStop)
        await reloadRecords()
        return result
    }

    func sendReportReason(boxId: String, reference: String, reason: String) async -> Bool {
        await actions.sendReason(boxId: boxId, reference: reference, reason: reason)
    }

    /// The report sheet closed with a result: hide the answer through the Hide-this-Margin store, then say so.
    func finishReport(_ completion: ReplyReportForm.Completion, layerId: String) async {
        if completion.hidesAnswer, let model, let store = model.store {
            let read = try? await StoreReader(store).read { store -> (ImportedCommentaryLayer, [ImportedCommentaryInterjection])? in
                guard let layer = try store.loadImportedCommentaryLayer(id: layerId) else { return nil }
                return (layer, try store.loadImportedCommentaryInterjections(layerId: layerId))
            }
            if let read {
                for margin in read.1 { model.hideMargin(layer: read.0, margin: margin) }
            }
        }
        model?.reportConfirmation(completion.banner)
    }
}

/// The pickup's importer: the quiet import and the Library check, handed in as closures so the pickup's actor holds no
/// reference to the main-actor types.
private struct ReplyBoxAppImporter: ReplyBoxImporting {
    let importing: @Sendable (ReplyBoxAnswer) async -> ReplyBoxImportOutcome
    let checkingLayer: @Sendable (String) async -> Bool

    func importAnswer(_ answer: ReplyBoxAnswer) async -> ReplyBoxImportOutcome { await importing(answer) }
    func layerIsInLibrary(id: String) async -> Bool { await checkingLayer(id) }
}

/// A fetched answer's packet on disk for the length of one import, in Caches (the system may empty it; nothing here is
/// kept). The import copies it into its own folder first.
enum ReplyBoxAnswerFile {
    static func write(_ packet: Data) throws -> URL {
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "ReplyBoxAnswers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(UUID().uuidString).spokenmargins")
        try packet.write(to: file, options: .atomic)
        return file
    }

    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}
