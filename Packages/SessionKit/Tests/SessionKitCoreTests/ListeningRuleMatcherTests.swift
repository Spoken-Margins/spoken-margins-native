import XCTest
@testable import SessionKit

/// #4046 PR 9: how rule words match an episode's title and summary. A table of neighbouring inputs: case, diacritics,
/// width, punctuation at word edges, apostrophes, a trailing star, a phrase, empty words, length limits, whole words only,
/// and scripts with no spaces.
final class ListeningRuleMatcherTests: XCTestCase {
    private struct Row {
        let words: [String]
        let title: String
        let summary: String?
        let matches: Bool
        let note: String
        init(_ words: [String], _ title: String, _ summary: String?, _ matches: Bool, _ note: String) {
            self.words = words; self.title = title; self.summary = summary; self.matches = matches; self.note = note
        }

        init(_ words: [String], _ title: String, _ matches: Bool, _ note: String) {
            self.init(words, title, nil, matches, note)
        }
    }

    func testMatchTable() {
        let rows: [Row] = [
            Row(["crypto"], "Crypto weekly", true, "case"),
            Row(["CRYPTO"], "crypto weekly", true, "the rule's case"),
            Row(["cafe"], "A Café in Paris", true, "diacritics fold, text side"),
            Row(["café"], "Cafe culture", true, "diacritics fold, rule side"),
            Row(["résumé"], "Resume tips", true, "two accents"),
            Row(["ai"], "ＡＩ and you", true, "full-width text"),
            Row(["ＡＩ"], "ai and you", true, "full-width rule"),
            Row(["crypto"], "Crypto, weekly", true, "punctuation after the word"),
            Row(["crypto"], "“Crypto” weekly", true, "quotes around the word"),
            Row(["crypto"], "(crypto)", true, "brackets"),
            Row(["crypto"], "weekly: crypto!", true, "colon and bang"),
            Row(["crypto"], "Cryptography 101", false, "a longer word is not the word"),
            Row(["art"], "How to start", false, "art is not inside start"),
            Row(["art"], "The art of war", true, "art as a whole word"),
            Row(["art"], "Start the art", true, "the whole word later in the title"),
            Row(["crypto*"], "Cryptography 101", true, "a trailing star matches a word's start"),
            Row(["crypto*"], "Anticrypto", false, "a star is not a contains"),
            Row(["crypto*"], "Crypto", true, "a star also matches the word itself"),
            Row(["*crypto"], "Anticrypto", false, "a leading star is not a wildcard"),
            Row(["crypto**"], "Cryptography", true, "two trailing stars are one"),
            Row(["don't"], "Don’t panic", true, "a curly apostrophe is a straight one, text side"),
            Row(["don’t"], "Don't panic", true, "a curly apostrophe is a straight one, rule side"),
            Row(["rock'n'roll"], "Rock’n’Roll nights", true, "apostrophes inside a word stay"),
            Row(["panic"], "'Panic'", true, "single quotes at word edges are ignored"),
            Row(["dont"], "Don't panic", false, "dont is not don't"),
            Row(["new york"], "A New York story", true, "a phrase"),
            Row(["new york"], "New   York", true, "a phrase across extra spaces"),
            Row(["new york"], "New, York", true, "a phrase across punctuation"),
            Row(["new york"], "York is new", false, "a phrase in the wrong order"),
            Row(["new york"], "New Jersey and York", false, "a phrase must be adjacent"),
            Row(["new york*"], "New Yorker cartoons", true, "a star on a phrase's last word"),
            Row(["new* york"], "Newer York", false, "a star only on the last word"),
            Row(["new york"], "New", "York", false, "a phrase doesn't run from the title into the summary"),
            Row(["wildfire"], "Weekly show", "All about the wildfire season", true, "the summary counts"),
            Row(["wildfire"], "Weekly show", nil, false, "no summary, no match"),
            Row(["", "  ", ",", "***"], "Anything", false, "empty words match nothing"),
            Row(["", "crypto"], "Crypto", true, "an empty word beside a real one"),
            Row([], "Anything", false, "no words"),
            Row(["e-mail"], "E-mail me", true, "a hyphenated word matches the same words"),
            Row(["email"], "E-mail me", false, "email is not e-mail"),
            Row(["2024"], "Election 2024 recap", true, "digits"),
            Row(["covid-19"], "Covid 19 update", true, "hyphen and space are the same break"),
            Row(["криптовалюта"], "Криптовалюта сегодня", true, "Cyrillic"),
            Row(["КРИПТО*"], "Криптовалюта сегодня", true, "Cyrillic, case and star"),
            Row(["ελλάδα"], "Ελλαδα σήμερα", true, "Greek, diacritics"),
            Row(["比特币"], "今日比特币行情", true, "Chinese words have no spaces, so characters match as a run"),
            Row(["比特币"], "比特 币", true, "a space between ideographs doesn't break the run"),
            Row(["比特币"], "比特 now 币", false, "but another word between them does"),
            Row(["ニュース"], "今夜のニュース", true, "kana"),
            Row(["バイク"], "ハイクの話", false, "a voiced kana is not its plain form"),
            Row(["パン"], "ハンの話", false, "a semi-voiced kana is not its plain form"),
            Row(["がっこう"], "かっこうの話", false, "hiragana dakuten is not stripped either"),
            Row(["バイク"], "バイクの話", true, "the same kana match"),
            Row(["ﾊﾞｲｸ"], "バイクの話", true, "half-width katakana fold to full-width"),
            Row(["バイク"], "ﾊﾞｲｸの話", true, "half-width text matches too"),
            Row(["café バイク"], "Cafe バイク", true, "kana beside accented Latin: the Latin still folds"),
            Row(["दुनिया"], "दुनिया भर की खबरें", true, "Devanagari keeps its combining marks"),
            Row(["crypto"], "Crypto\u{0301}", true, "a combining mark folds away"),
        ]
        for row in rows {
            let matcher = ListeningRuleMatcher(words: row.words)
            XCTAssertEqual(matcher.matches(title: row.title, summary: row.summary), row.matches, "\(row.note): \(row.words) vs \(row.title)")
        }
    }

