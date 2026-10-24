import SubstackCanaryCore
import XCTest

/// The daily Substack canary's rules (#2027). The canary itself reads live pages; these pin what it calls a
/// failure, so the #2024 class (the page holds a voice, the parser reads nothing) can't pass quietly.
final class SubstackCanaryTests: XCTestCase {
    private let cdn = #"<link rel="preconnect" href="https://substackcdn.com">"#

    private func tagPage(_ items: String) -> String {
        cdn + #"<script type="application/json" id="preloads-json">{"post":{"id":7,"type":"newsletter","audio_items":["# + items + "]}}</script>"
    }

    private let completedTTS = #"{"post_id":7,"voice_id":"en-US","audio_url":"https://substack-video.s3.amazonaws.com/7/tts.mp3","type":"tts","status":"completed"}"#
    private let paywalledTTS = #"{"post_id":7,"voice_id":"en-US","audio_url":null,"type":"tts","status":"paywalled"}"#

    private func reading(parser: String? = nil, absence: String, app: String? = nil, words: Int? = 2_000) -> SubstackCanary.AppReading {
        SubstackCanary.AppReading(parserVoice: parser, absence: absence, appVoice: app, bodyWordCount: words, publisherPlatform: "substack")
    }

    func testRawPageReadsCompletedItemsInBothOfSubstacksFormats() {
        let tag = SubstackCanary.RawPage(html: tagPage(completedTTS))
        XCTAssertEqual(tag.completedItems, [.init(type: "tts", postID: 7)])
        XCTAssertTrue(tag.isSubstackPage)

        // The string literal Substack served before October 2026: quotes and slashes escaped.
        let literal = cdn + #"<script>window._preloads = JSON.parse("{\"post\":{\"id\":7,\"audio_items\":[{\"post_id\":7,\"audio_url\":\"https:\/\/api.substack.com\/a\/src\",\"type\":\"voiceover\",\"status\":\"completed\",\"duration\":12.5}]}}")</script>"#
        XCTAssertEqual(SubstackCanary.RawPage(html: literal).completedItems, [.init(type: "voiceover", postID: 7)])

        XCTAssertEqual(SubstackCanary.RawPage(html: tagPage(paywalledTTS)).completedItems, [])
        XCTAssertEqual(SubstackCanary.RawPage(html: tagPage("")).completedItems, [])
        // A completed item without an https address isn't playable, so it isn't evidence.
        let http = completedTTS.replacingOccurrences(of: "https://", with: "http://")
        XCTAssertEqual(SubstackCanary.RawPage(html: tagPage(http)).completedItems, [])
    }

    /// #2024: Substack moved its data into the `preloads-json` tag and the parser read nothing.
    func testAParserThatReadsNoPostDataFromASubstackPageFails() {
        let raw = SubstackCanary.RawPage(html: tagPage(completedTTS))
        let verdict = SubstackCanary.verdict(raw: raw, app: reading(absence: "no_preloads"), minimumBodyWords: 600)
        guard case .parserMissed(let why) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertTrue(why.contains("no_preloads") && why.contains("tts"), why)
        // Even a page with no audio fails: the parser can no longer read any post.
        let silent = SubstackCanary.RawPage(html: tagPage(""))
        XCTAssertTrue(SubstackCanary.verdict(raw: silent, app: reading(absence: "no_post"), minimumBodyWords: 600).isFailure)
    }

    func testACompletedItemTheParserDoesntReportFails() {
        let raw = SubstackCanary.RawPage(html: tagPage(completedTTS))
        XCTAssertTrue(SubstackCanary.verdict(raw: raw, app: reading(absence: "no_recording"), minimumBodyWords: 600).isFailure)
        XCTAssertTrue(SubstackCanary.verdict(raw: raw, app: reading(absence: "generated_voice_unreadable"), minimumBodyWords: 600).isFailure)
        XCTAssertEqual(SubstackCanary.verdict(raw: raw, app: reading(absence: "podcast_post"), minimumBodyWords: 600),
                       .noneOffered("podcast_post"))
    }

