import Foundation
import XCTest
@testable import SessionKit

final class PocketSpeedCheckTests: XCTestCase {
    private var suiteName = ""
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    override func setUp() {
        super.setUp()
        suiteName = "pocket-speed-check-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> PocketSpeedCheckStore {
        PocketSpeedCheckStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func check(
        gate: PocketDeviceGate = PocketDeviceGate(),
        modelKey: String = "rev-1",
        deviceKey: String = "iPhone17,1",
        at date: Date = PocketSpeedCheckTests.start
    ) -> PocketSpeedCheck {
        PocketSpeedCheck(gate: gate, store: store(), modelKey: modelKey, deviceKey: deviceKey, now: { date })
    }

    /// A render counter the `@Sendable` closure can share.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var sentences: [String] = []
        var value: Int { lock.withLock { count } }
        var texts: [String] { lock.withLock { sentences } }
        func note(_ text: String) { lock.withLock { count += 1; sentences.append(text) } }
    }

    private struct RenderFailure: Error {}

    // MARK: Decisions from a timed render

    func testAFastRenderPassesAndIsRemembered() async {
        let calls = Calls()
        let subject = check()
        let outcome = await subject.check(conditions: SpeechEngineConditions()) { text in
            calls.note(text)
            return PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2)
        }
        XCTAssertEqual(outcome, .status(.passed(speed: 3)))
        XCTAssertEqual(calls.texts, [PocketDeviceGate.checkSentence], "it renders the fixed sentence, so every phone is timed on the same work")
        let currentStatus = await subject.currentStatus()
        XCTAssertEqual(currentStatus, .passed(speed: 3))
        XCTAssertTrue(currentStatus.allowsPocket)
    }

    func testASlowRenderIsTooSlowAndKeepsPocketOff() async {
        let subject = check()
        let outcome = await subject.check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6)
        }
        XCTAssertEqual(outcome, .status(.tooSlow(speed: 1, threshold: 2)))
        XCTAssertFalse(outcome == .status(.passed(speed: 1)))
        let currentStatus = await subject.currentStatus()
        XCTAssertFalse(currentStatus.allowsPocket)
    }

    func testBorderlineMatchesTheGate() async {
        let atThreshold = await check().check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 3)
        }
        XCTAssertEqual(atThreshold, .status(.passed(speed: 2)))
        UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
        let justBelow = await check().check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 3.01)
        }
        XCTAssertEqual(justBelow, .status(.tooSlow(speed: 6 / 3.01, threshold: 2)))
    }

    func testAnUnusableRenderStoresNothingAndMayBeMeasuredAgain() async {
        let table: [(String, PocketRenderMeasurement)] = [
            ("too little audio", PocketRenderMeasurement(audioSeconds: 1, renderSeconds: 0.2)),
            ("zero render time", PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 0)),
            ("negative render time", PocketRenderMeasurement(audioSeconds: 6, renderSeconds: -1)),
            ("NaN render time", PocketRenderMeasurement(audioSeconds: 6, renderSeconds: .nan)),
            ("infinite audio", PocketRenderMeasurement(audioSeconds: .infinity, renderSeconds: 1)),
        ]
        for (name, measurement) in table {
            let subject = check()
            let outcome = await subject.check(conditions: SpeechEngineConditions()) { _ in measurement }
            XCTAssertEqual(outcome, .inconclusive, name)
            let currentStatus = await subject.currentStatus()
            XCTAssertEqual(currentStatus, .notChecked, name)
            XCTAssertNil(store().record(modelKey: "rev-1", deviceKey: "iPhone17,1"), "\(name): nothing is stored")
        }
        let retry = await check().check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2)
        }
        XCTAssertEqual(retry, .status(.passed(speed: 3)), "the next try can still pass")
    }

    func testARenderThatThrowsStoresNothing() async {
        let subject = check()
        let outcome = await subject.check(conditions: SpeechEngineConditions()) { _ in throw RenderFailure() }
        XCTAssertEqual(outcome, .renderFailed)
        let currentStatus = await subject.currentStatus()
        XCTAssertEqual(currentStatus, .notChecked)
        XCTAssertNil(store().record(modelKey: "rev-1", deviceKey: "iPhone17,1"), "nothing is stored")
    }

    // MARK: When it may measure

    func testAHotPhoneIsNotMeasured() async {
        let calls = Calls()
        for thermal in [SpeechThermalLevel.serious, .critical] {
            let outcome = await check().check(conditions: SpeechEngineConditions(thermal: thermal)) { text in
                calls.note(text)
                return PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6)
            }
            XCTAssertEqual(outcome, .deferred(.hot), "\(thermal)")
        }
        XCTAssertEqual(calls.value, 0, "no render, so a phone that is merely warm now isn't marked too slow")
    }

    func testDeferralFollowsTheSpeechEnginePolicy() {
        let table: [SpeechEngineConditions] = [
            SpeechEngineConditions(), SpeechEngineConditions(thermal: .fair), SpeechEngineConditions(thermal: .serious),
            SpeechEngineConditions(thermal: .critical), SpeechEngineConditions(isLowPowerModeEnabled: true),
            SpeechEngineConditions(isRecoveringFromMemoryWarning: true),
            SpeechEngineConditions(thermal: .critical, isRecoveringFromMemoryWarning: true),
        ]
        for conditions in table {
            XCTAssertEqual(
                PocketSpeedCheck.deferral(for: conditions) == nil,
                SpeechEnginePolicy.onDeviceRenderingBlock(conditions) == nil,
                "\(conditions)"
            )
        }
        XCTAssertEqual(
            PocketSpeedCheck.deferral(for: SpeechEngineConditions(thermal: .critical, isRecoveringFromMemoryWarning: true)),
            .recoveringFromMemoryWarning
        )
    }

    func testAPhoneRecoveringFromAMemoryWarningIsNotMeasured() async {
        let outcome = await check().check(
            conditions: SpeechEngineConditions(isRecoveringFromMemoryWarning: true)
        ) { _ in PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6) }
        XCTAssertEqual(outcome, .deferred(.recoveringFromMemoryWarning))
    }

    func testLowPowerModeAndFairHeatDoNotStopTheCheck() async {
        let outcome = await check().check(
            conditions: SpeechEngineConditions(thermal: .fair, isLowPowerModeEnabled: true, isOnExternalPower: false)
        ) { _ in PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2) }
        XCTAssertEqual(outcome, .status(.passed(speed: 3)), "the reference speed was taken with Low Power Mode on")
    }

    func testAStoredAnswerIsUsedEvenWhenThePhoneIsHot() async {
        let first = check()
        _ = await first.check(conditions: SpeechEngineConditions()) { _ in PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2) }
        let calls = Calls()
        let outcome = await check().check(conditions: SpeechEngineConditions(thermal: .critical)) { text in
            calls.note(text)
            return PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 60)
        }
        XCTAssertEqual(outcome, .status(.passed(speed: 3)))
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: What it remembers

    func testTheAnswerSurvivesARelaunch() async {
        _ = await check().check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6)
        }
        let relaunched = await check().currentStatus()
        XCTAssertEqual(relaunched, .tooSlow(speed: 1, threshold: 2))
    }

    func testANewModelIsTimedAgain() async {
        _ = await check(modelKey: "rev-1").check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6)
        }
        let other = check(modelKey: "rev-2")
        let before = await other.currentStatus()
        XCTAssertEqual(before, .notChecked)
        let outcome = await other.check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2)
        }
        XCTAssertEqual(outcome, .status(.passed(speed: 3)))
        XCTAssertNil(store().record(modelKey: "rev-1", deviceKey: "iPhone17,1"), "the record belongs to the files it was timed on")
    }

    func testATooSlowRenderExpiresAndAPassingOneDoesNot() async {
        let slow = check()
        _ = await slow.check(conditions: SpeechEngineConditions()) { _ in PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6) }

        let almost = check(at: Self.start.addingTimeInterval(30 * Self.day - 1))
        let stillSlow = await almost.currentStatus()
        XCTAssertEqual(stillSlow, .tooSlow(speed: 1, threshold: 2))
        let expired = check(at: Self.start.addingTimeInterval(30 * Self.day))
        let afterThirtyDays = await expired.currentStatus()
        XCTAssertEqual(afterThirtyDays, .notChecked, "the voice gets one more try")

        store().forget()
        let fast = check()
        _ = await fast.check(conditions: SpeechEngineConditions()) { _ in PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2) }
        let later = check(at: Self.start.addingTimeInterval(400 * Self.day))
        let afterAYear = await later.currentStatus()
        XCTAssertEqual(afterAYear, .passed(speed: 3))
    }

    func testATooSlowRenderDatedInTheFutureExpiresPastADaysSkew() async {
        let slow = check()
        _ = await slow.check(conditions: SpeechEngineConditions()) { _ in PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6) }
        let slightlyEarlier = check(at: Self.start.addingTimeInterval(-Self.day))
        let withinSkew = await slightlyEarlier.currentStatus()
        XCTAssertEqual(withinSkew, .tooSlow(speed: 1, threshold: 2), "a clock a day behind is still the same record")
        let wrongClock = check(at: Self.start.addingTimeInterval(-Self.day - 1))
        let pastSkew = await wrongClock.currentStatus()
        XCTAssertEqual(pastSkew, .notChecked, "a record from a clock that was wrong can't stay for years")
    }

    func testAPassingRenderFromAnotherPhoneIsNotTrusted() async {
        // A backup restores UserDefaults onto a replacement phone: the old phone's pass says nothing about this one.
        let fast = check(deviceKey: "iPhone17,1")
        _ = await fast.check(conditions: SpeechEngineConditions()) { _ in PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2) }
        let replacement = check(deviceKey: "iPhone12,1")
        let before = await replacement.currentStatus()
        XCTAssertEqual(before, .notChecked)
        XCTAssertFalse(before.allowsPocket)
        let outcome = await replacement.check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6)
        }
        XCTAssertEqual(outcome, .status(.tooSlow(speed: 1, threshold: 2)), "it is timed itself")
    }

    func testANewReferenceSpeedDecidesAgainFromTheStoredRender() async {
        // 6 s of audio in 4 s is 1.5x: too slow against the floor of 2, but fine once the owner's phone is known to reach 1.6.
        _ = await check().check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 4)
        }
        let strict = await check().currentStatus()
        XCTAssertEqual(strict, .tooSlow(speed: 1.5, threshold: 2))
        let lenient = await check(gate: PocketDeviceGate(referencePhoneSpeed: 1.6, margin: 0.25)).currentStatus()
        XCTAssertEqual(lenient, .passed(speed: 1.5), "threshold 1.6 - 0.25 = 1.35, with no second timing")
    }

    func testAnUnreadableStoredRecordIsNotChecked() async {
        UserDefaults(suiteName: suiteName)!.set(Data("not json".utf8), forKey: PocketSpeedCheckStore.defaultsKey)
        let status = await check().currentStatus()
        XCTAssertEqual(status, .notChecked)
        UserDefaults(suiteName: suiteName)!.set("a string", forKey: PocketSpeedCheckStore.defaultsKey)
        let other = await check().currentStatus()
        XCTAssertEqual(other, .notChecked)
    }

    func testRemovingTheVoiceForgetsTheRender() async {
        _ = await check().check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 6)
        }
        store().forget()
        let status = await check().currentStatus()
        XCTAssertEqual(status, .notChecked)
    }

    // MARK: One at a time

    func testCallsThatOverlapShareOneRender() async throws {
        let calls = Calls()
        let gate = AsyncGate()
        let subject = check()
        async let first = subject.check(conditions: SpeechEngineConditions()) { text in
            calls.note(text)
            await gate.wait()
            return PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2)
        }
        try await waitUntil { calls.value == 1 }
        async let second = subject.check(conditions: SpeechEngineConditions()) { text in
            calls.note(text)
            return PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 60)
        }
        // The first render is still held, so the second call can only have joined it once it is counted.
        try await waitUntil { await subject.joinedCallers == 1 }
        await gate.open()
        let results = await [first, second]
        XCTAssertEqual(results, [.status(.passed(speed: 3)), .status(.passed(speed: 3))])
        XCTAssertEqual(calls.value, 1, "the second caller took the first render's answer")
    }

    func testACallAfterAFailedRenderStartsAFreshOne() async {
        let subject = check()
        let first = await subject.check(conditions: SpeechEngineConditions()) { _ in throw RenderFailure() }
        XCTAssertEqual(first, .renderFailed)
        let second = await subject.check(conditions: SpeechEngineConditions()) { _ in
            PocketRenderMeasurement(audioSeconds: 6, renderSeconds: 2)
        }
        XCTAssertEqual(second, .status(.passed(speed: 3)), "not the old failure")
    }

    /// Waits for `condition` itself, with a deadline that is only a ceiling (docs/testing.md).
    private func waitUntil(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(30)
        while await !condition() {
            if Date() > deadline {
                XCTFail("condition never became true", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    /// A gate the test controls, so no test waits on the clock.
    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
}
