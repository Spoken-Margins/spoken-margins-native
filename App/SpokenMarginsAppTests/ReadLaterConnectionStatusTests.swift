import Combine
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #944: Read Later said "Connected" because a token was stored, even after the service rejected it.
/// The state machine and its tests moved to SessionKit (`ReadLaterPickerCoreTests`, #318). What stays here is what only
/// the app has: the `ObservableObject` shell around it, and the Readwise sync it ends.
@MainActor
final class ReadLaterConnectionStatusAppTests: XCTestCase {
    private final class Tokens: @unchecked Sendable {
        var stored: [ReadLaterService: String] = [:]
        var credentials: ReadLaterCredentials {
            ReadLaterCredentials(
                load: { [self] in stored[$0] },
                save: { [self] value, service in
                    if value.isEmpty { stored[service] = nil } else { stored[service] = value }
                    return 0
                }
            )
        }
    }

    /// The screen binds to `$connection.token` and `$connection.service`, so the shell must write through to the core
    /// and tell SwiftUI before each change.
    func testTheShellForwardsEditsToTheCoreAndPublishesBeforeEachOne() {
        let tokens = Tokens()
        tokens.stored[.reader] = "token"
        let model = ReadLaterModel(credentials: tokens.credentials)
        var published = 0
        let subscription = model.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        model.token = "typed"
        XCTAssertEqual(model.token, "typed")
        XCTAssertEqual(published, 1)

        model.service = .raindrop
        XCTAssertEqual(model.service, .raindrop)
        XCTAssertEqual(published, 2)
        XCTAssertFalse(model.connected)

        model.selectService()
        XCTAssertEqual(model.token, "")
        XCTAssertGreaterThan(published, 2)
    }

    /// #1467: Disconnect ends the Readwise connection, so a later one is a new destination with sending off.
    func testDisconnectingReaderTurnsReadwiseSendingOff() {
        let tokens = Tokens()
        tokens.stored[.reader] = "token"
        let model = ReadLaterModel(credentials: tokens.credentials)
        let sync = ReadwiseHighlightSync()
        sync.enabled = true
        XCTAssertTrue(model.disconnect())
        sync.destinationDisconnected()
        XCTAssertFalse(sync.enabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "readwiseHighlightsEnabled"))
        XCTAssertTrue(sync.links.isEmpty)
        XCTAssertFalse(sync.statusIsFailure)
    }
}
