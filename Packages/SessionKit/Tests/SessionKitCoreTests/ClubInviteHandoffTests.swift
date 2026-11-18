import Foundation
import XCTest
@testable import SessionKit

/// The address the invitation page's button opens (#1799, slice 4): `spokenmargins://club?link=<invite link>`.
/// The app must read the same string the page builds in the browser, hand the link to `ClubInvite.parse`, and
/// refuse anything that is not exactly that shape.
final class ClubInviteHandoffTests: XCTestCase {
    private let invite = ClubInvite.random()

    /// The page's own encoding is `encodeURIComponent`, which leaves `- _ . ! ~ * ' ( )` bare.
    private func browserAddress(for link: URL) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = link.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed)!
        return URL(string: "spokenmargins://club?link=\(encoded)")!
    }

    func testTheAddressTheAppBuildsAndTheOneThePageBuildsBothOpenTheSameClub() {
        XCTAssertEqual(ClubInviteHandoff.parse(ClubInviteHandoff.url(carrying: invite)), .invite(invite))
        XCTAssertEqual(ClubInviteHandoff.parse(browserAddress(for: invite.url())), .invite(invite))
    }

    func testTheKeyStaysInsideTheEncodedLinkAndNeverInTheAddressItself() throws {
        let address = ClubInviteHandoff.url(carrying: invite)
        XCTAssertNil(address.fragment, "the key must travel in the query, not as the address's own fragment")
        XCTAssertFalse(address.absoluteString.contains("#"))
        XCTAssertTrue(address.absoluteString.hasPrefix("spokenmargins://club?link=https%3A%2F%2F"))
    }

    func testSchemeAndHostAreMatchedWithoutCase() {
        let link = invite.url().absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        for text in ["SPOKENMARGINS://club?link=\(link)", "spokenmargins://CLUB?link=\(link)"] {
            XCTAssertEqual(ClubInviteHandoff.parse(URL(string: text)!), .invite(invite), text)
        }
    }

    /// Neighbouring inputs. Each is "not a club hand-off", so another handler may take the URL.
    func testShapesThatAreNotAClubHandoffAreLeftAlone() throws {
        let link = invite.url().absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let second = ClubInvite.random().url().absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let shareLink = "https%3A%2F%2F\(ProductServer.productionHost)%2Fl%2F\(String(repeating: "a", count: 32))%23\(invite.key.fragment)"
        let cases: [String: String] = [
            "another scheme": "https://club?link=\(link)",
            "another host": "spokenmargins://margin?link=\(link)",
            "no query": "spokenmargins://club",
            "empty link": "spokenmargins://club?link=",
            "another name": "spokenmargins://club?url=\(link)",
            "the link twice": "spokenmargins://club?link=\(link)&link=\(second)",
            "a fragment of its own": "spokenmargins://club?link=\(link)#\(invite.key.fragment)",
            "a share link, not a club": "spokenmargins://club?link=\(shareLink)",
            "another site": "spokenmargins://club?link=https%3A%2F%2Fexample.org%2Fc%2F\(invite.id)%23\(invite.key.fragment)",
            "plain http": "spokenmargins://club?link=http%3A%2F%2F\(ProductServer.productionHost)%2Fc%2F\(invite.id)%23\(invite.key.fragment)",
            "a path after the host": "spokenmargins://club/anything?link=\(link)",
            "a port": "spokenmargins://club:80?link=\(link)",
            "a user": "spokenmargins://someone@club?link=\(link)",
            "another query item": "spokenmargins://club?link=\(link)&x=1",
            "not a URL": "spokenmargins://club?link=%20not%20a%20url",
        ]
        for (name, text) in cases {
            let url = try XCTUnwrap(URL(string: text), name)
            XCTAssertEqual(ClubInviteHandoff.parse(url), .notAClubLink, name)
        }
    }

    func testAClubLinkThatCannotOpenIsDamagedNotIgnored() throws {
        let host = ProductServer.productionHost
        // No key, a key that is not one, and a key for another club.
        let other = ClubInvite.random()
        let cases: [String: String] = [
            "no key": "https://\(host)/c/\(invite.id)",
            "a key that is not one": "https://\(host)/c/\(invite.id)#nope",
            "another club's key": "https://\(host)/c/\(invite.id)#\(other.key.fragment)",
        ]
        for (name, inner) in cases {
            let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let url = try XCTUnwrap(URL(string: "spokenmargins://club?link=\(encoded)"), name)
            XCTAssertEqual(ClubInviteHandoff.parse(url), .incompleteOrDamaged, name)
        }
    }

    func testTheInviteDoesNotPrintItsKeyThroughTheHandoff() {
        let printed = "\(ClubInviteHandoff.parse(ClubInviteHandoff.url(carrying: invite)))"
        XCTAssertFalse(printed.contains(invite.key.fragment), "a parsed hand-off must not print the club's key")
    }
}
