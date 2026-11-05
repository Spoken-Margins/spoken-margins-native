import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #3438: Type III Audio's narrations of LessWrong and EA Forum posts. The answers below are a real `find` answer for
/// a narrated LessWrong post and a real 404 (2026-11-05, descriptions and chapters trimmed); the tests never call the
/// live API.
final class TypeIIIAudioNarrationTests: XCTestCase {
    private static let lessWrong = "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/local-validity-as-a-key-to-sanity-and-civilization"
    private static let post = URL(string: lessWrong)!

    private static func answer(
        status: String = "Uploaded",
        source: String? = lessWrong,
        mp3: String? = "https://dl.type3.audio/episodes/uploaded-audio/Buzzsprout-11490580.mp3",
        duration: String = "1631"
    ) -> Data {
        var fields = [
            #""id":"Buzzsprout-11490580""#, #""status":"\#(status)""#, #""author":null"#, #""client_id":"lesswrong""#,
            #""description":"<p>Tl;dr: There&apos;s a similarity between these three concepts</p>""#, #""duration":\#(duration)"#,
            #""title":"\"Local Validity as a Key to Sanity and Civilization\" by Eliezer Yudkowsky""#, #""type":"ai_narration""#,
            #""chapters":[{"Text":"0.","AudioOffset":21000},{"Text":"i.","AudioOffset":88000}]"#
        ]
        if let source { fields.append(#""source_url":"\#(source)""#) }
        if let mp3 { fields.append(#""mp3_url":"\#(mp3)""#) }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    // MARK: - Which addresses leave the phone

    func testOnlyLessWrongAndEAForumPostAddressesAreLookedUp() {
        let yes: [(String, String)] = [
            (Self.lessWrong, Self.lessWrong),
            ("https://lesswrong.com/posts/WQFioaudEH8R7fyhm/local-validity", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/local-validity"),
            ("https://WWW.LessWrong.COM/posts/WQFioaudEH8R7fyhm/local-validity/", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/local-validity"),
            ("https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm"),
            ("https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x?utm_source=share&commentId=abc#top", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x"),
            ("https://forum.effectivealtruism.org/posts/abc123XYZ789/some-post", "https://forum.effectivealtruism.org/posts/abc123XYZ789/some-post"),
            ("https://Forum.EffectiveAltruism.org/posts/abc123XYZ789/some-post?utm_campaign=x", "https://forum.effectivealtruism.org/posts/abc123XYZ789/some-post")
        ]
        for (given, canonical) in yes {
            XCTAssertEqual(TypeIIIAudioNarration.postURL(for: URL(string: given)!)?.absoluteString, canonical, given)
        }
        let no = [
            // Scheme.
            "http://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x", "ftp://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x",
            // Other hosts, lookalikes and subdomains.
            "https://example.com/posts/WQFioaudEH8R7fyhm/x", "https://lesswrong.com.evil.example/posts/WQFioaudEH8R7fyhm/x",
            "https://evil-lesswrong.com/posts/WQFioaudEH8R7fyhm/x", "https://notlesswrong.com/posts/WQFioaudEH8R7fyhm/x",
            "https://evil.lesswrong.com/posts/WQFioaudEH8R7fyhm/x", "https://api.lesswrong.com/posts/WQFioaudEH8R7fyhm/x",
            "https://www.greaterwrong.com/posts/WQFioaudEH8R7fyhm/x", "https://effectivealtruism.org/posts/abc123XYZ789/x",
            "https://www.effectivealtruism.org/posts/abc123XYZ789/x", "https://forum.effectivealtruism.org.evil.example/posts/abc123XYZ789/x",
            "https://evil.forum.effectivealtruism.org/posts/abc123XYZ789/x", "https://substack.com/p/x", "https://www.thezvi.com/p/x",
            // Userinfo and ports.
            "https://www.lesswrong.com@evil.example/posts/WQFioaudEH8R7fyhm/x", "https://user:pw@www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x",
            "https://www.lesswrong.com:8443/posts/WQFioaudEH8R7fyhm/x",
            // Pages on the site that are not a post.
            "https://www.lesswrong.com/", "https://www.lesswrong.com", "https://www.lesswrong.com/posts", "https://www.lesswrong.com/posts/",
            "https://www.lesswrong.com/posts//x", "https://www.lesswrong.com/users/eliezer_yudkowsky", "https://www.lesswrong.com/tag/ai",
            "https://www.lesswrong.com/s/abc/p/WQFioaudEH8R7fyhm", "https://www.lesswrong.com/Posts/WQFioaudEH8R7fyhm/x",
            "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x/comment/abc", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm//",
            "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/a+b", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/a&b=c",
            "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/a%2Fb", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/a%0Ab",
            "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/a%20b", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/caf%C3%A9",
            "https://www.lesswrong.com/posts/short/x", "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm!/x",
            "https://www.lesswrong.com/?post=WQFioaudEH8R7fyhm", "https://forum.effectivealtruism.org/topics/ai"
        ]
        for given in no {
            XCTAssertNil(TypeIIIAudioNarration.postURL(for: URL(string: given)!), given)
        }
        let long = "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/" + String(repeating: "a", count: 2_100)
        XCTAssertNil(TypeIIIAudioNarration.postURL(for: URL(string: long)!), "a very long address")
        XCTAssertNil(TypeIIIAudioNarration.postURL(for: URL(string: "file:///posts/WQFioaudEH8R7fyhm/x")!))
    }

    func testTheFindRequestCarriesOnlyThePostAddress() throws {
        let post = try XCTUnwrap(TypeIIIAudioNarration.postURL(for: URL(string: Self.lessWrong + "?utm_source=share&r=1#top")!))
        let request = try XCTUnwrap(TypeIIIAudioNarration.findURL(for: post))
        XCTAssertEqual(request.absoluteString.hasPrefix("https://api.type3.audio/narration/find?url="), true)
        let query = try XCTUnwrap(URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.map(\.name), ["url"], "one parameter: no key, no name, no source tag")
        XCTAssertEqual(query.first?.value, Self.lessWrong)
    }

    // MARK: - Answers

    func testANarratedPostGivesTheRecordToStream() {
        let outcome = TypeIIIAudioNarration.interpret(data: Self.answer(), status: 200, post: Self.post, itemId: "item-1")
        XCTAssertEqual(outcome, .found(PublisherAudio(
            itemId: "item-1", audioURL: "https://dl.type3.audio/episodes/uploaded-audio/Buzzsprout-11490580.mp3",
            durationMs: 1_631_000, detectedFrom: "type3_audio_narration"
        )))
        XCTAssertEqual(
            TypeIIIAudioNarration.interpret(data: Self.answer(status: "Succeeded", duration: "12.5"), status: 200, post: Self.post, itemId: "i"),
            .found(PublisherAudio(itemId: "i", audioURL: "https://dl.type3.audio/episodes/uploaded-audio/Buzzsprout-11490580.mp3",
                                  durationMs: 12_500, detectedFrom: "type3_audio_narration")))
    }

    func testThePostTheAnswerNamesMustBeThisPost() {
        func outcome(_ source: String?) -> TypeIIIAudioNarration.Outcome {
            TypeIIIAudioNarration.interpret(data: Self.answer(source: source), status: 200, post: Self.post, itemId: "i")
        }
        guard case .found = outcome(Self.lessWrong + "/") else { return XCTFail("a trailing slash is the same post") }
        guard case .found = outcome("https://lesswrong.com/posts/WQFioaudEH8R7fyhm/local-validity-as-a-key-to-sanity-and-civilization?x=1") else {
            return XCTFail("host spelling and tracking are not a different post")
        }
        guard case .found = outcome(nil) else { return XCTFail("an answer with no source address is taken as asked for") }
        XCTAssertEqual(outcome("https://www.lesswrong.com/posts/ZZZZZZZZZZZZZZZZZ/another"), .noNarration(reason: "type3_other_post"))
        XCTAssertEqual(outcome("https://forum.effectivealtruism.org/posts/WQFioaudEH8R7fyhm/local-validity-as-a-key-to-sanity-and-civilization"),
                       .noNarration(reason: "type3_other_post"), "a crosspost on the other site has its own narration")
    }

    func testAnAnswerWithNoPlayableRecordGivesNone() {
        func outcome(_ data: Data, _ status: Int = 200) -> TypeIIIAudioNarration.Outcome {
            TypeIIIAudioNarration.interpret(data: data, status: status, post: Self.post, itemId: "i")
        }
        XCTAssertEqual(outcome(Data(#"{"message":"There is no narration for the provided URL"}"#.utf8), 404), .noNarration(reason: "type3_no_narration"))
        XCTAssertEqual(outcome(Data(), 404), .noNarration(reason: "type3_no_narration"))
        for (status, reason) in [("Failed", "type3_failed"), ("Skipped", "type3_skipped"), ("too_long__20K_words", "type3_toolong20kwords"), ("", "type3_unknown")] {
            XCTAssertEqual(outcome(Self.answer(status: status)), .noNarration(reason: reason), status)
        }
        // The recording must stream over HTTPS from Type III's own host.
        for mp3 in [
            "http://dl.type3.audio/episodes/a.mp3", "https://evil.example/a.mp3", "https://type3.audio.evil.example/a.mp3",
            "https://eviltype3.audio/a.mp3", "https://dl.type3.audio:8443/a.mp3", "https://user@dl.type3.audio/a.mp3", "file:///a.mp3", "not a url", ""
        ] {
            XCTAssertEqual(outcome(Self.answer(mp3: mp3)), .noNarration(reason: "type3_no_audio_address"), mp3)
        }
        XCTAssertEqual(outcome(Self.answer(mp3: nil)), .noNarration(reason: "type3_no_audio_address"))
    }

    func testAnUnfinishedNarrationIsTriedAgainLaterAndAFinalOneIsNot() {
        for status in ["NotStarted", "Running", "GettingHTML", "ProcessingHTML", "ReviewQueued", "Reviewing"] {
            guard case .noNarration(let reason) = TypeIIIAudioNarration.interpret(data: Self.answer(status: status), status: 200, post: Self.post, itemId: "i") else {
                return XCTFail(status)
            }
            XCTAssertTrue(TypeIIIAudioNarration.isNotYet(reason: reason), status)
        }
        for reason in ["type3_no_narration", "type3_failed", "type3_skipped", "type3_other_post", "type3_no_audio_address", "voiceover_pending", ""] {
            XCTAssertFalse(TypeIIIAudioNarration.isNotYet(reason: reason), reason)
        }
        var ledger = VoiceoverLookupLedger()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ledger.claim(itemId: "lw", now: start))
        ledger.record(status: "none:type3_running", itemId: "lw", now: start)
        XCTAssertFalse(ledger.mayLookUp(itemId: "lw", now: start.addingTimeInterval(10)), "waits before looking again")
        XCTAssertTrue(ledger.mayLookUp(itemId: "lw", now: start.addingTimeInterval(61)))
        XCTAssertTrue(ledger.claim(itemId: "none", now: start))
        ledger.record(status: "none:type3_no_narration", itemId: "none", now: start)
        XCTAssertFalse(ledger.mayLookUp(itemId: "none", now: start.addingTimeInterval(3_600)), "no narration is final for the launch")
    }

    func testABadAnswerIsAFailureNotAVerdict() {
        func outcome(_ data: Data, _ status: Int) -> TypeIIIAudioNarration.Outcome {
            TypeIIIAudioNarration.interpret(data: data, status: status, post: Self.post, itemId: "i")
        }
        // A busy Type III is tried again after a wait; any other refusal is final, so a post is not asked about on every open.
        for busy in [408, 429, 500, 503] {
            XCTAssertEqual(outcome(Data(), busy), .noNarration(reason: "type3_busy"), "\(busy)")
        }
        for refused in [400, 401, 403, 410] {
            XCTAssertEqual(outcome(Data(), refused), .noNarration(reason: "type3_http_\(refused)"), "\(refused)")
        }
        XCTAssertTrue(TypeIIIAudioNarration.isNotYet(reason: "type3_busy"))
        XCTAssertFalse(TypeIIIAudioNarration.isNotYet(reason: "type3_http_403"))
        XCTAssertEqual(outcome(Data("<html>".utf8), 200), .failed("unreadable_answer"))
        XCTAssertEqual(outcome(Data("[1]".utf8), 200), .failed("unreadable_answer"))
        XCTAssertEqual(outcome(Data(count: TypeIIIAudioNarration.maximumResponseBytes + 1), 200), .failed("unreadable_answer"))
    }

    // MARK: - Calls made

    func testOneFindCallForACoveredPostAndNoneForAnythingElse() async {
        let calls = Calls()
        let fetch: TypeIIIAudioNarration.Fetch = { url in
            calls.add(url)
            return (Self.answer(), 200)
        }
        let found = await TypeIIIAudioNarration.find(url: URL(string: Self.lessWrong + "?utm_source=share")!, itemId: "i", fetch: fetch)
        guard case .found = found else { return XCTFail("\(found)") }
        XCTAssertEqual(calls.urls.count, 1)
        XCTAssertEqual(calls.urls.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }, Self.lessWrong)

        for other in ["https://example.com/posts/WQFioaudEH8R7fyhm/x", "http://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x", "https://garymarcus.substack.com/p/x",
                      "https://www.lesswrong.com/", ""] {
            let outcome = await TypeIIIAudioNarration.find(url: URL(string: other) ?? URL(string: "about:blank")!, itemId: "i", fetch: fetch)
            XCTAssertEqual(outcome, .notCovered, other)
        }
        XCTAssertEqual(calls.urls.count, 1, "no other address reached the network")
    }

    func testAFailedCallIsReportedAndNotRetried() async {
        let calls = Calls()
        let outcome = await TypeIIIAudioNarration.find(url: Self.post, itemId: "i") { url in
            calls.add(url)
            throw URLError(.notConnectedToInternet)
        }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(calls.urls.count, 1)
    }

    func testTheSharedPostLookupSendsLessWrongPostsToTypeIIIAndReadsNoPage() async {
        let pages = Calls(), narrations = Calls()
        let fetchPage: SharedPostVoiceoverLookup.FetchPage = { url in
            pages.add(url)
            return ("<html></html>", url)
        }
        let fetchNarration: TypeIIIAudioNarration.Fetch = { url in
            narrations.add(url)
            return (Self.answer(), 200)
        }
        let memo = FetchedPageMemo()
        memo.remember(Data("<html></html>".utf8), for: Self.post)
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: Self.post, articleURL: Self.lessWrong, itemId: "i", fetched: memo, fetchPage: fetchPage, fetchNarration: fetchNarration
        )
        guard case .found(let audio) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(audio.detectedFrom, "type3_audio_narration")
        XCTAssertEqual(narrations.urls.count, 1)
        XCTAssertEqual(pages.urls.count, 0, "the post page is not fetched for Type III's sites")

        // A Substack post does not reach Type III.
        let substack = URL(string: "https://garymarcus.substack.com/p/breaking")!
        _ = await SharedPostVoiceoverLookup.find(sharedURL: substack, articleURL: substack.absoluteString, itemId: "j", fetched: nil,
                                                 fetchPage: fetchPage, fetchNarration: fetchNarration)
        XCTAssertEqual(narrations.urls.count, 1)
        XCTAssertEqual(pages.urls.count, 1)

        // Without a narration fetcher a covered address finds nothing and sends nothing.
        let none = await SharedPostVoiceoverLookup.find(sharedURL: Self.post, articleURL: Self.lessWrong, itemId: "k", fetched: nil, fetchPage: fetchPage)
        XCTAssertEqual(none, .notSubstack)
        XCTAssertEqual(pages.urls.count, 1)
    }

    func testAPostWithNoNarrationFallsBackToNormalReading() async {
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: Self.post, articleURL: Self.lessWrong, itemId: "i", fetched: nil,
            fetchPage: { _ in XCTFail("no page"); throw URLError(.cancelled) },
            fetchNarration: { _ in (Data(#"{"message":"There is no narration for the provided URL"}"#.utf8), 404) }
        )
        XCTAssertEqual(outcome, .noVoiceover(reason: "type3_no_narration"), "an answer of none, not a failure the listener sees")
    }

    func testOpeningOrPlayingAPostLooksItUpOnlyForCoveredAddresses() {
        func decision(_ address: String?) -> VoiceoverLookupDecision {
            .decide(textCharacterCount: 5_000, externalReference: address, hasPublisherAudioRecord: false, alreadyLookedUp: false)
        }
        XCTAssertEqual(decision(Self.lessWrong), .lookUp(address: Self.lessWrong))
        XCTAssertEqual(decision("https://forum.effectivealtruism.org/posts/abc123XYZ789/x"), .lookUp(address: "https://forum.effectivealtruism.org/posts/abc123XYZ789/x"))
        XCTAssertEqual(decision("https://example.com/posts/WQFioaudEH8R7fyhm/x"), .skip(reason: "not_substack_address"))
        XCTAssertEqual(decision("http://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x"), .skip(reason: "not_substack_address"))
        XCTAssertEqual(VoiceoverLookupDecision.decide(textCharacterCount: 5_000, externalReference: Self.lessWrong, hasPublisherAudioRecord: true, alreadyLookedUp: false),
                       .skip(reason: "has_record"))
        XCTAssertEqual(VoiceoverLookupDecision.decide(textCharacterCount: 5_000, externalReference: Self.lessWrong, hasPublisherAudioRecord: false, alreadyLookedUp: true),
                       .skip(reason: "already_looked_up"))
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    func add(_ url: URL) { lock.withLock { recorded.append(url) } }
    var urls: [URL] { lock.withLock { recorded } }
}
