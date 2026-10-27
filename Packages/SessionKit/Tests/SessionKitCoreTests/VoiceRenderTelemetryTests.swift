import Foundation
import XCTest
@testable import SessionKit

/// #2701: the owner's phone often falls back from Supertonic and nothing recorded how fast each voice rendered.
/// These pin the per-chunk event, the switch events and the session line.
final class VoiceRenderTelemetryTests: XCTestCase {
    private func chunk(
        voice: String = "supertonic:F1", audio: TimeInterval = 10, compute: TimeInterval = 4, speed: Double = 2,
        start: SpeechThermalLevel = .nominal, end: SpeechThermalLevel = .nominal
    ) -> VoiceRenderChunk {
        VoiceRenderChunk(
            engine: voice.split(separator: ":").first.map(String.init) ?? voice, voiceId: voice,
            audioSeconds: audio, computeSeconds: compute, listeningSpeed: speed,
            thermalAtStart: start, thermalAtEnd: end, isInBackground: false, isLowPowerModeEnabled: false
        )
    }

    func testHealthyBarIsOnePointTwoFiveTimesListeningSpeed() {
        XCTAssertEqual(VoiceHeadroom.healthyMultiple, 1.25)
        XCTAssertTrue(chunk(audio: 10, compute: 4, speed: 2).isHealthy)
        XCTAssertFalse(chunk(audio: 9.9, compute: 4, speed: 2).isHealthy)
        XCTAssertEqual(chunk(audio: 10, compute: 4, speed: 2).headroom, 1.25, accuracy: 1e-9)
    }

    func testChunkEventCarriesEveryField() {
        var telemetry = VoiceRenderTelemetry(chosenVoice: "supertonic:F1")
        let out = telemetry.handle(.chunk(chunk(start: .fair, end: .serious)), uptime: 100, isCharging: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, "voicepace.chunk")
        let f = out[0].fields
        XCTAssertEqual(f["voice"], "supertonic:F1")
        XCTAssertEqual(f["engine"], "supertonic")
        XCTAssertEqual(f["rtf"], "2.50")
        XCTAssertEqual(f["headroom"], "1.25")
        XCTAssertEqual(f["healthy"], "true")
        XCTAssertEqual(f["thermal_start"], "fair")
        XCTAssertEqual(f["thermal_end"], "serious")
        XCTAssertEqual(f["charging"], "true")
        XCTAssertEqual(f["low_power"], "false")
        XCTAssertEqual(f["background"], "false")
    }

    func testUnmeasurableChunkIsIgnored() {
        var telemetry = VoiceRenderTelemetry(chosenVoice: "kitten")
        XCTAssertTrue(telemetry.handle(.chunk(chunk(voice: "kitten", compute: 0)), uptime: 1).isEmpty)
        XCTAssertTrue(telemetry.handle(.sessionEnded, uptime: 2).isEmpty)
    }

    func testSwitchesNameFromToAndReasonIncludingTheWayBack() {
        var telemetry = VoiceRenderTelemetry(chosenVoice: "supertonic:F1")
        let toKitten = telemetry.handle(.switched(to: "kitten", reason: "device_too_warm"), uptime: 1)
        XCTAssertEqual(toKitten.first?.fields, ["from": "supertonic:F1", "to": "kitten", "reason": "device_too_warm"])
        let toIOS = telemetry.handle(.switched(to: "ios", reason: "render_too_slow"), uptime: 2)
        XCTAssertEqual(toIOS.first?.fields, ["from": "kitten", "to": "ios", "reason": "render_too_slow"])
        let back = telemetry.handle(.restored(reason: "condition_cleared"), uptime: 3)
        XCTAssertEqual(back.first?.fields, ["from": "ios", "to": "supertonic:F1", "reason": "condition_cleared"])
        XCTAssertTrue(telemetry.handle(.restored(reason: "again"), uptime: 4).isEmpty, "already on the chosen voice")
    }

