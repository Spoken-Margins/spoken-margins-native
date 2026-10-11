import XCTest
import SessionKit
import UIKit
@testable import SpokenMarginsApp

/// The playback bar draws the chapters and Margins `PlaybackBarLayout` decides (#428).
@MainActor
final class PlaybackBarRendererTests: XCTestCase {
    func testAPlainSliderKeepsItsSystemTrackAndDrawsNothing() {
        let slider = makeSlider(content: nil)
        XCTAssertTrue(layers(named: "bar-segment", in: slider).isEmpty)
        XCTAssertTrue(layers(named: "bar-diamond", in: slider).isEmpty)
        XCTAssertNil(slider.minimumTrackImage(for: .normal))
    }

    func testAnEpisodeWithoutChaptersStillKeepsTheSystemTrackButShowsItsMargins() {
        let slider = makeSlider(content: content(chapterStarts: [], marks: [mark("a", 600, .own)]))
        XCTAssertTrue(layers(named: "bar-segment", in: slider).isEmpty, "nothing to divide, so the row looks as it did")
        XCTAssertNil(slider.minimumTrackImage(for: .normal))
        XCTAssertEqual(layers(named: "bar-diamond", in: slider).count, 1)
    }

    func testChaptersSplitTheTrackAndTheSystemTrackStepsAside() {
        let slider = makeSlider(content: content(chapterStarts: [0, 900, 2_700], marks: []), value: 1_000)
        let segments = layers(named: "bar-segment", in: slider)
        XCTAssertEqual(segments.count, 3)
        XCTAssertNotNil(slider.minimumTrackImage(for: .normal))
        XCTAssertGreaterThan(segments[0].frame.maxX, 0)
        XCTAssertLessThan(segments[0].frame.maxX, segments[1].frame.minX, "a small gap between chapters")
        XCTAssertGreaterThan(segments[1].frame.height, segments[0].frame.height, "the current chapter is a little thicker")
        // At 1,000 s the first chapter is heard in full and the second is part-way through.
        let fills = layers(named: "bar-segment-fill", in: slider)
        XCTAssertEqual(fills[0].frame.width, segments[0].frame.width, accuracy: 0.5)
        XCTAssertGreaterThan(fills[1].frame.width, 0)
        XCTAssertLessThan(fills[1].frame.width, segments[1].frame.width)
        XCTAssertEqual(fills[2].frame.width, 0, accuracy: 0.5)
    }

    func testManyChaptersShowTicksInsteadOfGaps() {
        let starts = (0..<40).map { Double($0) * 90 }
        let slider = makeSlider(content: content(chapterStarts: starts, marks: []))
        XCTAssertEqual(layers(named: "bar-segment", in: slider).count, 40)
        XCTAssertEqual(layers(named: "bar-tick", in: slider).count, 39)
        let segments = layers(named: "bar-segment", in: slider)
        XCTAssertEqual(segments[0].frame.maxX, segments[1].frame.minX, accuracy: 0.01, "no gaps, so the track stays whole")
    }

    func testOwnAndSharedMarginsAreDifferentShapesAndCrowdedOnesStack() {
        let slider = makeSlider(content: content(chapterStarts: [], marks: [
            mark("mine", 600, .own),
            mark("theirs", 1_800, .shared),
            mark("near-1", 3_000, .own), mark("near-2", 3_001, .shared),
        ]))
        let diamonds = layers(named: "bar-diamond", in: slider).compactMap { $0 as? CAShapeLayer }
        XCTAssertEqual(diamonds.count, 4, "one each for the first two, and a two-layer stack")
        XCTAssertEqual(diamonds.filter { $0.lineWidth == 1.5 }.count, 2, "a shared Margin is an outline, in the stack too")
        XCTAssertEqual(diamonds.filter { $0.lineWidth == 1 }.count, 2, "an own Margin is solid amber")
    }

    func testTwelveMarginsInOneSpotShowThreeGhostLayersAndTheCount() {
        let marks = (0..<12).map { mark("m\($0)", 1_800 + Double($0) * 0.1, .own) }
        let slider = makeSlider(content: content(chapterStarts: [], marks: marks))
        XCTAssertEqual(layers(named: "bar-diamond", in: slider).count, 4, "three ghosts behind a larger front diamond")
        let count = layers(named: "bar-count", in: slider).first as? CATextLayer
        XCTAssertEqual(count?.string as? String, "12")
    }

    func testDiamondsLineUpWithTheThumbAtTheSamePosition() throws {
        let slider = makeSlider(content: content(chapterStarts: [], marks: [mark("a", 1_800, .own)]), value: 1_800)
        let track = slider.trackRect(forBounds: slider.bounds)
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: 1_800)
        let diamond = try XCTUnwrap(layers(named: "bar-diamond", in: slider).first as? CAShapeLayer)
        let box = try XCTUnwrap(diamond.path?.boundingBox)
        XCTAssertEqual(box.midX, thumb.midX, accuracy: 0.5)
        XCTAssertLessThan(box.maxY, track.midY, "the diamond rides above the track")
    }

    func testTheBarFollowsTheValueWithoutRedrawingTheMargins() {
        let slider = makeSlider(content: content(chapterStarts: [0, 1_800], marks: [mark("a", 600, .own)]), value: 100)
        let before = layers(named: "bar-diamond", in: slider).first
        slider.setValue(2_000, animated: false)
        slider.layoutIfNeeded()
        XCTAssertTrue(layers(named: "bar-diamond", in: slider).first === before)
        let segments = layers(named: "bar-segment", in: slider)
        XCTAssertGreaterThan(segments[1].frame.height, segments[0].frame.height, "the second chapter is now current")
    }

    // MARK: Helpers

    private func makeSlider(content: PlaybackBarContent?, value: Float = 0) -> TrackingPlaybackSlider {
        let slider = TrackingPlaybackSlider(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        slider.minimumValue = 0
        slider.maximumValue = 3_600
        slider.barContent = content
        slider.setValue(value, animated: false)
        slider.layoutIfNeeded()
        return slider
    }

    private func content(chapterStarts: [Double], marks: [PlaybackBarLayout.Mark]) -> PlaybackBarContent {
        PlaybackBarContent(length: 3_600, chapterStarts: chapterStarts, marks: marks)
    }

    private func mark(_ id: String, _ position: Double, _ kind: PlaybackBarLayout.MarkKind) -> PlaybackBarLayout.Mark {
        PlaybackBarLayout.Mark(id: id, position: position, kind: kind)
    }

    private func layers(named name: String, in slider: UIView) -> [CALayer] {
        func walk(_ layer: CALayer) -> [CALayer] {
            (layer.sublayers ?? []).flatMap { ($0.name == name ? [$0] : []) + walk($0) }
        }
        return walk(slider.layer)
    }
}
