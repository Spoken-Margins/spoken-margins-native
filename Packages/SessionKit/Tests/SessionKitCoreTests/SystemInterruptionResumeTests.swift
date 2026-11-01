import XCTest
@testable import SessionKit

/// The one owner of the resume decision after a system interruption (#3032). Both playback clients (AVPlayer and
/// Supertonic) report these events and obey the answers, so this table is the behaviour of both.
final class SystemInterruptionResumeTests: XCTestCase {
    private enum Step {
        case began(SystemInterruptionResume.Cause, wasPlaying: Bool)
        case ended(shouldResume: Bool)
        case otherAudioStopped(sourceStillPaused: Bool)
        case listenerTookOver
    }

    private struct Scenario {
        let name: String
        let steps: [Step]
        /// The answer of each step: began = paused by it, ended and otherAudioStopped = resume now, listenerTookOver = nil.
        let answers: [Bool?]
    }

    func testScenarios() {
        let scenarios: [Scenario] = [
            Scenario(name: "nothing was playing: nothing resumes",
                     steps: [.began(.interruption, wasPlaying: false), .ended(shouldResume: true)],
                     answers: [false, false]),
            Scenario(name: "playing, ended with should-resume: resumes",
                     steps: [.began(.interruption, wasPlaying: true), .ended(shouldResume: true)],
                     answers: [true, true]),
            Scenario(name: "playing, ended without should-resume: stays paused",
                     steps: [.began(.interruption, wasPlaying: true), .ended(shouldResume: false)],
                     answers: [true, false]),
            Scenario(name: "a late second end does not resume twice",
                     steps: [.began(.interruption, wasPlaying: true), .ended(shouldResume: true), .ended(shouldResume: true)],
                     answers: [true, true, false]),
            Scenario(name: "an end without should-resume spends the arming",
                     steps: [.began(.interruption, wasPlaying: true), .ended(shouldResume: false), .ended(shouldResume: true)],
                     answers: [true, false, false]),
            Scenario(name: "the listener's Pause, Play or Stop cancels the resume",
                     steps: [.began(.interruption, wasPlaying: true), .listenerTookOver, .ended(shouldResume: true)],
                     answers: [true, nil, false]),
            Scenario(name: "a second interruption that finds the source already paused keeps the resume",
                     steps: [.began(.interruption, wasPlaying: true), .began(.interruption, wasPlaying: false), .ended(shouldResume: true)],
                     answers: [true, false, true]),
            Scenario(name: "a lost route never resumes by itself",
                     steps: [.began(.routeLost, wasPlaying: true), .ended(shouldResume: true)],
                     answers: [true, false]),
            Scenario(name: "a lost route during an interruption cancels its resume, even though it paused nothing",
                     steps: [.began(.interruption, wasPlaying: true), .began(.routeLost, wasPlaying: false), .ended(shouldResume: true)],
                     answers: [true, false, false]),
            Scenario(name: "other audio stopping without an end resumes while still paused",
                     steps: [.began(.interruption, wasPlaying: true), .otherAudioStopped(sourceStillPaused: true)],
                     answers: [true, true]),
            Scenario(name: "other audio stopping does not resume a source the listener already moved",
                     steps: [.began(.interruption, wasPlaying: true), .otherAudioStopped(sourceStillPaused: false), .ended(shouldResume: true)],
                     answers: [true, false, false]),
            Scenario(name: "other audio stopping and then a late end resume once",
                     steps: [.began(.interruption, wasPlaying: true), .otherAudioStopped(sourceStillPaused: true), .ended(shouldResume: true)],
                     answers: [true, true, false]),
            Scenario(name: "other audio stopping with nothing armed does nothing",
                     steps: [.otherAudioStopped(sourceStillPaused: true)],
                     answers: [false]),
            Scenario(name: "a second playing interruption after a spent one arms again",
                     steps: [.began(.interruption, wasPlaying: true), .ended(shouldResume: true),
                             .began(.interruption, wasPlaying: true), .ended(shouldResume: true)],
                     answers: [true, true, true, true]),
        ]
        for scenario in scenarios {
            var resume = SystemInterruptionResume()
            var seen: [Bool?] = []
            for step in scenario.steps {
                switch step {
                case .began(let cause, let wasPlaying): seen.append(resume.began(cause, wasPlaying: wasPlaying))
                case .ended(let shouldResume): seen.append(resume.ended(shouldResume: shouldResume))
                case .otherAudioStopped(let paused): seen.append(resume.otherAudioStopped(sourceStillPaused: paused))
                case .listenerTookOver:
                    resume.cancelAutomaticResume()
                    seen.append(nil)
                }
            }
            XCTAssertEqual(seen, scenario.answers, scenario.name)
        }
    }

    func testArmedStateIsVisible() {
        var resume = SystemInterruptionResume()
        XCTAssertFalse(resume.isArmed)
        resume.began(.interruption, wasPlaying: true)
        XCTAssertTrue(resume.isArmed)
        _ = resume.ended(shouldResume: false)
        XCTAssertFalse(resume.isArmed)
    }
}
