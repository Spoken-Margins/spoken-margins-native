import XCTest
@testable import SessionKit

/// Every case below is a real chunk the app plans, rendered with Supertonic 3 INT8 voice M2 at
/// speed 1 (research/C2's port of the app's runtime) and transcribed with whisper small.en, on
/// 2026-10-04 for #708. The durations are the rendered lengths.
final class SupertonicOutputCheckTests: XCTestCase {
    /// The opening of the owner's phone test plan. Whisper heard "Phone build 1744 DIF. What to
    /// try built 2026 1004 1042 from next at 1744 DevF": spoken correctly, a hash a letter at a
    /// time, at 7.5 characters a second. Build 29 handed it to the iOS voice ("too_slow_7.5").
    func testCorrectlySpokenHashesStayInTheVoice() {
        XCTAssertNil(SupertonicOutputCheck.problem(
            text: "Phone build 1744dff: what to try Built 2026-10-04 10:42 from next at 1744dff.",
            durationSeconds: 10.21))
        XCTAssertNil(SupertonicOutputCheck.problem(
            text: "Build 29 was fcc4974, tagged testflight/0.1-build-29 on 2026-09-25.", durationSeconds: 9.0))
    }

    /// Percentages, counts and times in prose all spoke correctly, at 7.9–8.5 characters a second.
    func testNumbersInProseStayInTheVoice() {
        let spokenCorrectly: [(String, Double)] = [
            ("Revenue rose 12% to $4.2 billion, while margins fell from 31% to 27%;", 8.4),
            ("the company expects 8% growth in 2027 and 6% in 2028.", 6.56),
            ("Of the 1,284 adults, 642 took the supplement and 642 took a placebo; after 3.2 years, 61 and 67 had developed diabetes.", 14.05),
            ("The ferry leaves at 7:05, 9:40 and 12:15, and returns at 10:20,", 7.96),
        ]
        for (text, seconds) in spokenCorrectly {
            XCTAssertNil(SupertonicOutputCheck.problem(text: text, durationSeconds: seconds), text)
        }
    }

    /// Every chunk whisper heard as babble ("Dierma de l'Orginival entaine…", "This is going to be a
    /// full-forwards" three times) was a run of table numbers. All of them are still flagged.
    func testTableBabbleIsStillFlagged() {
        let babble: [(String, Double)] = [
            ("Model Overall Win Tie Loss VBench 0.8889 91.1% 8.9% 0.0 T2I-CompBench 0.7421 74.2% 25.8%", 13.65),
            ("0.0 GenEval 0.8125 81.3% 12.5% 6.2% Qwen2.5-VL-7B 0.6923 69.2% 23.1%", 12.3),
            ("7.7% GPT-4o 0.8571 85.7% 14.3% 0.0 Ours 0.9286 92.9% 7.1% 0.0 Steps", 11.9),
            ("7,494 tool decisions 2,548 summaries 1,203 retries 312 failures Latency 12.4 s 3.8 s 0.9 s 0.27 s Cost", 14.84),
            ("$0.021 $0.004 $0.0007 per query, n = 1,024, p < 0.001, σ = 0.042,", 8.12),
            ("74.1 131.2 22.7 +Rerank 78.3 75.6 133.0 25.9 +Both 81.2 79.4 139.8", 11.45),
            ("29.4 Full (ours) 83.7 81.9 142.1 31.0 Δ vs base +12.3 +13.7 +17.6 +12.7.", 11.49),
            ("Year Revenue Profit 2021 4.1 0.8 2022 4.6 1.1 2023 5.2 1.4 2024 5.9", 10.54),
        ]
        for (text, seconds) in babble {
            XCTAssertEqual(SupertonicOutputCheck.problem(text: text, durationSeconds: seconds)?.hasPrefix("too_slow_"), true, text)
        }
    }

    /// Slower than any correct speech measured is flagged even without a table run.
    func testVerySlowChunkIsFlaggedWithoutATableRun() {
        XCTAssertNotNil(SupertonicOutputCheck.problem(text: String(repeating: "a", count: 77), durationSeconds: 14.3))
        XCTAssertNil(SupertonicOutputCheck.problem(text: String(repeating: "a", count: 77), durationSeconds: 11.0))
    }

    func testLengthSpeedAndShortChunkRulesAreUnchanged() {
        let prose = String(repeating: "a", count: 139)
        XCTAssertNil(SupertonicOutputCheck.problem(text: prose, durationSeconds: 9.4))
        XCTAssertNotNil(SupertonicOutputCheck.problem(text: prose, durationSeconds: 2), "lost words")
        XCTAssertNotNil(SupertonicOutputCheck.problem(text: prose, durationSeconds: 23), "past the length ceiling")
        XCTAssertNil(SupertonicOutputCheck.problem(text: "Print 11", durationSeconds: 1.6), "too short to judge")
        XCTAssertNil(SupertonicOutputCheck.problem(text: prose, durationSeconds: 4.7, speed: 2), "speed is accounted for")
        XCTAssertEqual(SupertonicOutputCheck.problem(text: prose, durationSeconds: 0), "no_audio")
    }

    func testNumberRunIgnoresUnitsAndOperatorsButBreaksOnWords() {
        XCTAssertEqual(SupertonicOutputCheck.longestNumberRun(in: "Latency 12.4 s 3.8 s 0.9 s"), 3)
        XCTAssertEqual(SupertonicOutputCheck.longestNumberRun(in: "p < 0.001, σ = 0.042,"), 2)
        XCTAssertEqual(SupertonicOutputCheck.longestNumberRun(in: "Links: PR #730, issue #643 3."), 2)
        XCTAssertEqual(SupertonicOutputCheck.longestNumberRun(in: "no numbers here"), 0)
    }
}
