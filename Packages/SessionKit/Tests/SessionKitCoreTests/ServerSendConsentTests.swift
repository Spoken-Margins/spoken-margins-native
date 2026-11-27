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
        // Only the name crosses into the teardown closure: UserDefaults itself would be a data-race error in Swift 6.
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
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

    /// Build 36's alert (version 1) never mentioned the App Attest code or the tie from a link to its install, so
    /// whoever agreed to it is asked again (#2239).
    func testAnAgreementToTheFirstWordsDoesNotCoverTheAttestedCheck() {
        XCTAssertGreaterThanOrEqual(ServerSendConsent.disclosureVersion, 2)
        let defaults = freshDefaults()
        defaults.set(1, forKey: "serverSendConsent.share-links.version")
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .shareLinks, in: defaults))
    }

    /// Version 2's alert never said a friend's open leaves a mark on the server, so whoever agreed to it reads the
    /// alert once more (#5275).
    func testAnAgreementBeforeOpenedMarksDoesNotCoverThem() {
        XCTAssertEqual(ServerSendConsent.disclosureVersion, 3)
        let defaults = freshDefaults()
        defaults.set(2, forKey: "serverSendConsent.share-links.version")
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .shareLinks, in: defaults))
        let text = ShareLinkConsentCopy.message
        for phrase in ["their browser or app tells our server the link was opened", "your app shows \"Opened\"", "Nothing else is kept, and it is deleted with the link", "Either of you can turn this off in Settings"] {
            XCTAssertTrue(text.contains(phrase), "the consent text should say: \(phrase)")
        }
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
        for phrase in ["Margins", "audio and text", "excerpt of the source", "title and address", "sender name", "key that is only in the link", "30 days", "random code for this app", "tie each link to this install", "Deleting the app deletes your phone's copy", "90 days without use", "send the file instead"] {
            XCTAssertTrue(text.contains(phrase), "the consent text should say: \(phrase)")
        }
        XCTAssertFalse(ShareLinkConsentCopy.title.isEmpty)
        XCTAssertNotEqual(ShareLinkConsentCopy.accept, ShareLinkConsentCopy.decline)
    }

    /// A club is a different send from a share link, so agreeing to links does not cover it, and the other way round.
    func testAgreeingToLinksDoesNotCoverClubsOrTheOtherWayRound() {
        let defaults = freshDefaults()
        ServerSendConsent.record(.shareLinks, in: defaults)
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .clubs, in: defaults))
        ServerSendConsent.record(.clubs, in: defaults)
        XCTAssertTrue(ServerSendConsent.hasConsented(to: .clubs, in: defaults))
        ServerSendConsent.withdraw(.shareLinks, in: defaults)
        XCTAssertTrue(ServerSendConsent.hasConsented(to: .clubs, in: defaults))
        ServerSendConsent.withdraw(.clubs, in: defaults)
        XCTAssertFalse(ServerSendConsent.hasConsented(to: .clubs, in: defaults))
        XCTAssertEqual(ServerSendFeature.clubs.rawValue, "clubs")
    }

    /// The club alert says what `docs/design/club-mailbox.md` says the server holds and what a club cannot do.
    func testTheClubWordsNameWhatIsSentWhatTheServerKeepsAndWhatAClubCannotDo() {
        let text = ClubConsentCopy.message
        // Each thing design sections 2, 3, 5, 7 and 8 say a club sends, keeps or cannot do.
        for phrase in ["box on our server", "sends its name and the name they chose", "Everyone who posts sends each Margin",
                       "audio and text", "excerpt of the source", "source's title and address", "random code made on your phone for that club",
                       "key that is only in the invite link", "We can't read it, except in one case", "reports the club as abuse material",
                       "keep it for a year", "Anyone who has the link can read the club, from its first post, and post to it",
                       "A post can't be taken back", "no way to take someone out", "start a new club",
                       "no list of members", "no names", "makes no code of its own", "the club's number and a proof",
                       "how big each post is, their order and the day the club was last used", "kept only in memory, for up to an hour",
                       "90 days with no post and no visit", "7 days if nobody has posted",
                       "open the app or pull to refresh", "not in the background", "send a friend the file instead"] {
            XCTAssertTrue(text.contains(phrase), "the club consent text should say: \(phrase)")
        }
        XCTAssertFalse(ClubConsentCopy.title.isEmpty)
        XCTAssertNotEqual(ClubConsentCopy.accept, ClubConsentCopy.decline)
        XCTAssertNotEqual(ClubConsentCopy.message, ShareLinkConsentCopy.message)
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
