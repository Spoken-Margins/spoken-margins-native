import Foundation
import SessionKit
import SessionKitPersistence
#if canImport(UIKit)
import UIKit
#endif

/// Margin Output (#161, #171, #492): writes each Margin as a Markdown note into every destination the listener set up.
///
/// A destination is a named folder plus what goes into it (`MarginOutputDestination`, kept in a JSON file in
/// Application Support). A pass runs when the app becomes active and then once a minute, a few seconds after a Margin
/// or its transcript is saved, and once more under a background task when the app leaves the foreground, so a Margin
/// recorded just before switching apps still arrives. Passes never overlap; one asked for during a pass runs right
/// after it. The writer only rewrites its own unedited files, so repeated passes are safe.
///
/// Each destination is planned, built and written on its own (`MarginNotePassPlanner` is per destination, because its
/// scope and its folder differ), so one that has lost access to its folder is marked "Needs folder access" while the
/// others keep delivering. A pass rebuilds only the notes whose sessions changed, and does nothing when none did; every
/// 30 minutes, on the first pass and when the folder or the destination's choices change it rebuilds all of them (#1192).
@MainActor
final class MarginOutputCoordinator: ObservableObject {
    /// One destination as Settings shows it.
    struct Row: Identifiable, Equatable {
        var destination: MarginOutputDestination
        /// The folder's own name, which can differ from what the listener calls the destination.
        var folderName: String
        var status: MarginOutputStatus
        /// The folder can't be reached; delivery to it waits for the listener to reselect it.
        var needsAccess: Bool
        var id: String { destination.id }
    }

    /// How the coordinator makes and reads bookmarks; tests swap it to simulate a folder that was revoked.
    struct FolderAccess: Sendable {
        var makeBookmark: @Sendable (URL) throws -> Data
        var resolve: @Sendable (Data) throws -> (url: URL, refreshedBookmark: Data?)
        var folderName: @Sendable (Data) -> String?
        var isReachable: @Sendable (URL) -> Bool

        static let live = FolderAccess(
            makeBookmark: { try SavedFolderSetting.makeBookmark(for: $0) },
            resolve: { try SavedFolderSetting.resolve(bookmark: $0) },
            folderName: { SavedFolderSetting.folderName(inBookmark: $0) },
            isReachable: { url in
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        )
    }

    static let quickPassDelay: Duration = .seconds(2)
    static let loopInterval: Duration = .seconds(60)

    /// The destinations in the order the listener sees them.
    @Published private(set) var destinations: [MarginOutputDestination] = []
    /// What the last pass, test or change said about each destination, by id.
    @Published private(set) var statuses: [String: MarginOutputStatus] = [:]
    /// Destinations whose folder can't be reached.
    @Published private(set) var accessLost: Set<String> = []
    /// Something that isn't about one destination: the saved list couldn't be read or written.
    @Published private(set) var notice: MarginOutputStatus?

    var rows: [Row] {
        destinations.map { destination in
            Row(
                destination: destination,
                folderName: folderNames[destination.id] ?? folders.folderName(destination.bookmark) ?? "Folder",
                status: statuses[destination.id] ?? Self.defaultStatus(for: destination),
                needsAccess: accessLost.contains(destination.id)
            )
        }
    }

    /// Cheap: the Library is open.
    private let store: @MainActor () -> SQLiteSessionStore?
    /// Skips a pass while a Margin is being recorded; the save at the end of the recording asks for one.
    private let isRecording: @MainActor () -> Bool
    private let recordGather: @MainActor (_ ms: Int, _ sessions: Int, _ notes: Int) -> Void
    private let journalURL: () throws -> URL
    private let destinationStore: MarginOutputDestinationStore
    private let folders: FolderAccess
    /// False when the saved list exists but couldn't be read: it is left alone rather than replaced by a guess.
    private var canSave = true

    private var loop: Task<Void, Never>?
    private var quickPass: Task<Void, Never>?
    private var isDelivering = false
    private var passRequestedDuringPass = false
    private var writer: AutomaticMarginWriter?
    /// What each destination's last finished pass left to do next time (#1192).
    private var planners: [String: MarginNotePassPlanner] = [:]
    private var folderNames: [String: String] = [:]

