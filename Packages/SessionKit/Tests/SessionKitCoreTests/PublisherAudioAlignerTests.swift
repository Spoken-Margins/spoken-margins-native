import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #546: lining up a publisher's recording with its article's text.
///
/// The fixtures are generated filler, not a recorded article. `SpokenFixture` "reads" an article
/// the way a narrator would, with word lengths and pauses setting the pace, and keeps the true
/// time each sentence starts. It then turns that reading into a transcript the way the on-device
/// recogniser reports one: phrases of several words, each with one start and end time.
final class PublisherAudioAlignerTests: XCTestCase {
    static let article = """
    The harbour at Kettleness was built for herring boats, and for a century it smelled of them. \
    Every autumn the fleet followed the shoals south along the coast. Families moved with it, \
    renting rooms above chandlers and net lofts.
    When the herring vanished in the nineteen fifties, nobody agreed on why. Some blamed the new \
    trawlers from Hull. Others pointed to warmer water, or to the factory ships anchored offshore \
    that took everything their nets could hold.
    The town tried other catches first. Crab and lobster paid, but only for the boats that already \
    had pots. Whitefish needed bigger hulls than the old cobles could manage. By nineteen seventy \
    the quay held more pleasure craft than working vessels.
    Tourism arrived slowly and then all at once. A railway poster from nineteen sixty three shows \
    the harbour wall in improbable sunshine. Within a decade the net lofts had become holiday \
    flats, and the chandlers sold postcards and buckets.
    Not everyone welcomed the change. Fishermen's widows complained that rents had tripled. The \
    parish council argued for years about parking on the cliff road. A petition to keep one \
    working slipway gathered four hundred signatures and was ignored.
    Today a single crab boat still works out of Kettleness. Its skipper, Ruth Alder, inherited it \
    from her uncle and lands her catch before dawn. She sells most of it to a restaurant in York \
    that prints her boat's name on the menu.
    Ask her about the herring and she shrugs. The sea changes, she says, and the town changes \
    with it. What matters is whether anyone is still here to notice.
    The museum by the lifeboat station keeps a single herring barrel. Visitors photograph it \
    beside a chart of the old fishing grounds, most of them now marked as wind farms.
    """

    static let otherArticle = """
    Sourdough starters are older than most bakeries. A healthy culture can be fed for decades, \
    and some families pass theirs down like heirlooms. The yeast and bacteria inside it compete \
    for the same flour, and the balance between them sets the flavour of the bread.
    Bakers argue endlessly about hydration. A wetter dough gives an open crumb with big glossy \
    holes. A stiffer one is easier to shape and holds its height in the oven.
    Temperature matters more than any recipe admits. In a cold kitchen a loaf can take a whole \
    day to rise, while in summer it may overproof before lunch.
    """

    // MARK: - Fixtures

    /// A narrator's reading of `text` and the transcript a recogniser would make of it.
    struct SpokenFixture {
        var transcript: TranscriptTimeline
        /// The true start time of each sentence that was read, by the sentence's first character.
        var sentenceStartMs: [Int: Int]
        /// First characters of sentences in a paragraph the narrator skipped.
        var skippedSentenceStarts: Set<Int>
    }

