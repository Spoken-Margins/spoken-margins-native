import Foundation
import XCTest
@testable import SessionKit

/// A shared ChatGPT page keeps its chat as data in inline scripts, not as readable HTML (#874). These
/// pages are built in the encoding the real page uses (checked against a live `chatgpt.com/s/t_…` page on
/// 2026-10-05), with invented text.
final class ChatGPTSharedPageTests: XCTestCase {
    private let shareURL = URL(string: "https://chatgpt.com/s/t_0123456789abcdef0123456789abcdef")!

    func testReadsTheWholeResponseNotJustTheTitle() throws {
        let response = """
        I rewrote the plan as **Version 2**, keeping the three layers. \u{E200}filecite\u{E202}turn0file0\u{E202}L20-L39\u{E201}

        [**Download the revised plan (.md)**](sandbox:/mnt/data/plan_v2.md)

        Major additions include fixed caches and daily drone logistics.

        ---

        If you want, I can:

        - Explain the cache model
        - Describe the pilot roadmap
        """
        let page = sharedPage(title: "Closed Loop Power Generation", messages: [
            message(id: "m1", role: "assistant", time: 1_791_227_954.5, text: response)
        ])

        let handoff = try ChatGPTSharedPage.handoff(fromPageSource: page, url: shareURL)

        XCTAssertEqual(handoff.source.title, "Closed Loop Power Generation")
        XCTAssertEqual(handoff.source.url, shareURL.absoluteString)
        XCTAssertEqual(handoff.source.author, "ChatGPT")
        XCTAssertEqual(handoff.source.publishedAt, "2026-10-05T19:21:16Z")
        XCTAssertEqual(handoff.captureMode, .readablePage)
        XCTAssertEqual(handoff.contentFormat, .markdown)
        XCTAssertEqual(handoff.text, """
        I rewrote the plan as **Version 2**, keeping the three layers.

        **Download the revised plan (.md)**

        Major additions include fixed caches and daily drone logistics.

        ---

        If you want, I can:

        - Explain the cache model
        - Describe the pilot roadmap
        """)
    }

    func testTheEnqueueWordInsideOtherScriptDataDoesNotConfuseTheScan() throws {
        let page = """
        <script>window.flags = {"enqueue_strategy":"kafka","note":"call .enqueue( later"};</script>
        \(sharedPage(title: "Notes", messages: [message(id: "m1", role: "assistant", time: 1, text: "The answer is forty-two.")]))
        """
        let handoff = try ChatGPTSharedPage.handoff(fromPageSource: page, url: shareURL)
        XCTAssertEqual(handoff.text, "The answer is forty-two.")
    }

    func testAnEntityMarkerKeepsItsName() {
        let raw = "Visit \u{E200}entity\u{E202}[\"city\",\"Lisbon\",\"capital of Portugal\"]\u{E201} in spring \u{E200}cite\u{E202}turn0search1\u{E201}."
        XCTAssertEqual(ChatGPTSharedPage.cleaned(raw), "Visit Lisbon in spring.")
    }

    func testAnUnclosedMarkerLosesOnlyItsOwnCharacter() {
        XCTAssertEqual(ChatGPTSharedPage.cleaned("Before \u{E200}cite and after"), "Before cite and after")
    }

    func testOnlySandboxLinksAreFlattened() {
        let raw = "[the file](sandbox:/mnt/data/x.csv) and [the site](https://example.com/page)"
        XCTAssertEqual(ChatGPTSharedPage.cleaned(raw), "the file and [the site](https://example.com/page)")
    }

    func testTwoTurnsAreLabelledAndOrderedByTime() throws {
        let page = sharedPage(title: "Trip", messages: [
            message(id: "a", role: "assistant", time: 20, text: "Take the morning train."),
            message(id: "u", role: "user", time: 10, text: "How should I get to Porto?")
        ])
        let handoff = try ChatGPTSharedPage.handoff(fromPageSource: page, url: shareURL)
        XCTAssertEqual(handoff.text, "User: How should I get to Porto?\n\nChatGPT: Take the morning train.")
    }

    func testHiddenSystemAndRepeatedMessagesAreLeftOut() throws {
        let page = sharedPage(title: "Trip", messages: [
            message(id: "s", role: "system", time: 1, text: "You are a helpful assistant."),
            message(id: "h", role: "assistant", time: 2, text: "Hidden scaffolding.", hidden: true),
            message(id: "a", role: "assistant", time: 3, text: "Take the morning train."),
            message(id: "a", role: "assistant", time: 3, text: "Take the morning train.")
        ])
        let handoff = try ChatGPTSharedPage.handoff(fromPageSource: page, url: shareURL)
        XCTAssertEqual(handoff.text, "Take the morning train.")
    }

    func testTitleFallsBackToThePageTitleThenTheFirstLine() throws {
        let untitled = sharedPage(title: nil, messages: [message(id: "a", role: "assistant", time: 1, text: "**Plan B** starts at dawn.\n\nMore.")])
        XCTAssertEqual(
            try ChatGPTSharedPage.handoff(fromPageSource: untitled, url: shareURL, pageTitle: "ChatGPT - Trip Plan").source.title,
            "Trip Plan"
        )
        XCTAssertEqual(
            try ChatGPTSharedPage.handoff(fromPageSource: untitled, url: shareURL, pageTitle: "ChatGPT").source.title,
            "Plan B starts at dawn."
        )
    }

