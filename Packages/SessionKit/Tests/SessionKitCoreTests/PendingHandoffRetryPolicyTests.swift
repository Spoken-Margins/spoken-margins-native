import Foundation
import XCTest
@testable import SessionKit

/// #1546: a link sent from Safari while offline was quarantined for good, with no message and no retry.
final class PendingHandoffRetryPolicyTests: XCTestCase {
    private struct BadPDF: LocalizedError {
        var errorDescription: String? { "The shared link did not return a readable PDF." }
    }

    private enum StoreError: Error { case invalid, missing }

    func testConnectionFailuresAreTransientAndOthersAreNot() {
        let transient: [URLError.Code] = [
            .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff
        ]
        for code in transient {
            XCTAssertTrue(PendingHandoffRetryPolicy.isTransientNetworkFailure(URLError(code)), "\(code.rawValue)")
        }
        let permanent: [URLError.Code] = [
            .badServerResponse, .badURL, .unsupportedURL, .fileDoesNotExist, .cancelled,
            .secureConnectionFailed, .dataLengthExceedsMaximum, .userAuthenticationRequired, .unknown
        ]
        for code in permanent {
            XCTAssertFalse(PendingHandoffRetryPolicy.isTransientNetworkFailure(URLError(code)), "\(code.rawValue)")
        }
        XCTAssertFalse(PendingHandoffRetryPolicy.isTransientNetworkFailure(BadPDF()))
        XCTAssertFalse(PendingHandoffRetryPolicy.isTransientNetworkFailure(SessionKitError.persistenceFailed("x")))
        XCTAssertFalse(PendingHandoffRetryPolicy.isTransientNetworkFailure(CancellationError()))
    }

