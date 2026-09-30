import Foundation
import XCTest
@testable import SessionKit

/// Every way the kill switch can be in doubt must read as "off" (#315, #300 finding 9).
final class ServerConfigTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func configJSON(serial: Int = 3, bridge: String = #"{"enabled":true}"#, extra: String = "") -> Data {
        Data(#"{"schema":"spokenmargins.server-config","version":1,"serial":\#(serial),"checkAfterSeconds":21600,"services":{"attest":{"enabled":true},"bridge":\#(bridge)}\#(extra)}"#.utf8)
    }

    private func state(_ cached: CachedServerConfig?, build: Int = 40) -> ServerFeatureState {
        ServerFeatureGate.state(of: ServerService.bridge, cached: cached, now: now, appBuild: build)
    }

    private func fetched(_ data: Data, at date: Date? = nil, into held: CachedServerConfig? = nil) -> CachedServerConfig {
        ServerFeatureGate.merge(fetched: data, at: date ?? now, into: held)
    }

    func testAValidFreshConfigWithBridgeEnabledIsOn() {
        XCTAssertEqual(state(fetched(Self.configJSON())), .on)
    }

    func testMissingConfigIsOff() {
        XCTAssertEqual(state(nil), .off(.noConfig))
        XCTAssertEqual(state(CachedServerConfig(config: nil, fetchedAt: now)), .off(.noConfig), "the server said the config is gone")
    }

    func testMalformedConfigIsOff() {
        let cases: [String: Data] = [
            "not JSON": Data("<html>502 Bad Gateway</html>".utf8),
            "empty": Data(),
            "wrong schema": Data(#"{"schema":"something-else","version":1,"serial":1,"services":{"bridge":{"enabled":true}}}"#.utf8),
            "newer version": Data(#"{"schema":"spokenmargins.server-config","version":2,"serial":1,"services":{"bridge":{"enabled":true}}}"#.utf8),
            "enabled is a string": Self.configJSON(bridge: #"{"enabled":"yes"}"#),
            "no services": Data(#"{"schema":"spokenmargins.server-config","version":1,"serial":1}"#.utf8),
            "negative serial": Self.configJSON(serial: -1),
            "oversized": Self.configJSON(extra: #","padding":"\#(String(repeating: "x", count: 17_000))""#),
        ]
        for (name, data) in cases {
            XCTAssertEqual(state(fetched(data)), .off(.malformedConfig), name)
        }
    }

    func testAMalformedAnswerSwitchesOffEvenWithAGoodConfigCached() {
        let good = fetched(Self.configJSON())
        XCTAssertEqual(state(good), .on)
        let afterBadAnswer = fetched(Data("{".utf8), into: good)
        XCTAssertEqual(state(afterBadAnswer), .off(.malformedConfig))
        // The next good answer switches it back on.
        XCTAssertEqual(state(fetched(Self.configJSON(serial: 4), into: afterBadAnswer)), .on)
    }

    func testSwitchedOffOrAbsentServiceIsOff() {
        XCTAssertEqual(state(fetched(Self.configJSON(bridge: #"{"enabled":false}"#))), .off(.switchedOff))
        let noBridge = Data(#"{"schema":"spokenmargins.server-config","version":1,"serial":1,"services":{"attest":{"enabled":true}}}"#.utf8)
        XCTAssertEqual(state(fetched(noBridge)), .off(.switchedOff), "a service the config doesn't mention is off")
    }

    func testAConfigOlderThanAWeekIsOff() {
        let cached = fetched(Self.configJSON(), at: now.addingTimeInterval(-ServerFeatureGate.maximumConfigAge - 60))
        XCTAssertEqual(state(cached), .off(.staleConfig))
        let justInside = fetched(Self.configJSON(), at: now.addingTimeInterval(-ServerFeatureGate.maximumConfigAge + 60))
        XCTAssertEqual(state(justInside), .on)
        let fromTheFuture = fetched(Self.configJSON(), at: now.addingTimeInterval(3_600))
        XCTAssertEqual(state(fromTheFuture), .off(.staleConfig), "a clock change must not make a config fresh forever")
    }

    func testABuildBelowMinimumBuildIsOff() {
        let cached = fetched(Self.configJSON(bridge: #"{"enabled":true,"minimumBuild":41}"#))
        XCTAssertEqual(state(cached, build: 40), .off(.buildTooOld(minimumBuild: 41)))
        XCTAssertEqual(state(cached, build: 41), .on)
    }

    func testALowerSerialNeverReplacesOrRefreshesTheHeldConfig() {
        let off = fetched(Self.configJSON(serial: 5, bridge: #"{"enabled":false}"#), at: now.addingTimeInterval(-3_600))
        let replayedOn = fetched(Self.configJSON(serial: 4), into: off)
        XCTAssertEqual(replayedOn, off, "an older 'on' document can't undo a newer 'off'")
        XCTAssertEqual(state(replayedOn), .off(.switchedOff))
        // The same serial is accepted (the server re-served its current document).
        XCTAssertEqual(fetched(Self.configJSON(serial: 5, bridge: #"{"enabled":false}"#), into: off).fetchedAt, now)
    }

    func testUnknownFieldsFromANewerServerAreIgnored() {
        let data = Self.configJSON(bridge: #"{"enabled":true,"region":"eu"}"#, extra: #","message":"hello""#)
        XCTAssertEqual(state(fetched(data)), .on)
    }
}