    /// `databaseURLOverride` is a test database: the destinations and the journal then live beside it, and there is no
    /// single folder from the earlier builds to migrate, so a test never touches the real settings.
    init(
        store: @escaping @MainActor () -> SQLiteSessionStore?,
        isRecording: @escaping @MainActor () -> Bool,
        recordGather: @escaping @MainActor (_ ms: Int, _ sessions: Int, _ notes: Int) -> Void = { _, _, _ in },
        databaseURLOverride: URL? = nil,
        destinationStore: MarginOutputDestinationStore? = nil,
        legacy: (() -> MarginOutputMigration.LegacySettings)? = nil,
        folders: FolderAccess = .live,
        journalURL: (() throws -> URL)? = nil
    ) {
        self.store = store
        self.isRecording = isRecording
        self.recordGather = recordGather
        self.folders = folders
        if let databaseURLOverride {
            self.journalURL = journalURL ?? { databaseURLOverride.appendingPathExtension("margin-output-journal.json") }
            self.destinationStore = destinationStore ?? MarginOutputDestinationStore(fileURL: databaseURLOverride.appendingPathExtension("margin-output.json"))
        } else {
            self.journalURL = journalURL ?? MarginOutputCoordinator.defaultJournalURL
            self.destinationStore = destinationStore ?? MarginOutputDestinationStore(
                fileURL: (try? MarginOutputDestinationStore.defaultFileURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("MarginOutputDestinations.json")
            )
        }
        let legacySettings = legacy ?? (databaseURLOverride == nil
            ? MarginOutputCoordinator.liveLegacySettings
            : { MarginOutputMigration.LegacySettings(bookmark: nil, destinationID: nil, isEnabled: false) })
        do {
            destinations = try MarginOutputMigration.loadOrMigrate(store: self.destinationStore, legacy: legacySettings)
        } catch {
            canSave = false
            notice = MarginOutputStatus.failure("Your Margin Output destinations couldn't be read, so none are shown and none can be changed. Your Margins remain safely in the Library.")
        }
    }

    nonisolated static func defaultJournalURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenMargins/MarginOutputJournal.json")
    }

    /// Today's single notes folder, as the earlier builds kept it in UserDefaults. They stay in place for the previous
    /// build to read. Splitting the notes folder from the export folder (#930) runs first, so an install from before
    /// it still finds its folder.
    nonisolated static func liveLegacySettings() -> MarginOutputMigration.LegacySettings {
        SavedFolderSetting.separateMarginNotesFromSessionExport()
        let defaults = UserDefaults.standard
        return MarginOutputMigration.LegacySettings(
            bookmark: SavedFolderSetting.marginNotes.bookmark(),
            destinationID: defaults.string(forKey: "marginOutputDestinationID"),
            isEnabled: defaults.bool(forKey: "automaticMarginOutputEnabled")
        )
    }

    // MARK: - Delivering

    /// Cheap: some destination is delivering and the Library is open.
    var isEnabled: Bool { store() != nil && destinations.contains { $0.isEnabled } }

