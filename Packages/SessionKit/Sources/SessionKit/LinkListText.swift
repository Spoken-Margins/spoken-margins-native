import Foundation

/// Finds a `spoken-margins.link-list.v1` object inside pasted text, such as a reply copied from the listener's own AI
/// (#4683). The reply is prose around a JSON block, often inside a code fence, so the file rule in `LinkListFile`
/// ("the whole file is the object") can't be used directly.
///
/// The marker is the format's `schemaVersion` family. Text without the marker is never a list and never refused, so
/// ordinary pasted links go the way they always did. Code: no app call site yet; PR 3 of #4683 wires it into Paste & go.
public enum LinkListText {
    /// The substring that makes pasted text worth reading as a link list.
    public static let marker = LinkListFile.schemaFamilyPrefix

    /// At most this many marker-bearing objects are tried per reply, so a hostile or odd paste with a very deeply
    /// nested object costs a bounded number of JSON parses.
    static let maxCandidates = 16

    static let unreadableMessage =
        "Your AI's reply has a link list that couldn't be read. Ask it for the JSON block again."

    /// A plain substring check, cheap enough for the main thread. It says nothing about whether a list can be read.
    public static func mightContain(_ text: String) -> Bool {
        let needle = Array(marker.utf8)
        // Bytes, not Characters, so this agrees with `find` (a combining mark after the marker doesn't hide it).
        if let found = text.utf8.withContiguousStorageIfAvailable({ firstOffset(of: needle, in: $0) != nil }) {
            return found
        }
        return firstOffset(of: needle, in: Array(text.utf8)) != nil
    }

    /// Decides what `text` holds. It never throws and does no network or file work; call it off the main actor for
    /// large replies.
    ///
    /// 1. Text over `LinkListFile.maxFileBytes` UTF-8 bytes is refused with the size message when it holds the marker,
    ///    and is `.notALinkList` otherwise.
    /// 2. Every balanced `{ ... }` object that contains the marker is tried with `LinkListFile.recognize`, outermost
    ///    and earliest first. The first list wins; a later object's refusal never beats an earlier list.
    /// 3. With no list, the first refusal from `recognize` is returned (a newer version, too many links, ...). If an
    ///    object holds the marker but isn't valid JSON, or the reply ends inside an open object whose string holds the
    ///    marker, the listener is told to ask for the block again.
    /// 4. The marker only in prose, with no object around it, is `.notALinkList`.
    public static func find(in text: String) -> LinkListFile.Recognition {
        guard text.utf8.count <= LinkListFile.maxFileBytes else {
            return mightContain(text) ? .rejected(LinkListFile.tooLargeMessage) : .notALinkList
        }
        let bytes = Array(text.utf8)
        let markers = offsets(of: Array(marker.utf8), in: bytes)
        guard !markers.isEmpty else { return .notALinkList }

        let scan = scanObjects(in: bytes)
        var candidates = scan.closed.filter { range in
            // `markers` is ascending: the first marker at or after the object's start must also be before its end.
            let next = lowerBound(of: range.lowerBound, in: markers)
            return next < markers.count && markers[next] <= range.upperBound
        }
        candidates.sort { $0.lowerBound < $1.lowerBound }

        var firstRejection: String?
        for range in candidates.prefix(maxCandidates) {
            switch LinkListFile.recognize(Data(bytes[range])) {
            case .linkList(let list):
                return .linkList(list)
            case .rejected(let message):
                firstRejection = firstRejection ?? message
            case .notALinkList:
                break
            }
        }
        if let firstRejection { return .rejected(firstRejection) }
        // A marker inside an object that couldn't be read, or after an object that was never closed (a reply cut off).
        if !candidates.isEmpty { return .rejected(unreadableMessage) }
        // A reply cut off inside the block: an object was opened and never closed, and the marker is the start of a
        // JSON string after it (`"schemaVersion": "spoken-margins...`). A `{` in the prose and the marker named in a
        // sentence is not that.
        if let firstOpen = scan.unclosedStarts.min(),
           markers.contains(where: { $0 > firstOpen && startsAJSONValue(at: $0, in: bytes) }) {
            return .rejected(unreadableMessage)
        }
        return .notALinkList
    }

    // MARK: - Scanning

    /// Balanced objects, as byte ranges including both braces, and the starts of `{` that never closed.
    ///
    /// One pass with a stack, so nested and sibling objects cost one scan together. Quotes only matter inside an
    /// object, so an apostrophe or a stray quote mark in the prose around the block changes nothing, and a stray quote
    /// after an unclosed `{` in the prose is forgotten at the end of its line.
    private static func scanObjects(in bytes: [UInt8]) -> (closed: [ClosedRange<Int>], unclosedStarts: [Int]) {
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        var stack: [Int] = []
        var closed: [ClosedRange<Int>] = []
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                // A JSON string never holds a raw line break, so one ends a string a stray quote in the prose began.
                if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    inString = false
                    escaped = false
                } else if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                continue
            }
            switch byte {
            case quote where !stack.isEmpty:
                inString = true
            case openBrace:
                stack.append(index)
            case closeBrace:
                if let start = stack.popLast() { closed.append(start...index) }
            default:
                break
            }
        }
        return (closed, stack)
    }

    /// Whether the marker at `index` opens a JSON string value: a quote, before it (past spaces) a colon.
    private static func startsAJSONValue(at index: Int, in bytes: [UInt8]) -> Bool {
        guard index > 0, bytes[index - 1] == UInt8(ascii: "\"") else { return false }
        var before = index - 2
        while before >= 0, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(bytes[before]) {
            before -= 1
        }
        return before >= 0 && bytes[before] == UInt8(ascii: ":")
    }

    /// The index of the first element of ascending `values` that is at least `target` (`values.count` if none).
    private static func lowerBound(of target: Int, in values: [Int]) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func offsets<Bytes: RandomAccessCollection>(of needle: [UInt8], in haystack: Bytes) -> [Int]
    where Bytes.Element == UInt8, Bytes.Index == Int {
        var found: [Int] = []
        var from = 0
        while let next = firstOffset(of: needle, in: haystack, from: from) {
            found.append(next)
            from = next + needle.count
        }
        return found
    }

    private static func firstOffset<Bytes: RandomAccessCollection>(of needle: [UInt8], in haystack: Bytes, from start: Int = 0) -> Int?
    where Bytes.Element == UInt8, Bytes.Index == Int {
        guard let first = needle.first, haystack.count >= needle.count else { return nil }
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first, haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }
}
