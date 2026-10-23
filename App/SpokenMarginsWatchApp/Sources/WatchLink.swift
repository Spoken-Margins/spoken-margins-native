import Foundation
import WatchConnectivity
import WatchKit

/// The Watch's side of the contract with the phone (#2487 slice 1b; DESIGN section 4). It owns the WatchConnectivity
/// session from app launch (`WatchAppDelegate`), not from the first screen, so a background wake still hears the
/// phone's answer. The decisions are made by `WatchMarginLedger` and `WatchSessionModel` (WatchContractState.swift,
/// host-tested in SessionKit); this wraps them with the two lanes, the recordings on disk and a state file.
///
/// - A recording is kept until the phone answers "filed" for its id and bytes; then, and only then, it is deleted.
/// - Every message goes on the sure lane (`transferUserInfo`, `transferFile`); while the app is in front and the phone
///   is reachable it also goes on the fast lane (`sendMessage`), whose reply measures the clock.
/// - "Hello" on opening lists what the Watch holds; the reply answers what the phone already filed, and the rest is
///   sent again at once.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    @Published private(set) var ledger = WatchMarginLedger()
    @Published private(set) var model = WatchSessionModel()
    @Published private(set) var isReachable = false
    /// The Margin recorded last, whose state shows under Record.
    @Published private(set) var lastMarginId: String?

    private var seq = 0
    private var activated = false
    private var retryLoop: Task<Void, Never>?
    private var contentPendingObservation: NSKeyValueObservation?
    private var pendingRefreshTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private let files = WatchLinkFiles()

    /// The saved state is read off the main thread at launch. Until it is in, every change waits, so nothing is
    /// decided on an empty ledger and then overwritten.
    private var isLoaded = false
    private var waitingForLoad: [@MainActor () -> Void] = []

    private override init() {
        super.init()
        Task { [files] in
            let saved = await files.loadState()
            if let saved {
                ledger = saved.ledger
                model = saved.model
                seq = saved.seq
            }
            isLoaded = true
            let waiting = waitingForLoad
            waitingForLoad = []
            for body in waiting { body() }
        }
    }

    private func whenLoaded(_ body: @escaping @MainActor () -> Void) {
        if isLoaded { body() } else { waitingForLoad.append(body) }
    }

    // MARK: Launch and opening

    /// Called at launch, foreground or background. Safe to call again.
    func activate() {
        whenLoaded { self.activateNow() }
    }

    private func activateNow() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        contentPendingObservation = session.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.completeRefreshTasksIfDone() }
        }
        Task { await adoptOrphans() }
    }

    /// The app came to the front: say hello, send what is due, and keep retrying while it stays open.
    func appBecameActive() {
        activate()
        whenLoaded { self.becameActiveNow() }
    }

    private func becameActiveNow() {
        sayHello()
        sendDue()
        retryLoop?.cancel()
        retryLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.sendDue()
            }
        }
    }

    func appWentToBackground() {
        retryLoop?.cancel()
        retryLoop = nil
    }

    /// A WatchConnectivity background wake: finished once the delivered content has been handled.
    func keep(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        activate()
        pendingRefreshTasks.append(task)
        completeRefreshTasksIfDone()
    }

    private func completeRefreshTasksIfDone() {
        guard WCSession.default.activationState == .activated, !WCSession.default.hasContentPending else { return }
        let tasks = pendingRefreshTasks
        pendingRefreshTasks = []
        Task {
            await files.waitForWrites() // the answers it brought are saved before the app is suspended
            for task in tasks { task.setTaskCompletedWithSnapshot(false) }
        }
    }

    // MARK: Sessions

    func home(now: Date) -> WatchSessionModel.Home {
        model.home(now: now, phoneReachable: isReachable)
    }

    func startSession(kind: WatchSessionKind) {
        whenLoaded { self.startSessionNow(kind: kind) }
    }

    private func startSessionNow(kind: WatchSessionKind) {
        let info = model.start(kind: kind, id: "live-\(UUID().uuidString.lowercased())", now: Date())
        saveState()
        send(.sessionStart(info))
    }

    func endSession() {
        whenLoaded { self.endSessionNow() }
    }

    private func endSessionNow() {
        guard let ended = model.end(now: Date()) else { return }
        saveState()
        send(.sessionEnd(id: ended.id, endedAt: ended.endedAt))
    }

    func resumeSession() {
        whenLoaded { self.resumeSessionNow() }
    }

    private func resumeSessionNow() {
        guard let id = model.resume(now: Date()) else { return }
        saveState()
        send(.sessionResume(id: id))
    }

    // MARK: Margins

    /// A finished recording, closed on disk: it is held until the phone files it.
    func record(_ finished: WatchMarginCapture.Finished, id: String, wallStart: Date) {
        whenLoaded { self.recordNow(finished, id: id, wallStart: wallStart) }
    }

    private func recordNow(_ finished: WatchMarginCapture.Finished, id: String, wallStart: Date) {
        let transfer = WatchMarginTransfer(
            id: id, wallStart: wallStart, durationMs: max(0, Int((finished.duration * 1_000).rounded())),
            sessionId: model.sessionIdForMargin(now: wallStart),
            clock: model.clock.flatMap { $0.isFresh(at: wallStart) ? $0 : nil },
            sha256: finished.sha256
        )
        ledger.record(transfer, fileName: finished.url.lastPathComponent, now: Date())
        lastMarginId = id
        saveState()
        sendDue()
    }

    func retry(_ id: String) {
        guard isLoaded else { return }
        ledger.retry(id)
        saveState()
        sendDue()
    }

    func delete(_ id: String) {
        guard isLoaded else { return }
        for transfer in WCSession.default.outstandingFileTransfers where transfer.file.metadata?[WatchMarginTransfer.Key.id] as? String == id {
            transfer.cancel()
        }
        guard let fileName = ledger.delete(id) else { return }
        saveState()
        files.removeRecording(named: fileName)
        send(.withdraw(id: id))
    }

    /// Hands every due Margin to WatchConnectivity: the file on the sure lane, its details on the fast lane.
    func sendDue() {
        guard isLoaded, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        let inFlight = Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?[WatchMarginTransfer.Key.id] as? String })
        let now = Date()
        var sent = false
        for id in ledger.due(now: now, inFlight: inFlight) {
            guard let item = ledger.held(id), let url = WatchLinkFiles.recordingURL(named: item.fileName),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let transfer = ledger.markSent(id, now: now) else { continue }
            session.transferFile(url, metadata: transfer.metadata)
            sendFast(.marginDetails(transfer))
            sent = true
        }
        if sent { saveState() }
    }

    // MARK: The lanes

    private func envelope(_ message: WatchMessage) -> WatchEnvelope {
        seq += 1
        return WatchEnvelope(seq: seq, sentAt: Date(), clock: model.clock, message: message)
    }

    /// The sure lane always; the fast lane as well when the phone is reachable.
    private func send(_ message: WatchMessage) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let wrapped = envelope(message)
        WCSession.default.transferUserInfo(wrapped.dictionary)
        sendFast(wrapped)
    }

    private func sendFast(_ message: WatchMessage) {
        sendFast(envelope(message))
    }

    private func sendFast(_ wrapped: WatchEnvelope, afterHello holding: [String]? = nil) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        let sentAt = wrapped.sentAt
        WCSession.default.sendMessage(wrapped.dictionary, replyHandler: { [weak self] dictionary in
            let receivedAt = Date()
            guard let reply = WatchPhoneReply(dictionary: dictionary) else { return }
            Task { @MainActor in self?.apply(reply, sentAt: sentAt, receivedAt: receivedAt, helloHolding: holding) }
        }, errorHandler: nil)
    }

    private func sayHello() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let holding = ledger.holdingIds
        let wrapped = envelope(.hello(holding: holding))
        WCSession.default.transferUserInfo(wrapped.dictionary)
        sendFast(wrapped, afterHello: holding)
    }

    // MARK: What the phone says

    private func apply(_ reply: WatchPhoneReply, sentAt: Date, receivedAt: Date, helloHolding: [String]?) {
        if let stamp = WatchClockStamp.measure(sentAt: sentAt, phoneTime: reply.phoneTime, receivedAt: receivedAt) {
            model.clock = stamp
        }
        model.apply(reply.board, receivedAt: receivedAt)
        for answer in reply.answers { apply(answer) }
        if let helloHolding {
            let answered = Set(reply.answers.map(\.receipt.captureId))
            let inFlight = Set(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?[WatchMarginTransfer.Key.id] as? String })
            ledger.unansweredAfterHello(answered: answered.intersection(helloHolding), inFlight: inFlight)
            sendDue()
        }
        saveState()
    }

    fileprivate func apply(_ answer: WatchMarginAnswer) {
        switch ledger.apply(answer, now: Date()) {
        case .filed(let fileName):
            files.removeRecording(named: fileName)
            if WKApplication.shared().applicationState == .active { WKInterfaceDevice.current().play(.click) }
        case .willResend, .rejected, .ignored:
            break
        }
        saveState()
    }

    fileprivate func apply(board: WatchBoard) {
        model.apply(board, receivedAt: Date())
        saveState()
    }

    fileprivate func transferFailed(id: String, error: String) {
        ledger.transferFailed(id, error: error)
        saveState()
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        isReachable = reachable
        if reachable, WKApplication.shared().applicationState == .active {
            sayHello()
            sendDue()
        }
    }

    // MARK: Disk

    private func saveState() {
        files.save(WatchLinkState(ledger: ledger, model: model, seq: seq))
    }

    /// Recordings the first Watch build left behind after a failed transfer: it kept them but never sent them again.
    private func adoptOrphans() async {
        let known = Set(ledger.held.map(\.fileName))
        let orphans = await files.orphanRecordings(excluding: known)
        guard !orphans.isEmpty else { return }
        for orphan in orphans {
            let id = orphan.url.deletingPathExtension().lastPathComponent
            guard ledger.held(id) == nil else { continue }
            let transfer = WatchMarginTransfer(
                id: id, wallStart: orphan.createdAt, durationMs: Int((orphan.duration * 1_000).rounded()), sha256: orphan.sha256
            )
            ledger.record(transfer, fileName: orphan.url.lastPathComponent, now: Date())
        }
        saveState()
        sendDue()
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let board = WatchBoard(context: session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            if let board { self.apply(board: board) }
            self.isReachable = reachable
            if WKApplication.shared().applicationState == .active {
                self.sayHello()
            }
            self.sendDue()
            self.completeRefreshTasksIfDone()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let board = WatchBoard(context: applicationContext) else { return }
        Task { @MainActor in self.apply(board: board) }
    }

    /// The phone's answers on the sure lane.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let answer = WatchMarginAnswer(userInfo: userInfo) else { return }
        Task { @MainActor in self.apply(answer) }
    }

    /// A finished transfer is not an answer: the recording stays until the phone says "filed" (#2531). A failed one
    /// goes back to "saved" and is sent again.
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let error, let id = fileTransfer.file.metadata?[WatchMarginTransfer.Key.id] as? String else { return }
        let words = error.localizedDescription
        Task { @MainActor in self.transferFailed(id: id, error: words) }
    }
}