    /// Called when the app becomes active and when delivery is turned on.
    func start() {
        guard isEnabled, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pass()
                do { try await Task.sleep(for: Self.loopInterval) } catch { break }
            }
        }
    }

    /// Called when the last destination stops delivering. A pass already writing finishes its current note set.
    func stop() {
        loop?.cancel(); loop = nil
        quickPass?.cancel(); quickPass = nil
    }

    /// A Margin or its transcript changed: deliver within a few seconds instead of on the next minute.
    /// Repeated calls while one is pending don't push it back.
    func deliverSoon() {
        guard quickPass == nil, isEnabled else { return }
        quickPass = Task { [weak self] in
            do { try await Task.sleep(for: Self.quickPassDelay) } catch { return }
            guard let self else { return }
            self.quickPass = nil
            await self.pass()
        }
    }

    /// Called when the app leaves the foreground: stops the loop, then runs one last pass under a background task
    /// (after any pass already running), so a Margin saved just before is written now, not on the next foreground.
    @discardableResult
    func finishBeforeBackground() -> Task<Void, Never>? {
        stop()
        guard isEnabled else { return nil }
        let backgroundWork = BackgroundWork(name: "Save Margins to Notes Folder")
        return Task { [weak self] in
            defer { backgroundWork.end() }
            guard let self else { return }
            while self.isDelivering {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            await self.pass()
        }
    }

    func pass() async {
        guard isEnabled, !isRecording() else { return }
        guard !isDelivering else { passRequestedDuringPass = true; return }
        isDelivering = true
        defer { isDelivering = false }
        repeat {
            passRequestedDuringPass = false
            await deliverOnce()
        } while passRequestedDuringPass && isEnabled && !isRecording()
    }

    private func deliverOnce() async {
        guard let store = store() else { return }
        var claimedFolders: [String: String] = [:]
        for id in destinations.filter(\.isEnabled).map(\.id) {
            // Re-read each time: the listener can pause or remove a destination while an earlier one is writing.
            guard let destination = destination(id), destination.isEnabled else { continue }
            await deliver(to: destination, store: store, claimedFolders: &claimedFolders)
        }
    }

    private func deliver(to destination: MarginOutputDestination, store: SQLiteSessionStore, claimedFolders: inout [String: String]) async {
        do {
            let folder = try resolveFolder(of: destination)
            // Resolving can refresh a stale bookmark and save it. Compare against that, or `isCurrent` would see the
            // refresh as the listener repointing the destination and drop this pass's notes.
            guard let destination = self.destination(destination.id) else { return }
            let path = folder.standardizedFileURL.path
            if let owner = claimedFolders[path] {
                // Two destinations writing one folder would take each other's notes for edits.
                setStatus(.failure("\(owner) already delivers to this folder. Pick a different folder here so the two don't overwrite each other."), for: destination.id)
                return
            }
            claimedFolders[path] = destination.name
            let content = destination.content
            // The choices are part of the key, so changing one rebuilds every note instead of waiting for the repair pass.
            let key = [
                destination.id, path, content.scope.rawValue, String(content.includesContext), content.text.rawValue,
                content.shape.rawValue, String(content.itemNotesSince?.timeIntervalSince1970 ?? 0),
            ].joined(separator: "|")
            // Planning reads every transcript's size and the Margin changes across the Library: off the main actor, which
            // only waits. It ran on main as the app left the foreground, just after a Margin was saved (#2184).
            let planner = planners[destination.id] ?? MarginNotePassPlanner()
            let pass = try await Task.detached(priority: .utility) { try planner.plan(store: store, targetKey: key) }.value
            guard isCurrent(destination) else { return }
            var delivered: (noteIDs: [String], keptEditIDs: Set<String>) = ([], [])
            if pass.scope != .nothing {
                var sessionIds: Set<String>?
                if case .sessions(let changed) = pass.scope { sessionIds = changed }
                // Built on a background task (#161); the main actor only waits.
                let gathered = try await AutomaticMarginNoteGatherer.gather(store: store, sessionIds: sessionIds, content: content)
                recordGather(gathered.elapsedMs, gathered.sessionCount, gathered.notes.count)
                // Gathering can take seconds. If the listener paused, removed, repointed or re-scoped this destination
                // meanwhile, these notes were built for choices that no longer hold: write nothing.
                guard isCurrent(destination) else { return }
                let result = try await currentWriter().deliverReportingKeptEdits(gathered.notes, to: folder, destinationID: destination.id)
                delivered = (gathered.notes.map(\.id), result.keptEditIDs)
            }
            // Removed or paused while it was writing: its planner is not kept, so a later start begins with a full pass.
            guard isCurrent(destination) else { return }
            // Committed in place: a completion noted while this pass was writing stays in the planner for the next one.
            planners[destination.id, default: MarginNotePassPlanner()].commit(pass, noteIDs: delivered.noteIDs, keptEditIDs: delivered.keptEditIDs)
            setStatus(MarginOutputStatus(MarginNoteDelivery.statusLine(
                planners[destination.id]?.folderSummary ?? .init(), folderName: destination.name,
                checkedAt: Date().formatted(date: .omitted, time: .shortened),
                noun: content.shape == .itemOnCompletion ? ("item note", "item notes") : ("Margin", "Margins")
            )), for: destination.id)
        } catch is NeedsFolderAccess {
            // Already marked; the other destinations carry on.
        } catch {
            setStatus(.failure("Delivery needs attention: \(error.localizedDescription)"), for: destination.id)
        }
    }

    /// The destination is still there, still delivering, with the same folder and choices as when the pass began.
    private func isCurrent(_ started: MarginOutputDestination) -> Bool {
        guard let now = destination(started.id) else { return false }
        return now.isEnabled && now.content == started.content && now.bookmark == started.bookmark
    }

    private func currentWriter() throws -> AutomaticMarginWriter {
        if let writer { return writer }
        let created = AutomaticMarginWriter(journalURL: try journalURL())
        writer = created
        return created
    }

    // MARK: - The folder behind a destination

    private struct NeedsFolderAccess: Error {}

    /// The destination's folder. A stale bookmark that still resolves is refreshed and saved. One that doesn't, or a
    /// folder that is gone, marks only this destination "Needs folder access" and throws `NeedsFolderAccess`.
    private func resolveFolder(of destination: MarginOutputDestination) throws -> URL {
        let url: URL
        do {
            let resolved = try folders.resolve(destination.bookmark)
            if let refreshed = resolved.refreshedBookmark { update(destination.id, save: true) { $0.bookmark = refreshed } }
            url = resolved.url
        } catch {
            markNeedsAccess(destination)
            throw NeedsFolderAccess()
        }
        guard folders.isReachable(url) else {
            markNeedsAccess(destination)
            throw NeedsFolderAccess()
        }
        folderNames[destination.id] = url.lastPathComponent
        if accessLost.remove(destination.id) != nil { statuses[destination.id] = nil }
        return url
    }

    private func markNeedsAccess(_ destination: MarginOutputDestination) {
        accessLost.insert(destination.id)
        statuses[destination.id] = MarginOutputStatus.failure("Needs folder access. Reselect the folder to keep delivering to \(destination.name). Your Margins remain safely in the Library.")
    }

    // MARK: - What the listener can do

    /// Adds a destination for a folder the listener picked. It starts paused: choosing a folder doesn't write
    /// anything until the listener has sent a test note and chosen to deliver.
    @discardableResult
    func addDestination(folder url: URL) -> MarginOutputDestination? {
        guard canSave else { return nil }
        do {
            let destination = MarginOutputDestination(
                name: MarginOutputDestination.nextName(base: url.lastPathComponent, existing: destinations),
                bookmark: try folders.makeBookmark(url),
                isEnabled: false
            )
            destinations.append(destination)
            guard persist() else {
                destinations.removeLast()
                return nil
            }
            folderNames[destination.id] = url.lastPathComponent
            statuses[destination.id] = MarginOutputStatus("Folder set to \(url.lastPathComponent). Send a test note, then start delivery.")
            return destination
        } catch {
            notice = MarginOutputStatus.failure("Couldn't use that folder: \(error.localizedDescription)")
            return nil
        }
    }

    /// Points a destination at a folder the listener picked: re-granting access to the same folder, or choosing another.
    /// The id stays, so the writer's journal still recognizes the notes already written.
    func replaceFolder(of id: String, with url: URL) {
        guard canSave, destination(id) != nil else { return }
        do {
            let bookmark = try folders.makeBookmark(url)
            update(id, save: true) { $0.bookmark = bookmark }
            folderNames[id] = url.lastPathComponent
            accessLost.remove(id)
            statuses[id] = MarginOutputStatus("Folder set to \(url.lastPathComponent).")
            planners[id] = nil
            deliverSoon()
        } catch {
            statuses[id] = MarginOutputStatus.failure("Couldn't use that folder: \(error.localizedDescription)")
        }
    }

    func reportFolderPickFailure(_ error: Error) {
        notice = MarginOutputStatus.failure("Folder selection failed: \(error.localizedDescription)")
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id, save: true) { $0.name = trimmed }
    }

    /// Changes what a destination's notes hold. The next pass rewrites the notes this build wrote, not ones the listener edited.
    func setContent(of id: String, scope: MarginOutputDestination.Scope? = nil, includesContext: Bool? = nil, text: MarginOutputDestination.TextChoice? = nil) {
        update(id, save: true) {
            if let scope { $0.scope = scope }
            if let includesContext { $0.includesContext = includesContext }
            if let text { $0.text = text }
        }
        deliverSoon()
    }

    /// Chooses a note for each Margin, or one note per item when it is marked complete (#587). Choosing the second shape
    /// remembers when, so items already finished don't each get a note.
    func setShape(of id: String, _ shape: MarginNotesShape) {
        guard let current = destination(id), current.shape != shape else { return }
        update(id, save: true) {
            $0.shape = shape
            $0.itemNotesSince = shape == .itemOnCompletion ? Date() : nil
        }
        deliverSoon()
    }

    /// An item was marked complete (#587). That writes no Margin row, so tell the destinations that write item notes.
    /// Finishing an item by listening isn't reported here; the 30-minute repair pass picks it up.
    func noteCompletion(ofItem itemId: String) {
        var asked = false
        for destination in destinations where destination.isEnabled && destination.shape == .itemOnCompletion {
            planners[destination.id, default: MarginNotePassPlanner()].noteCompletion(ofItem: itemId)
            asked = true
        }
        if asked { deliverSoon() }
    }

    /// Pauses a destination or starts it again. Pausing keeps its folder, choices and journal.
    func setEnabled(_ id: String, _ enabled: Bool) {
        update(id, save: true) { $0.isEnabled = enabled }
        if enabled {
            statuses[id] = nil
            start()
            deliverSoon()
        } else {
            planners[id] = nil
            statuses[id] = MarginOutputStatus("Paused. Margins stay in your Library and nothing new is written here.")
            if !isEnabled { stop() }
        }
    }

    /// Removes a destination. Files already written stay where they are.
    func remove(_ id: String) {
        guard canSave, destination(id) != nil else { return }
        let before = destinations
        destinations.removeAll { $0.id == id }
        guard persist() else {
            // Still saved on disk, so it must stay on screen: it would come back on the next launch.
            destinations = before
            return
        }
        planners[id] = nil
        statuses[id] = nil
        folderNames[id] = nil
        accessLost.remove(id)
        if !isEnabled { stop() }
    }

    /// Runs one pass for every destination now ("Retry Delivery").
    func retry() async { await pass() }

    /// Sends a sample note so the listener can check the folder before turning delivery on.
    func sendTestNote(to id: String) async {
        guard let destination = destination(id) else { return }
        do {
            let folder = try resolveFolder(of: destination)
            let summary = try await currentWriter().deliver(
                [.init(id: "sample-margin", markdown: "# Spoken Margins test\n\nYour thoughts will arrive here as Markdown, with the source around each one.\n")],
                to: folder, destinationID: destination.id
            )
            let file = "Margin-\(ListeningEdition.digest("sample-margin")).md"
            setStatus(
                summary.keptEdits > 0
                    ? MarginOutputStatus("The test note \(file) is already in this folder and you edited it, so it was left as is.")
                    : MarginOutputStatus("Test note saved. Open \(file) in your notes app."),
                for: id
            )
        } catch is NeedsFolderAccess {
        } catch {
            setStatus(.failure(error.localizedDescription), for: id)
        }
    }

    // MARK: - Bookkeeping

    func destination(_ id: String) -> MarginOutputDestination? { destinations.first { $0.id == id } }

    static func defaultStatus(for destination: MarginOutputDestination) -> MarginOutputStatus {
        destination.isEnabled
            ? MarginOutputStatus("Delivering. The next check is within a minute.")
            : MarginOutputStatus("Paused. Send a test note, then start delivery.")
    }

    private func setStatus(_ status: MarginOutputStatus, for id: String) {
        guard destination(id) != nil else { return }
        statuses[id] = status
    }

    /// Changes one destination in place. Nothing happens for an id that was removed meanwhile.
    private func update(_ id: String, save: Bool, _ change: (inout MarginOutputDestination) -> Void) {
        guard canSave, let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        change(&destinations[index])
        if save { persist() }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try destinationStore.save(destinations)
            notice = nil
            return true
        } catch {
            notice = MarginOutputStatus.failure("Couldn't save your Margin Output settings: \(error.localizedDescription)")
            return false
        }
    }
}

/// Asks iOS for time to finish after the app leaves the foreground, and gives it back when done or when time runs out.
@MainActor
private final class BackgroundWork {
    #if canImport(UIKit)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(name: String) {
        #if canImport(UIKit)
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
        #endif
    }

    func end() {
        #if canImport(UIKit)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #endif
    }
}
