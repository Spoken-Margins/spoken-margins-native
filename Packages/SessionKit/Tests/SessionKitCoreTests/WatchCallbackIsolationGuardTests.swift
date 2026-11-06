import Foundation
import XCTest
import SessionKitTestInputs

/// #2964: the Watch app closed itself every time it was opened with the phone in reach. `WatchLink` is main-actor
/// code, and it handed `WCSession.sendMessage` a reply closure. Apple's header does not mark that closure `@Sendable`,
/// so under Swift 6 the closure quietly took on the main actor's isolation. WatchConnectivity calls it on its own
/// background queue, and the isolation check Swift puts at the top of the closure then stopped the app. The compiler
/// says nothing about this, and only a real phone answering a real Watch gets there.
///
/// So every closure handed to `sendMessage` must say `@Sendable`, which takes it off the main actor; it hops back
/// itself with `Task { @MainActor in ... }`. This scans the sources the Watch and the phone send from.
final class WatchCallbackIsolationGuardTests: XCTestCase {
    /// A closure given as `replyHandler:` or `errorHandler:`, or as the trailing closure of a `sendMessage` call,
    /// captured from its opening brace.
    private static let sendCallback = try! NSRegularExpression(
        pattern: #"(?:(?:replyHandler|errorHandler):\s*|sendMessage(?:Data)?\([^{}]*\)\s*)(\{\s*(?:@Sendable\b)?)"#
    )

    private func offences(in source: String) -> Int {
        let whole = NSRange(source.startIndex..., in: source)
        return Self.sendCallback.matches(in: source, range: whole).filter { match in
            guard let brace = Range(match.range(at: 1), in: source) else { return true }
            return !source[brace].contains("@Sendable")
        }.count
    }

    func testTheScanTellsASafeCallbackFromAnUnsafeOne() {
        let table: [(source: String, offences: Int)] = [
            ("send(m, replyHandler: { [weak self] d in x() }, errorHandler: nil)", 1),
            ("send(m, replyHandler: { d in x() }, errorHandler: nil)", 1),
            ("send(m, replyHandler: {\n    x($0)\n}, errorHandler: nil)", 1),
            ("send(m, replyHandler:\n    { d in x() }, errorHandler: nil)", 1),
            ("send(m, replyHandler: nil, errorHandler: { e in x() })", 1),
            ("send(m, replyHandler: { d in x() }, errorHandler: { e in x() })", 2),
            ("session.sendMessage(m, replyHandler: nil) { [weak self] error in x() }", 1),
            ("session.sendMessageData(d, replyHandler: nil) { error in x() }", 1),
            ("send(m, replyHandler: { @Sendable [weak self] d in x() }, errorHandler: nil)", 0),
            ("send(m, replyHandler: {  @Sendable d in x() }, errorHandler: nil)", 0),
            ("send(m, replyHandler: {\n    @Sendable d in x()\n}, errorHandler: nil)", 0),
            ("send(m, replyHandler: nil, errorHandler: { @Sendable e in x() })", 0),
            ("session.sendMessage(m, replyHandler: nil) { @Sendable [weak self] error in x() }", 0),
            ("session.sendMessage(m, replyHandler: nil, errorHandler: nil)", 0),
            ("", 0),
        ]
        for row in table {
            XCTAssertEqual(offences(in: row.source), row.offences, row.source)
        }
    }

    func testEveryCallbackHandedToSendMessageLeavesTheMainActor() throws {
        var found: [String] = []
        var scannedSends = 0
        let inputs: [TestInputs.Input] = [.appWatchApp, .appWatch, .appSources, .appSharedSources]
        for input in inputs {
            let root = try TestInputs.directory(input).standardizedFileURL
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                if source.contains(".sendMessage(") { scannedSends += 1 }
                if offences(in: source) > 0 { found.append(url.lastPathComponent) }
            }
        }
        XCTAssertGreaterThan(scannedSends, 0, "The scan found no sendMessage call, so it proves nothing")
        XCTAssertEqual(found, [], "These hand sendMessage a closure without @Sendable; it would stop the app when called (#2964)")
    }
}
