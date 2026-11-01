import Foundation

/// The Markdown files of a multi-session export, built in a temporary folder for the system share sheet
/// (#1528). Nothing here chooses or writes a remembered destination: the listener picks AirDrop, Save to
/// Files or another target each time, and "shared" is only claimed after the sheet says it completed.
public struct SessionShareFiles: Equatable, Sendable {
    public struct Source: Equatable, Sendable {
        public let sessionId: String
        public let itemTitle: String
        public let sessionDate: Date?
        public init(sessionId: String, itemTitle: String, sessionDate: Date?) {
            self.sessionId = sessionId; self.itemTitle = itemTitle; self.sessionDate = sessionDate
        }
    }

    /// The folder holding this share's files; nil when no file could be built.
    public let directory: URL?
    public let fileURLs: [URL]
    /// "<title>: <reason>" for each session that could not be built.
    public let failures: [String]

    public static let folderName = "SpokenMarginsBatchShare"

    /// Every share's folder lives under here until its sheet closes. iPad windows can each have a sheet
    /// open, so a new share never clears another's files.
    public static func shareRoot(in temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Builds one `.md` file per source in a fresh folder under `root`, named by `SessionMarkdownFileWriter`.
    /// `render` returns one session's Markdown. A session that fails is listed in `failures` and the rest
    /// are still built.
    public static func build(_ sources: [Source], root: URL,
                             render: (Source) throws -> String) -> SessionShareFiles {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return SessionShareFiles(directory: nil, fileURLs: [],
                                     failures: sources.map { "\($0.itemTitle): \(error.localizedDescription)" })
        }
        let writer = SessionMarkdownFileWriter()
        var urls: [URL] = []
        var failures: [String] = []
        for source in sources {
            do {
                urls.append(try writer.write(markdown: try render(source), itemTitle: source.itemTitle,
                                             sessionDate: source.sessionDate, sessionId: source.sessionId, to: directory))
            } catch {
                failures.append("\(source.itemTitle): \(error.localizedDescription)")
            }
        }
        if urls.isEmpty { try? FileManager.default.removeItem(at: directory) }
        return SessionShareFiles(directory: urls.isEmpty ? nil : directory, fileURLs: urls, failures: failures)
    }

    /// `build`, with the file work off the caller's actor (#2510). The folder is made and each file is written on a
    /// background task; `render` runs on the caller's actor, where a caller can read the store with an async
    /// read. Sources are rendered and written one at a time, in order, so a failure lists the same text as `build`
    /// and the files are named the same. A caller that is cancelled between sources stops there: what was written
    /// is removed and every unbuilt source is listed as cancelled, so no half share is left behind.
    public static func buildOffMain(_ sources: [Source], root: URL,
                                    isolation: isolated (any Actor)? = #isolation,
                                    render: (Source) async throws -> String) async -> SessionShareFiles {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }.value
        } catch {
            return SessionShareFiles(directory: nil, fileURLs: [],
                                     failures: sources.map { "\($0.itemTitle): \(error.localizedDescription)" })
        }
        var urls: [URL] = []
        var failures: [String] = []
        for source in sources {
            if Task.isCancelled {
                failures.append("\(source.itemTitle): cancelled")
                continue
            }
            do {
                let markdown = try await render(source)
                let url = try await Task.detached(priority: .userInitiated) {
                    try SessionMarkdownFileWriter().write(markdown: markdown, itemTitle: source.itemTitle,
                                                          sessionDate: source.sessionDate, sessionId: source.sessionId,
                                                          to: directory)
                }.value
                urls.append(url)
            } catch {
                failures.append("\(source.itemTitle): \(error.localizedDescription)")
            }
        }
        if urls.isEmpty || Task.isCancelled {
            _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
            return SessionShareFiles(directory: nil, fileURLs: [], failures: failures)
        }
        return SessionShareFiles(directory: directory, fileURLs: urls, failures: failures)
    }

    /// Removes this share's folder once its sheet has closed. Leaves any folder outside `root` alone.
    public func discard(root: URL = SessionShareFiles.shareRoot()) {
        guard let directory,
              directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes folders left by an app that was killed while a sheet was open. Run at launch.
    public static func removeLeftovers(root: URL = SessionShareFiles.shareRoot()) {
        try? FileManager.default.removeItem(at: root)
    }

    /// "Shared 2 files", or "Shared 2 files with AirDrop" when iOS names the activity.
    public static func sharedSummary(count: Int, activityType: String?) -> String {
        let base = "Shared \(count) file\(count == 1 ? "" : "s")"
        guard let name = activityName(activityType) else { return base }
        return "\(base) with \(name)"
    }

    /// A listener-readable name for the activity iOS reports, for the system targets worth naming. Another
    /// app's identifier is not shown: it would read as noise.
    public static func activityName(_ activityType: String?) -> String? {
        guard let activityType else { return nil }
        return [
            "com.apple.UIKit.activity.AirDrop": "AirDrop",
            "com.apple.DocumentManagerUICore.SaveToFiles": "Save to Files",
            "com.apple.CloudDocsUI.AddToiCloudDrive": "iCloud Drive",
            "com.apple.UIKit.activity.Mail": "Mail",
            "com.apple.UIKit.activity.Message": "Messages",
            "com.apple.UIKit.activity.CopyToPasteboard": "Copy",
            "com.apple.UIKit.activity.Print": "Print",
            "com.apple.mobilenotes.SharingExtension": "Notes",
        ][activityType]
    }
}
