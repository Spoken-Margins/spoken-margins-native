import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

/// #662: a response shared from the ChatGPT app reaches the share extension as ordinary plain text,
/// with no file name and no link. The extension dropped it before trying to load it, so nothing
/// reached the Library.
final class SharedTextIntakeTests: XCTestCase {
    private static let response = """
    Here's the completed review. My recommendation is to ship the fix first.

    ## What changed
    The share extension now keeps the whole response. See https://example.com/notes for the
    background, and https://example.com/plan for the plan.

    - First point
    - Second point
    """

    // MARK: Which representations the extension tries

    func testUnnamedPlainTextIsTried() {
        for identifier in ["public.utf8-plain-text", "public.plain-text", "public.text", "public.utf16-plain-text"] {
            XCTAssertTrue(SharedTextIntake.acceptsTextRepresentation(identifier: identifier, suggestedName: nil), identifier)
            XCTAssertTrue(SharedTextIntake.acceptsTextRepresentation(identifier: identifier, suggestedName: ""), identifier)
        }
    }

    func testNamedMarkdownAndTextFilesAreStillTried() {
        XCTAssertTrue(SharedTextIntake.acceptsTextRepresentation(identifier: "net.daringfireball.markdown", suggestedName: "Notes.md"))
        XCTAssertTrue(SharedTextIntake.acceptsTextRepresentation(identifier: "public.plain-text", suggestedName: "Notes.TXT"))
        XCTAssertTrue(SharedTextIntake.namesTextFile("Draft.markdown"))
    }

    func testMarkupTypesStayOut() {
        // Their bytes are markup: reading them as text would speak the tags.
        for identifier in ["public.rtf", "public.html", "public.json", "public.swift-source", "public.comma-separated-values-text"] {
            XCTAssertFalse(SharedTextIntake.acceptsTextRepresentation(identifier: identifier, suggestedName: nil), identifier)
        }
        XCTAssertFalse(SharedTextIntake.acceptsTextRepresentation(identifier: "public.html", suggestedName: "page.html"))
        XCTAssertFalse(SharedTextIntake.isPlainText("public.rtf"))
        XCTAssertTrue(SharedTextIntake.isPlainText("public.utf8-plain-text"))
    }

    // MARK: What the text becomes

    func testAResponseWithLinksKeepsItsWholeBody() {
        XCTAssertEqual(
            SharedTextIntake.route("\n  \(Self.response)  \n"),
            .text(title: "Here's the completed review. My recommendation is to", body: Self.response)
        )
    }

    func testOneParagraphWithoutALinkIsText() {
        XCTAssertEqual(
            SharedTextIntake.route("Short answer: yes, it works."),
            .text(title: "Short answer: yes, it works.", body: "Short answer: yes, it works.")
        )
    }

    func testALoneHTTPSLinkIsALink() {
        XCTAssertEqual(SharedTextIntake.route(" https://example.com/post \n"), .link(URL(string: "https://example.com/post")!))
        XCTAssertEqual(
            SharedTextIntake.route("Episode 12: the share sheet https://example.com/ep12"),
            .link(URL(string: "https://example.com/ep12")!)
        )
    }

    func testNothingUsableIsNil() {
        XCTAssertNil(SharedTextIntake.route("  \n "))
        // The extension hands off https links only, as before.
        XCTAssertNil(SharedTextIntake.route("http://example.com/post"))
        XCTAssertNil(SharedTextIntake.route("mailto:someone@example.com"))
    }

    // MARK: Into the Library

    /// What the main app imports from the extension's handoff: two responses that open alike stay
    /// two items, each with its whole text, and the import starts no listening session.
    func testTwoResponsesThatStartAlikeBecomeTwoItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "test", displayName: "Test", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        let second = Self.response.replacingOccurrences(of: "ship the fix first", with: "wait a week")

        func handoff(_ text: String) throws -> BrowserTextHandoff {
            guard case .text(let title, let body) = SharedTextIntake.route(text) else {
                throw XCTSkip("not routed as text")
            }
            return BrowserTextHandoff(
                itemId: SharedTextIntake.newItemID(),
                captureMode: .plainTextFile,
                source: BrowserTextSource(url: SharedTextIntake.sourceURL, title: title),
                text: body,
                contentFormat: .markdown
            )
        }

        let firstItem = try engine.importBrowserTextInBackground(handoff(Self.response))
        let secondItem = try engine.importBrowserTextInBackground(handoff(second))

        XCTAssertNotEqual(firstItem.id, secondItem.id)
        XCTAssertTrue(firstItem.id.hasPrefix("item-shared-text-"))
        let storedFirst = try store.loadItem(id: firstItem.id)
        let storedSecond = try store.loadItem(id: secondItem.id)
        XCTAssertEqual(storedFirst.title, "Here's the completed review. My recommendation is to")
        XCTAssertTrue((storedFirst.text ?? "").contains("ship the fix first"))
        XCTAssertTrue((storedFirst.text ?? "").contains("Second point"))
        XCTAssertTrue((storedSecond.text ?? "").contains("wait a week"))
        XCTAssertEqual(storedFirst.mediaType, "text")
        XCTAssertNil(engine.currentSession)
    }
}
