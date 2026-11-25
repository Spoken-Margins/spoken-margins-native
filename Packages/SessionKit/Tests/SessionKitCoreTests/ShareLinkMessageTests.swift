import Foundation
import XCTest
@testable import SessionKit

/// The sentence that goes out beside a share link (#3787), true for what was shared (#5264).
final class ShareLinkMessageTests: XCTestCase {
    private typealias Message = ShareLinkMessage
    private let oneVoice = Message.Notes(count: 1, allVoice: true)
    private let threeVoice = Message.Notes(count: 3, allVoice: true)
    private let oneWords = Message.Notes(count: 1, allVoice: false)
    private let threeMixed = Message.Notes(count: 3, allVoice: false)
    private let playsTail = "Tap the link, then Play. It works in your browser, nothing to install."

    func testTheSentenceIsTheOwnersWordsAndSaysNothingToInstall() {
        XCTAssertEqual(
            Message.sentence,
            "I left you a voice note on a podcast. Tap the link, then Play. It works in your browser, nothing to install."
        )
    }

    /// The owner's sentence still goes out, byte for byte, for one voice note on an episode that plays, or one with an
    /// audio address or page whose check hasn't finished.
    func testTheOwnersSentenceGoesOutForAPlayableOrUncheckedEpisode() {
        XCTAssertEqual(Message.chooseSentence(item: .episode, notes: oneVoice, hasAudioOrPage: true, playability: .plays), Message.sentence)
        XCTAssertEqual(Message.chooseSentence(item: .episode, notes: oneVoice, hasAudioOrPage: true, playability: .unknown), Message.sentence)
        XCTAssertEqual(Message.chooseSentence(item: .episode, notes: oneVoice, hasAudioOrPage: false, playability: .plays), Message.sentence)
    }

    /// Today's single sentence was told to a friend sent Margins on an article. It must not be any more.
    func testAnArticleIsNotCalledAPodcastAndPromisesNothingTheBrowserCantDo() {
        let sentence = Message.chooseSentence(item: .article, notes: oneVoice, hasAudioOrPage: false, playability: .unknown)
        XCTAssertNotEqual(sentence, Message.sentence)
        XCTAssertFalse(sentence.contains("podcast"))
        XCTAssertFalse(sentence.contains("nothing to install"))
    }

    /// The Design's strings, written out by hand.
    func testTheDesignsSentencesWordForWord() {
        let rows: [(Message.SharedKind, Message.Notes, Bool, Message.Playability, String)] = [
            (.episode, oneVoice, true, .cannot,
             "I left you a voice note on a podcast. You'll need Spoken Margins on iPhone to hear it with the episode. The link shows what it's on and how to get the app."),
            (.episode, oneVoice, false, .unknown,
             "I left you a voice note on a podcast. You'll need Spoken Margins on iPhone to hear it with the episode. The link shows what it's on and how to get the app."),
            (.article, oneVoice, true, .cannot,
             "I left you a voice note on an article. You'll need Spoken Margins on iPhone to hear it with the article. The link shows what it's on and how to get the app."),
            (.pdf, oneVoice, false, .unknown,
             "I left you a voice note on a PDF. You'll need Spoken Margins on iPhone to hear it with the PDF. The link shows what it's on and how to get the app."),
            (.book, oneVoice, false, .cannot,
             "I left you a voice note on a book. You'll need Spoken Margins on iPhone to hear it with the book. The link shows what it's on and how to get the app."),
            (.spokenNote, oneVoice, false, .unknown,
             "I left you a voice note on something I wrote. You'll need Spoken Margins on iPhone to hear it with what I wrote. The link shows what it's on and how to get the app."),
            (.recording, oneVoice, false, .unknown,
             "I left you a voice note on a recording. You'll need Spoken Margins on iPhone to hear it with the recording. The link shows what it's on and how to get the app."),
            (.article, oneVoice, true, .plays,
             "I left you a voice note on an article. Tap the link, then Play. It works in your browser, nothing to install."),
            (.article, threeMixed, true, .unknown,
             "I left you notes on an article. You'll need Spoken Margins on iPhone to hear them with the article. The link shows what they're on and how to get the app.")
        ]
        for (item, notes, page, playability, expected) in rows {
            XCTAssertEqual(
                Message.chooseSentence(item: item, notes: notes, hasAudioOrPage: page, playability: playability), expected,
                "\(item) \(notes) page=\(page) \(playability)"
            )
        }
    }

