import XCTest
@testable import SessionKit

/// #3770: a folder's location in words a listener can read. A table of the shapes iOS gives, and their neighbours.
final class FolderLocationLabelTests: XCTestCase {
    private let appGroup = "/private/var/mobile/Containers/Shared/AppGroup/6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    private func check(_ path: String, _ expected: String?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(FolderLocationLabel.label(forPath: path), expected, message.isEmpty ? path : message, file: file, line: line)
    }

    func testICloudDrive() {
        let drive = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs"
        check("\(drive)/Clippings", "iCloud Drive › Clippings")
        check("\(drive)/Clippings/", "iCloud Drive › Clippings", "a trailing slash is how a folder URL is written")
        check("\(drive)/Work/Reading/Clippings", "iCloud Drive › Work › Reading › Clippings")
        check("\(drive)/", "iCloud Drive", "the root of iCloud Drive")
        check("\(drive)", "iCloud Drive", "the root, without the slash")
    }

    func testObsidiansICloudFolder() {
        let obsidian = "/private/var/mobile/Library/Mobile Documents/iCloud~md~obsidian/Documents"
        check("\(obsidian)/Vault/Web/Clippings", "Obsidian › Vault › Web › Clippings")
        check("\(obsidian)/Clippings", "Obsidian › Clippings")
        check("/x/Mobile Documents/iCloud~com~apple~Pages/Documents/Drafts", "Pages › Drafts", "the app's own name is the last part")
        check("/x/Mobile Documents/iCloud~md~obsidian/Elsewhere/Vault", "… › iCloud~md~obsidian › Elsewhere › Vault",
              "not under Documents/: the whole path, cut")
    }

    func testFileProviderStorage() {
        check("\(appGroup)/File Provider Storage/Clippings", "Clippings")
        check("\(appGroup)/File Provider Storage/0A1B2C3D4E5F6A7B8C9D/Work/Clippings", "Work › Clippings", "an opaque id is dropped")
        check("\(appGroup)/File Provider Storage/6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D/Work/Clippings", "Work › Clippings", "a UUID is dropped")
        check("\(appGroup)/File Provider Storage/0A1B2C3D4E5F6A7B8C9D", nil, "only an opaque id: nothing readable")
        check("\(appGroup)/File Provider Storage/", nil)
    }

    func testTheOpaqueRule() {
        XCTAssertTrue(FolderLocationLabel.isOpaque("6A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"))
        XCTAssertTrue(FolderLocationLabel.isOpaque("0123456789abcdef"), "16 hex digits")
        XCTAssertTrue(FolderLocationLabel.isOpaque("0123456789ab_cdef-01"), "hex, underscore and dash")
        XCTAssertFalse(FolderLocationLabel.isOpaque("0123456789abcde"), "15 is a name")
        XCTAssertFalse(FolderLocationLabel.isOpaque("Reading list 2026"), "letters outside hex, and spaces")
        XCTAssertFalse(FolderLocationLabel.isOpaque("Clippings"))
        XCTAssertFalse(FolderLocationLabel.isOpaque("0123456789abcdeg"), "one non-hex letter makes it a name")
    }

    func testADeepPathIsCutWithAnEllipsisFirst() {
        let drive = "/x/Mobile Documents/com~apple~CloudDocs"
        check("\(drive)/Vault/Web/Clippings", "iCloud Drive › Vault › Web › Clippings", "exactly three names are not cut")
        check("\(drive)/Archive/Vault/Web/Clippings", "iCloud Drive › … › Vault › Web › Clippings")
        check("/a/b/c/d/e", "… › c › d › e", "no prefix, cut")
        check("/a/b/c", "a › b › c", "three names, not cut")
    }

    func testRootLevelAndOrdinaryPaths() {
        check("/Clippings", "Clippings")
        check("/", nil)
        check("", nil)
        check("   ", nil)
        check("/Users/x/Documents/Brief", "… › x › Documents › Brief", "an unknown shape: the whole path, cut to three")
        check("Clippings", "Clippings", "a bare name")
        check("//a///b//", "a › b", "empty parts of the path are dropped")
    }

    func testNFCAgainstNFDAndSpaces() {
        check("/x/Cafe\u{301} notes/Re\u{301}sume\u{301}", "x › Café notes › Résumé")
        XCTAssertEqual(FolderLocationLabel.label(forPath: "/x/Cafe\u{301}"), FolderLocationLabel.label(forPath: "/x/Café"))
        check("/Work Notes/Reading List", "Work Notes › Reading List", "spaces are kept")
        check("/Work  Notes", "Work  Notes", "and not collapsed")
    }

    func testAFileURLStringReadsLikeItsPath() {
        check("file:///private/var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/My%20Clippings/", "iCloud Drive › My Clippings")
    }

    func testTwoClippingsFoldersInDifferentPlacesLookDifferentWhileTheNamesDiffer() {
        let one = FolderLocationLabel.label(forPath: "/x/Mobile Documents/com~apple~CloudDocs/Clippings")
        let two = FolderLocationLabel.label(forPath: "/x/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Clippings")
        XCTAssertNotEqual(one, two)
        // The stated limit: the same prefix and last three names look the same.
        XCTAssertEqual(FolderLocationLabel.label(forPath: "/x/A/Vault/Web/Clippings"), FolderLocationLabel.label(forPath: "/x/B/Vault/Web/Clippings"))
    }

    func testTheSpokenLabelUsesCommasAndLeavesOutTheEllipsis() {
        XCTAssertEqual(FolderLocationLabel.spokenLabel(forPath: "/x/Mobile Documents/com~apple~CloudDocs/Clippings"), "iCloud Drive, Clippings")
        XCTAssertEqual(FolderLocationLabel.spokenLabel(forPath: "/x/Mobile Documents/com~apple~CloudDocs/A/B/C/D"), "iCloud Drive, B, C, D")
        XCTAssertNil(FolderLocationLabel.spokenLabel(forPath: "/"))
    }

    func testDoubledSlashesInsideAMarkerDoNotHideIt() {
        XCTAssertEqual(FolderLocationLabel.label(forPath: "/a/Mobile Documents//com~apple~CloudDocs//Vault"),
                       FolderLocationLabel.label(forPath: "/a/Mobile Documents/com~apple~CloudDocs/Vault"))
        XCTAssertEqual(FolderLocationLabel.label(forPath: "/a/Mobile Documents/iCloud~md~obsidian//Documents/Vault"),
                       FolderLocationLabel.label(forPath: "/a/Mobile Documents/iCloud~md~obsidian/Documents/Vault"))
        XCTAssertEqual(FolderLocationLabel.label(forPath: "/a/File Provider Storage//Clippings"),
                       FolderLocationLabel.label(forPath: "/a/File Provider Storage/Clippings"))
    }

    func testAnAppNameKeepsItsFirstLetterWhenCapitalizingWouldChangeItsLength() {
        XCTAssertEqual(FolderLocationLabel.label(forPath: "/a/Mobile Documents/iCloud~ab~ßeta/Documents/V")?.hasPrefix("ßeta"), true)
    }
}
