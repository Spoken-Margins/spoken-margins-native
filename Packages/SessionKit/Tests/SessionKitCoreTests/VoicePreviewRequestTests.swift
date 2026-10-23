import SessionKit
import XCTest

final class VoicePreviewRequestTests: XCTestCase {
    func testAPreviewWithNothingElseGoingOnPlays() {
        var preview = VoicePreviewRequest<String>()
        let token = preview.begin(voice: "james")
        XCTAssertTrue(preview.mayPlay(token, selectedVoice: "james", otherAudioActive: false))
        XCTAssertFalse(preview.isPending)
    }

    func testAPreviewCancelledByPlaybackDoesNotPlay() {
        var preview = VoicePreviewRequest<String>()
        let token = preview.begin(voice: "james")
        preview.cancel() // the listener pressed play on an item
        XCTAssertFalse(preview.mayPlay(token, selectedVoice: "james", otherAudioActive: false))
    }

    func testAPreviewForAVoiceNoLongerPickedDoesNotPlay() {
        var preview = VoicePreviewRequest<String>()
        let token = preview.begin(voice: "james")
        XCTAssertFalse(preview.mayPlay(token, selectedVoice: "sarah", otherAudioActive: false),
                       "it would play James labelled as Sarah")
    }

    func testAPreviewNeverPlaysOverNarrationOrARecording() {
        var preview = VoicePreviewRequest<String>()
        let token = preview.begin(voice: "james")
        XCTAssertFalse(preview.mayPlay(token, selectedVoice: "james", otherAudioActive: true))
        XCTAssertFalse(preview.isPending, "the request is used up even when it may not play")
    }

    func testANewerPreviewMakesTheOlderOneStale() {
        var preview = VoicePreviewRequest<String>()
        let first = preview.begin(voice: "james")
        let second = preview.begin(voice: "james")
        XCTAssertFalse(preview.mayPlay(first, selectedVoice: "james", otherAudioActive: false))
        XCTAssertTrue(preview.mayPlay(second, selectedVoice: "james", otherAudioActive: false))
    }

    func testAPreviewPlaysAtMostOnce() {
        var preview = VoicePreviewRequest<String>()
        let token = preview.begin(voice: "james")
        XCTAssertTrue(preview.mayPlay(token, selectedVoice: "james", otherAudioActive: false))
        XCTAssertFalse(preview.mayPlay(token, selectedVoice: "james", otherAudioActive: false))
    }

    /// #2125: the render is slow; the listener presses play on an item before it lands.
    @MainActor
    func testASlowRenderThatLandsAfterPlaybackStartedIsDropped() async {
        let settings = PreviewModel()
        let render = AsyncRenderGate()
        let task = settings.preview("james") { await render.wait() }
        await render.waitUntilWaiting()
        settings.startPlayback()
        await render.open()
        await task.value
        XCTAssertEqual(settings.played, [], "the stale preview must not play over the narration")
    }

    @MainActor
    func testASlowRenderThatLandsAfterTheVoiceChangedIsDropped() async {
        let settings = PreviewModel()
        let render = AsyncRenderGate()
        let task = settings.preview("james") { await render.wait() }
        await render.waitUntilWaiting()
        settings.pickVoice("sarah")
        await render.open()
        await task.value
        XCTAssertEqual(settings.played, [])
    }

    @MainActor
    func testASlowRenderWithNothingInTheWayPlays() async {
        let settings = PreviewModel()
        let render = AsyncRenderGate()
        let task = settings.preview("james") { await render.wait() }
        await render.waitUntilWaiting()
        await render.open()
        await task.value
        XCTAssertEqual(settings.played, ["james"])
    }
}

/// The settings screen's preview shape in miniature: a slow render, then play only if still wanted.
@MainActor
private final class PreviewModel {
    var request = VoicePreviewRequest<String>()
    var selectedVoice = "james"
    var isPlaying = false
    var played: [String] = []

    func preview(_ voice: String, render: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        selectedVoice = voice
        let token = request.begin(voice: voice)
        return Task { @MainActor in
            await render()
            guard self.request.mayPlay(token, selectedVoice: self.selectedVoice, otherAudioActive: self.isPlaying) else { return }
            self.played.append(voice)
        }
    }

    func startPlayback() {
        request.cancel()
        isPlaying = true
    }

    func pickVoice(_ voice: String) {
        request.cancel()
        selectedVoice = voice
    }
}

private actor AsyncRenderGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilWaiting() async {
        while waiters.isEmpty && !isOpen { await Task.yield() }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
