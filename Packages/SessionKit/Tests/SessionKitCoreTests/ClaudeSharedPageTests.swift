import Foundation
import XCTest
@testable import SessionKit

/// A shared Claude page is an empty shell until its scripts fetch the chat (#876). The snapshot here has the
/// shape of the real `/api/chat_snapshots/<id>` response (checked against a live share link on 2026-10-05),
/// with invented text.
final class ClaudeSharedPageTests: XCTestCase {
    private let shareURL = URL(string: "https://claude.ai/share/00000000-1111-2222-3333-444444444444")!

    func testReadsBothSidesOfTheChatInOrderWithTheSharersName() throws {
        let snapshot = snapshotJSON(name: "Trip to Porto", sharer: "Sam", messages: [
            ["sender": "assistant", "index": 1, "content": [["type": "text", "text": "Take the **morning train**.\n\n- Leave at 8\n- Arrive at 11"]]],
            ["sender": "human", "index": 0, "content": [
                ["type": "image", "file_uuid": "abc"],
                ["type": "text", "text": "How should I get to Porto?"]
            ]]
        ])

        let handoff = try ClaudeSharedPage.handoff(fromSnapshot: snapshot, url: shareURL)

        XCTAssertEqual(handoff.source.title, "Trip to Porto")
        XCTAssertEqual(handoff.source.author, "Claude")
        XCTAssertEqual(handoff.source.url, shareURL.absoluteString)
        XCTAssertEqual(handoff.source.publishedAt, "2026-10-05T19:38:37.429126Z")
        XCTAssertEqual(handoff.contentFormat, .markdown)
        XCTAssertEqual(handoff.text, "Sam: How should I get to Porto?\n\nClaude: Take the **morning train**.\n\n- Leave at 8\n- Arrive at 11")
    }

    func testThinkingAndToolBlocksAreNotText() throws {
        let snapshot = snapshotJSON(name: "Notes", sharer: "Sam", messages: [
            ["sender": "assistant", "index": 0, "content": [
                ["type": "thinking", "thinking": "Let me work out the route."],
                ["type": "tool_use", "name": "web_search", "input": ["query": "trains to porto"]],
                ["type": "tool_result", "content": [["type": "text", "text": "Search results text"]]],
                ["type": "text", "text": "Take the morning train."]
            ]]
        ])
        let handoff = try ClaudeSharedPage.handoff(fromSnapshot: snapshot, url: shareURL)
        XCTAssertEqual(handoff.text, "Take the morning train.")
    }

    func testAnOlderMessageWithOnlyATextFieldStillReads() throws {
        let snapshot = snapshotJSON(name: "Old", sharer: nil, messages: [
            ["sender": "assistant", "index": 0, "text": "  An older reply.  "]
        ])
        XCTAssertEqual(try ClaudeSharedPage.handoff(fromSnapshot: snapshot, url: shareURL).text, "An older reply.")
    }

    func testAnUnnamedSharerIsUserAndAMissingNameFallsBackToTheFirstLine() throws {
        let snapshot = snapshotJSON(name: nil, sharer: nil, messages: [
            ["sender": "human", "index": 0, "content": [["type": "text", "text": "Hi there"]]],
            ["sender": "assistant", "index": 1, "content": [["type": "text", "text": "**Hello** again."]]]
        ])
        let handoff = try ClaudeSharedPage.handoff(fromSnapshot: snapshot, url: shareURL)
        XCTAssertEqual(handoff.text, "User: Hi there\n\nClaude: **Hello** again.")
        XCTAssertEqual(handoff.source.title, "User: Hi there")
    }

    func testNoReadableMessagesAndNoSnapshotAreSeparateFailures() {
        let empty = snapshotJSON(name: "Empty", sharer: "Sam", messages: [
            ["sender": "human", "index": 0, "content": [["type": "image", "file_uuid": "abc"]]]
        ])
        XCTAssertThrowsError(try ClaudeSharedPage.handoff(fromSnapshot: empty, url: shareURL)) {
            XCTAssertEqual($0 as? ClaudeSharedPage.ParseError, .noResponse)
        }
        XCTAssertThrowsError(try ClaudeSharedPage.handoff(fromSnapshot: "<html>Just a moment...</html>", url: shareURL)) {
            XCTAssertEqual($0 as? ClaudeSharedPage.ParseError, .noSnapshot)
        }
        XCTAssertThrowsError(try ClaudeSharedPage.handoff(fromSnapshot: #"{"error":"not found"}"#, url: shareURL)) {
            XCTAssertEqual($0 as? ClaudeSharedPage.ParseError, .noSnapshot)
        }
    }

    func testOnlyClaudeShareLinksMatch() {
        XCTAssertTrue(ClaudeSharedPage.matches(URL(string: "https://claude.ai/share/342aad12-5f5f-435a-90ce-e24f8363823b")!))
        XCTAssertFalse(ClaudeSharedPage.matches(URL(string: "https://claude.ai/chat/342aad12")!))
        XCTAssertFalse(ClaudeSharedPage.matches(URL(string: "https://claude.ai/share")!))
        XCTAssertFalse(ClaudeSharedPage.matches(URL(string: "http://claude.ai/share/abc")!))
        XCTAssertFalse(ClaudeSharedPage.matches(URL(string: "https://example.com/share/abc")!))
        XCTAssertFalse(ClaudeSharedPage.matches(URL(string: "https://claude.ai.example.com/share/abc")!))
    }

    /// The rules are what keeps a page that runs scripts from reaching anything else, so they must be valid JSON
    /// that blocks first, allows exactly the three hosts, and re-blocks event logging last.
    func testContentRulesAllowOnlyTheThreeHostsAndBlockLogging() throws {
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ClaudeSharedPage.contentRules.utf8)) as? [[String: Any]])
        let filters = rules.map { ($0["trigger"] as? [String: Any])?["url-filter"] as? String ?? "" }
        let actions = rules.map { ($0["action"] as? [String: Any])?["type"] as? String ?? "" }
        XCTAssertEqual(actions, ["block", "ignore-previous-rules", "ignore-previous-rules", "ignore-previous-rules", "block"])
        XCTAssertEqual(filters, [
            ".*", #"^https://claude\.ai/"#, #"^https://assets-proxy\.anthropic\.com/"#,
            #"^https://s-cdn\.anthropic\.com/"#, #"^https://claude\.ai/api/event_logging"#
        ])
        for filter in filters.dropFirst() {
            XCTAssertNoThrow(try NSRegularExpression(pattern: filter))
        }
    }

    private func snapshotJSON(name: String?, sharer: String?, messages: [[String: Any]]) -> String {
        var snapshot: [String: Any] = [
            "uuid": "00000000-1111-2222-3333-444444444444",
            "created_at": "2026-10-05T19:38:37.429126Z",
            "is_public": true,
            "chat_messages": messages.map { message -> [String: Any] in
                var full = message
                full["uuid"] = UUID().uuidString
                full["created_at"] = "2026-10-03T11:42:05.864750Z"
                return full
            }
        ]
        if let name { snapshot["snapshot_name"] = name }
        if let sharer { snapshot["created_by"] = sharer }
        return String(data: try! JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
    }
}
