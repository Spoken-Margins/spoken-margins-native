import Foundation
import SessionKit

/// Voice downloads on a background URLSession (#1819), so a 141 MB voice keeps downloading after the
/// listener leaves the app. It feeds VoiceModelInstaller (#1817) through its transport protocol: each file
/// is a download task, and its finished bytes are handed to the installer, which checks the hash and puts
/// the voice in place.
///
/// Three things outlive a single `fetch` call:
/// - a task that was running when the app was suspended or ended is picked up again by URL;
/// - a file that finished while nothing was waiting is kept and served to the next `fetch` of that URL;
/// - resume data from a cancelled or dropped download continues it instead of starting over.
final class BackgroundVoiceModelTransport: NSObject, VoiceModelTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.spokenmargins.voice-downloads"
    static let shared = BackgroundVoiceModelTransport()

    /// True around an install the app starts by itself for a new listener (#2858): its requests wait for Wi-Fi
    /// instead of using mobile data, a hotspot or Low Data Mode, including after the app has left the foreground,
    /// where the app can no longer watch the network. Read when a file's task is made; installs the listener starts
    /// in Voices leave it false and keep the ask they were given.
    @TaskLocal static var wifiOnly = false

    /// Bytes of the file in flight, for a progress bar that moves inside a large file.
    var onBytesWritten: (@Sendable (_ url: URL, _ bytesWritten: Int64) -> Void)? {
        get { lock.withLock { bytesWrittenHandler } }
        set { lock.withLock { bytesWrittenHandler = newValue } }
    }

    private struct Waiter {
        var offset: Int
        var onHead: @Sendable (VoiceModelResponseHead) throws -> Bool
        var onChunk: @Sendable (Data) throws -> Void
        var continuation: CheckedContinuation<Void, Error>
        var cancelledByCaller = false
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    /// Finished files moved out of URLSession's temporary location, by task, until didComplete runs.
    private var finishedFiles: [Int: URL] = [:]
    private var bytesWrittenHandler: (@Sendable (URL, Int64) -> Void)?
    private var backgroundEventsCompletion: (() -> Void)?
    private let folder: URL
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    private override init() {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        folder = caches.appending(path: "VoiceDownloads", directoryHint: .isDirectory)
        super.init()
    }

    /// Set at launch: continues an unfinished install when iOS wakes the app for this session's events.
    var onBackgroundEvents: (@Sendable () -> Void)? {
        get { lock.withLock { backgroundEventsHandler } }
        set { lock.withLock { backgroundEventsHandler = newValue } }
    }
    private var backgroundEventsHandler: (@Sendable () -> Void)?

    /// Called from the app delegate when iOS relaunches the app for this session's events.
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        let handler = lock.withLock {
            backgroundEventsCompletion = completion
            return backgroundEventsHandler
        }
        _ = session
        handler?()
    }

    // MARK: VoiceModelTransport

    func fetch(
        _ url: URL,
        from offset: Int,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        if offset == 0, let kept = keptFile(for: url) {
            // Finished while nothing was waiting: hand it over now.
            defer { try? FileManager.default.removeItem(at: kept) }
            try Self.deliver(kept, head: VoiceModelResponseHead(statusCode: 200), onHead: onHead, onChunk: onChunk)
            return
        }
        let task = await existingTask(for: url, offset: offset) ?? newTask(for: url, offset: offset)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    waiters[task.taskIdentifier] = Waiter(offset: offset, onHead: onHead, onChunk: onChunk, continuation: continuation)
                }
                if task.state == .completed {
                    // A task picked up from before a relaunch finished before this waiter was in place:
                    // its file, if whole, was kept. Fail this attempt so the installer asks again and gets it.
                    if let waiter = lock.withLock({ waiters.removeValue(forKey: task.taskIdentifier) }) {
                        waiter.continuation.resume(throwing: URLError(.networkConnectionLost))
                    }
                    return
                }
                task.resume()
            }
        } onCancel: {
            self.lock.withLock { self.waiters[task.taskIdentifier]?.cancelledByCaller = true }
            task.cancel { [weak self] data in
                // Resume data carries the request it came from, so a Wi-Fi-only file's would hold a later download the
                // listener starts themselves to Wi-Fi too (#2858 audit). Those files start over instead.
                if let data, !Self.isWiFiOnly(task) { self?.saveResumeData(data, for: url) }
            }
        }
    }

    private func newTask(for url: URL, offset: Int) -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        // Resume data carries the request it was made from, which may allow mobile data, so a Wi-Fi-only file
        // starts over and leaves the saved data for a download the listener starts themselves. Wi-Fi-only
        // files save none (`isWiFiOnly`), so what is saved always came from a download the listener started.
        if offset == 0, !Self.wifiOnly, let resumeData = takeResumeData(for: url) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            if Self.wifiOnly {
                request.allowsCellularAccess = false
                request.allowsExpensiveNetworkAccess = false
                request.allowsConstrainedNetworkAccess = false
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = Self.describe(url: url, offset: offset)
        return task
    }

    /// A task still running from before the app was suspended or relaunched, for the same request.
    private func existingTask(for url: URL, offset: Int) async -> URLSessionDownloadTask? {
        let tasks = await session.allTasks
        let waiting = lock.withLock { Set(waiters.keys) }
        // Only a task made under the same rule: a download the listener starts is never handed a Wi-Fi-only one.
        let wifiOnly = Self.wifiOnly
        return tasks.first {
            $0.taskDescription == Self.describe(url: url, offset: offset) && $0.state != .completed
                && !waiting.contains($0.taskIdentifier) && Self.isWiFiOnly($0) == wifiOnly
        } as? URLSessionDownloadTask
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url ?? Self.url(fromDescription: downloadTask.taskDescription) else { return }
        let handler = lock.withLock { bytesWrittenHandler }
        handler?(url, totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so move it somewhere we own first.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appending(path: "task-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: location, to: kept)) != nil else { return }
        lock.withLock { finishedFiles[downloadTask.taskIdentifier] = kept }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiter, file) = lock.withLock { (waiters.removeValue(forKey: task.taskIdentifier), finishedFiles.removeValue(forKey: task.taskIdentifier)) }
        let url = task.originalRequest?.url ?? Self.url(fromDescription: task.taskDescription)
        if let error, let url, !Self.isWiFiOnly(task),
           let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            saveResumeData(data, for: url)
        }
        guard let waiter else {
            // Nobody is waiting (the app was relaunched): keep a whole file for the next fetch of this URL.
            if error == nil, let file, let url, let status = (task.response as? HTTPURLResponse)?.statusCode,
               (200..<300).contains(status), Self.offset(fromDescription: task.taskDescription) == 0 {
                keep(file, for: url)
            } else if let file {
                try? FileManager.default.removeItem(at: file)
            }
            return
        }
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        if waiter.cancelledByCaller {
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        if let error {
            waiter.continuation.resume(throwing: (error as? URLError) ?? URLError(.unknown))
            return
        }
        guard let http = task.response as? HTTPURLResponse, let file else {
            waiter.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        // A download continued from resume data arrives whole, as the original request asked.
        let head: VoiceModelResponseHead = if waiter.offset == 0, (200..<300).contains(http.statusCode) {
            VoiceModelResponseHead(statusCode: 200)
        } else {
            VoiceModelResponseHead(statusCode: http.statusCode, contentRangeStart: Self.rangeStart(http.value(forHTTPHeaderField: "Content-Range")))
        }
        do {
            try Self.deliver(file, head: head, onHead: waiter.onHead, onChunk: waiter.onChunk)
            waiter.continuation.resume()
        } catch {
            waiter.continuation.resume(throwing: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            let completion = backgroundEventsCompletion
            backgroundEventsCompletion = nil
            return completion
        }
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    // MARK: Files kept between launches

    private static func deliver(_ file: URL, head: VoiceModelResponseHead, onHead: (VoiceModelResponseHead) throws -> Bool, onChunk: (Data) throws -> Void) throws {
        guard try onHead(head) else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try onChunk(chunk)
        }
    }

    private func name(for url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
            .suffix(120).description
    }

    private func keptFile(for url: URL) -> URL? {
        let candidate = folder.appending(path: "done-\(name(for: url))")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func keep(_ file: URL, for url: URL) {
        let destination = folder.appending(path: "done-\(name(for: url))")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: file, to: destination)
    }

    private func saveResumeData(_ data: Data, for url: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appending(path: "resume-\(name(for: url))"), options: .atomic)
    }

    private func takeResumeData(for url: URL) -> Data? {
        let file = folder.appending(path: "resume-\(name(for: url))")
        defer { try? FileManager.default.removeItem(at: file) }
        return try? Data(contentsOf: file)
    }

    /// Made by an install the app started by itself (`wifiOnly`): its request refuses mobile data.
    static func isWiFiOnly(_ task: URLSessionTask) -> Bool {
        task.originalRequest?.allowsCellularAccess == false
    }

    private static func describe(url: URL, offset: Int) -> String { "\(offset) \(url.absoluteString)" }

    private static func url(fromDescription description: String?) -> URL? {
        description?.split(separator: " ", maxSplits: 1).last.flatMap { URL(string: String($0)) }
    }

    private static func offset(fromDescription description: String?) -> Int? {
        description?.split(separator: " ", maxSplits: 1).first.flatMap { Int($0) }
    }

    /// `bytes 100-199/200` gives 100.
    private static func rangeStart(_ header: String?) -> Int? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        return parts[1].split(separator: "-", maxSplits: 1).first.flatMap { Int($0) }
    }
}
