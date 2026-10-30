// Compiled against a shipped build's SessionKit and SessionKitPersistence (Build 29, 32 or 34, from its
// testflight/0.1-build-N tag) by scripts/check-build29-database.sh. Opens a database written by the current
// code and reads it the way that build does. Arguments: the database path, then the build's name ("Build 29").
// HAS_LINKED_EPISODE is defined for builds whose Item carries `linkedEpisode` (Build 34 on, #755).

import CryptoKit
import Foundation
import SessionKit
import SessionKitPersistence

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
    exit(1)
}

let path = CommandLine.arguments[1]
let build = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Build 29"
guard let data = FileManager.default.contents(atPath: path + ".expected.json"),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let expected = root["items"] as? [[String: Any]] else { fail("no expected.json beside the database") }

// Opening runs that build's migrate(), which rejects a schema version it doesn't know.
let store: SQLiteSessionStore
do { store = try SQLiteSessionStore(path: path) } catch { fail("\(build) can't open the database: \(error)") }

// The Library, as that build's LibraryReadSnapshot.read loads it.
let items: [Item]
let sessions: [Session]
do {
    items = try store.listItems(includeDeleted: true)
    sessions = try store.loadSessions()
    _ = try store.loadPreparedAudioManifests()
    _ = try store.loadAudioPreparationJobs()
    _ = try store.loadPodcastDownloads()
} catch { fail("\(build) can't read the Library: \(error)") }

for entry in expected {
    guard let itemId = entry["itemId"] as? String, let sha = entry["textSHA256"] as? String,
          let sessionId = entry["sessionId"] as? String, let marginId = entry["marginId"] as? String else { fail("bad expected.json") }
    guard items.contains(where: { $0.id == itemId && $0.deletedAt == nil }) else { fail("\(itemId) missing from the Library") }
    let item: Item
    do { item = try store.loadItem(id: itemId) } catch { fail("\(itemId) doesn't load: \(error)") }
    let text = item.text ?? ""
    guard SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined() == sha else {
        fail("\(itemId): Item.text differs from what the current code wrote")
    }
    if entry["hasListeningMap"] as? Bool == true, (try? store.loadListeningMap(itemId: itemId)) == nil {
        fail("\(itemId): listening map missing")
    }
    guard sessions.contains(where: { $0.id == sessionId }) else { fail("\(itemId): session \(sessionId) missing") }
    // An article that plays its publisher's recording is stored as a plain article being read (#547).
    if let target = entry["sessionTargetType"] as? String,
       sessions.first(where: { $0.id == sessionId })?.currentTargetType.rawValue != target {
        fail("\(itemId): session \(sessionId) is not stored as \(target)")
    }
    if entry["itemHasNoMedia"] as? Bool == true, item.media != nil { fail("\(itemId): the article has media of its own") }
    let margins: [Interjection]
    do { margins = try store.loadInterjections(sessionId: sessionId) } catch { fail("\(itemId): Margins don't load: \(error)") }
    guard let margin = margins.first(where: { $0.id == marginId }) else { fail("\(itemId): Margin \(marginId) missing") }
    guard margin.anchor.endChar <= text.count else { fail("\(itemId): Margin anchor runs past Item.text") }
    if let words = entry["marginWords"] as? String {
        let opened = String(Array(text)[margin.anchor.startChar..<margin.anchor.endChar])
        guard opened == words else { fail("\(itemId): Margin opens at \"\(opened)\", not \"\(words)\"") }
    }
    print("ok   \(itemId): \(text.count) characters, Margin \(marginId) at \(margin.anchor.startChar)..<\(margin.anchor.endChar)")
}
// Imported Margins, including replies that carry links (#472).
for entry in root["importedMargins"] as? [[String: Any]] ?? [] {
    guard let layerId = entry["layerId"] as? String, let marginId = entry["marginId"] as? String else { fail("bad expected.json") }
    let layers: [ImportedCommentaryLayer]
    let margins: [ImportedCommentaryInterjection]
    do {
        layers = try store.loadImportedCommentaryLayers()
        margins = try store.loadImportedCommentaryInterjections(layerId: layerId)
    } catch { fail("imported Margins don't load: \(error)") }
    guard layers.contains(where: { $0.id == layerId }) else { fail("imported layer \(layerId) missing") }
    guard margins.contains(where: { $0.id == marginId }) else { fail("imported Margin \(marginId) missing") }
    print("ok   imported Margin \(marginId) in layer \(layerId)")
}
// Feed entries with fields Build 29 doesn't know (#545).
if let feedEntryIds = root["feedEntryIds"] as? [String] {
    let entries: [FeedEntry]
    do { entries = try store.loadFeedEntries(subscriptionId: nil) } catch { fail("feed entries don't load: \(error)") }
    for id in feedEntryIds where !entries.contains(where: { $0.id == id }) { fail("feed entry \(id) missing") }
    print("ok   \(feedEntryIds.count) feed entries with newer fields")
}
// Podcasts with a saved download, a Margin placed by media time and a linked episode (#1900).
for entry in root["podcasts"] as? [[String: Any]] ?? [] {
    guard let itemId = entry["itemId"] as? String, let mediaURL = entry["mediaURL"] as? String,
          let durationMs = entry["durationMs"] as? Int else { fail("bad expected.json") }
    let item: Item
    do { item = try store.loadItem(id: itemId) } catch { fail("\(itemId) doesn't load: \(error)") }
    guard item.media?.url == mediaURL, item.media?.durationMs == durationMs else {
        fail("\(itemId): media is \(String(describing: item.media?.url)), \(String(describing: item.media?.durationMs)) ms")
    }
    if let downloadId = entry["downloadId"] as? String {
        let downloads: [PodcastDownloadRecord]
        do { downloads = try store.loadPodcastDownloads() } catch { fail("downloads don't load: \(error)") }
        guard let download = downloads.first(where: { $0.id == downloadId }), download.itemId == itemId,
              download.localRelativePath == entry["downloadPath"] as? String, download.state == .availableOffline else {
            fail("\(itemId): download \(downloadId) missing or changed")
        }
    }
    if let sessionId = entry["sessionId"] as? String, let marginId = entry["marginId"] as? String {
        let margins: [Interjection]
        do { margins = try store.loadInterjections(sessionId: sessionId) } catch { fail("\(itemId): Margins don't load: \(error)") }
        guard let margin = margins.first(where: { $0.id == marginId }) else { fail("\(itemId): Margin \(marginId) missing") }
        guard margin.anchor.mediaTimeMs == entry["marginMediaTimeMs"] as? Int else { fail("\(itemId): Margin lost its media time") }
    }
#if HAS_LINKED_EPISODE
    if let guid = entry["linkedEpisodeGUID"] as? String {
        guard item.linkedEpisode?.guid == guid else { fail("\(itemId): the linked episode is gone") }
    }
#endif
    print("ok   podcast \(itemId)")
}
let quarantined = (try? store.quarantinedRecordCount()) ?? -1
guard quarantined == 0 else { fail("\(quarantined) records quarantined as undecodable") }
print("ok   \(build) opened the database: \(items.count) items, \(sessions.count) sessions, nothing quarantined")
