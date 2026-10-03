import XCTest
import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class BridgeServiceTests: XCTestCase {
    func testUnavailableStoreFailsClosed() async {
        let service = BridgeService(store: nil)
        let snapshot = await service.current()
        XCTAssertEqual(snapshot.state, .off(.noConfig))
        XCTAssertNil(snapshot.manifest)
        let outcome = await service.refresh()
        XCTAssertEqual(outcome, .off(.noConfig))
    }

    func testUnreachableServerDoesNotEscapeIntoTheApp() async {
        let cache = FileManager.default.temporaryDirectory.appending(path: "bridge-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = BridgeManifestStore(cacheDirectory: cache, appBuild: 30) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let service = BridgeService(store: store)
        let outcome = await service.refresh()
        XCTAssertEqual(outcome, .off(.noConfig))
        let snapshot = await service.current()
        XCTAssertFalse(snapshot.isUpdating)
        XCTAssertNil(snapshot.manifest)
    }
}
