import XCTest
@testable import SessionKit

/// #1506: on Bluetooth headphones playing music-profile audio, opening the headset microphone made iOS switch the
/// headphones to the hands-free profile, which took over a second. The phone's microphone avoids the switch.
final class RecordingInputPolicyTests: XCTestCase {
    func testHeadphonesPlayingOverA2DPRecordFromThePhoneAndStayOnA2DP() {
        XCTAssertEqual(RecordingInputPolicy.choice(outputPortTypes: ["BluetoothA2DPOutput"]), .phoneMicrophoneKeepingA2DP)
    }

    func testEveryOtherRouteKeepsTheEarlierBehavior() {
        let routes: [(String, [String])] = [
            ("already on the hands-free profile (a call)", ["BluetoothHFP"]),
            ("both reported at once", ["BluetoothA2DPOutput", "BluetoothHFP"]),
            ("phone speaker", ["Speaker"]),
            ("receiver", ["Receiver"]),
            ("wired headphones", ["Headphones"]),
            ("USB audio", ["USBAudio"]),
            ("Bluetooth LE audio", ["BluetoothLE"]),
            ("no output reported", []),
            ("a lookalike name", ["BluetoothA2DP", "a2dp", "bluetoothA2DPOutput", ""]),
        ]
        for (name, ports) in routes {
            XCTAssertEqual(RecordingInputPolicy.choice(outputPortTypes: ports), .headsetMicrophoneAllowed, name)
        }
    }

    func testThePortNamesAreTheOnesTheAudioSessionReports() {
        // AVAudioSession.Port raw values; a rename here would silently turn the policy off.
        XCTAssertEqual(RecordingInputPolicy.Port.bluetoothA2DP, "BluetoothA2DPOutput")
        XCTAssertEqual(RecordingInputPolicy.Port.bluetoothHandsFree, "BluetoothHFP")
    }

    func testTheChoiceIsNamedInDiagnostics() {
        XCTAssertEqual(RecordingInputChoice.phoneMicrophoneKeepingA2DP.rawValue, "phone_microphone_a2dp_kept")
        XCTAssertEqual(RecordingInputChoice.headsetMicrophoneAllowed.rawValue, "headset_microphone_allowed")
    }
}