    func testAPageWithNoResponseThrowsInsteadOfImportingAFewWords() {
        let page = sharedPage(title: "Closed Loop Power Generation", messages: [])
        XCTAssertThrowsError(try ChatGPTSharedPage.handoff(fromPageSource: page, url: shareURL)) {
            XCTAssertEqual($0 as? ChatGPTSharedPage.ParseError, .noResponse)
        }
        XCTAssertThrowsError(try ChatGPTSharedPage.handoff(fromPageSource: "<html><h1>Closed Loop Power Generation</h1></html>", url: shareURL)) {
            XCTAssertEqual($0 as? ChatGPTSharedPage.ParseError, .noPageData)
        }
    }

    func testOnlyChatGPTShareLinksMatch() {
        XCTAssertTrue(ChatGPTSharedPage.matches(URL(string: "https://chatgpt.com/s/t_abc")!))
        XCTAssertTrue(ChatGPTSharedPage.matches(URL(string: "https://chatgpt.com/share/6f2a-91")!))
        XCTAssertTrue(ChatGPTSharedPage.matches(URL(string: "https://chat.openai.com/share/6f2a-91")!))
        XCTAssertFalse(ChatGPTSharedPage.matches(URL(string: "https://chatgpt.com/c/6f2a-91")!))
        XCTAssertFalse(ChatGPTSharedPage.matches(URL(string: "https://chatgpt.com/")!))
        XCTAssertFalse(ChatGPTSharedPage.matches(URL(string: "http://chatgpt.com/s/t_abc")!))
        XCTAssertFalse(ChatGPTSharedPage.matches(URL(string: "https://example.com/s/t_abc")!))
    }

    func testALongResponseInALargePageStaysWhole() throws {
        let paragraph = String(repeating: "A sentence about caches and routes. ", count: 40).trimmingCharacters(in: .whitespaces)
        let text = (1...200).map { "Paragraph \($0). \(paragraph)" }.joined(separator: "\n\n")
        let noise = String(repeating: "x", count: 600_000)
        let page = "<script>window.session = \"\(noise)\";</script>"
            + sharedPage(title: "Long", messages: [message(id: "a", role: "assistant", time: 1, text: text)])
        let handoff = try ChatGPTSharedPage.handoff(fromPageSource: page, url: shareURL)
        XCTAssertEqual(handoff.text, text)
    }

    // MARK: Building a page in the real encoding

    private struct Turn {
        var id: String
        var role: String
        var time: Double
        var text: String
        var hidden: Bool
    }

    private func message(id: String, role: String, time: Double, text: String, hidden: Bool = false) -> Turn {
        Turn(id: id, role: role, time: time, text: text, hidden: hidden)
    }

    private func sharedPage(title: String?, messages: [Turn]) -> String {
        var post: [String: Any] = [
            "id": "t_0123456789abcdef0123456789abcdef",
            "posted_at": 1_791_228_076.777_635,
            "og_title": "Check out this chat",
            "permissions": ["can_read": true, "can_write": false, "share_setting": "public"],
            "attachments": [[
                "id": "t_0123456789abcdef0123456789abcdef-attachment-0",
                "tags": [Any](),
                "message_slice": ["messages": messages.map { turn -> [String: Any] in
                    [
                        "id": turn.id,
                        "author": ["role": turn.role, "name": NSNull()],
                        "create_time": turn.time,
                        "content": ["content_type": "text", "parts": [turn.text]],
                        "metadata": ["is_visually_hidden_from_conversation": turn.hidden, "model_slug": "gpt-test"]
                    ]
                }]
            ] as [String: Any]]
        ]
        if let title { post["text"] = title }
        let root: [String: Any] = [
            "loaderData": [
                "root": ["featureFlags": ["enqueue_strategy": "kafka"]],
                "routes/s.$postId": ["kind": "post_with_profile", "postWithProfile": ["post": post]]
            ],
            "actionData": NSNull(),
            "errors": NSNull()
        ]
        let flat = FlatEncoder.encode(root)
        let literal = String(data: try! JSONSerialization.data(withJSONObject: [flat], options: []), encoding: .utf8)!
            .dropFirst().dropLast() // the JSON array's brackets leave the string literal
        return """
        <html><head><title>ChatGPT - \(title ?? "")</title></head><body><h1>\(title ?? "")</h1>
        <script>window.__reactRouterContext.stream = new ReadableStream({start(c){window.__reactRouterContext.streamController = c;}});</script>
        <div hidden id="S:0"><script>window.__reactRouterContext.streamController.enqueue(\(literal));</script></div>
        <div hidden id="S:1"><script>window.__reactRouterContext.streamController.enqueue("P272:[{}]\\n");</script></div>
        <div hidden id="S:2"><script>window.__reactRouterContext.streamController.close();</script></div>
        </body></html>
        """
    }

    /// Writes a graph the way the page does: one table, strings shared, an object's `"_N"` keys naming
    /// table positions, a `-5` for null.
    private struct FlatEncoder {
        private var table: [Any] = []
        private var strings: [String: Int] = [:]

        static func encode(_ root: Any) -> String {
            var encoder = FlatEncoder()
            _ = encoder.add(root)
            let data = try! JSONSerialization.data(withJSONObject: encoder.table, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)! + "\n"
        }

        private mutating func add(_ value: Any) -> Int {
            if value is NSNull { return -5 }
            if let string = value as? String {
                if let existing = strings[string] { return existing }
                table.append(string)
                strings[string] = table.count - 1
                return table.count - 1
            }
            if let object = value as? [String: Any] {
                let index = table.count
                table.append(NSNull())
                var encoded: [String: Int] = [:]
                for key in object.keys.sorted() { encoded["_\(add(key))"] = add(object[key]!) }
                table[index] = encoded
                return index
            }
            if let array = value as? [Any] {
                let index = table.count
                table.append(NSNull())
                table[index] = array.map { add($0) }
                return index
            }
            table.append(value)
            return table.count - 1
        }
    }
}
