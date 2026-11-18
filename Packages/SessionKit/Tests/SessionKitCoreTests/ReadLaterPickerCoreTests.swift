import XCTest
@testable import SessionKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func response(_ request: URLRequest, status: Int, body: String = "{}") -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

/// #944: Read Later said "Connected" because a token was stored, even after the service rejected it.
/// These drive the real `ReadLaterPickerCore` with injected responses and an in-memory token store.
/// They were app-hosted tests of `ReadLaterModel` before #318 moved its logic into SessionKit.
@MainActor
final class ReadLaterPickerCoreTests: XCTestCase {
    private final class Tokens: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ReadLaterService: String] = [:]
        var stored: [ReadLaterService: String] {
            get { lock.withLock { values } }
            set { lock.withLock { values = newValue } }
        }
        var credentials: ReadLaterCredentials {
            ReadLaterCredentials(
                load: { [self] service in lock.withLock { values[service] } },
                save: { [self] value, service in
                    lock.withLock { values[service] = value.isEmpty ? nil : value }
                    return 0
                }
            )
        }
    }

    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    /// Waits until the fetch finishes, by a deadline in seconds rather than a count of polls (#4131).
    private func settle(_ core: ReadLaterPickerCore, timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now + timeout
        while core.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(core.isLoading)
    }

    private func core(
        _ tokens: Tokens,
        transport: @escaping ReadLaterClient.Transport
    ) -> ReadLaterPickerCore {
        ReadLaterPickerCore(transport: transport, credentials: tokens.credentials)
    }

    func testARejectedTokenStaysRejectedAfterSwitchingServiceAwayAndBack() async {
        let tokens = Tokens()
        let model = core(tokens) { request in response(request, status: 401) }
        model.token = "bad-token"
        model.connect()
        await settle(model)
        XCTAssertEqual(model.status, ReadLaterClient.accessRejectedMessage)
        XCTAssertTrue(model.statusIsFailure)

        model.service = .raindrop
        model.selectService()
        model.service = .reader
        model.selectService()

        XCTAssertEqual(model.status, "Access rejected — reconnect with a valid token.")
        XCTAssertTrue(model.statusIsFailure)
        XCTAssertFalse(model.status.contains("Connected"))
        XCTAssertNil(model.statusSymbol)
    }

    func testAStoredTokenNeverCheckedIsSavedNotConnected() {
        let tokens = Tokens()
        tokens.stored[.reader] = "token-from-an-earlier-launch"
        let model = core(tokens) { request in response(request, status: 500) }
        // Straight after opening the screen, before anything touches the picker.
        XCTAssertEqual(model.status, "Token saved — connection not checked. Refresh to choose articles.")
        XCTAssertEqual(model.statusSymbol, .saved)
        model.selectService()
        XCTAssertEqual(model.status, "Token saved — connection not checked. Refresh to choose articles.")
        XCTAssertEqual(model.statusSymbol, .saved)
        XCTAssertFalse(model.statusIsFailure)
    }

    func testAnOfflineRefreshDoesNotTurnSavedIntoConnected() async {
        let tokens = Tokens()
        tokens.stored[.reader] = "token"
        let model = core(tokens) { _ in throw URLError(.notConnectedToInternet) }
        model.refresh()
        await settle(model)
        XCTAssertTrue(model.statusIsFailure)
        model.service = .raindrop; model.selectService()
        model.service = .reader; model.selectService()
        XCTAssertEqual(model.statusSymbol, .saved)
        XCTAssertFalse(model.status.contains("Connected"))
    }

    func testASuccessfulFetchIsWhatMakesItConnected() async {
        let tokens = Tokens()
        let body = #"{"results":[],"nextPageCursor":null}"#
        let model = core(tokens) { request in response(request, status: 200, body: body) }
        model.token = "good-token"
        model.connect()
        await settle(model)
        model.service = .raindrop; model.selectService()
        model.service = .reader; model.selectService()
        XCTAssertEqual(model.status, "Connected. Refresh to choose articles.")
        XCTAssertEqual(model.statusSymbol, .connected)
    }

    func testPastingANewTokenClearsAnEarlierRejection() async {
        let tokens = Tokens()
        let attempts = Attempts()
        let model = core(tokens) { request in
            response(request, status: attempts.next() == 1 ? 401 : 200, body: #"{"results":[],"nextPageCursor":null}"#)
        }
        model.token = "bad"; model.connect(); await settle(model)
        model.token = "good"; model.connect(); await settle(model)
        model.service = .raindrop; model.selectService()
        model.service = .reader; model.selectService()
        XCTAssertEqual(model.statusSymbol, .connected)
    }

    func testDisconnectForgetsTheRejection() async {
        let tokens = Tokens()
        let model = core(tokens) { request in response(request, status: 403) }
        model.token = "bad"; model.connect(); await settle(model)
        model.disconnect()
        XCTAssertFalse(model.connected)
        tokens.stored[.reader] = "next"
        model.selectService()
        XCTAssertEqual(model.statusSymbol, .saved)
    }

    func testDisconnectingRemovesTheTokenAndSaysSo() {
        let tokens = Tokens()
        tokens.stored[.reader] = "token"
        let model = core(tokens) { request in response(request, status: 500) }
        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.disconnect())
        XCTAssertFalse(model.connected)
        XCTAssertNil(tokens.stored[.reader])
        XCTAssertEqual(model.status, "Disconnected. What you imported and your Margins remain in your Library.")
        XCTAssertFalse(model.statusIsFailure)
    }

    /// A store that refuses the write must not claim the token is gone or saved.
    func testAStoreThatRefusesTheWriteReportsFailureAndKeepsTheToken() {
        let refusing = ReadLaterCredentials(load: { _ in "kept" }, save: { _, _ in -25308 })
        let model = ReadLaterPickerCore(transport: { request in response(request, status: 500) }, credentials: refusing)
        XCTAssertFalse(model.disconnect())
        XCTAssertEqual(model.status, "The token could not be removed. Try again while the device is unlocked.")
        XCTAssertTrue(model.statusIsFailure)
        XCTAssertTrue(model.connected)

        model.token = "new"
        model.connect()
        XCTAssertEqual(model.status, "The token could not be saved securely.")
        XCTAssertTrue(model.statusIsFailure)
        XCTAssertFalse(model.isLoading)
    }

    func testBlankTokensAreRefusedWithoutTouchingTheStore() {
        let tokens = Tokens()
        let model = core(tokens) { request in response(request, status: 500) }
        model.token = "  \n "
        model.connect()
        XCTAssertEqual(model.status, "Enter an access token.")
        XCTAssertNil(tokens.stored[.reader])
        XCTAssertFalse(model.isLoading)
    }

    /// The app's `ObservableObject` shell redraws on this callback; it must come before each change, as `@Published` does.
    func testOnWillChangeFiresBeforeEachChangeIncludingTheFetchResult() async {
        let tokens = Tokens()
        let body = #"{"results":[],"nextPageCursor":null}"#
        let model = core(tokens) { request in response(request, status: 200, body: body) }
        var fired = 0
        model.onWillChange = { fired += 1 }
        model.token = "typed"
        XCTAssertEqual(fired, 1)
        model.connect()
        await settle(model)
        XCTAssertGreaterThan(fired, 3)
        let afterFetch = fired
        model.service = .raindrop
        XCTAssertEqual(fired, afterFetch + 1)
    }

    func testLeavingTheServiceMidFetchDropsTheLateAnswer() async {
        let tokens = Tokens()
        tokens.stored[.reader] = "token"
        let body = #"{"results":[],"nextPageCursor":null}"#
        let model = core(tokens) { request in
            try await Task.sleep(for: .milliseconds(30))
            return response(request, status: 200, body: body)
        }
        model.refresh()
        XCTAssertTrue(model.isLoading)
        model.service = .raindrop
        model.selectService()
        XCTAssertFalse(model.isLoading)
        model.service = .reader
        model.selectService()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.loaded)
    }
}