/// What the Watch keeps across launches.
struct WatchLinkState: Codable, Sendable {
    var ledger: WatchMarginLedger
    var model: WatchSessionModel
    var seq: Int
}

/// The Watch's files: recordings, and the state file, written off the main thread on one serial queue, so writes land
/// in the order they were made.
final class WatchLinkFiles: @unchecked Sendable {
    struct Orphan: Sendable {
        var url: URL
        var createdAt: Date
        var duration: TimeInterval
        var sha256: String
    }

    private let queue = DispatchQueue(label: "com.spokenmargins.watch.files", qos: .utility)

    static func recordingsDirectory() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let directory = support.appending(path: "WatchMargins", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func recordingURL(named name: String) -> URL? {
        recordingsDirectory()?.appending(path: name)
    }

    private static func stateURL() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return support.appending(path: "WatchLinkState.json")
    }

    /// Read once at launch, on the files queue: a few kilobytes.
    func loadState() async -> WatchLinkState? {
        await withCheckedContinuation { (done: CheckedContinuation<WatchLinkState?, Never>) in
            queue.async {
                guard let url = Self.stateURL(), let data = try? Data(contentsOf: url) else {
                    done.resume(returning: nil)
                    return
                }
                done.resume(returning: try? WatchContractCoding.decoder.decode(WatchLinkState.self, from: data))
            }
        }
    }

    func save(_ state: WatchLinkState) {
        queue.async {
            guard let url = Self.stateURL(), let data = try? WatchContractCoding.encoder.encode(state) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Returns once every write made before it has landed.
    func waitForWrites() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    func removeRecording(named name: String) {
        queue.async {
            guard let url = Self.recordingURL(named: name) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func orphanRecordings(excluding known: Set<String>) async -> [Orphan] {
        await withCheckedContinuation { (done: CheckedContinuation<[Orphan], Never>) in
            queue.async {
                guard let directory = Self.recordingsDirectory(),
                      let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else {
                    done.resume(returning: [])
                    return
                }
                let orphans = urls
                    .filter { $0.pathExtension == "m4a" && !known.contains($0.lastPathComponent) }
                    .compactMap { url -> Orphan? in
                        guard let digest = WatchMarginCapture.digest(of: url) else { return nil }
                        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                        return Orphan(url: url, createdAt: created, duration: WatchMarginCapture.duration(of: url), sha256: digest)
                    }
                done.resume(returning: orphans)
            }
        }
    }
}
