import Foundation
import XCTest
import SessionKitTestInputs

/// #2846: a hidden sender's Margins stay hidden only if every screen's loader is given the list. The loaders take it
/// with an empty default, so a new call that forgets it would compile and quietly show the sender again (the first
/// version missed the background reload). This fails on any such call in the app's sources.
final class HiddenSendersCallSiteGuardTests: XCTestCase {
    /// Calls that read the imported layers a screen shows, each of which must be passed the hidden senders.
    private static let needles = [
        "ItemDetailLoader.load(", "MarginRowsReading.all(", "MarginRowsReading.item(", "SharedMarginReview.entries("
    ]

    func testEveryAppCallThatLoadsLayersForAScreenIsGivenTheHiddenSenders() throws {
        // Read through TestInputs, so a package checked out alone skips this with the input named.
        let sources = try TestInputs.directory(.appSources)

        var checked = 0
        var missing: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in Self.needles {
                var searchStart = text.startIndex
                while let found = text.range(of: needle, range: searchStart..<text.endIndex) {
                    searchStart = found.upperBound
                    // The call's own parentheses, starting at the one the needle ends with. The call may wrap lines.
                    var depth = 0
                    var end = found.upperBound
                    var index = text.index(before: found.upperBound)
                    scan: while index < text.endIndex {
                        switch text[index] {
                        case "(": depth += 1
                        case ")": depth -= 1; if depth == 0 { end = index; break scan }
                        default: break
                        }
                        index = text.index(after: index)
                    }
                    let call = String(text[found.lowerBound..<end])
                    // `entries(layers:records:)` works on layers the caller already holds (the open item's, already
                    // filtered); only the overload that reads a repository by `itemId:` loads layers itself.
                    if needle.hasPrefix("SharedMarginReview"),
                       !call.dropFirst(needle.count).drop(while: { $0.isWhitespace }).hasPrefix("itemId:") { continue }
                    checked += 1
                    if !call.contains("hiddenSenders:") {
                        let line = text[..<found.lowerBound].filter { $0 == "\n" }.count + 1
                        missing.append("\(file.lastPathComponent):\(line) \(needle)")
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 7, "the guard no longer finds the calls it guards; update its list")
        XCTAssertEqual(missing, [], "these calls would show a hidden sender's Margins again")
    }
}
