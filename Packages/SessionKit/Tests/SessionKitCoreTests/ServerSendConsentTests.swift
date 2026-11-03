import Foundation
import XCTest
@testable import SessionKit

/// Consent before the phone first sends the listener's own words or audio to our server (#2842, Apple agreement
/// 3.3.3): nothing is sealed or posted until the listener has agreed, the agreement is per feature and per wording
/// version, and deleting the app (its defaults) takes it away.
final class ServerSendConsentTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "ServerSendConsentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testNobodyHasAgreedOnAFreshInstall() {
        for feature in ServerSendFeature.allCases {
            XCTAssertFalse(ServerSendConsent.hasConsented(to: feature, in: freshDefaults()))
        }
    }

    func testAgreeingIsRememberedAndWithdrawingTakesItBack() {
        let defaults = freshDefaults()
        ServerSendConsent.record(.shareLinks, in: defaults)
        XCTAssertTrue(ServerSendConsent.hasConsented(to: .shareLinks, in: defaults))
        ServerSendConsent.withdraw(.shareLinks, in: defaults)
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .shareLinks, in: defaults))
    }

    func testAnAgreementToEarlierWordsNoLongerCounts() {
        let defaults = freshDefaults()
        let current = ServerSendConsent.disclosureVersion
        defaults.set(current - 1, forKey: "serverSendConsent.share-links.version")
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .shareLinks, in: defaults), "a bumped wording asks again")
        defaults.set(current + 1, forKey: "serverSendConsent.share-links.version")
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .shareLinks, in: defaults), "a record from a newer build is not trusted either")
        defaults.set("1", forKey: "serverSendConsent.share-links.version")
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .shareLinks, in: defaults), "a value of the wrong type is not an agreement")
    }

    func testTheWordsNameWhatTheUploadCarriesAndWhereTheFileGoes() {
        let text = ShareLinkConsentCopy.message
        // Each thing the upload holds (docs/legal/privacy-policy-draft.md row 14) and the way out.
        for phrase in ["Margins", "audio and text", "excerpt of the source", "title and address", "sender name", "key that is only in the link", "30 days", "send the file instead"] {
            XCTAssertTrue(text.contains(phrase), "the consent text should say: \(phrase)")
        }
        XCTAssertFalse(ShareLinkConsentCopy.title.isEmpty)
        XCTAssertNotEqual(ShareLinkConsentCopy.accept, ShareLinkConsentCopy.decline)
    }
}

/// The upload itself refuses to start without the agreement, whoever calls it.
final class ShareLinkConsentGateTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var posts: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }

    func testWithoutConsentNothingIsSealedOrPosted() async throws {
        let counter = Counter()
        let client = ShareLinkClient(consent: { false }) { _, _, _ in
            counter.bump()
            return (201, Data())
        }
        let preview = try ShareLinkPreviewBuilder.make(
            title: "T", show: nil, pageURL: nil, enclosureURL: nil, marginTexts: ["Hello."]
        )
        let result = await client.makeLink(packet: Data([1, 2, 3]), preview: preview, linksState: .on)
        XCTAssertEqual(result, .needsConsent)
        XCTAssertEqual(counter.posts, 0)
    }

    func testConsentIsAskedBeforeTheServerSwitchIsLookedAt() async throws {
        let client = ShareLinkClient(consent: { false }) { _, _, _ in (201, Data()) }
        let preview = try ShareLinkPreviewBuilder.make(
            title: "T", show: nil, pageURL: nil, enclosureURL: nil, marginTexts: ["Hello."]
        )
        let off = ServerFeatureState.off(.switchedOff)
        let result = await client.makeLink(packet: Data([1]), preview: preview, linksState: off)
        XCTAssertEqual(result, .needsConsent, "the listener is asked first; an off switch is reported only after they agree")
    }
}
