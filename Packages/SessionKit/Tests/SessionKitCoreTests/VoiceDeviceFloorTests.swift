import Foundation
import SessionKit
import XCTest

/// The A14 floor for the Neural Engine voices (#2700): which devices pass, and that entries without a floor
/// behave as before.
final class VoiceDeviceFloorTests: XCTestCase {
    func testModelIdentifiersMapToTheirChip() {
        let rows: [(String, Int?, String)] = [
            ("iPhone12,8", 13, "iPhone SE (2nd) A13"),
            ("iPhone12,1", 13, "iPhone 11 A13"),
            ("iPhone13,1", 14, "iPhone 12 mini A14"),
            ("iPhone13,4", 14, "iPhone 12 Pro Max A14"),
            ("iPhone14,6", 15, "iPhone SE (3rd) A15"),
            ("iPhone14,7", 15, "iPhone 14 A15"),
            ("iPhone15,4", 16, "iPhone 15 A16"),
            ("iPhone17,5", 18, "iPhone 16e A18"),
            ("iPhone18,1", 19, "iPhone 17 Pro A19"),
            ("iPhone40,1", 41, "a phone newer than the table"),
            ("iPhone8,1", 9, "iPhone 6s A9, oldest numbered the same way"),
            ("iPhone7,2", nil, "before the numbering held"),
            ("iPad11,6", 12, "iPad (8th) A12"),
            ("iPad12,1", 13, "iPad (9th) A13"),
            ("iPad13,1", 14, "iPad Air (4th) A14"),
            ("iPad13,18", 14, "iPad (10th) A14"),
            ("iPad13,8", 14, "iPad Pro M1"),
            ("iPad14,1", 15, "iPad mini (6th) A15"),
            ("iPad16,3", 17, "iPad Pro M4"),
            ("iPad30,1", 17, "an iPad newer than the table"),
            ("iPad9,1", nil, "a major number the table skips"),
            ("Mac14,2", 14, "Apple silicon Mac running the iPad app"),
            ("MacBookPro18,1", 14, "older Mac identifier style"),
            ("RealityDevice14,1", 14, "Vision Pro"),
            ("arm64", nil, "simulator or Mac without a model identifier"),
            ("x86_64", nil, "Intel simulator"),
            ("", nil, "empty"),
            ("iPhone13", nil, "no minor number"),
            ("iPhone13,", nil, "empty minor number"),
            ("iPhone,2", nil, "empty major number"),
            ("iphone13,2", nil, "lowercase"),
            ("iPhone13,2 ", nil, "trailing space"),
            (" iPhone13,2", nil, "leading space"),
            ("iPhone13,2\n", nil, "trailing newline"),
            ("iPhone1３,2", nil, "full-width digit"),
            ("iPhone13,2,1", nil, "three parts"),
            ("Watch6,1", nil, "not a device that runs the app"),
        ]
        for (identifier, expected, why) in rows {
            XCTAssertEqual(VoiceDeviceFloor.generation(ofMachine: identifier), expected, "\(why): \(identifier.debugDescription)")
        }
    }

    func testTheA14FloorSplitsTheIPhone11FromTheIPhone12() {
        let floored = entry(minimumChip: VoiceDeviceFloor.neuralVoiceFloor)
        XCTAssertFalse(VoiceDeviceFloor.allows(floored, deviceGeneration: VoiceDeviceFloor.generation(ofMachine: "iPhone12,1")))
        XCTAssertTrue(VoiceDeviceFloor.allows(floored, deviceGeneration: VoiceDeviceFloor.generation(ofMachine: "iPhone13,2")))
        XCTAssertTrue(VoiceDeviceFloor.allows(floored, deviceGeneration: VoiceDeviceFloor.generation(ofMachine: "iPhone18,2")))
    }

    func testAnEntryWithoutAFloorIsAllowedEverywhereAsBefore() {
        let plain = entry(minimumChip: nil)
        for generation in [nil, 9, 13, 14, 19] {
            XCTAssertTrue(VoiceDeviceFloor.allows(plain, deviceGeneration: generation), "generation \(String(describing: generation))")
        }
    }

    func testAFloorOnAnUnknownDeviceOrAnUnreadableFloorKeepsTheVoiceOff() {
        XCTAssertFalse(VoiceDeviceFloor.allows(entry(minimumChip: "A14"), deviceGeneration: nil))
        XCTAssertFalse(VoiceDeviceFloor.allows(entry(minimumChip: "M1"), deviceGeneration: 19))
    }

    private func entry(minimumChip: String?) -> VoiceModelEntry {
        VoiceModelEntry(
            id: "neural", displayName: "Neural", publisher: "Example", version: "1",
            runtime: VoiceModelRuntime(name: "coreml", version: "9"), minimumIOSVersion: "26.0",
            minimumMemoryMegabytes: 1, minimumChip: minimumChip, files: [],
            licenses: []
        )
    }
}
