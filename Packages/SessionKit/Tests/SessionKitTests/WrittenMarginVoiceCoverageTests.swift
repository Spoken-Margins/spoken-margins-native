import Foundation
import XCTest
import SessionKit
@testable import SessionKitAudio

/// #3402: the count asks `canRead`, the render asks `voice(forNote:)`. If the two disagree, a note is counted as new that no
/// voice reads (the bug), or a note a voice could read is never offered. So they are held together here, row by row.
final class WrittenMarginVoiceCoverageTests: XCTestCase {
    private let notes = [
        "Great point.", "Café au lait, très bien, merci beaucoup à tous.", "これは素晴らしい港です。", "ok はい", "你好世界",
        "Great point. 你好世界。Listen again.", "안녕하세요", "यह बहुत अच्छा है", "สวัสดีครับ", "مرحبا بالعالم", "ہم سب", "שלום עולם",
        "Привет, мир", "Γειά σου κόσμε", "வணக்கம்", "বাংলা", "こんにちは שלום", "한글 中文", "🎧 https://example.com",
    ]
    private let voiceSets: [Set<String>] = [
        [], ["ja"], ["zh-Hans"], ["zh-Hant"], ["ko"], ["hi"], ["th"], ["ar"], ["he"], ["ru"], ["uk"], ["el"], ["ja", "hi"],
        Set(WrittenMarginVoice.coverage.map(\.language)),
    ]

    func testCanReadGivesTheRendersAnswerForEveryNoteAndEveryVoiceSet() {
        for voices in voiceSets {
            for note in notes {
                let render = WrittenMarginVoice.voice(
                    forNote: WrittenMarginSpeech.speakable(note), voiceFor: { voices.contains($0) ? "v.\($0)" : nil },
                    defaultVoice: { "v.default" }
                )
                XCTAssertEqual(WrittenMarginVoice.canRead(note: note, hasVoice: voices.contains), render != nil, "\(note) with \(voices.sorted())")
            }
        }
    }

    #if canImport(AVFoundation)
    // Real AVFoundation: the language list the count uses finds what the render finds on this machine.
    func testTheInstalledLanguagesMatchWhatTheRenderFinds() {
        let samples: [String: String] = [
            "ja": "こんにちは", "ko": "안녕하세요", "hi": "यह बहुत अच्छा है", "th": "สวัสดีครับ", "ar": "مرحبا بالعالم", "he": "שלום עולם", "el": "Γειά σου κόσμε",
        ]
        let installed = WrittenMarginVoiceCoverage.installedLanguages()
        for (language, note) in samples {
            let render = WrittenMarginReader.installedVoice(forNote: note) != nil
            XCTAssertEqual(WrittenMarginVoice.canRead(note: note, hasVoice: installed.contains), render, "\(language) has \(installed.contains(language))")
        }
    }
    #endif

    private final class Voices: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Set<String>
        private var count = 0
        var lookups: Int { lock.withLock { count } }
        init(_ value: Set<String>) { self.value = value }
        func set(_ new: Set<String>) { lock.withLock { value = new } }
        func read() -> Set<String> { lock.withLock { count += 1; return value } }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    func testALatinNoteNeverAsksWhichVoicesAreHere() {
        let voices = Voices([])
        let coverage = WrittenMarginVoiceCoverage(findVoices: { voices.read() })
        XCTAssertTrue(coverage.canRead("Great point."))
        XCTAssertTrue(coverage.canRead("🎧"))
        XCTAssertFalse(coverage.canRead("வணக்கம்"), "a script no voice language covers has its answer at once")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(voices.lookups, 0)
    }

    func testAnOtherScriptNoteIsYesUntilTheLookupLandsThenFollowsTheVoices() {
        let voices = Voices([])
        let coverage = WrittenMarginVoiceCoverage(findVoices: { voices.read() })
        let told = expectation(description: "the screens are told the first lookup changed the answer")
        coverage.telling { told.fulfill() }
        XCTAssertTrue(coverage.canRead("यह बहुत अच्छा है"), "as before this: offered until the voices are known")
        wait(for: [told], timeout: 5)
        XCTAssertFalse(coverage.canRead("यह बहुत अच्छा है"))

        // A voice is downloaded: the same note reads, with nothing stored anywhere.
        voices.set(["hi"])
        let again = expectation(description: "told again")
        coverage.telling { again.fulfill() }
        coverage.lookUp()
        wait(for: [again], timeout: 5)
        XCTAssertTrue(coverage.canRead("यह बहुत अच्छा है"))
    }

    /// PR #3606's audit: the arrival reads its count once and nothing redraws it, so on the first such note since launch
    /// it said "1 new Margin" about a note no voice here can read. The count's own question starts the lookup.
    func testACountReadOnceWaitsForTheLookupItStarted() async {
        let voices = Voices([])
        let coverage = WrittenMarginVoiceCoverage(findVoices: { Thread.sleep(forTimeInterval: 0.2); return voices.read() })
        let count = await coverage.onceVoicesAreKnown(upTo: 10) { coverage.canRead("यह बहुत अच्छा है") ? 1 : 0 }
        XCTAssertEqual(count, 0)
    }

    func testACountReadAgainWhenTheLookupLandedWhileItWasBeingRead() async {
        let voices = Voices([])
        let coverage = WrittenMarginVoiceCoverage(findVoices: { voices.read() })
        let count = await coverage.onceVoicesAreKnown(upTo: 10) { () -> Int in
            let answer = coverage.canRead("यह बहुत अच्छा है")
            try? await Task.sleep(for: .milliseconds(300)) // the store read is slower than the lookup
            return answer ? 1 : 0
        }
        XCTAssertEqual(count, 0)
    }

    func testACountWithNoLookupToWaitForIsReadOnce() async {
        let voices = Voices([])
        let coverage = WrittenMarginVoiceCoverage(findVoices: { voices.read() })
        let reads = Calls()
        let count = await coverage.onceVoicesAreKnown(upTo: 10) { () -> Int in
            reads.add()
            return coverage.canRead("Great point.") ? 1 : 0
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(reads.value, 1, "an English note costs no second read")
        XCTAssertEqual(voices.lookups, 0, "and no voice lookup")
    }

    /// A voice lookup that hangs never holds a finished import: the count stands as it was, as it did before this.
    func testACountDoesNotWaitLongerThanItsLimit() async {
        let release = DispatchSemaphore(value: 0)
        let coverage = WrittenMarginVoiceCoverage(findVoices: { release.wait(); return [] })
        let count = await coverage.onceVoicesAreKnown(upTo: 0.1) { coverage.canRead("यह बहुत अच्छा है") ? 1 : 0 }
        XCTAssertEqual(count, 1)
        release.signal()
    }

    func testALookupThatChangesNothingTellsNobody() {
        let voices = Voices(Set(WrittenMarginVoice.coverage.map(\.language)))
        let coverage = WrittenMarginVoiceCoverage(findVoices: { voices.read() })
        let calls = Calls()
        coverage.telling { calls.add() }
        coverage.lookUp()
        coverage.lookUp()
        XCTAssertEqual(calls.value, 0)
    }
}
