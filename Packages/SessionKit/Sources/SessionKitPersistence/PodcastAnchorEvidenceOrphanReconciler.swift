import Foundation
import SessionKit

/// Removes only aged, unreferenced signature files whose path and filename
/// match this app's capture writer for a Margin still present in the store.
/// Unknown files and directories are never adopted or deleted.
public enum PodcastAnchorEvidenceOrphanReconciler {
    public static let minimumOrphanAge: TimeInterval = 24 * 60 * 60

    public static func safeComponent(_ value: String) -> String {
        let safe = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression
        )
        return safe.isEmpty ? "unknown" : String(safe.prefix(96))
    }

    @discardableResult
    public static func reclaim(
        in root: URL,
        store: SQLiteSessionStore,
        now: Date = Date(),
        minimumAge: TimeInterval = minimumOrphanAge
    ) throws -> Int {
        let manager = FileManager.default
        let supportRoot = root.deletingLastPathComponent().deletingLastPathComponent()
        guard isPlainDirectory(root), isPlainDirectory(root.deletingLastPathComponent()),
              isPlainDirectory(supportRoot) else { return 0 }
        var protectedPaths = Set<String>()
        for asset in try store.loadOwnedOfflineAssets() {
            protectedPaths.insert(supportRoot.appending(path: asset.relativePath).standardizedFileURL.path)
        }
        var knownMargins: [String: Set<String>] = [:]
        for session in try store.loadSessions() {
            let safeSession = safeComponent(session.id)
            for margin in try store.loadInterjections(sessionId: session.id) {
                knownMargins[safeSession, default: []].insert(safeComponent(margin.id))
                for evidence in margin.podcastAnchorEvidence ?? [] {
                    protectedPaths.insert(URL(fileURLWithPath: evidence.localPath).standardizedFileURL.path)
                }
            }
        }
        let generatedSuffixes = [
            "stream-pre", "stream-post", "local-pre", "local-post",
            "source-window-pre", "source-window-post"
        ]
        var removed = 0
        for sessionDirectory in (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? [] where isPlainDirectory(sessionDirectory) {
            let sessionName = sessionDirectory.lastPathComponent
            guard let marginNames = knownMargins[sessionName] else { continue }
            for marginDirectory in (try? manager.contentsOfDirectory(
                at: sessionDirectory, includingPropertiesForKeys: nil
            )) ?? [] where isPlainDirectory(marginDirectory) {
                let marginName = marginDirectory.lastPathComponent
                guard marginNames.contains(marginName) else { continue }
                let generatedNames = Set(generatedSuffixes.map {
                    "anchor-\(sessionName)-\(marginName)-\($0).shazamsignature"
                })
                for file in (try? manager.contentsOfDirectory(
                    at: marginDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? [] {
                    guard generatedNames.contains(file.lastPathComponent),
                          isPlainRegularFile(file),
                          !protectedPaths.contains(file.standardizedFileURL.path),
                          let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          now.timeIntervalSince(modified) >= minimumAge else { continue }
                    // A fresh capture could still be completing. The age gate,
                    // exact writer name, and absence of both reference kinds
                    // are all required before removing anything.
                    if (try? manager.removeItem(at: file)) != nil { removed += 1 }
                }
            }
        }
        return removed
    }

    private static func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isPlainRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