    func testWrappedConnectionFailuresAreTransient() {
        let offline = URLError(.notConnectedToInternet)
        // A bare NSError in the URL domain, as Objective-C APIs hand it over.
        XCTAssertTrue(PendingHandoffRetryPolicy.isTransientNetworkFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        ))
        // Wrapped one and two levels deep under NSUnderlyingErrorKey.
        let once = NSError(domain: "SomeLoader", code: 1, userInfo: [NSUnderlyingErrorKey: offline as NSError])
        let twice = NSError(domain: "Outer", code: 2, userInfo: [NSUnderlyingErrorKey: once])
        XCTAssertTrue(PendingHandoffRetryPolicy.isTransientNetworkFailure(once))
        XCTAssertTrue(PendingHandoffRetryPolicy.isTransientNetworkFailure(twice))
        // Among several underlying errors.
        let several = NSError(domain: "Outer", code: 3, userInfo: [
            NSMultipleUnderlyingErrorsKey: [NSError(domain: "x", code: 1), URLError(.networkConnectionLost) as NSError]
        ])
        XCTAssertTrue(PendingHandoffRetryPolicy.isTransientNetworkFailure(several))
        // The article extractor's wrapper, which a shared article link throws.
        XCTAssertTrue(PendingHandoffRetryPolicy.isTransientNetworkFailure(
            LinkArticleFallbackError(extractorFailure: offline.localizedDescription, extractorError: offline)
        ))
        XCTAssertFalse(PendingHandoffRetryPolicy.isTransientNetworkFailure(
            LinkArticleFallbackError(extractorFailure: "no article", extractorError: BadPDF())
        ))
        XCTAssertFalse(PendingHandoffRetryPolicy.isTransientNetworkFailure(
            NSError(domain: "Outer", code: 4, userInfo: [NSUnderlyingErrorKey: URLError(.badServerResponse) as NSError])
        ))
    }

    func testOutcomeKeepsStoreErrorsAndDiagnosticValues() {
        let storeOutcome: (any Error) -> PendingHandoffOutcome? = {
            switch $0 as? StoreError {
            case .invalid: return .deletedInvalidPayload
            case .missing: return .missing
            case nil: return nil
            }
        }
        XCTAssertEqual(PendingHandoffRetryPolicy.outcome(for: StoreError.invalid, storeOutcome: storeOutcome), .deletedInvalidPayload)
        XCTAssertEqual(PendingHandoffRetryPolicy.outcome(for: StoreError.missing, storeOutcome: storeOutcome), .missing)
        XCTAssertEqual(PendingHandoffRetryPolicy.outcome(for: URLError(.notConnectedToInternet)).diagnosticValue, "waiting_for_network")
        XCTAssertEqual(
            PendingHandoffRetryPolicy.outcome(for: BadPDF()).diagnosticValue,
            "quarantined:The shared link did not return a readable PDF."
        )
        XCTAssertNil(PendingHandoffRetryPolicy.waitingLine(count: 0))
        XCTAssertEqual(PendingHandoffRetryPolicy.waitingLine(count: 1), "1 link waiting for a connection")
        XCTAssertEqual(PendingHandoffRetryPolicy.waitingLine(count: 3), "3 links waiting for a connection")
    }

    /// The owner's case: offline, the link stays pending (today it was quarantined); back online, the
    /// next pass imports it and nothing lands in the failed inbox.
    @MainActor
    func testOfflineLinkWaitsThenImportsWhenOnline() async {
        let store = FakeHandoffStore(pending: ["source-link-A35C07CC"])
        var online = false
        var imported: [String] = []
        let importPayload: (String) async throws -> Void = { id in
            guard online else { throw URLError(.notConnectedToInternet) }
            imported.append(id)
        }

        let offlinePass = await store.drain(importPayload)
        XCTAssertEqual(offlinePass.outcomes.map(\.outcome), [.waitingForNetwork])
        XCTAssertEqual(offlinePass.waitingCount, 1)
        XCTAssertEqual(store.pending, ["source-link-A35C07CC"], "an offline link must stay pending for the next pass")
        XCTAssertTrue(store.quarantined.isEmpty, "an offline link must not be quarantined")

        online = true
        let onlinePass = await store.drain(importPayload)
        XCTAssertEqual(onlinePass.outcomes.map(\.outcome), [.imported])
        XCTAssertEqual(onlinePass.waitingCount, 0)
        XCTAssertEqual(imported, ["source-link-A35C07CC"])
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(store.quarantined.isEmpty)
    }

    @MainActor
    func testNonNetworkFailureQuarantinesWithItsReason() async {
        let store = FakeHandoffStore(pending: ["bad", "fine"])
        let report = await store.drain { id in
            if id == "bad" { throw BadPDF() }
        }
        XCTAssertEqual(report.outcomes.map(\.outcome), [
            .quarantined(reason: "The shared link did not return a readable PDF."), .imported
        ])
        XCTAssertEqual(report.quarantinedCount, 1)
        XCTAssertEqual(store.quarantined, ["bad": "The shared link did not return a readable PDF."])
        XCTAssertTrue(store.pending.isEmpty)
    }

    /// The integration run's failure: a Spotify share (the resolver says "unsupported") reached the listener as an
    /// error banner reading "persistence_failed:...". It goes to the inbox with the readable message and no banner.
    @MainActor
    func testUnplayableLinkIsQuarantinedWithItsMessageAndNoAnnouncement() async {
        let message = "Spoken Margins could not find a public audio file for this Spotify episode."
        let store = FakeHandoffStore(pending: ["spotify", "bad"])
        let report = await store.drain { id in
            if id == "spotify" { throw SourceLinkNotPlayableError(message) }
            throw BadPDF()
        }
        XCTAssertEqual(report.outcomes.map(\.outcome), [
            .notPlayable(reason: message), .quarantined(reason: "The shared link did not return a readable PDF.")
        ])
        XCTAssertEqual(report.quarantinedCount, 2)
        XCTAssertEqual(report.announcedFailures, ["The shared link did not return a readable PDF."])
        XCTAssertEqual(store.quarantined["spotify"], message)
        XCTAssertEqual(report.outcomes.first?.outcome.diagnosticValue, "quarantined:\(message)")
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testQuarantineReasonDropsTheInternalErrorCode() {
        let error = SessionKitError.persistenceFailed("This share does not contain a valid podcast, RSS, or audio URL.")
        XCTAssertEqual(error.localizedDescription, "persistence_failed:This share does not contain a valid podcast, RSS, or audio URL.")
        XCTAssertEqual(
            PendingHandoffRetryPolicy.outcome(for: error),
            .quarantined(reason: "This share does not contain a valid podcast, RSS, or audio URL.")
        )
        XCTAssertEqual(PendingHandoffRetryPolicy.readableReason(for: BadPDF()), "The shared link did not return a readable PDF.")
        XCTAssertEqual(PendingHandoffRetryPolicy.readableReason(for: URLError(.badURL)), URLError(.badURL).localizedDescription)
    }

    @MainActor
    func testStoreErrorsKeepTheirHandling() async {
        let store = FakeHandoffStore(pending: ["invalid", "missing"])
        let report = await store.drain(storeOutcome: {
            switch $0 as? StoreError {
            case .invalid: return .deletedInvalidPayload
            case .missing: return .missing
            case nil: return nil
            }
        }) { id in
            throw id == "invalid" ? StoreError.invalid : StoreError.missing
        }
        XCTAssertEqual(report.outcomes.map(\.outcome), [.deletedInvalidPayload, .missing])
        XCTAssertEqual(store.pending, ["missing"])
        XCTAssertTrue(store.quarantined.isEmpty)
    }
}

@MainActor
private final class FakeHandoffStore {
    var pending: [String]
    var quarantined: [String: String] = [:]

    init(pending: [String]) { self.pending = pending }

    func drain(
        storeOutcome: @escaping (any Error) -> PendingHandoffOutcome? = { _ in nil },
        _ importPayload: (String) async throws -> Void
    ) async -> PendingHandoffDrain.Report {
        await PendingHandoffDrain.run(
            payloadIDs: pending,
            importPayload: importPayload,
            deletePayload: { id in self.pending.removeAll { $0 == id } },
            quarantine: { id, reason in
                self.quarantined[id] = reason
                self.pending.removeAll { $0 == id }
            },
            storeOutcome: storeOutcome
        )
    }
}
