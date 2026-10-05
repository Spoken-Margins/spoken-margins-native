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

    /// Codex audit on #380: a restored session that is paused isn't being prepared, so its item
    /// waits like the rest. It shows progress again once playback is active.
    func testAPausedSessionsItemWaitsWhileAnotherItemIsPrepared() {
        let model = modelWithOnDeviceVoice()
        let items = (1...3).map { textItem("queued-\($0)") }
        func states() -> [NativeTextStartupAudioState] {
            items.map { model.libraryStartupAudioPresentation(item: $0, manifest: nil, job: nil).state }
        }
        model.libraryAudioPreparingItemId = "queued-2"
        var paused = model.snapshot
        paused.sessionId = "session-queued-1"
        paused.itemId = "queued-1"
        paused.status = .paused
        model.snapshot = paused
        model.libraryAudioPreparingItemId = "queued-2"
        XCTAssertEqual(states(), [.waiting, .preparing, .waiting], "the paused item isn't being prepared")
        model.snapshot.status = .playing
        model.libraryAudioPreparingItemId = "queued-2"
        XCTAssertEqual(states(), [.preparing, .preparing, .waiting], "the playing item prepares as it plays")
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