    /// Deterministic pseudo-random numbers, so the fixtures never change between runs.
    struct SeededRandom {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func spoken(
        _ text: String,
        intro: String? = nil,
        outro: String? = nil,
        skipParagraph: Int? = nil,
        readInstead: String? = nil,
        paragraphReadLast: Int? = nil,
        errorRate: Double = 0,
        seed: UInt64 = 546
    ) -> SpokenFixture {
        let characters = Array(text)
        let words = PublisherAudioAligner.words(in: characters)
        let sentences = PublisherAudioAligner.sentences(in: characters, words: words)
        var random = SeededRandom(state: seed)
        var clockMs = 1_200
        var heard: [(word: String, startMs: Int, endMs: Int)] = []

        func say(_ word: String) {
            let lengthMs = 140 + 48 * word.count
            heard.append((word, clockMs, clockMs + lengthMs))
            clockMs += lengthMs + 60
        }
        func sayPhrase(_ phrase: String) {
            for word in PublisherAudioAligner.words(in: Array(phrase)) { say(word.normalized) }
            clockMs += 700
        }

        if let intro { sayPhrase(intro) }
        var paragraphs: [Int] = []
        for (index, sentence) in sentences.enumerated() {
            let breaks = index > 0 && characters[sentences[index - 1].endChar..<sentence.startChar].contains(where: \.isNewline)
            paragraphs.append((paragraphs.last ?? 0) + (breaks ? 1 : 0))
        }
        var order = Array(sentences.indices)
        if let last = paragraphReadLast {
            order = order.filter { paragraphs[$0] != last } + order.filter { paragraphs[$0] == last }
        }
        var sentenceStartMs: [Int: Int] = [:]
        var skipped = Set<Int>()
        var previousParagraph = 0
        for index in order {
            let sentence = sentences[index]
            if paragraphs[index] != previousParagraph {
                if previousParagraph == skipParagraph, let readInstead { sayPhrase(readInstead) }
                previousParagraph = paragraphs[index]
                clockMs += 500
            }
            if paragraphs[index] == skipParagraph {
                skipped.insert(sentence.startChar)
                continue
            }
            sentenceStartMs[sentence.startChar] = clockMs
            for wordIndex in sentence.wordRange {
                let word = words[wordIndex].normalized
                let roll = random.next()
                if roll < errorRate * 0.6 {
                    say(word.count > 3 ? String(word.dropLast(2)) + "ed" : "uh") // misheard
                } else if roll < errorRate * 0.8 {
                    clockMs += 140 + 48 * word.count // spoken but not recognised
                } else if roll < errorRate {
                    let middle = word.index(word.startIndex, offsetBy: word.count / 2)
                    say(String(word[..<middle]) + "a")
                    say("n" + String(word[middle...])) // heard as two words
                } else {
                    say(word)
                }
            }
            clockMs += 350
        }
        if let outro { sayPhrase(outro) }

        // The recogniser reports phrases of five to nine words.
        var segments: [MediaTimelineSegment] = []
        var start = 0
        while start < heard.count {
            let end = min(heard.count, start + 5 + Int(random.next() * 5))
            let phrase = heard[start..<end]
            segments.append(MediaTimelineSegment(
                id: "seg-\(segments.count + 1)",
                startMs: phrase.first!.startMs,
                endMs: phrase.last!.endMs,
                startChar: nil,
                endChar: nil,
                text: phrase.map(\.word).joined(separator: " ")
            ))
            start = end
        }
        return SpokenFixture(
            transcript: TranscriptTimeline(segments: segments, chapters: [], durationMs: clockMs + 2_000),
            sentenceStartMs: sentenceStartMs,
            skippedSentenceStarts: skipped
        )
    }

    // MARK: - Checks

    private func assertMap(
        _ alignment: PublisherAudioAlignment,
        matches fixture: SpokenFixture,
        text: String = PublisherAudioAlignerTests.article,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let timeline = try XCTUnwrap(alignment.timeline, "expected a map, got \(alignment.status)", file: file, line: line)
        XCTAssertFalse(timeline.segments.isEmpty, file: file, line: line)
        let characters = Array(text)
        var previous: MediaTimelineSegment?
        for segment in timeline.segments {
            let startChar = try XCTUnwrap(segment.startChar, file: file, line: line)
            let endChar = try XCTUnwrap(segment.endChar, file: file, line: line)
            XCTAssertEqual(String(characters[startChar..<endChar]), segment.text, file: file, line: line)
            XCTAssertFalse(fixture.skippedSentenceStarts.contains(startChar), "skipped sentence placed: \(segment.text)", file: file, line: line)
            let truth = try XCTUnwrap(fixture.sentenceStartMs[startChar], "no truth for \(segment.text)", file: file, line: line)
            XCTAssertLessThanOrEqual(abs(segment.startMs - truth), 1_000, "\(segment.text): \(segment.startMs) vs \(truth)", file: file, line: line)
            XCTAssertLessThan(segment.startMs, segment.endMs, file: file, line: line)
            if let previous {
                XCTAssertGreaterThan(startChar, try XCTUnwrap(previous.endChar), file: file, line: line)
                XCTAssertGreaterThanOrEqual(segment.startMs, previous.endMs, file: file, line: line)
            }
            previous = segment
        }
    }

