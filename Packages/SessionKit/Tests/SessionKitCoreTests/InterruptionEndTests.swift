import XCTest
@testable import SessionKit

/// iOS's answer to "an interruption ended" is parsed once, here (#3180). Table-driven: the raw bit, the missing
/// options, and bits this build does not name.
final class InterruptionEndTests: XCTestCase {
    func testOptionBitsAreReadAsOneReport() {
        struct Row { let name: String; let raw: UInt; let allowsStart: Bool }
        let rows = [
            Row(name: "no options (another app kept the audio)", raw: 0, allowsStart: false),
            Row(name: "iOS says should resume", raw: 1, allowsStart: true),
            Row(name: "an unnamed bit alone says nothing", raw: 2, allowsStart: false),
            Row(name: "should resume with an unnamed bit", raw: 1 | 4, allowsStart: true),
            Row(name: "many unnamed bits, none of them the resume bit", raw: 0b1111_1110, allowsStart: false),
            Row(name: "every bit set", raw: UInt.max, allowsStart: true),
        ]
        for row in rows {
            XCTAssertEqual(InterruptionEnd(rawOptions: row.raw).iosAllowsAudioToStart, row.allowsStart, row.name)
            XCTAssertEqual(InterruptionEnd(rawOptions: row.raw).rawOptions, row.raw, "the raw value is kept for the log: \(row.name)")
        }
    }

    func testTheNotificationUserInfoIsReadAtTheEdge() {
        let key = "AVAudioSessionInterruptionOptionKey"
        struct Row { let name: String; let userInfo: [AnyHashable: Any]?; let allowsStart: Bool }
        let rows = [
            Row(name: "options with the resume bit", userInfo: [key: UInt(1)], allowsStart: true),
            Row(name: "options without it", userInfo: [key: UInt(0)], allowsStart: false),
            Row(name: "no options entry", userInfo: ["other": UInt(1)], allowsStart: false),
            Row(name: "no userInfo at all", userInfo: nil, allowsStart: false),
            Row(name: "an entry of the wrong type is not a resume", userInfo: [key: "1"], allowsStart: false),
            Row(name: "a signed number is not the unsigned option set", userInfo: [key: Int(1)], allowsStart: false),
        ]
        for row in rows {
            XCTAssertEqual(InterruptionEnd(userInfo: row.userInfo, optionsKey: key).iosAllowsAudioToStart, row.allowsStart, row.name)
        }
    }

    func testTheNamedReportsMatchTheirRawForms() {
        XCTAssertEqual(InterruptionEnd.audioMayStart, InterruptionEnd(rawOptions: 1))
        XCTAssertEqual(InterruptionEnd.audioStaysStopped, InterruptionEnd(rawOptions: 0))
        XCTAssertTrue(InterruptionEnd.audioMayStart.iosAllowsAudioToStart)
        XCTAssertFalse(InterruptionEnd.audioStaysStopped.iosAllowsAudioToStart)
    }
}
