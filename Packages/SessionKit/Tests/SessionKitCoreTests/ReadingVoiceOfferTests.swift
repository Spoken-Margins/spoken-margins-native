import SessionKit
import XCTest

/// #2700: the App Voice picker lists a downloaded voice only when it has a player, is installed and may run on this
/// chip; and an installed voice this device can't run is never told it "keeps working" (#2735 review).
final class ReadingVoiceOfferTests: XCTestCase {
    private let always: [ReadingVoiceChoice] = [.james, .lily, .kitten, .system]

    private func row(_ id: String, installed: Bool = true, offered: Bool = true, unusable: VoiceUnusableReason? = nil) -> VoiceCatalogRow {
        VoiceCatalogRow(
            entry: VoiceModelEntry(
                id: id, displayName: id, publisher: "p", version: "1",
                runtime: VoiceModelRuntime(name: "coreml", version: "1"), minimumIOSVersion: "26.0",
                minimumMemoryMegabytes: 1, minimumChip: "A14", files: [], licenses: []
            ),
            state: installed ? .installed(version: "1", byteCount: 10) : .notInstalled,
            licensesNeedingAgreement: [],
            isOffered: offered,
            unusableHere: unusable
        )
    }

    private let both: Set<String> = [ReadingVoiceChoice.phononVoiceId, ReadingVoiceChoice.kokoroVoiceId]

    func testWithNothingDownloadedOnlyTheVoicesThatNeedNoDownloadOfTheirOwnAreListed() {
        XCTAssertEqual(ReadingVoiceOffer.choices(current: .kitten, rows: [], playableVoiceIds: both), always)
    }

    func testAnInstalledVoiceWithAPlayerOnAnAllowedChipIsListed() {
        let rows = [row("phonon-31m-en"), row("kokoro-82m")]
        XCTAssertEqual(ReadingVoiceOffer.choices(current: .kitten, rows: rows, playableVoiceIds: both), always + [.phonon, .kokoro])
    }

    func testAVoiceWithNoRegisteredPlayerIsNeverListedEvenWhenInstalled() {
        let rows = [row("phonon-31m-en"), row("kokoro-82m")]
        XCTAssertEqual(ReadingVoiceOffer.choices(current: .kitten, rows: rows, playableVoiceIds: ["kokoro-82m"]), always + [.kokoro])
        XCTAssertEqual(ReadingVoiceOffer.choices(current: .kitten, rows: rows, playableVoiceIds: []), always)
    }

    func testANotInstalledOrBelowTheFloorVoiceIsNotListed() {
        let rows = [row("phonon-31m-en", installed: false), row("kokoro-82m", offered: false, unusable: .chipBelowFloor)]
        XCTAssertEqual(ReadingVoiceOffer.choices(current: .james, rows: rows, playableVoiceIds: both), always)
        XCTAssertFalse(ReadingVoiceOffer.isUsable(voiceId: "kokoro-82m", rows: rows, playableVoiceIds: both))
    }

    func testAWithdrawnButInstalledVoiceStillReads() {
        let rows = [row("kokoro-82m", offered: false)]
        XCTAssertTrue(ReadingVoiceOffer.isUsable(voiceId: "kokoro-82m", rows: rows, playableVoiceIds: both))
    }

    func testTheCurrentChoiceStaysListedSoThePickerIsNeverBlank() {
        XCTAssertEqual(ReadingVoiceOffer.choices(current: .kokoro, rows: [], playableVoiceIds: []), always + [.kokoro])
    }

    func testAnInstalledVoiceBelowTheFloorIsToldKittenReadsNotThatItKeepsWorking() {
        let note = row("kokoro-82m", offered: false, unusable: .chipBelowFloor).installedButNotOfferedNote
        XCTAssertEqual(note, "This phone is older than this voice needs, so Kitten reads instead. Remove frees the space.")
        XCTAssertFalse(note?.contains("keeps working") ?? true)
        XCTAssertEqual(row("kokoro-82m", offered: false).installedButNotOfferedNote, "No longer offered. This copy keeps working.")
        XCTAssertNil(row("kokoro-82m").installedButNotOfferedNote)
        XCTAssertNil(row("kokoro-82m", installed: false, offered: false, unusable: .chipBelowFloor).installedButNotOfferedNote)
    }
}