    func testFirstMatchReturnsTheWordAsTheListenerWroteIt() {
        let matcher = ListeningRuleMatcher(words: ["Bitcoin", "Crypto*"])
        XCTAssertEqual(matcher.firstMatch(in: ListeningRuleText(title: "Cryptography", summary: nil)), "Crypto*")
        XCTAssertEqual(matcher.firstMatch(in: ListeningRuleText(title: "Bitcoin and crypto", summary: nil)), "Bitcoin", "the first word in the rule's order")
        XCTAssertNil(matcher.firstMatch(in: ListeningRuleText(title: "Gardening", summary: nil)))
    }

    func testVeryLongTextStillMatches() {
        let filler = String(repeating: "lorem ipsum ", count: 20_000)
        XCTAssertTrue(ListeningRuleMatcher(words: ["needle"]).matches(title: "Long", summary: filler + " needle"))
    }

    // MARK: Words

    func testWordValidationTable() {
        XCTAssertEqual(ListeningRuleWords.validate(["crypto", " nft* "]), .valid(["crypto", "nft*"]), "trimmed")
        XCTAssertEqual(ListeningRuleWords.validate(["", " ", "crypto", "!!!"]), .valid(["crypto"]), "empty words are dropped")
        XCTAssertEqual(ListeningRuleWords.validate(["Crypto", "crypto", "CRYPTO"]), .valid(["Crypto"]), "a word written twice is kept once")
        XCTAssertEqual(ListeningRuleWords.validate(["crypto", "crypto*"]), .valid(["crypto", "crypto*"]), "a star makes it a different word")
        XCTAssertEqual(ListeningRuleWords.validate([]), .invalid(.noWords))
        XCTAssertEqual(ListeningRuleWords.validate(["", " "]), .invalid(.noWords))
        XCTAssertEqual(ListeningRuleWords.validate(["a,b"]), .invalid(.wordHasComma("a,b")))
        XCTAssertEqual(ListeningRuleWords.validate(["a，b"]), .invalid(.wordHasComma("a，b")), "the full-width comma too")
        let sixty = String(repeating: "a", count: 60)
        XCTAssertEqual(ListeningRuleWords.validate([sixty]), .valid([sixty]), "60 characters is allowed")
        XCTAssertEqual(ListeningRuleWords.validate([sixty + "a"]), .invalid(.wordTooLong(sixty + "a")), "61 is not")
        let emoji60 = String(repeating: "👩‍👩‍👧", count: 60)
        XCTAssertEqual(emoji60.count, 60)
        XCTAssertEqual(ListeningRuleWords.validate([emoji60 + "x"]), .invalid(.wordTooLong(emoji60 + "x")), "length counts Characters, not scalars")
        let twenty = (0..<20).map { "w\($0)" }
        XCTAssertEqual(ListeningRuleWords.validate(twenty), .valid(twenty))
        XCTAssertEqual(ListeningRuleWords.validate(twenty + ["w20"]), .invalid(.tooManyWords))
        XCTAssertTrue(ListeningRuleWords.hasRoom(forRulesAlreadyKept: 199))
        XCTAssertFalse(ListeningRuleWords.hasRoom(forRulesAlreadyKept: 200))
        XCTAssertEqual(ListeningRuleWords.split("a, b ,c，d,,"), ["a", " b ", "c", "d"])
    }
}
