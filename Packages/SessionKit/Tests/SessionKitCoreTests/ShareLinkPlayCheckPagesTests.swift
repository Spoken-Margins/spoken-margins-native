import XCTest
@testable import SessionKit

/// #4783: in production a share link's page sends the browser on to the web listener, which is the page that answers the
/// check. Before this, the hidden view refused that hop, so on a real link the check never heard from the page.
final class ShareLinkPlayCheckPagesTests: XCTestCase {
    private let link = URL(string: "https://spokenmargins.proximitytoprogress.com/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z")!

    func testTheLinkAndTheHopToTheSameLinkOnTheWebListenerAreFollowed() {
        XCTAssertTrue(ShareLinkPlayCheck.mayNavigate(to: link, from: link))
        // What the link's page does: `location.replace(<data-web>/l/<id><#key>)`.
        XCTAssertTrue(ShareLinkPlayCheck.mayNavigate(to: URL(string: "https://app.spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z")!, from: link))
        XCTAssertTrue(ShareLinkPlayCheck.mayNavigate(to: URL(string: "https://APP.spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z")!, from: link))
        XCTAssertTrue(ShareLinkPlayCheck.mayNavigate(to: URL(string: "https://app.spokenmargins.proximitytoprogress.com/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z")!, from: link))
    }

    /// A table of what is never followed.
    func testEveryOtherAddressIsRefused() {
        let refused: [(String, String)] = [
            ("https://app.spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1b#k3y_-Z", "another link"),
            ("https://app.spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1a#other", "another key"),
            ("https://app.spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1a", "no key"),
            ("https://app.spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1a?report#k3y_-Z", "the report page"),
            ("https://app.spokenmargins.com/#library", "the app's own page"),
            ("http://app.spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z", "not https"),
            ("https://app.spokenmargins.com:8443/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z", "another port"),
            ("https://app.spokenmargins.com.evil.example/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z", "a lookalike host"),
            ("https://evil.example/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z", "an outside host"),
            ("https://spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z", "a link server is not a page the link goes to"),
            ("https://spokenmargins.proximitytoprogress.com/l/919b917bf739cb4ca513e44d9e692f1a?report", "the link's own report form"),
            ("https://spokenmargins.proximitytoprogress.com/join/", "the join page"),
            ("https://spokenmargins.proximitytoprogress.com:8443/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z", "the link's host on another port"),
            ("https://u@spokenmargins.proximitytoprogress.com/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z", "a sign-in in the address"),
            ("https://u:p@app.spokenmargins.com/l/919b917bf739cb4ca513e44d9e692f1a#k3y_-Z", "a sign-in on the web listener"),
            ("https://podcasts.apple.com/us/podcast/x/id1?i=2", "a publisher"),
        ]
        for (url, why) in refused {
            XCTAssertFalse(ShareLinkPlayCheck.mayNavigate(to: URL(string: url)!, from: link), why)
        }
    }

    func testThePageMayLoadFromTheLinksHostTheWebListenerAndTheLinkServersOnly() {
        XCTAssertEqual(ShareLinkPlayCheck.pageHosts(for: link), [
            "spokenmargins.proximitytoprogress.com", "app.spokenmargins.com", "app.spokenmargins.proximitytoprogress.com", "spokenmargins.com",
        ])
        XCTAssertEqual(ShareLinkPlayCheck.pageHosts(for: URL(string: "https://SpokenMargins.com/l/a#k")!).first, "spokenmargins.com")
        XCTAssertEqual(Set(ShareLinkPlayCheck.pageHosts(for: URL(string: "https://spokenmargins.com/l/a#k")!)).count, 4, "each host once")
    }

    func testMessagesAreTakenFromTheLinksPageAndTheWebListenersOnly() {
        XCTAssertTrue(ShareLinkPlayCheck.isCheckPageHost("spokenmargins.proximitytoprogress.com", link: link))
        XCTAssertTrue(ShareLinkPlayCheck.isCheckPageHost("app.spokenmargins.com", link: link))
        XCTAssertFalse(ShareLinkPlayCheck.isCheckPageHost("spokenmargins.com", link: link), "the packet server shows no page")
        XCTAssertFalse(ShareLinkPlayCheck.isCheckPageHost("evil.example", link: link))
        XCTAssertFalse(ShareLinkPlayCheck.isCheckPageHost("", link: link))
    }
}
