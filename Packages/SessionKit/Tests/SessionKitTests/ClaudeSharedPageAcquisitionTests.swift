#if canImport(JavaScriptCore) && canImport(WebKit)
import Foundation
import JavaScriptCore
import WebKit
import XCTest
@testable import SessionKit

/// The shared-Claude-page parser is tested in SessionKitCoreTests with snapshots written by hand. A snapshot
/// only reaches it through the hook script the page reader injects and the content rules it compiles, so
/// these run those two strings through real engines (#1049, LNK-10): the hook in JavaScriptCore against a
/// stand-in `fetch`, and the rules through WebKit's own content-rule compiler, which rejects patterns and
/// keys that `NSRegularExpression` and `JSONSerialization` accept.
final class ClaudeSharedPageAcquisitionTests: XCTestCase {
    private static let snapshotAddress = "https://claude.ai/api/chat_snapshots/342aad12-5f5f-435a-90ce-e24f8363823b?rendering_mode=messages"
    private static let snapshotBody = #"{"chat_messages":[{"sender":"assistant","text":"Hello."}]}"#

    /// A page world with the real hook installed over a `fetch` that answers with `ok` and `body`, recording
    /// the arguments it was called with.
    private func pageWithHook() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript("""
        var window = this;
        window.__fetchCalls = [];
        window.__nextResponse = null;
        window.fetch = function () {
            window.__fetchCalls.push(Array.prototype.slice.call(arguments));
            return Promise.resolve(window.__nextResponse);
        };
        function makeResponse(ok, body) {
            return { ok: ok, marker: "page's own response", clone: function () {
                return { text: function () { return Promise.resolve(body); } };
            } };
        }
        """)
        context.evaluateScript(ClaudeSharedPage.snapshotHookScript)
        XCTAssertNil(exception, "the hook script must run without throwing")
        return context
    }

    /// Calls `fetch` the way the page does, lets its promises settle, and returns what the reader would see.
    private func pageFetches(_ argument: String, ok: Bool, in context: JSContext) -> (kept: String?, returnedOriginal: Bool) {
        context.evaluateScript("""
        window.__nextResponse = makeResponse(\(ok), \(jsonString(Self.snapshotBody)));
        window.fetch(\(argument)).then(function (response) { window.__returned = response; });
        """)
        let read = context.evaluateScript("(function () { \(ClaudeSharedPage.snapshotReadScript) })()")
        let kept = read.flatMap { $0.isNull || $0.isUndefined ? nil : $0.toString() }
        let returnedOriginal = context.evaluateScript("window.__returned === window.__nextResponse")?.toBool() ?? false
        return (kept, returnedOriginal)
    }

    private func jsonString(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast().description
    }

    func testHookKeepsTheSnapshotThePageFetches() throws {
        let page = try pageWithHook()

        let result = pageFetches(jsonString(Self.snapshotAddress), ok: true, in: page)

        XCTAssertEqual(result.kept, Self.snapshotBody, "the reader must find the chat the page fetched")
        XCTAssertTrue(result.returnedOriginal, "the page must still get its own response")
        XCTAssertEqual(page.evaluateScript("window.__fetchCalls.length")?.toInt32(), 1)
        XCTAssertEqual(page.evaluateScript("window.__fetchCalls[0][0]")?.toString(), Self.snapshotAddress)
    }

    func testHookKeepsTheSnapshotWhenThePageFetchesARequestObject() throws {
        let page = try pageWithHook()

        let result = pageFetches("{ url: \(jsonString(Self.snapshotAddress)) }", ok: true, in: page)

        XCTAssertEqual(result.kept, Self.snapshotBody)
        XCTAssertTrue(result.returnedOriginal)
    }

    func testHookIgnoresOtherAddressesAndFailedResponses() throws {
        for (address, ok) in [
            ("https://claude.ai/api/organizations/abc", true),
            ("https://claude.ai/share/342aad12", true),
            (Self.snapshotAddress, false)
        ] {
            let page = try pageWithHook()
            let result = pageFetches(jsonString(address), ok: ok, in: page)
            XCTAssertNil(result.kept, "\(address) ok=\(ok) must not be kept as the chat")
            XCTAssertTrue(result.returnedOriginal, "\(address) ok=\(ok) must still reach the page")
        }
    }

    /// The page reader compiles these with `WKContentRuleListStore` and fails the import if WebKit refuses them.
    @MainActor
    func testContentRulesCompileInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-share-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))

        let ruleList = try await store.compileContentRuleList(
            forIdentifier: "claude-share-rules-test",
            encodedContentRuleList: ClaudeSharedPage.contentRules
        )

        XCTAssertNotNil(ruleList)
    }
}
#endif
