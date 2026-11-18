import Foundation
import XCTest
@testable import SessionKit

/// #4453: the scene the Now tab shows, which scene stays when the listener reads on, and the line after it.
final class PlaybackNowSceneStateTests: XCTestCase {
    private func sentences(_ count: Int, prefix: String) -> String {
        (1...count).map { "\(prefix) sentence number \($0) says something." }.joined(separator: " ")
    }

    private struct Fixture {
        let text: String
        let chapters: [Chapter]
        let starts: [Int]
        func offset(of phrase: String) -> Int { (text as NSString).range(of: phrase).location }
    }

    private func fixture() -> Fixture {
        let first = sentences(5, prefix: "Opening"), middle = sentences(40, prefix: "Middle"), last = sentences(6, prefix: "Closing")
        let text = [first, middle, last].joined(separator: " ")
        let middleStart = first.count + 1, lastStart = middleStart + middle.count + 1
        return Fixture(text: text, chapters: [
            Chapter(id: "c1", title: "One", startChar: 0, endChar: middleStart, percent: 0),
            Chapter(id: "c2", title: "Two", startChar: middleStart, endChar: lastStart, percent: 0),
            Chapter(id: "c3", title: "Three", startChar: lastStart, endChar: text.count, percent: 0)
        ], starts: [0, middleStart, lastStart])
    }