    func testKittenChosenSwitchingToIOSIsAFallbackAndBackIsNot() {
        var telemetry = VoiceRenderTelemetry(chosenVoice: "kitten")
        XCTAssertTrue(telemetry.handle(.switched(to: "kitten", reason: "x"), uptime: 0).isEmpty)
        _ = telemetry.handle(.chunk(chunk(voice: "kitten")), uptime: 5)
        _ = telemetry.handle(.switched(to: "ios", reason: "memory_warning"), uptime: 6)
        _ = telemetry.handle(.restored(reason: "retry"), uptime: 7)
        let fields = telemetry.handle(.sessionEnded, uptime: 8).first?.fields
        XCTAssertEqual(fields?["fallbacks"], "1")
        XCTAssertEqual(fields?["switches"], "2")
    }

    func testSessionSummaryMedianP10AndThermalTime() throws {
        var telemetry = VoiceRenderTelemetry(chosenVoice: "supertonic:F1")
        // Real-time factors 1 to 10 (10 s of audio each).
        let computes: [Double] = [10, 5, 10.0 / 3, 2.5, 2, 10.0 / 6, 10.0 / 7, 1.25, 10.0 / 9, 1]
        for (i, compute) in computes.enumerated() {
            let level: SpeechThermalLevel = i < 3 ? .nominal : .fair
            _ = telemetry.handle(.chunk(chunk(compute: compute, start: level, end: level)), uptime: Double(i + 1) * 10)
        }
        _ = telemetry.handle(.switched(to: "ios", reason: "render_too_slow"), uptime: 101)
        let fields = try XCTUnwrap(telemetry.handle(.sessionEnded, uptime: 110).first?.fields)
        XCTAssertEqual(fields["chunks"], "10")
        XCTAssertEqual(fields["median_rtf"], "5.00")
        XCTAssertEqual(fields["p10_rtf"], "1.00")
        XCTAssertEqual(fields["fallbacks"], "1")
        XCTAssertEqual(fields["healthy_headroom"], "1.25")
        let nominal = try XCTUnwrap(Double(fields["thermal_nominal_s"] ?? ""))
        let fair = try XCTUnwrap(Double(fields["thermal_fair_s"] ?? ""))
        XCTAssertGreaterThan(nominal, 0)
        XCTAssertGreaterThan(fair, nominal)
        XCTAssertEqual(fields["thermal_serious_s"], "0.00")
    }

    func testAPauseIsNotCountedAsThermalTime() throws {
        var telemetry = VoiceRenderTelemetry(chosenVoice: "kitten")
        _ = telemetry.handle(.chunk(chunk(voice: "kitten", compute: 1)), uptime: 10)
        _ = telemetry.handle(.chunk(chunk(voice: "kitten", compute: 1)), uptime: 10_000)
        let fields = try XCTUnwrap(telemetry.handle(.sessionEnded, uptime: 10_001).first?.fields)
        let nominal = try XCTUnwrap(Double(fields["thermal_nominal_s"] ?? ""))
        XCTAssertLessThanOrEqual(nominal, VoiceRenderTelemetry.longestCountedGap + 10)
    }

    func testSessionResetsAfterItsSummary() {
        var telemetry = VoiceRenderTelemetry(chosenVoice: "kitten")
        _ = telemetry.handle(.chunk(chunk(voice: "kitten")), uptime: 5)
        XCTAssertEqual(telemetry.handle(.sessionEnded, uptime: 6).count, 1)
        XCTAssertTrue(telemetry.handle(.sessionEnded, uptime: 7).isEmpty)
    }

    func testNothingIdentifyingIsLogged() {
        var telemetry = VoiceRenderTelemetry(chosenVoice: "supertonic:F1")
        let out = telemetry.handle(.chunk(chunk()), uptime: 5)
        let keys = Set(out[0].fields.keys)
        XCTAssertTrue(keys.isDisjoint(with: ["text", "title", "url", "item", "offset"]))
    }
}
