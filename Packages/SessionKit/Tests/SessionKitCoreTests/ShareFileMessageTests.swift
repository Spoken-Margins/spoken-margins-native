import Foundation
import XCTest
@testable import SessionKit

/// The words that go with a `.spokenmargins` file sent as a file (#3800).
final class ShareFileMessageTests: XCTestCase {
    func testTheCaptionIsBothSentencesWithLinksOnAndTheFirstWithLinksOff() {
        XCTAssertEqual(
            ShareFileMessage.caption(linksOffered: true),
            "Your friend needs Spoken Margins to open a file. A link opens in any browser."
        )
        XCTAssertEqual(
            ShareFileMessage.caption(linksOffered: false),
            "Your friend needs Spoken Margins to open a file."
        )
    }

    func testTheLineNamesTheItemAndTheJoinPage() {
        XCTAssertEqual(
            ShareFileMessage.text(itemTitle: "The Daily"),
            "I left you notes on “The Daily”. Open this file in Spoken Margins. Get it here: https://spokenmargins.com/join"
        )
        XCTAssertEqual(ShareFileMessage.mailSubject(itemTitle: "The Daily"), "Margins on “The Daily”")
    }

    /// Only Messages and Mail are known to deliver a text and a file together. Anything else, including a type we have
    /// not seen and no type at all, gets the file alone, so the file is never separated from what it came with.
    func testOnlyMessagesAndMailGetTheLine() {
        XCTAssertTrue(ShareFileMessage.carriesMessage(activityType: "com.apple.UIKit.activity.Message"))
        XCTAssertTrue(ShareFileMessage.carriesMessage(activityType: "com.apple.UIKit.activity.Mail"))
        for other in [
            "com.apple.UIKit.activity.AirDrop",
            "com.apple.CloudDocsUI.AddToiCloudDrive",
            "com.apple.UIKit.activity.CopyToPasteboard",
            "com.apple.UIKit.activity.SaveToCameraRoll",
            "net.whatsapp.WhatsApp.ShareExtension",
            "com.apple.UIKit.activity.message",
            "com.apple.UIKit.activity.Message ",
            "",
        ] {
            XCTAssertFalse(ShareFileMessage.carriesMessage(activityType: other), other)
        }
        XCTAssertFalse(ShareFileMessage.carriesMessage(activityType: nil))
        XCTAssertTrue(ShareFileMessage.isMail(activityType: "com.apple.UIKit.activity.Mail"))
        XCTAssertFalse(ShareFileMessage.isMail(activityType: "com.apple.UIKit.activity.Message"))
        XCTAssertFalse(ShareFileMessage.isMail(activityType: nil))
    }

    /// Neighbouring titles: the cut at the limit, graphemes, quotes, blanks, and other spellings of the same title.
    func testTitleTable() {
        let limit = ShareFileMessage.titleLimit
        XCTAssertEqual(limit, 80)
        let exactly = String(repeating: "a", count: limit)
        let one = String(repeating: "a", count: limit + 1)
        let long = String(repeating: "b", count: 500)
        // A family emoji is one character made of several scalars; a cut must not split it.
        let family = "👨‍👩‍👧‍👦"
        let familyTitle = String(repeating: family, count: limit + 5)
        let combined = String(repeating: "e\u{301}", count: limit + 5)

        let table: [(name: String, title: String, quoted: String?)] = [
            ("plain", "The Daily", "“The Daily”"),
            ("exactly the limit is kept whole", exactly, "“\(exactly)”"),
            ("one over is cut to 79 and an ellipsis", one, "“\(String(repeating: "a", count: limit - 1))…”"),
            ("very long", long, "“\(String(repeating: "b", count: limit - 1))…”"),
            ("emoji cluster is not split", familyTitle, "“\(String(repeating: family, count: limit - 1))…”"),
            ("combining accent is not split", combined, "“\(String(repeating: "e\u{301}", count: limit - 1))…”"),
            ("straight quotes stay", "He said \"hi\"", "“He said \"hi\"”"),
            ("curly quotes stay", "“Quoted” title", "““Quoted” title”"),
            ("apostrophe stays", "What's new", "“What's new”"),
            ("outer whitespace is trimmed", "  The Daily \n", "“The Daily”"),
            ("inner whitespace stays", "The  Daily", "“The  Daily”"),
            ("empty", "", nil),
            ("only spaces", "   ", nil),
            ("only a newline", "\n", nil),
        ]
        for row in table {
            XCTAssertEqual(ShareFileMessage.quotedTitle(row.title), row.quoted, row.name)
        }
        for row in table where row.quoted != nil {
            let quoted = row.quoted ?? ""
            // The title inside the quotes is at most the limit, "…" included.
            XCTAssertLessThanOrEqual(quoted.count - 2, limit, row.name)
        }
    }

    func testABlankTitleLeavesOutTheOnPart() {
        XCTAssertEqual(
            ShareFileMessage.text(itemTitle: "  "),
            "I left you notes. Open this file in Spoken Margins. Get it here: https://spokenmargins.com/join"
        )
        XCTAssertEqual(ShareFileMessage.mailSubject(itemTitle: ""), "Margins from Spoken Margins")
    }

    func testALongTitleIsCutInTheLineAndTheSubjectAlike() {
        let title = String(repeating: "x", count: 200)
        let cut = String(repeating: "x", count: 79) + "…"
        XCTAssertEqual(
            ShareFileMessage.text(itemTitle: title),
            "I left you notes on “\(cut)”. Open this file in Spoken Margins. Get it here: https://spokenmargins.com/join"
        )
        XCTAssertEqual(ShareFileMessage.mailSubject(itemTitle: title), "Margins on “\(cut)”")
    }

    /// The line holds the address exactly once, and the address is the one the web page's button and the beta invite use.
    func testTheLineCarriesTheJoinAddressOnce() {
        let text = ShareFileMessage.text(itemTitle: "A")
        XCTAssertEqual(text.components(separatedBy: BetaInviteShare.joinURL).count - 1, 1)
        XCTAssertTrue(text.hasSuffix(BetaInviteShare.joinURL))
    }
}
