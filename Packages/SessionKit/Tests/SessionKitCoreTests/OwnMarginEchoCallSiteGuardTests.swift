import Foundation
import XCTest
import SessionKitTestInputs

/// #4910: a copy of the listener's own Margin that came back in a packet must not show or count as a friend's. Screens
/// read friend Margins from two filtered sources (`ItemDetailLoader.load`, `MarginRowsReading`), but an app call that
/// reads the imported Margins straight from the store skips that filter, which is how the arrival banner and #4697's
/// Library row each got it wrong. This fails on any such call that hasn't been classified below.
final class OwnMarginEchoCallSiteGuardTests: XCTestCase {
    private static let needles = ["loadImportedCommentaryInterjections(", "loadImportedCommentaryLayers("]

    private enum Kind {
        /// It goes through `OwnMarginEchoes` (or a function built on it) before anything reaches the listener.
        case usesTheRule
        /// It reads the store to write, by id: copies must stay included (placement, hiding, saving one record).
        case readsToWrite
        /// Nothing it reads is shown or counted to the listener as a friend's Margins.
        case notAListenerSurface
    }

    /// "File.swift function" for the function the call is in, with why it may read the store directly.
    private static let allowed: [String: (Kind, String)] = [
        "SpokenMarginsPackageImportCoordinator.swift commit": (.usesTheRule,
            "the banner counts through SharedPacketArrival with the item's own Margins; a failed own read counts as before"),
        "ImportedPodcastPlacementCoordinator.swift performResolve": (.readsToWrite,
            "places every layer's Margins on the listener's audio, copies included, so a layer that comes back is placed"),
        "ImportedPodcastPlacementCoordinator.swift layersNeedTranscript": (.notAListenerSurface,
            "only decides whether placement needs a transcript"),
        "ReplyBoxCoordinator.swift finishReport": (.readsToWrite, "hides every Margin of a reported layer by id"),
        "Gate1AppModel+SharedMarginReadAloud.swift setSharedMarginReadAloud": (.readsToWrite, "saves one record's read-aloud choice by id"),
        "Gate1AppModel+FriendPacketCheck.swift libraryHoldsFriendPacket": (.notAListenerSurface,
            "hides the first-launch link card once any packet is in; an own re-import means the listener already shared, so they are past it; it counts no Margins"),
        "ImportedFileEpisodeLinker.swift hasLinkedMargins": (.notAListenerSurface, "whether a file's episode link can still change"),
        "SkimBridgeController.swift readResources": (.notAListenerSurface, "reads layers for a shared Listening Map, no Margins"),
    ]

    func testEveryAppReadOfImportedMarginsFromTheStoreIsClassified() throws {
        // Read through TestInputs, so a package checked out alone skips this with the input named.
        let sources = try TestInputs.directory(.appSources)
        let function = try NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)

        var found = Set<String>()
        var unclassified: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let ns = text as NSString
            let units = Array(text.utf16)
            let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}"))
            // Whether the body of the function declared at `start` is still open at `offset`. A local function that
            // closed before the call doesn't count, so the call is named for the function it is really in.
            func bodyEncloses(_ start: Int, _ offset: Int) -> Bool {
                var index = start
                while index < offset, units[index] != open { index += 1 }
                var depth = 0
                while index < offset {
                    if units[index] == open { depth += 1 }
                    if units[index] == close { depth -= 1; if depth == 0 { return false } }
                    index += 1
                }
                return depth > 0
            }
            for needle in Self.needles {
                var searchStart = text.startIndex
                while let hit = text.range(of: needle, range: searchStart..<text.endIndex) {
                    searchStart = hit.upperBound
                    let offset = NSRange(hit, in: text).location
                    // The function the call is in: the nearest `func` before it whose body is still open.
                    let enclosing = function.matches(in: text, range: NSRange(location: 0, length: offset)).reversed()
                        .first { bodyEncloses($0.range.location, offset) }
                        .map { ns.substring(with: $0.range(at: 1)) } ?? "<top level>"
                    let key = "\(file.lastPathComponent) \(enclosing)"
                    found.insert(key)
                    if Self.allowed[key] == nil {
                        let line = text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1
                        unclassified.append("\(file.lastPathComponent):\(line) \(enclosing) \(needle)")
                    }
                }
            }
        }
        XCTAssertEqual(unclassified, [], """
            these app calls read imported Margins straight from the store: show friend Margins through ItemDetailLoader or \
            MarginRowsReading, or call OwnMarginEchoes, then add the call to `allowed` with why (#4910)
            """)
        XCTAssertEqual(Set(Self.allowed.keys).subtracting(found), [], "these entries match no call any more; remove them")
    }
}