    func testFollowingShowsThePlayingSceneAndLightsItsSentence() {
        let f = fixture()
        var state = PlaybackNowSceneState(text: f.text, chapters: f.chapters)
        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.move(offset: f.offset(of: "Middle sentence number 20")))
        XCTAssertEqual(state.shownScene.chapterTitle, "Two")
        XCTAssertEqual(state.shownScene.sentences.count, 40)
        XCTAssertEqual(state.litSentence, 19)
        XCTAssertEqual(state.litSentenceID, state.shownScene.sentences[19].id)
        XCTAssertEqual(state.playingSentenceID, state.litSentenceID)
        XCTAssertTrue(state.follow.isFollowing)
        XCTAssertFalse(state.offersBackToPlaying)
        XCTAssertNil(state.nowInTitle)
    }

    func testNextSentenceMovesOnlyTheLightAndNeverTheRows() {
        let f = fixture()
        var state = PlaybackNowSceneState(text: f.text, chapters: f.chapters)
        state.move(offset: f.offset(of: "Middle sentence number 20"))
        let revision = state.sceneRevision
        XCTAssertTrue(state.move(offset: f.offset(of: "Middle sentence number 21")))
        XCTAssertEqual(state.litSentence, 20)
        XCTAssertEqual(state.sceneRevision, revision, "no new scene, so a view redraws no row")
        XCTAssertFalse(state.move(offset: f.offset(of: "Middle sentence number 21") + 3), "inside the same sentence")
    }

    func testReadingAwayKeepsTheSceneAndThePlayheadMovingOnDoesNotPullItBack() {
        let f = fixture()
        var state = PlaybackNowSceneState(text: f.text, chapters: f.chapters)
        state.move(offset: f.offset(of: "Middle sentence number 39"))
        state.listenerScrolled()
        XCTAssertTrue(state.offersBackToPlaying)
        state.move(offset: f.offset(of: "Middle sentence number 40"))
        // The light still moves in the scene being read; the scene is the same value.
        XCTAssertEqual(state.litSentence, 39)
        XCTAssertFalse(state.follow.isFollowing)
        let revision = state.sceneRevision
        // Playback reaches the next scene's first sentence while the listener reads Two.
        state.move(offset: f.offset(of: "Closing sentence number 1"))
        XCTAssertEqual(state.shownScene.chapterTitle, "Two", "nothing is swapped out from under the listener")
        XCTAssertEqual(state.sceneRevision, revision)
        XCTAssertNil(state.litSentence, "nothing is lit in an older scene")
        XCTAssertEqual(state.nowInTitle, "Three")
        XCTAssertTrue(state.isReadingAnotherScene)
        XCTAssertTrue(state.offersBackToPlaying)
        // Back to playing loads the new scene at its lit sentence.
        state.backToPlaying()
        XCTAssertEqual(state.shownScene.chapterTitle, "Three")
        XCTAssertEqual(state.litSentence, 0)
        XCTAssertGreaterThan(state.sceneRevision, revision)
        XCTAssertNil(state.nowInTitle)
        XCTAssertTrue(state.follow.isFollowing)
        XCTAssertFalse(state.isReadingAnotherScene)
    }

    func testWhileFollowingTheNextSceneReplacesThisOneAtItsFirstSentence() {
        let f = fixture()
        var state = PlaybackNowSceneState(text: f.text, chapters: f.chapters)
        state.move(offset: f.offset(of: "Middle sentence number 40"))
        state.move(offset: f.offset(of: "Closing sentence number 1"))
        XCTAssertEqual(state.shownScene.chapterTitle, "Three")
        XCTAssertEqual(state.litSentence, 0)
        XCTAssertTrue(state.follow.isFollowing)
    }

    func testAJumpStartsFollowingAgainEvenWhenTheListenerScrolledAway() {
        let f = fixture()
        var state = PlaybackNowSceneState(text: f.text, chapters: f.chapters)
        state.move(offset: f.offset(of: "Middle sentence number 5"))
        state.listenerScrolled()
        state.move(offset: f.offset(of: "Middle sentence number 30"))
        XCTAssertTrue(state.follow.isFollowing)
        XCTAssertEqual(state.litSentence, 29)
        // A seek into another scene is a jump too.
        state.listenerScrolled()
        state.move(offset: f.offset(of: "Opening sentence number 2"))
        XCTAssertTrue(state.follow.isFollowing)
        XCTAssertEqual(state.shownScene.chapterTitle, "One")
        XCTAssertEqual(state.litSentence, 1)
        // A listener control that looks like playback (the next sentence) is a jump all the same.
        state.listenerScrolled()
        state.move(offset: f.offset(of: "Opening sentence number 3"), byListenerControl: true)
        XCTAssertTrue(state.follow.isFollowing)
    }

    func testAScrollThatRestsOnTheLitSentenceFollowsAgainButNotOffIt() {
        let f = fixture()
        var state = PlaybackNowSceneState(text: f.text, chapters: f.chapters)
        state.move(offset: f.offset(of: "Middle sentence number 10"))
        state.listenerScrolled()
        state.scrollCameToRest(litSentenceIsVisible: false)
        XCTAssertFalse(state.follow.isFollowing)
        state.scrollCameToRest(litSentenceIsVisible: true)
        XCTAssertTrue(state.follow.isFollowing)
    }

    func testMarginsLandOnTheirRowsAndOneInAnotherSceneLeavesTheSceneAlone() {
        let f = fixture()
        var state = PlaybackNowSceneState(text: f.text, chapters: f.chapters)
        let inMiddle = PlaybackLivePassage.Margin(id: "m1", offset: f.offset(of: "Middle sentence number 3"), origin: .own)
        let inClosing = PlaybackLivePassage.Margin(id: "m2", offset: f.offset(of: "Closing sentence number 2"), origin: .own)
        state.move(offset: f.offset(of: "Middle sentence number 20"), margins: [inMiddle])
        XCTAssertEqual(state.shownScene.sentences[2].diamonds.map(\.id), ["m1"])
        let revision = state.sceneRevision
        state.move(offset: f.offset(of: "Middle sentence number 20"), margins: [inMiddle, inClosing])
        XCTAssertEqual(state.sceneRevision, revision)
        state.move(offset: f.offset(of: "Middle sentence number 20"), margins: [])
        XCTAssertGreaterThan(state.sceneRevision, revision)
        XCTAssertTrue(state.shownScene.sentences[2].diamonds.isEmpty)
    }

    func testTheEndLineSaysWhatComesNext() {
        let f = fixture()
        var state = PlaybackNowSceneState(text: f.text, chapters: f.chapters)
        state.move(offset: f.offset(of: "Opening sentence number 2"))
        XCTAssertEqual(state.endLine, .init(heading: "End of this scene", next: "Two"))
        state.move(offset: f.offset(of: "Middle sentence number 2"))
        XCTAssertEqual(state.endLine, .init(heading: "End of this scene", next: "Three"))
        state.move(offset: f.offset(of: "Closing sentence number 2"))
        XCTAssertEqual(state.endLine, .init(heading: "End of the last scene", next: nil))
        var whole = PlaybackNowSceneState(text: sentences(30, prefix: "Only"))
        whole.move(offset: 0)
        XCTAssertEqual(whole.endLine, .init(heading: "End of the text", next: nil))
        XCTAssertEqual(whole.shownScene.sentences.count, 30)
    }

    func testAMegabyteWithNoChaptersIsOneSceneAndATickBuildsNoRow() {
        let text = (1...9_000).map { "This is sentence number \($0) of a very long book." }.joined(separator: " ")
        var state = PlaybackNowSceneState(text: text)
        state.move(offset: 0)
        XCTAssertEqual(state.shownScene.sentences.count, 9_000)
        let revision = state.sceneRevision
        let middle = (text as NSString).range(of: "sentence number 4500 ").location
        state.move(offset: middle)
        state.move(offset: (text as NSString).range(of: "sentence number 4501 ").location)
        XCTAssertEqual(state.litSentence, 4500)
        XCTAssertEqual(state.sceneRevision, revision)
    }

    func testNoTextAndAChapterWithNoSentenceCauseNoHarm() {
        var empty = PlaybackNowSceneState(text: "")
        XCTAssertFalse(empty.move(offset: 0))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.litSentenceID)
        XCTAssertNil(empty.playingSentenceID)
        let text = "   \nFirst real sentence here. Second one follows."
        let chapters = [Chapter(id: "a", title: "Blank", startChar: 0, endChar: 4, percent: 0),
                        Chapter(id: "b", title: "Real", startChar: 4, endChar: text.count, percent: 0)]
        var state = PlaybackNowSceneState(text: text, chapters: chapters)
        state.move(offset: 1)
        XCTAssertNil(state.litSentence)
        XCTAssertTrue(state.shownScene.sentences.isEmpty)
        state.move(offset: 10)
        XCTAssertEqual(state.shownScene.chapterTitle, "Real")
        XCTAssertEqual(state.litSentence, 0)
    }
}
