import Foundation

/// Character-based navigation for generated speech. The offsets match SessionKit's
/// text anchors rather than estimating a timestamp for synthesized audio.
public enum DesktopTextNavigation {
    public static func nextSentence(after offset: Int, in text: String) -> Int {
        let limit = text.count
        let bounded = max(0, min(offset, limit))
        return boundaries(in: text).first(where: { $0 > bounded }) ?? limit
    }

    public static func previousSentence(before offset: Int, in text: String) -> Int {
        let bounded = max(0, min(offset, text.count))
        return boundaries(in: text).last(where: { $0 < bounded }) ?? 0
    }

    private static func boundaries(in text: String) -> [Int] {
        let characters = Array(text)
        var result = [0]
        for index in characters.indices where ".!?".contains(characters[index]) {
            var next = index + 1
            while next < characters.count && characters[next].isWhitespace { next += 1 }
            if next > result.last! { result.append(next) }
        }
        if result.last != characters.count { result.append(characters.count) }
        return result
    }
}
