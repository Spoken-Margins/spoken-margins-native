import XCTest
@testable import SessionKit

/// #3801: every way opening a friend's share link can fail maps to exactly one row of the failure sheet, in the words of
/// the share page, with one next step.
final class PacketOpenFailureSheetContentTests: XCTestCase {
    typealias Content = PacketOpenFailureSheetContent
    private let id = String(repeating: "ab12", count: 8)
    private var host: String { ShareLinkURL.shareHosts[0] }

    func testEveryDownloadFailureMapsToItsOwnRow() {
        let expected: [ShareLinkPacketDownloader.Failure: Content.Row] = [
            .offline: .offline, .expired: .expired, .serverProblem: .serverProblem, .switchedOff: .switchedOff,
            .expiredOrUnreachable: .unavailable, .cutOff: .cutOff, .damaged: .linkDamaged,
        ]
        XCTAssertEqual(Set(expected.keys), Set(ShareLinkPacketDownloader.Failure.allCases), "a new failure needs a row")
        for (failure, row) in expected {
            XCTAssertEqual(Content(failure, linkID: id).row, row, "\(failure)")
        }
        XCTAssertEqual(Set(expected.values).count, expected.count, "no two failures share a row")
    }

    func testTheWordsAreThoseOfTheSharePage() {
        let table: [(Content.Row, String, String)] = [
            (.expired, "This link has expired.", "Ask your friend to share it again."),
            (.unavailable, "This link isn't available.", "It may have expired, or been removed. Ask your friend to share it again."),
            (.cutOff, "This link is cut off.", "Copy the whole link from the message and open it again."),
            (.linkDamaged, "This link couldn't be opened.", "It may have been damaged on the way. Ask your friend to share it again."),
            (.switchedOff, "Links are switched off for now.", "Ask your friend to send the Margins as a file."),
            (.serverProblem, "The server had a problem.", "Try again in a minute."),
            (.offline, "You're offline.", "Connect to the internet, then tap Try Again."),
            (.notAShareLink, "This isn't a link to a friend's Margins.", "Copy the whole link from the message and try again."),
            (.fileDamaged, "This file couldn't be opened.", "It may have been damaged on the way. Ask your friend to send it again."),
            (.fileNeedsNewerApp, "This needs a newer Spoken Margins.", "Your friend made this with a newer version. Update the app to hear it."),
            (.fileTooBig, "This file is too big to open.", "Ask your friend to send fewer Margins at a time."),
            (.fileDoesNotMatchLibrary, "These Margins don't match your copy.",
             "Check you have the same copy and edition, then open them again. If it still fails, ask your friend to send them again."),
        ]
        XCTAssertEqual(Set(table.map(\.0)), Set(Content.Row.allCases), "every row is in the table")
        for (row, headline, line) in table {
            let content = Content(row: row)
            XCTAssertEqual(content.headline, headline, "\(row)")
            XCTAssertEqual(content.line, line, "\(row)")
        }
    }

    func testOnlyAServerFaultAndBeingOfflineOfferTryAgain() {
        let retryable = Content.Row.allCases.filter { Content(row: $0).isRetryable }
        XCTAssertEqual(Set(retryable), [.serverProblem, .offline])
    }

    func testEveryRowHasItsOwnWords() {
        let contents = Content.Row.allCases.map { Content(row: $0) }
        XCTAssertEqual(Set(contents.map(\.headline)).count, contents.count, "no two rows share a headline")
        for content in contents {
            XCTAssertFalse(content.headline.isEmpty)
            XCTAssertFalse(content.line.isEmpty)
        }
    }

    func testReportThisLinkIsOfferedOnlyOnACutOffLinkWhoseIdIsWhole() {
        XCTAssertEqual(Content(.cutOff, linkID: id).reportLinkID, id)
        XCTAssertTrue(Content(.cutOff, linkID: id).offersReport)
        for failure in ShareLinkPacketDownloader.Failure.allCases where failure != .cutOff {
            XCTAssertFalse(Content(failure, linkID: id).offersReport, "\(failure)")
        }
        XCTAssertFalse(Content(row: .cutOff).offersReport, "no id")
        XCTAssertFalse(Content(row: .cutOff, reportLinkID: String(id.prefix(12))).offersReport, "short id")
        XCTAssertFalse(Content(row: .cutOff, reportLinkID: id.uppercased()).offersReport, "not the id's own spelling")
        XCTAssertFalse(Content(row: .expired, reportLinkID: id).offersReport, "only the cut-off row")
    }

    /// The first guard of `openShareLink`: a share-host URL `ShareLinkURL` rejects.
    func testAShareHostURLTheLinkParserRejectsIsCutOffUnderLAndNotALinkElsewhere() throws {
        let cutOff: [(String, String?)] = [
            ("https://\(host)/l/", nil),
            ("https://\(host)/l/\(id.prefix(12))", nil),
            ("https://\(host)/l/\(id.prefix(12))#key", nil),
            ("https://\(host)/l/\(id)0", nil),
            ("https://\(host)/l/\(id.uppercased())", nil),
            ("https://\(host)/l/\(id)/", id),
            ("https://\(host)/l/\(id)/packet", id),
            ("https://\(host)/l/\(id)/report#key", id),
        ]
        for (text, reportID) in cutOff {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertNil(ShareLinkURL(url: url), text)
            let content = Content(unparsedShareHostURL: url)
            XCTAssertEqual(content.row, .cutOff, text)
            XCTAssertEqual(content.reportLinkID, reportID, text)
        }
        for text in ["https://\(host)/", "https://\(host)/join", "https://\(host)/l", "https://\(host)/lx/\(id)",
                     "https://\(host)/about/l/\(id)"] {
            let url = try XCTUnwrap(URL(string: text))
            let content = Content(unparsedShareHostURL: url)
            XCTAssertEqual(content.row, .notAShareLink, text)
            XCTAssertFalse(content.offersReport, text)
        }
    }

    func testTheReportIdIsTheLinkIdAndNeverTheKey() throws {
        let key = ShareLinkSealing.Key.random().fragment
        let url = try XCTUnwrap(URL(string: "https://\(host)/l/\(id)/packet#\(key)"))
        let content = Content(unparsedShareHostURL: url)
        XCTAssertEqual(content.reportLinkID, id)
        XCTAssertFalse(String(describing: content).contains(key))
    }

    func testEveryHeadlineNamesWhatFailedAsTheLinkTheFileOrTheServer() {
        let links: [Content.Row] = [.expired, .unavailable, .cutOff, .linkDamaged]
        for row in links { XCTAssertTrue(Content(row: row).headline.hasPrefix("This link"), "\(row)") }
        let files: [Content.Row] = [.fileDamaged, .fileTooBig]
        for row in files { XCTAssertTrue(Content(row: row).headline.hasPrefix("This file"), "\(row)") }
    }
}