    /// Every cell: the Plays shape only on plays, or for an episode with an audio address or page that isn't checked;
    /// "podcast" only for an episode; the noun follows what is going.
    func testEveryCellFollowsTheRules() {
        let ons: [Message.SharedKind: String] = [
            .episode: "a podcast", .article: "an article", .pdf: "a PDF", .book: "a book",
            .spokenNote: "something I wrote", .recording: "a recording"
        ]
        let withs: [Message.SharedKind: String] = [
            .episode: "the episode", .article: "the article", .pdf: "the PDF", .book: "the book",
            .spokenNote: "what I wrote", .recording: "the recording"
        ]
        let nouns: [(Message.Notes, String, String, String)] = [
            (oneVoice, "a voice note", "it", "it's"), (threeVoice, "voice notes", "them", "they're"),
            (oneWords, "a note", "it", "it's"), (threeMixed, "notes", "them", "they're")
        ]
        for item in Message.SharedKind.allCases {
            for page in [true, false] {
                for playability in [Message.Playability.plays, .cannot, .unknown] {
                    for (notes, noun, pronoun, whatOn) in nouns {
                        let sentence = Message.chooseSentence(item: item, notes: notes, hasAudioOrPage: page, playability: playability)
                        let label = "\(item) \(notes) page=\(page) \(playability)"
                        let shouldPlay = playability == .plays || (playability == .unknown && item == .episode && page)
                        let opening = "I left you \(noun) on \(ons[item]!)."
                        let expected = shouldPlay
                            ? "\(opening) \(playsTail)"
                            : "\(opening) You'll need Spoken Margins on iPhone to hear \(pronoun) with \(withs[item]!). The link shows what \(whatOn) on and how to get the app."
                        XCTAssertEqual(sentence, expected, label)
                        XCTAssertEqual(sentence.contains("nothing to install"), shouldPlay, label)
                        XCTAssertEqual(sentence.contains("podcast"), item == .episode, label)
                        XCTAssertFalse(sentence.contains("  "), label)
                        XCTAssertFalse(sentence.contains("\u{2019}"), "straight apostrophes: \(label)")
                    }
                }
            }
        }
    }

    func testTheItemFromThePacketsTypeAndTheSpokenNoteFlag() {
        let rows: [(SharedItemType, Bool, Message.SharedKind)] = [
            (.podcast, false, .episode), (.podcast, true, .episode),
            (.text, false, .article), (.text, true, .spokenNote),
            (.pdf, false, .pdf), (.pdf, true, .pdf),
            (.epub, false, .book), (.epub, true, .book),
            (.other, false, .recording), (.other, true, .recording)
        ]
        for (type, flag, expected) in rows {
            XCTAssertEqual(Message.SharedKind(itemType: type, isSpokenNote: flag), expected, "\(type) \(flag)")
        }
    }