    private func placed(_ alignment: PublisherAudioAlignment) -> (Int, Int) {
        switch alignment {
        case .aligned(_, let placed, let total), .tooFewPlaced(let placed, let total), .noMatch(let placed, let total):
            return (placed, total)
        }
    }

    // MARK: - Cases

    func testACleanReadingPlacesEverySentence() throws {
        let fixture = Self.spoken(Self.article)
        let alignment = PublisherAudioAligner.align(articleText: Self.article, recognised: fixture.transcript)
        try assertMap(alignment, matches: fixture)
        let (placed, total) = placed(alignment)
        XCTAssertEqual(placed, total)
        XCTAssertEqual(total, fixture.sentenceStartMs.count)
        XCTAssertEqual(alignment.timeline?.durationMs, fixture.transcript.durationMs)
    }

    func testRecogniserErrorsOnTenPercentOfWords() throws {
        for seed: UInt64 in [1, 2, 3, 546] {
            let fixture = Self.spoken(Self.article, errorRate: 0.1, seed: seed)
            let alignment = PublisherAudioAligner.align(articleText: Self.article, recognised: fixture.transcript)
            try assertMap(alignment, matches: fixture)
            let (placed, total) = placed(alignment)
            XCTAssertGreaterThanOrEqual(Double(placed) / Double(total), 0.9, "seed \(seed): \(alignment.status)")
        }
    }

    func testASpokenIntroAndOutroThatArentInTheText() throws {
        let fixture = Self.spoken(
            Self.article,
            intro: "This is the audio version of The Harbour Letter, read by the author. Thanks for subscribing.",
            outro: "If you enjoyed this, share it with a friend, and see you next week.",
            errorRate: 0.05
        )
        XCTAssertGreaterThan(fixture.sentenceStartMs.values.min()!, 5_000, "the intro takes the first seconds")
        let alignment = PublisherAudioAligner.align(articleText: Self.article, recognised: fixture.transcript)
        try assertMap(alignment, matches: fixture)
    }

    func testAParagraphTheVoiceSkipsGetsNoSegment() throws {
        let fixture = Self.spoken(Self.article, skipParagraph: 4, errorRate: 0.05)
        XCTAssertEqual(fixture.skippedSentenceStarts.count, 4)
        let alignment = PublisherAudioAligner.align(articleText: Self.article, recognised: fixture.transcript)
        try assertMap(alignment, matches: fixture)
        let placedStarts = Set(alignment.timeline?.segments.compactMap(\.startChar) ?? [])
        XCTAssertTrue(placedStarts.isDisjoint(with: fixture.skippedSentenceStarts))
        let (placed, total) = placed(alignment)
        XCTAssertEqual(total - placed, 4, alignment.status)
    }

    func testAnAdReadInPlaceOfAParagraphPlacesNoneOfIt() throws {
        // Common words in the ad ("the", "and", "of") must not pull the skipped sentences in.
        let fixture = Self.spoken(
            Self.article,
            skipParagraph: 4,
            readInstead: "This episode is brought to you by the Northern Rail card, the easy way to see more of the coast. "
                + "Save a third on fares, and the card pays for itself in two trips. Find out more at the link in the notes.",
            errorRate: 0.05
        )
        let alignment = PublisherAudioAligner.align(articleText: Self.article, recognised: fixture.transcript)
        try assertMap(alignment, matches: fixture)
        let (placed, total) = placed(alignment)
        XCTAssertEqual(total - placed, 4, alignment.status)
    }

    func testAParagraphReadOutOfOrderCostsOnlyThatParagraph() throws {
        // The narrator reads the opening paragraph last. Matching in article order alone would
        // place it and lose everything after it.
        let fixture = Self.spoken(Self.article, paragraphReadLast: 0, errorRate: 0.05)
        let alignment = PublisherAudioAligner.align(articleText: Self.article, recognised: fixture.transcript)
        let timeline = try XCTUnwrap(alignment.timeline, alignment.status)
        let opening = Self.article.components(separatedBy: "\n")[0].count
        XCTAssertFalse(timeline.segments.contains { ($0.startChar ?? 0) < opening }, "the opening is out of order")
        let (placed, total) = placed(alignment)
        XCTAssertEqual(total - placed, 3, alignment.status)
        try assertMap(alignment, matches: fixture)
    }

