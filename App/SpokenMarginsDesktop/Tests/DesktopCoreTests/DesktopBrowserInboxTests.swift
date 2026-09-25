import Foundation
import XCTest
@testable import DesktopCore
import SessionKit

final class DesktopBrowserInboxTests: XCTestCase {
    func testBrowserImportKeepsEarlierEditionAndMargin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopSessionStore(databaseURL: root.appendingPathComponent("sessions.sqlite"))
        func handoff(_ text: String) -> BrowserTextHandoff {
            BrowserTextHandoff(
                captureMode: .readablePage,
                source: BrowserTextSource(url: "https://example.com/story", title: "Story"),
                text: text,
                contentFormat: .plainText,
                requestedContinuation: BrowserTextContinuation(startSession: true)
            )
        }
        let first = try store.importBrowserPage(handoff("Opening chapter. Original conclusion."))
        let anchor = try store.sourceAnchor(sessionID: first.session.id, charOffset: 8)
        _ = try store.addMargin(sessionID: first.session.id, anchor: anchor, transcript: "Original Margin")
        let duplicate = try store.importBrowserPage(handoff("Opening chapter. Original conclusion."))
        XCTAssertEqual(duplicate.session.id, first.session.id)
        let changed = try store.importBrowserPage(handoff("Opening chapter. Revised conclusion."))
        XCTAssertNotEqual(changed.item.id, first.item.id)
        XCTAssertEqual(try store.loadSession(id: first.session.id).margins.first?.transcript, "Original Margin")
        XCTAssertEqual(try store.loadSession(id: first.session.id).sourceText, "Opening chapter. Original conclusion.")
        XCTAssertEqual(changed.item.externalReference, "https://example.com/story")
    }

    func testInboxRejectsWrongRouteAndRetainsFailedPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = DesktopBrowserInbox(directory: root)
        XCTAssertThrowsError(try inbox.payloadID(from: URL(string: "spokenmargins-desktop://browser-text?payloadId=../../secret")!))
        XCTAssertThrowsError(try inbox.payloadID(from: URL(string: "spokenmargins://browser-text?payloadId=\(UUID().uuidString)")!))
        let id = UUID().uuidString
        let path = root.appendingPathComponent(id).appendingPathExtension("json")
        try Data("{}".utf8).write(to: path)
        XCTAssertThrowsError(try inbox.load(id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
}
