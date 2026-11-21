import Foundation
import XCTest
import SessionKitTestInputs

/// #3769 audit: a collection import fills its collection one file at a time, and `LibraryCollectionModel.update` makes
/// each write read the stored collection on one serial writer. Any app code that saves a collection it read earlier,
/// outside that writer, can write back a copy from before the import's last file and drop it; the next launch then marks
/// that member `removed` for good. The Add to Collection sheet did exactly this. So collection writes in the app go
/// through `LibraryCollectionModel`, and this guard fails when a new caller writes to the store directly.
final class CollectionWriteGuardTests: XCTestCase {
    /// Files allowed to call the store's collection writes, and how many calls each may make.
    /// `Gate1AppModel+CollectionImportLaunch.swift` settles interrupted imports at launch, before the Library is shown,
    /// so no import or sheet can be writing at the same time.
    private static let allowed: [String: Int] = [
        "LibraryCollectionModel.swift": .max,
        "Gate1AppModel+CollectionImportLaunch.swift": 1,
    ]

    func testCollectionsAreWrittenOnlyThroughTheCollectionModel() throws {
        let inputs: [TestInputs.Input] = [.appSources, .appSharedSources, .appGate2Shared, .appShareExtension]
        let regex = try NSRegularExpression(pattern: #"\.(?:saveItemCollection|deleteItemCollection)\("#)
        var counts: [String: Int] = [:]
        for input in inputs {
            let directory = try TestInputs.directory(input)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let count = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                if count > 0 { counts[file.lastPathComponent, default: 0] += count }
            }
        }
        XCTAssertGreaterThan(counts["LibraryCollectionModel.swift"] ?? 0, 0, "the scan must see the model's own writes")
        let over = counts.filter { $0.value > (Self.allowed[$0.key] ?? 0) }.map { "\($0.key): \($0.value)" }.sorted()
        XCTAssertEqual(over, [], "write collections through LibraryCollectionModel (update, create, delete), never the store")
    }
}
