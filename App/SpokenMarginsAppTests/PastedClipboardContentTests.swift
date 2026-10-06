import UniformTypeIdentifiers
import XCTest
@testable import SpokenMarginsApp

/// #145, owner FAIL on cb3d6c4: a link copied with "Copy Link" couldn't be pasted with Paste & go, while a
/// Wikipedia link and plain text could. "Copy Link" puts a URL item on the clipboard, often with no plain-text
/// copy, and the button only accepted plain text, so it stayed disabled.
@MainActor
final class PastedClipboardContentTests: XCTestCase {
    private let link = "https://www.slowboring.com/p/who-lost-afghanistan"

    func testALinkCopiedWithCopyLinkCanBePasted() async throws {
        // A clipboard item with only the URL representation, as NSURL itself writes it.
        let url = NSItemProvider(object: try XCTUnwrap(NSURL(string: link)))
        let urlData: Data? = await withCheckedContinuation { continuation in
            _ = url.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        let data = try XCTUnwrap(urlData)
        let copiedLink = NSItemProvider()
        copiedLink.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        XCTAssertFalse(copiedLink.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), "the item carries only a URL")

        XCTAssertTrue(
            PastedClipboardContent.supportedTypes.contains { type in
                copiedLink.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: type) == true }
            },
            "the button must be enabled for a URL-only clipboard"
        )
        let pasted = await PastedClipboardContent.text(from: [copiedLink])
        XCTAssertEqual(pasted, link)
    }

    func testCopiedTextIsPastedAsText() async {
        let text = "Field notes on listening slowly https://example.com/notes"
        let pasted = await PastedClipboardContent.text(from: [NSItemProvider(object: text as NSString)])
        XCTAssertEqual(pasted, text)
    }

    func testTextIsPreferredWhenTheItemAlsoCarriesALink() async throws {
        let item = NSItemProvider(object: "Who lost Afghanistan? \(link)" as NSString)
        let url = try XCTUnwrap(NSURL(string: "https://example.com/other"))
        item.registerObject(url, visibility: .all)

        let pasted = await PastedClipboardContent.text(from: [item])
        XCTAssertEqual(pasted, "Who lost Afghanistan? \(link)")
    }
}
