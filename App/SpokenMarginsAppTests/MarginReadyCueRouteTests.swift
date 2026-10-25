import AVFoundation
import XCTest
import SessionKit

/// #2594: SessionKit decides the ready cue's level from AVAudioSession port names as strings. This pins that the
/// strings are the ones iOS really uses, so a renamed port cannot quietly send headphones back to the speaker level.
final class MarginReadyCueRouteTests: XCTestCase {
    func testTheRealHeadphonePortsAreHeadphones() {
        let ports: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .usbAudio]
        for port in ports {
            XCTAssertEqual(ReadyCueOutputRoute(outputPortTypes: [port.rawValue]), .headphones, port.rawValue)
        }
    }

    func testTheSpeakerAndTheOtherRoutesKeepTheSpeakerLevel() {
        let ports: [AVAudioSession.Port] = [.builtInSpeaker, .builtInReceiver, .airPlay, .carAudio, .lineOut, .HDMI]
        for port in ports {
            XCTAssertEqual(ReadyCueOutputRoute(outputPortTypes: [port.rawValue]), .speaker, port.rawValue)
        }
    }
}