    func testAPageThatHonestlyHasNoVoicePasses() {
        let paywalled = SubstackCanary.RawPage(html: tagPage(paywalledTTS))
        XCTAssertEqual(SubstackCanary.verdict(raw: paywalled, app: reading(absence: "generated_voice_paywalled"), minimumBodyWords: 600),
                       .noneOffered("generated_voice_paywalled"))
        XCTAssertEqual(SubstackCanary.verdict(raw: SubstackCanary.RawPage(html: tagPage("")), app: reading(absence: "no_recording"), minimumBodyWords: 600),
                       .noneOffered("no_recording"))
    }

    func testABlockPageIsNotEvidence() {
        let block = SubstackCanary.RawPage(html: "<html><title>Just a moment...</title></html>")
        guard case .couldNotCheck = SubstackCanary.verdict(raw: block, app: reading(absence: "no_preloads"), minimumBodyWords: 600) else {
            return XCTFail("a challenge page must not count as a parser failure")
        }
    }

    func testTheAppsLookupDroppingAVoiceTheParserReadFailsUnlessThePostIsShort() {
        let raw = SubstackCanary.RawPage(html: tagPage(completedTTS))
        XCTAssertEqual(SubstackCanary.verdict(raw: raw, app: reading(parser: "generated_voice", absence: "x", app: "generated_voice"), minimumBodyWords: 600),
                       .voice("generated_voice"))
        XCTAssertTrue(SubstackCanary.verdict(raw: raw, app: reading(parser: "generated_voice", absence: "x"), minimumBodyWords: 600).isFailure)
        XCTAssertEqual(SubstackCanary.verdict(raw: raw, app: reading(parser: "voiceover", absence: "x", words: 120), minimumBodyWords: 600),
                       .noneOffered("short_post:120_words"))
    }

    func testFeedAndRunVerdicts() {
        XCTAssertEqual(SubstackCanary.feedVerdict([.noneOffered("generated_voice_paywalled"), .voice("generated_voice")]), .voice)
        XCTAssertEqual(SubstackCanary.feedVerdict([.voice("voiceover"), .parserMissed("x")]), .failed)
        XCTAssertEqual(SubstackCanary.feedVerdict([.couldNotCheck("x"), .noneOffered("no_recording")]), .noneOffered)
        XCTAssertEqual(SubstackCanary.feedVerdict([.couldNotCheck("x")]), .couldNotCheck)
        XCTAssertEqual(SubstackCanary.feedVerdict([]), .couldNotCheck)

        XCTAssertEqual(SubstackCanary.exitStatus([.voice, .noneOffered, .couldNotCheck]), 0)
        XCTAssertEqual(SubstackCanary.exitStatus([.voice, .failed]), 1)
        // Every feed read and none gave a voice: for these feeds the audio has gone somewhere neither reading looks.
        XCTAssertEqual(SubstackCanary.exitStatus([.noneOffered, .noneOffered]), 1)
        XCTAssertEqual(SubstackCanary.exitStatus([.noneOffered, .couldNotCheck]), 3)
        // Nothing could be checked: the run tested nothing, so it is not the soft "inconclusive" (#2596).
        XCTAssertEqual(SubstackCanary.exitStatus([.couldNotCheck, .couldNotCheck, .couldNotCheck]), 5)
        XCTAssertEqual(SubstackCanary.exitStatus([]), 5)
        // One feed unchecked beside a checked, passing one stays a warning.
        XCTAssertEqual(SubstackCanary.exitStatus([.voice, .couldNotCheck, .couldNotCheck]), 0)
        XCTAssertEqual(SubstackCanary.exitStatus([.noneOffered, .couldNotCheck, .couldNotCheck]), 3)
    }
}
