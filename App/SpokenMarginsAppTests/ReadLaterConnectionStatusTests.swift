import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

private func response(_ request: URLRequest, status: Int, body: String = "{}") -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

/// #944: Read Later said "Connected" because a token was stored, even after the service rejected it.
/// These drive the real `ReadLaterModel` with injected responses and an in-memory token store.
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

    private func settle(_ model: ReadLaterModel) async {
        for _ in 0..<200 where model.isLoading { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isLoading)
    }

    func testARejectedTokenStaysRejectedAfterSwitchingServiceAwayAndBack() async {
        let tokens = Tokens()
        let model = ReadLaterModel(transport: { request in response(request, status: 401) }, credentials: tokens.credentials)
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
        let model = ReadLaterModel(transport: { request in response(request, status: 500) }, credentials: tokens.credentials)
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
        let model = ReadLaterModel(transport: { _ in throw URLError(.notConnectedToInternet) }, credentials: tokens.credentials)
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
        let model = ReadLaterModel(transport: { request in response(request, status: 200, body: body) }, credentials: tokens.credentials)
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
        let model = ReadLaterModel(transport: { request in
            response(request, status: attempts.next() == 1 ? 401 : 200, body: #"{"results":[],"nextPageCursor":null}"#)
        }, credentials: tokens.credentials)
        model.token = "bad"; model.connect(); await settle(model)
        model.token = "good"; model.connect(); await settle(model)
        model.service = .raindrop; model.selectService()
        model.service = .reader; model.selectService()
        XCTAssertEqual(model.statusSymbol, .connected)
    }

    func testDisconnectForgetsTheRejection() async {
        let tokens = Tokens()
        let model = ReadLaterModel(transport: { request in response(request, status: 403) }, credentials: tokens.credentials)
        model.token = "bad"; model.connect(); await settle(model)
        model.disconnect()
        XCTAssertFalse(model.connected)
        tokens.stored[.reader] = "next"
        model.selectService()
        XCTAssertEqual(model.statusSymbol, .saved)
    }

    private final class Attempts: @unchecked Sendable {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }
}
