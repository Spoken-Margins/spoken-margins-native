import Foundation

/// The files BackgroundVoiceModelTransport (#1819) keeps between launches, and the small parsing it does on
/// task descriptions and `Content-Range` headers. Split out of the transport (#318) so it is built and tested on
/// the host and Linux, while the background URLSession stays Apple-only.
///
/// Three kinds of file live in `folder`:
/// - `task-<uuid>`: a finished download moved out of URLSession's temporary location, until its task completes;
/// - `done-<name>`: a whole file that finished while nothing was waiting, served to the next fetch of that URL;
/// - `resume-<name>`: resume data from a cancelled or dropped download, taken once to continue it.
struct VoiceDownloadFileStore: Sendable {
    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    /// The app's own folder, `Caches/VoiceDownloads`, so iOS may clear it under storage pressure.
    static func inCaches() -> VoiceDownloadFileStore {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return VoiceDownloadFileStore(folder: caches.appending(path: "VoiceDownloads", directoryHint: .isDirectory))
    }

    /// Moves a file URLSession is about to delete into `folder`; nil when the move fails.
    func adopt(_ location: URL) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appending(path: "task-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: location, to: kept)) != nil else { return nil }
        return kept
    }

    func keptFile(for url: URL) -> URL? {
        let candidate = folder.appending(path: "done-\(Self.name(for: url))")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func keep(_ file: URL, for url: URL) {
        let destination = folder.appending(path: "done-\(Self.name(for: url))")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: file, to: destination)
    }

    func saveResumeData(_ data: Data, for url: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appending(path: "resume-\(Self.name(for: url))"), options: .atomic)
    }

    /// The saved resume data, once: the file is deleted as it is read.
    func takeResumeData(for url: URL) -> Data? {
        let file = folder.appending(path: "resume-\(Self.name(for: url))")
        defer { try? FileManager.default.removeItem(at: file) }
        return try? Data(contentsOf: file)
    }

    /// A file name for a URL: its base64 with the characters a path can't hold swapped, the last 120 of them.
    static func name(for url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
            .suffix(120).description
    }

    /// Hands a file to the installer the way a live response would: the head first, then the body in 1 MiB pieces.
    static func deliver(_ file: URL, head: VoiceModelResponseHead, onHead: (VoiceModelResponseHead) throws -> Bool, onChunk: (Data) throws -> Void) throws {
        guard try onHead(head) else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try onChunk(chunk)
        }
    }

    /// A task's `taskDescription`: `<offset> <url>`, which is how a task from before a relaunch is told apart.
    static func describe(url: URL, offset: Int) -> String { "\(offset) \(url.absoluteString)" }

    static func url(fromDescription description: String?) -> URL? {
        description?.split(separator: " ", maxSplits: 1).last.flatMap { URL(string: String($0)) }
    }

    static func offset(fromDescription description: String?) -> Int? {
        description?.split(separator: " ", maxSplits: 1).first.flatMap { Int($0) }
    }

    /// `bytes 100-199/200` gives 100.
    static func rangeStart(_ header: String?) -> Int? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        return parts[1].split(separator: "-", maxSplits: 1).first.flatMap { Int($0) }
    }
}
