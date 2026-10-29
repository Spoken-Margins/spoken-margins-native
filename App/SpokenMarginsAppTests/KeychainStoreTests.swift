import XCTest
import Security
@testable import SpokenMarginsApp

final class KeychainStoreTests: XCTestCase {
    func testKeychainStoreAddsUpdatesAndDeletesProtectedSecret() {
        let service = "SpokenMarginsTests.\(UUID().uuidString)"
        let account = "api-key"
        defer { KeychainStore.save("", service: service, account: account) }

        XCTAssertEqual(KeychainStore.save("first", service: service, account: account), errSecSuccess)
        XCTAssertEqual(KeychainStore.load(service: service, account: account), "first")
        XCTAssertEqual(KeychainStore.save("second", service: service, account: account), errSecSuccess)
        XCTAssertEqual(KeychainStore.load(service: service, account: account), "second")
        XCTAssertEqual(KeychainStore.save("", service: service, account: account), errSecSuccess)
        XCTAssertNil(KeychainStore.load(service: service, account: account))
    }
}
