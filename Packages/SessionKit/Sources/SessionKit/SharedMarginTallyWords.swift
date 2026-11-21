import Foundation

/// The Library row's words for who sent the Margins on an item, and the "Completed hidden" note that says when
/// the hidden items hold friends' Margins (#3794). Pure and host-tested: the row draws these strings, and nothing
/// here reads the database.
extension SharedMarginTally {
    /// One friend whose Margins are on an item. `key` is what tells two people apart (the sender's id; for a sender
    /// with no id, the name), so the same friend in two packets is one sender.
    public struct Sender: Hashable, Sendable {
        public let key: String
        /// The name as the friend gave it, trimmed; empty when they gave none.
        public let name: String
        public let count: Int

        public init(key: String? = nil, name: String?, count: Int) {
            // The app's one rule for what is a name (`SharedPacketArrival.senderName`): "Unsigned sender", "Imported
            // collection", "Someone" and "Your friend" are not names. Inner whitespace is collapsed so "Cole  M" is "Cole M".
            let usable = SharedPacketArrival.senderName(name).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
            self.name = usable.folded == "a friend" ? "" : usable
            let id = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.key = id.isEmpty ? (self.name.isEmpty ? "" : "name:" + self.name.folded) : "id:" + id
            self.count = max(0, count)
        }

        fileprivate init(merging first: Sender, _ second: Sender) {
            key = first.key
            // The same name whichever layer is read first: the longer one ("Cole M." over "Cole"), then the earlier in order.
            if first.name.isEmpty { name = second.name } else if second.name.isEmpty { name = first.name } else {
                name = (first.name.count, second.name) > (second.name.count, first.name) ? first.name : second.name
            }
            count = first.count + second.count
        }

        public var isNamed: Bool { !name.isEmpty }

        /// The name as the row shows it: over 24 characters, the first 23 and an ellipsis.
        var shownName: String {
            name.count > 24 ? String(name.prefix(23)) + "…" : name
        }
    }

    /// Senders merged by `key`; the unnamed with no id are one sender. Most Margins first, then by name.
    static func mergedSenders(_ senders: [Sender]) -> [Sender] {
        var order: [String] = []
        var merged: [String: Sender] = [:]
        for sender in senders where sender.count > 0 {
            if let existing = merged[sender.key] {
                merged[sender.key] = Sender(merging: existing, sender)
            } else {
                order.append(sender.key)
                merged[sender.key] = sender
            }
        }
        // A friend's older packet with a name and no id is the same friend as a newer one with an id and that name.
        for key in order where key.hasPrefix("name:") {
            guard let loose = merged[key],
                  let match = order.first(where: { $0.hasPrefix("id:") && merged[$0]?.name.folded == loose.name.folded })
            else { continue }
            merged[match] = Sender(merging: merged[match]!, loose)
            merged[key] = nil
        }
        return order.compactMap { merged[$0] }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.shownLabel.folded != $1.shownLabel.folded { return $0.shownLabel.folded < $1.shownLabel.folded }
            return $0.key < $1.key
        }
    }

    /// The counts alone, without who sent them, for the places that compare what counts apart from the names.
    public var counts: SharedMarginTally { SharedMarginTally(total: total, new: new) }

    /// "2 new Margins from Cole", "3 Margins from Cole · 1 new", "1 new reply and 1 new Margin from Sam",
    /// "5 Margins from Cole and Sam", "5 Margins from 3 friends · 2 new", "2 new Margins from a friend".
    /// Nil when nobody shared a Margin on the item.
    public var senderLine: String? { senderWords(spokenSuffix: false) }

    /// What VoiceOver says: the same words, and ", 1 new to you" in place of " · 1 new".
    public var senderAccessibilityLine: String? { senderWords(spokenSuffix: true) }

    private func senderWords(spokenSuffix: Bool) -> String? {
        guard total > 0 else { return nil }
        let people = Self.mergedSenders(senders)
        // A tally with no sender read (an older caller) is one friend with no name.
        let who = Self.who(people, spoken: spokenSuffix)
        let wordsAreNew = new == total
        let somewhatNew = new > 0 && new < total
        let marginCount = total - min(max(replies, 0), total)
        let replyCount = total - marginCount
        let countWords: String
        if people.count >= 2 || replyCount == 0 {
            countWords = Self.count(total, noun: "Margin", plural: "Margins", isNew: wordsAreNew)
        } else if marginCount == 0 {
            countWords = Self.count(replyCount, noun: "reply", plural: "replies", isNew: wordsAreNew)
        } else {
            countWords = Self.count(replyCount, noun: "reply", plural: "replies", isNew: wordsAreNew)
                + " and " + Self.count(marginCount, noun: "Margin", plural: "Margins", isNew: wordsAreNew)
        }
        var line = "\(countWords) from \(who)"
        if somewhatNew { line += spokenSuffix ? ", \(new) new to you" : " · \(new) new" }
        return line
    }

    /// "1 reply", "2 new replies": `new` goes before the noun when everything is new.
    private static func count(_ n: Int, noun: String, plural: String, isNew: Bool) -> String {
        "\(n) \(isNew ? "new " : "")\(n == 1 ? noun : plural)"
    }

    /// The words for who. On screen a long name is cut (`shownName`); spoken, VoiceOver gets the whole name, since
    /// how "…" is spoken depends on the voice (#4648). Two different friends who read the same ("Sam" and "Sam", or
    /// two long names cut to the same start) are "Sam and another Sam", so the line never reads as one friend twice.
    private static func who(_ people: [Sender], spoken: Bool) -> String {
        guard !people.isEmpty else { return "a friend" }
        let named = people.filter(\.isNamed).count
        func label(_ sender: Sender) -> String {
            guard sender.isNamed else { return "a friend" }
            return spoken ? sender.name : sender.shownName
        }
        switch people.count {
        case 1:
            return label(people[0])
        case 2:
            if named == 0 { return "friends" }
            let first = label(people[0]), second = label(people[1])
            if people[0].isNamed, people[1].isNamed, first.folded == second.folded {
                return "\(first) and another \(second)"
            }
            return "\(first) and \(second)"
        default:
            return "\(people.count) friends"
        }
    }

    /// Whether a Library search finds the item through who sent the Margins: the same match as titles (case and
    /// diacritics ignored, a substring). An unnamed sender matches nothing, so "friend" finds nobody.
    public func senderMatches(_ query: String) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        // `senders` was merged when the tally was made.
        return senders.contains { $0.isNamed && $0.name.localizedStandardContains(wanted) }
    }
}

extension SharedMarginTally.Sender {
    /// The sort label: the name, or "a friend".
    fileprivate var shownLabel: String { isNamed ? shownName : "a friend" }
}

extension String {
    /// Case and diacritics ignored, as the Library search folds titles.
    fileprivate var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
