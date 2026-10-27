import Foundation

// The device floor for a downloadable voice (#2700). The owner limited the Neural Engine voices to phones
// that run them well: "I am very happy to limit it to phones with a neural engine", and Kokoro and Phonon
// are offered on A14 (iPhone 12) and newer while A13 phones keep Kitten (Default taken, 2026-10-25).
//
// A catalog entry names its floor as an A-series chip (`minimumChip: "A14"`). The device is read from its
// model identifier (`iPhone13,2`), which the app's probe supplies; everything here is a pure function so
// the table can be tested on the host. Apple silicon counts as the A chip it grew from (M1 as A14, M2 as
// A15, M3 as A17, M4 as A18), which is how close their Neural Engines are.

public enum VoiceDeviceFloor {
    /// The floor Kokoro and Phonon use (owner, 2026-10-25).
    public static let neuralVoiceFloor = "A14"

    /// `A14` → 14. Nil for anything else: `a14`, `A`, `A014`, `M1`, ` A14`, `A14\n`.
    public static func generation(ofCatalogChip text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard (2...4).contains(bytes.count), bytes[0] == UInt8(ascii: "A"), bytes[1] != UInt8(ascii: "0"),
              bytes.dropFirst().allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(String(decoding: bytes.dropFirst(), as: UTF8.self))
    }

    /// The A-series generation of a device, from its model identifier, or nil when it can't be told.
    ///
    /// - iPhone: the major number is one below the chip's for every iPhone since the 6s (`iPhone8,x` A9,
    ///   `iPhone12,x` A13 including the SE 2, `iPhone13,x` A14, `iPhone14,7` the iPhone 14 on A15,
    ///   `iPhone17,5` the 16e on A18), so a phone newer than this table still reads right.
    /// - iPad: one major number mixes A and M chips; each maps to the oldest chip it holds.
    /// - Apple silicon Mac or Vision Pro running the iPad app: M1 or newer.
    public static func generation(ofMachine identifier: String) -> Int? {
        // An iPad app runs on a Mac or a Vision Pro only on Apple silicon (`Mac14,2`, `MacBookPro18,1`).
        if identifier.hasPrefix("Mac") || identifier.hasPrefix("RealityDevice") {
            return identifier.contains(",") ? appleSiliconFloor : nil
        }
        if let major = majorNumber(identifier, after: "iPhone") {
            return major >= 8 ? major + 1 : nil
        }
        if let major = majorNumber(identifier, after: "iPad") {
            if let known = iPadGenerations[major] { return known }
            // A major number past the table is a newer iPad than any listed.
            return major > (iPadGenerations.keys.max() ?? 0) ? iPadGenerations.values.max() : nil
        }
        return nil
    }

    /// Whether `entry` may be offered on a device of `deviceGeneration`. An entry with no floor is offered
    /// everywhere, as before. A floor the device can't be measured against (`deviceGeneration` nil) keeps
    /// the voice off: an unknown device is never handed a voice that may stall it.
    public static func allows(_ entry: VoiceModelEntry, deviceGeneration: Int?) -> Bool {
        guard let floorText = entry.minimumChip else { return true }
        guard let floor = generation(ofCatalogChip: floorText), let device = deviceGeneration else { return false }
        return device >= floor
    }

    /// M1, the oldest Apple silicon, is an A14 in the sense used here.
    static let appleSiliconFloor = 14

    /// The oldest chip under each iPad major number (iPadOS 26 runs from the A12 iPads up).
    static let iPadGenerations: [Int: Int] = [
        6: 9,   // iPad (5th) A9, iPad Pro (1st) A9X
        7: 10,  // iPad (6th, 7th) A10, iPad Pro (2nd) A10X
        8: 12,  // iPad Pro (3rd, 4th) A12X / A12Z
        11: 12, // iPad mini (5th), iPad Air (3rd), iPad (8th) A12
        12: 13, // iPad (9th) A13
        13: 14, // iPad Air (4th), iPad (10th) A14; iPad Pro and Air M1
        14: 15, // iPad mini (6th) A15; iPad Pro and Air M2
        15: 16, // iPad (A16); iPad Air M3
        16: 17, // iPad mini A17 Pro; iPad Pro M4
    ]

    /// `iPhone13,2` after `iPhone` → 13. Requires `<prefix><digits>,<digits>` and nothing else.
    private static func majorNumber(_ identifier: String, after prefix: String) -> Int? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ (1...3).contains($0.count) && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }) else { return nil }
        return Int(parts[0])
    }
}

/// Whether this device can use a catalog voice at all: chip floor, then memory. The one decision behind both the
/// speech player's "may the chosen voice render?" gate and Settings > Voices' "Kitten reads instead" note, so the two
/// can't disagree (#2744 review).
public enum VoiceDeviceFit {
    /// The catalog id of Supertonic, whose own gate (`SupertonicModelNotDownloaded`) checks only that the model is
    /// installed and that the phone's heat, memory pressure and power allow it. It has always rendered on a phone below
    /// its catalog memory figure, so it is not held to the downloaded-voice floors; its note stays "keeps working".
    public static let supertonicVoiceId = "supertonic-3-int8"

    /// The chip or memory floor `entry` fails on this device, whatever voice it is. Decides what is offered for download.
    public static func floorFailure(
        _ entry: VoiceModelEntry, deviceGeneration: Int?, physicalMemoryMegabytes: Int
    ) -> VoiceUnusableReason? {
        if !VoiceDeviceFloor.allows(entry, deviceGeneration: deviceGeneration) { return .chipBelowFloor }
        if entry.minimumMemoryMegabytes > VoiceCatalogCoordinator.nominalMemoryMegabytes(reported: physicalMemoryMegabytes) {
            return .notEnoughMemory
        }
        return nil
    }

    /// Why an installed copy of `entry` will not render here, or nil when it will. The bundled voice and Supertonic
    /// keep the behaviour they had before downloaded voices: no floor stops them.
    public static func renderBlocker(
        _ entry: VoiceModelEntry, deviceGeneration: Int?, physicalMemoryMegabytes: Int
    ) -> VoiceUnusableReason? {
        if entry.bundled || entry.id == supertonicVoiceId { return nil }
        return floorFailure(entry, deviceGeneration: deviceGeneration, physicalMemoryMegabytes: physicalMemoryMegabytes)
    }

    public static func canRender(_ entry: VoiceModelEntry, deviceGeneration: Int?, physicalMemoryMegabytes: Int) -> Bool {
        renderBlocker(entry, deviceGeneration: deviceGeneration, physicalMemoryMegabytes: physicalMemoryMegabytes) == nil
    }
}
