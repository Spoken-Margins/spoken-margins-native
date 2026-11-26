import XCTest
@testable import SessionKitAudio

/// #842: the hang probe cuts a label to 40 characters (`MainThreadOperationLabels.push`), so a longer name would
/// reach a `main.hang` record truncated and ambiguous. These read the real constants.
final class AudioSessionOperationLabelTests: XCTestCase {
    func testEveryAudioSessionLabelFitsTheProbesLabelLimitAndIsDistinct() {
        let names = [
            AudioSessionOperationLabel.playbackCategory, AudioSessionOperationLabel.releaseDucking,
            AudioSessionOperationLabel.speechActivate, AudioSessionOperationLabel.speechRelease,
            AudioSessionOperationLabel.mediaRelease, AudioSessionOperationLabel.supertonicActivate,
            AudioSessionOperationLabel.marginVoiceRelease
        ]
        for name in names { XCTAssertLessThanOrEqual(name.count, 40, name) }
        XCTAssertEqual(Set(names).count, names.count)
    }
}
