// Compiled against Build 29's SessionKit and SessionKitPersistence (from the
// testflight/0.1-build-29 tag) by scripts/check-build29-database.sh. Opens a
// database written by the current code and reads it the way Build 29 does.

import CryptoKit
import Foundation
import SessionKit
import SessionKitPersistence

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
    exit(1)
}

let path = CommandLine.arguments[1]
guard let data = FileManager.default.contents(atPath: path + ".expected.json"),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let expected = root["items"] as? [[String: Any]] else { fail("no expected.json beside the database") }

// Opening runs Build 29's migrate(), which rejects a schema version it doesn't know.
let store: SQLiteSessionStore
do { store = try SQLiteSessionStore(path: path) } catch { fail("Build 29 can't open the database: \(error)") }

// The Library, as Build 29's LibraryReadSnapshot.read loads it.
let items: [Item]
let sessions: [Session]
do {
    items = try store.listItems(includeDeleted: true)
    sessions = try store.loadSessions()
    _ = try store.loadPreparedAudioManifests()
    _ = try store.loadAudioPreparationJobs()
    _ = try store.loadPodcastDownloads()
} catch { fail("Build 29 can't read the Library: \(error)") }

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
let quarantined = (try? store.quarantinedRecordCount()) ?? -1
guard quarantined == 0 else { fail("\(quarantined) records quarantined as undecodable") }
print("ok   Build 29 opened the database: \(items.count) items, \(sessions.count) sessions, nothing quarantined")