    func testTheNotesNounFollowsTheVoiceOfEveryMargin() {
        XCTAssertEqual(Message.Notes(count: 0, allVoice: true), Message.Notes(count: 0, allVoice: false), "no Margins is words only")
        XCTAssertEqual(Message.Notes(count: 0, allVoice: true).noun, "a note")
        XCTAssertEqual(Message.Notes(kinds: [.originalAudioAndText]), oneVoice)
        XCTAssertEqual(Message.Notes(kinds: [.cleanedAudioAndText, .originalAudioAndText, .cleanedAudioAndText]), threeVoice)
        XCTAssertEqual(Message.Notes(kinds: [.textOnly]), oneWords)
        XCTAssertEqual(Message.Notes(kinds: [nil]), oneWords)
        XCTAssertEqual(Message.Notes(kinds: [.originalAudioAndText, .textOnly, .originalAudioAndText]), threeMixed)
        XCTAssertEqual(Message.Notes(kinds: []), Message.Notes(count: 0, allVoice: false))
        for kind in [SharedInterjectionRepresentationKind.textOnly, .summaryText, .summaryAudioAndText, .ttsAudioAndText] {
            XCTAssertFalse(Message.Notes.isSendersVoice(kind), "\(kind) is not the sender's voice")
        }
    }

    func testTheCheckOutcomeReadsAsPlaysCannotOrUnknown() {
        typealias Check = ShareLinkPlayCheck
        XCTAssertEqual(Message.Playability(Check.Outcome.plays), .plays)
        for reason in Check.Reason.allCases {
            let expected: Message.Playability
            switch reason {
            case .article, .noEpisodeAudio, .paidPost, .noPostVoice, .audioFormat: expected = .cannot
            case .audioRefused, .linkBroken, .linksOff: expected = .unknown
            }
            XCTAssertEqual(Message.Playability(Check.Outcome.problem(reason)), expected, "\(reason)")
        }
        let unknowns: [Check.Outcome?] = [
            nil, .checking, .gone, .notChecked(.offline), .notChecked(.lowDataMode), .notChecked(.didNotFinish),
            .notChecked(.postVoiceNotLookedUp)
        ]
        for outcome in unknowns {
            XCTAssertEqual(Message.Playability(outcome), .unknown, "\(String(describing: outcome))")
        }
    }

    /// A second Share link while the first check is queued or running: the newest link's own plays or cannot wins, the
    /// carried one is used only while the newest reads as unknown.
    func testTheNewestLinksAnswerWinsOverTheCarriedOne() {
        typealias Check = ShareLinkPlayCheck
        let newest: [Check.Outcome?] = [nil, .checking, .plays, .problem(.article), .problem(.audioRefused), .gone]
        let carried: [Message.Playability?] = [nil, .plays, .cannot]
        for outcome in newest {
            for previous in carried {
                let own = Message.Playability(outcome)
                let expected = own != .unknown ? own : (previous ?? .unknown)
                XCTAssertEqual(Message.Playability.current(newest: outcome, carried: previous), expected,
                               "\(String(describing: outcome)) carried \(String(describing: previous))")
            }
        }
        XCTAssertEqual(Message.Playability.current(newest: .notChecked(.didNotFinish), carried: .cannot), .cannot)
        XCTAssertEqual(Message.Playability.current(newest: .checking, carried: .unknown), .unknown)
    }

    /// The key is the link's `#` part. Losing it, or any other part of the address, would send a link that opens nothing.
    func testTheTextCarriesTheWholeAddressAfterTheSentence() throws {
        let key = ShareLinkSealing.Key.random()
        let base = URL(string: "https://spokenmargins.com/l/0123456789abcdef0123456789abcdef")!
        let link = try XCTUnwrap(ShareLinkSealing.linkURL(base: base, key: key))
        XCTAssertNotNil(link.fragment)

        for item in Message.SharedKind.allCases {
            let text = Message.text(for: link, item: item, notes: oneVoice, hasAudioOrPage: false, playability: .cannot)
            let sentence = Message.chooseSentence(item: item, notes: oneVoice, hasAudioOrPage: false, playability: .cannot)
            XCTAssertEqual(text, "\(sentence)\n\n\(link.absoluteString)")
            // A friend's phone reads the address back out of the text and gets the same link.
            let found = text.split(whereSeparator: \.isNewline).last.flatMap { URL(string: String($0)) }
            XCTAssertEqual(found, link)
            XCTAssertNotNil(ShareLinkURL(url: try XCTUnwrap(found)))
        }
    }
}