    func testARecordingOfADifferentArticleIsNoMatch() {
        let fixture = Self.spoken(Self.otherArticle, errorRate: 0.05)
        let alignment = PublisherAudioAligner.align(articleText: Self.article, recognised: fixture.transcript)
        XCTAssertNil(alignment.timeline)
        guard case .noMatch = alignment else {
            return XCTFail("expected no match, got \(alignment.status)")
        }
        XCTAssertTrue(alignment.status.hasPrefix("no_match"))
    }

    func testAMapIsKeptOnlyWhenEightyPercentOfSentencesArePlaced() throws {
        // Reading only the first half of the article places about half its sentences.
        let half = Self.article.components(separatedBy: "\n").prefix(4).joined(separator: "\n")
        let fixture = Self.spoken(half)
        let alignment = PublisherAudioAligner.align(articleText: Self.article, recognised: fixture.transcript)
        XCTAssertNil(alignment.timeline)
        guard case .tooFewPlaced(let placed, let total) = alignment else {
            return XCTFail("expected too few placed, got \(alignment.status)")
        }
        XCTAssertLessThan(Double(placed) / Double(total), PublisherAudioAligner.minimumPlacedFraction)

        let audio = PublisherAudio(itemId: "item-1", audioURL: "https://example.com/a.mp3", detectedFrom: "feed_enclosure")
        let rejected = audio.recordingTextMap(alignment)
        XCTAssertNil(rejected.textMap)
        XCTAssertEqual(rejected.textMapStatus, alignment.status)

        let full = PublisherAudioAligner.align(articleText: Self.article, recognised: Self.spoken(Self.article).transcript)
        let kept = audio.recordingTextMap(full)
        XCTAssertEqual(kept.textMap, full.timeline)
        XCTAssertNotNil(kept.textMap)
    }

    func testTheMapIsStoredInsideThePublisherAudioRecordNotAsATranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "article", displayName: "Article", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://harbourletter.substack.com/p/kettleness", title: "Kettleness"),
            text: Self.article
        ))
        let stored = try store.loadItem(id: item.id)
        let articleText = try XCTUnwrap(stored.text)
        let audio = PublisherAudio(itemId: item.id, audioURL: "https://api.substack.com/feed/podcast/1/a.mp3", detectedFrom: "feed_enclosure")
        try store.savePublisherAudio(audio)

        let alignment = PublisherAudioAligner.align(articleText: articleText, recognised: Self.spoken(articleText, errorRate: 0.1).transcript)
        let mapped = audio.recordingTextMap(alignment)
        XCTAssertNotNil(mapped.textMap, alignment.status)
        try store.savePublisherAudio(mapped)

        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try reopened.loadPublisherAudio(itemId: item.id), mapped)
        XCTAssertNil(try reopened.loadTranscriptTimeline(itemId: item.id))
        XCTAssertEqual(try reopened.loadItem(id: item.id), stored, "the item stays a plain article")
        XCTAssertNil(try reopened.loadItem(id: item.id).transcriptId)
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
    }

    func testSentencesKeepTheirArticleOffsetsInCharacters() {
        let text = "Caf\u{E9} society, she said. \u{201C}Don\u{2019}t go!\u{201D} Then nothing.\nA new line."
        let characters = Array(text)
        let words = PublisherAudioAligner.words(in: characters)
        XCTAssertEqual(words.map(\.normalized), ["cafe", "society", "she", "said", "dont", "go", "then", "nothing", "a", "new", "line"])
        let sentences = PublisherAudioAligner.sentences(in: characters, words: words).map { String(characters[$0.startChar..<$0.endChar]) }
        XCTAssertEqual(sentences, ["Caf\u{E9} society, she said.", "\u{201C}Don\u{2019}t go!\u{201D}", "Then nothing.", "A new line."])
    }

    func testAnEmptyTranscriptIsNoMatch() {
        let alignment = PublisherAudioAligner.align(
            articleText: Self.article,
            recognised: TranscriptTimeline(segments: [], chapters: [])
        )
        guard case .noMatch(0, _) = alignment else { return XCTFail(alignment.status) }
    }
}
