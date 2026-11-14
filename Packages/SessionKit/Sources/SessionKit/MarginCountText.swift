import Foundation

/// How the Margins tab says how many Margins there are (#3848): "1 Margin", "0 Margins", "2 Margins". The tab's scope
/// count and each item's heading read the same words on screen and in VoiceOver, so they share this one place.
public enum MarginCountText {
    /// "1 Margin" for exactly one, "N Margins" otherwise. A negative count reads as none.
    public static func count(_ margins: Int) -> String {
        let margins = max(0, margins)
        return margins == 1 ? "1 Margin" : "\(margins) Margins"
    }

    /// The line under an item's title on the Margins tab: "Newest · 1 Margin" for the newest item, else just the count.
    public static func itemLine(_ margins: Int, isNewest: Bool) -> String {
        isNewest ? "Newest · \(count(margins))" : count(margins)
    }

    /// The Shared list's line (#4105): the item line with " · N new" while some of its Margins are unheard.
    public static func itemLine(_ margins: Int, newCount: Int, isNewest: Bool) -> String {
        let line = itemLine(margins, isNewest: isNewest)
        return newCount > 0 ? "\(line) · \(newCount) new" : line
    }
}
