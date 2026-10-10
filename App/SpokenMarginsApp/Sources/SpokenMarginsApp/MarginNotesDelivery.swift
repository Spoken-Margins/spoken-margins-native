import Foundation
import SessionKit
import SessionKitPersistence
#if canImport(UIKit)
import UIKit
#endif

/// "Save Margins to Notes Folder": writes each Margin as a Markdown note (#161, #171).
///
/// A pass runs when the app becomes active and then once a minute, a few seconds after a Margin or its
/// transcript is saved, and once more under a background task when the app leaves the foreground, so a
/// Margin recorded just before switching apps still arrives. Passes never overlap; one asked for during a
/// pass runs right after it. The writer only rewrites its own unedited files, so repeated passes are safe.
///
/// A pass rebuilds only the notes whose sessions changed, and does nothing when none did; every 30 minutes, on the
/// first pass and when the folder changes it rebuilds all of them (#1192, `MarginNotePassPlanner`).
@MainActor
final class MarginNotesDelivery {
    /// What a pass writes to, read at the start of each pass.
    struct Target {
        var store: SQLiteSessionStore
        var folder: URL
        var destinationID: String
    }

    static let quickPassDelay: Duration = .seconds(2)
    static let loopInterval: Duration = .seconds(60)

    /// Cheap: delivery is on and the Library is open.
    private let isEnabled: @MainActor () -> Bool
    /// Skips a pass while a Margin is being recorded; the save at the end of the recording asks for one.
    private let isRecording: @MainActor () -> Bool
    /// Resolves the folder; throws a message for the listener when it can't.
    private let target: @MainActor () throws -> Target
    private let report: @MainActor (MarginOutputStatus) -> Void
    private let recordGather: @MainActor (_ ms: Int, _ sessions: Int, _ notes: Int) -> Void
    private let journalURL: () throws -> URL

    private var loop: Task<Void, Never>?
    private var quickPass: Task<Void, Never>?
    private var isDelivering = false
    private var passRequestedDuringPass = false
    private var writer: AutomaticMarginWriter?
    /// What the last finished pass left to do next time (#1192).
    private var planner = MarginNotePassPlanner()

    init(
        isEnabled: @escaping @MainActor () -> Bool,
        isRecording: @escaping @MainActor () -> Bool,
        target: @escaping @MainActor () throws -> Target,
        report: @escaping @MainActor (MarginOutputStatus) -> Void,
        recordGather: @escaping @MainActor (_ ms: Int, _ sessions: Int, _ notes: Int) -> Void = { _, _, _ in },
        journalURL: @escaping () throws -> URL = MarginNotesDelivery.defaultJournalURL
    ) {
        self.isEnabled = isEnabled
        self.isRecording = isRecording
        self.target = target
        self.report = report
        self.recordGather = recordGather
        self.journalURL = journalURL
    }

    nonisolated static func defaultJournalURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SpokenMargins/MarginOutputJournal.json")
    }

    /// Called when the app becomes active and when delivery is turned on.
    func start() {
        guard isEnabled(), loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pass()
                do { try await Task.sleep(for: Self.loopInterval) } catch { break }
            }
        }
    }

    /// Called when delivery is turned off. A pass already writing finishes its current note set.
    func stop() {
        loop?.cancel(); loop = nil
        quickPass?.cancel(); quickPass = nil
    }

    /// A Margin or its transcript changed: deliver within a few seconds instead of on the next minute.
    /// Repeated calls while one is pending don't push it back.
    func deliverSoon() {
        guard quickPass == nil, isEnabled() else { return }
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
        guard isEnabled() else { return nil }
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
        guard isEnabled(), !isRecording() else { return }
        guard !isDelivering else { passRequestedDuringPass = true; return }
        isDelivering = true
        defer { isDelivering = false }
        repeat {
            passRequestedDuringPass = false
            await deliverOnce()
        } while passRequestedDuringPass && isEnabled() && !isRecording()
    }

    /// Sends a sample note so the listener can check the folder before turning delivery on.
    func sendTestNote(to folder: URL, destinationID: String) async throws -> MarginOutputStatus {
        let summary = try await currentWriter().deliver(
            [.init(id: "sample-margin", markdown: "# Spoken Margins test\n\nYour thoughts will arrive here as Markdown, with source context and anchors.\n")],
            to: folder, destinationID: destinationID
        )
        let file = "Margin-\(ListeningEdition.digest("sample-margin")).md"
        if summary.keptEdits > 0 { return MarginOutputStatus("The test note \(file) is already in this folder and you edited it, so it was left as is.") }
        return MarginOutputStatus("Test note saved. Open \(file) in your notes app.")
    }

    private func deliverOnce() async {
        do {
            let target = try target()
            let pass = try planner.plan(store: target.store, targetKey: target.destinationID + "|" + target.folder.path)
            var delivered: (noteIDs: [String], keptEditIDs: Set<String>) = ([], [])
            if pass.scope != .nothing {
                var sessionIds: Set<String>?
                if case .sessions(let changed) = pass.scope { sessionIds = changed }
                // Built on a background task (#161); the main actor only waits.
                let gathered = try await AutomaticMarginNoteGatherer.gather(store: target.store, sessionIds: sessionIds)
                recordGather(gathered.elapsedMs, gathered.sessionCount, gathered.notes.count)
                let result = try await currentWriter().deliverReportingKeptEdits(gathered.notes, to: target.folder, destinationID: target.destinationID)
                delivered = (gathered.notes.map(\.id), result.keptEditIDs)
            }
            planner.commit(pass, noteIDs: delivered.noteIDs, keptEditIDs: delivered.keptEditIDs)
            report(MarginOutputStatus(MarginNoteDelivery.statusLine(
                planner.folderSummary, folderName: target.folder.lastPathComponent,
                checkedAt: Date().formatted(date: .omitted, time: .shortened)
            )))
        } catch {
            report(.failure("Delivery needs attention: \(error.localizedDescription)"))
        }
    }

    private func currentWriter() throws -> AutomaticMarginWriter {
        if let writer { return writer }
        let created = AutomaticMarginWriter(journalURL: try journalURL())
        writer = created
        return created
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
