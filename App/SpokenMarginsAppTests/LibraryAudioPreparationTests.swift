import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #281: many Library text items showed a spinner at once, and none finished.
@MainActor
final class LibraryAudioPreparationTests: XCTestCase {
    private func textItem(_ id: String) -> Item {
        Item(id: id, title: id, mediaType: "text", text: "A few words to read aloud.", externalReference: nil, status: "ready")
    }

    private func modelWithOnDeviceVoice() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.ttsVoiceSelection = .lily
        model.acceptCurrentTermsAndEnableOnDeviceVoice()
        return model
    }

    func testOnlyTheItemBeingPreparedShowsProgressAndTheRestWait() {
        let model = modelWithOnDeviceVoice()
        let items = (1...5).map { textItem("queued-\($0)") }
        func states() -> [NativeTextStartupAudioState] {
            items.map { model.libraryStartupAudioPresentation(item: $0, manifest: nil, job: nil).state }
        }
        XCTAssertEqual(states(), Array(repeating: .waiting, count: 5), "queued items wait; none shows a spinner")
        model.libraryAudioPreparingItemId = "queued-3"
        XCTAssertEqual(states(), [.waiting, .waiting, .preparing, .waiting, .waiting], "exactly one shows progress")
    }

    func testAWaitingItemStillStartsAtOnce() {
        let model = modelWithOnDeviceVoice()
        let itemID = "item-pill"
        guard let index = model.libraryItems.firstIndex(where: { $0.id == itemID }) else {
            return XCTFail("Missing seeded text item")
        }
        model.libraryItems[index].startupAudioState = .waiting
        model.startItem(id: itemID)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.diagnostics["startupAudioPlayback:\(itemID)"], "started_without_waiting_for_opening_buffer")
    }
}
