import XCTest
@testable import SessionKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// #944: Read Later said "Connected" because a token was stored, even after the service rejected it.
final class ReadLaterConnectionStatusTests: XCTestCase {
    private typealias Tracker = ReadLaterConnectionTracker

    func testStoredTokenAloneIsSavedNotConnected() throws {
        let tracker = Tracker()
        let line = try XCTUnwrap(tracker.presentation(for: .reader, hasToken: true))
        XCTAssertEqual(line.text, "Token saved — connection not checked. Refresh to choose articles.")
        XCTAssertEqual(line.symbol, .saved)
        XCTAssertFalse(line.isFailure)
        XCTAssertFalse(line.text.contains("Connected"))
    }

    func testNoTokenHasNoConnectionLine() {
        var tracker = Tracker()
        let generation = tracker.credentialChanged(for: .reader)
        tracker.record(.succeeded, for: .reader, generation: generation)
        XCTAssertNil(tracker.presentation(for: .reader, hasToken: false))
    }

    func testConnectedNeedsASuccessfulAuthenticatedAnswer() throws {
        var tracker = Tracker()
        let generation = tracker.credentialChanged(for: .reader)
        tracker.record(.succeeded, for: .reader, generation: generation)
        let line = try XCTUnwrap(tracker.presentation(for: .reader, hasToken: true))
        XCTAssertEqual(line.text, "Connected. Refresh to choose articles.")
        XCTAssertEqual(line.symbol, .connected)
        XCTAssertFalse(line.isFailure)
    }

    func testRejectionSurvivesSwitchingServiceAwayAndBack() throws {
        // The issue's table row: save a token, get 401/403, switch the picker away and back.
        var tracker = Tracker()
        let generation = tracker.credentialChanged(for: .reader)
        tracker.record(Tracker.outcome(forFailureMessage: ReadLaterClient.accessRejectedMessage), for: .reader, generation: generation)
        // Looking at the other service changes nothing about this one.
        _ = tracker.presentation(for: .raindrop, hasToken: false)
        let line = try XCTUnwrap(tracker.presentation(for: .reader, hasToken: true))
        XCTAssertEqual(line.symbol, .rejected)
        XCTAssertTrue(line.isFailure)
        XCTAssertEqual(line.text, "Access rejected — reconnect with a valid token.")
        XCTAssertFalse(line.text.contains("Connected"))
    }

    func testServicesAreTrackedSeparately() {
        var tracker = Tracker()
        let reader = tracker.credentialChanged(for: .reader)
        let raindrop = tracker.credentialChanged(for: .raindrop)
        tracker.record(.rejected, for: .reader, generation: reader)
        tracker.record(.succeeded, for: .raindrop, generation: raindrop)
        XCTAssertEqual(tracker.check(for: .reader), .rejected)
        XCTAssertEqual(tracker.check(for: .raindrop), .verified)
    }

    func testAFailureThatSaysNothingAboutTheTokenKeepsWhatWasKnown() {
        var tracker = Tracker()
        let generation = tracker.credentialChanged(for: .reader)
        // Offline right after saving: still only saved.
        tracker.record(.inconclusive, for: .reader, generation: generation)
        XCTAssertEqual(tracker.check(for: .reader), .notChecked)
        tracker.record(.succeeded, for: .reader, generation: generation)
        tracker.record(.inconclusive, for: .reader, generation: generation)
        XCTAssertEqual(tracker.check(for: .reader), .verified)
        tracker.record(.rejected, for: .reader, generation: generation)
        tracker.record(.inconclusive, for: .reader, generation: generation)
        XCTAssertEqual(tracker.check(for: .reader), .rejected)
    }

    func testOnlyAccessRejectedWordingCountsAsRejection() {
        for message in [nil, "", "Could not load articles. Check the connection and try again.",
                        "The service rate limit was reached. Wait before refreshing again.",
                        "The service returned HTTP 500. Try again later.",
                        ReadLaterClient.readerUnavailableMessage,
                        "Enter a valid access token.", "Invalid service response."] as [String?] {
            XCTAssertEqual(Tracker.outcome(forFailureMessage: message), .inconclusive, "\(message ?? "nil")")
        }
        XCTAssertEqual(Tracker.outcome(forFailureMessage: ReadLaterClient.accessRejectedMessage), .rejected)
    }

    func testTheClientsRealRejectionIsWhatTheTrackerRecognises() async throws {
        for code in [401, 403] {
            let client = ReadLaterClient { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            do {
                _ = try await client.page(service: .reader, token: "secret")
                XCTFail("HTTP \(code) must throw")
            } catch {
                XCTAssertEqual(Tracker.outcome(forFailureMessage: error.localizedDescription), .rejected, "HTTP \(code)")
            }
        }
        let rateLimited = ReadLaterClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await rateLimited.page(service: .raindrop, token: "secret")
            XCTFail("HTTP 429 must throw")
        } catch {
            XCTAssertEqual(Tracker.outcome(forFailureMessage: error.localizedDescription), .inconclusive)
        }
    }

    func testAnAnswerForAReplacedTokenCannotConfirmOrRejectTheCurrentOne() {
        var tracker = Tracker()
        let oldGeneration = tracker.credentialChanged(for: .reader)
        let newGeneration = tracker.credentialChanged(for: .reader)
        XCTAssertFalse(tracker.record(.succeeded, for: .reader, generation: oldGeneration))
        XCTAssertEqual(tracker.check(for: .reader), .notChecked)
        XCTAssertTrue(tracker.record(.rejected, for: .reader, generation: newGeneration))
        XCTAssertFalse(tracker.record(.succeeded, for: .reader, generation: oldGeneration))
        XCTAssertEqual(tracker.check(for: .reader), .rejected)
    }

    func testReplacingOrRemovingTheTokenForgetsThePriorAnswer() {
        var tracker = Tracker()
        var generation = tracker.credentialChanged(for: .reader)
        tracker.record(.rejected, for: .reader, generation: generation)
        generation = tracker.credentialChanged(for: .reader)   // pasted a new token
        XCTAssertEqual(tracker.check(for: .reader), .notChecked)
        tracker.record(.succeeded, for: .reader, generation: generation)
        XCTAssertEqual(tracker.check(for: .reader), .verified)
        tracker.credentialChanged(for: .reader)                // disconnected
        XCTAssertEqual(tracker.check(for: .reader), .notChecked)
    }
}
