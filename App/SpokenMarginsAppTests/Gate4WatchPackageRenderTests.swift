import XCTest
import AVFoundation
import SessionKit
@testable import SpokenMarginsApp

final class Gate4WatchPackageRenderTests: XCTestCase {
    func testSystemSpeechRendererWritesOfflineAudioPackage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "watch-render-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let item = Item(
            id: "item-render",
            title: "Render",
            mediaType: "text",
            text: "One short sentence.",
            externalReference: nil,
            status: "ready"
        )
        let coordinator = WatchPackageRenderCoordinator(applicationSupportDirectory: root)

        let output = try await coordinator.renderSystemSpeechPackage(
            item: item,
            map: nil,
            voiceIdentifier: nil,
            rate: AVSpeechUtteranceDefaultSpeechRate
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.audioURL.path))
        XCTAssertEqual(output.package.primaryAudioAsset?.fileName, output.audioURL.lastPathComponent)
        XCTAssertGreaterThan(output.package.primaryAudioAsset?.durationMs ?? 0, 0)
        XCTAssertNotNil(output.package.primaryAudioAsset?.sha256)
    }

    func testRenderPlanUsesListeningMapChaptersAsSegments() {
        let item = Item(
            id: "item-a",
            title: "Article",
            mediaType: "text",
            text: "First chapter text. Second chapter text.",
            externalReference: nil,
            status: "ready"
        )
        let map = ListeningMap(
            id: "map-a",
            itemId: item.id,
            overview: "Overview",
            chapters: [
                Chapter(id: "ch-first", title: "First", startChar: 0, endChar: 19, percent: 0),
                Chapter(id: "ch-second", title: "Second", startChar: 20, endChar: 40, percent: 50)
            ]
        )

        let plan = WatchPackageRenderPlan.make(item: item, map: map, createdAt: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(plan.packageId, "watch-package-item-a-10")
        XCTAssertEqual(plan.segments.map(\.id), ["seg-ch-first", "seg-ch-second"])
        XCTAssertEqual(plan.segments.map(\.startChar), [0, 20])
        XCTAssertEqual(plan.segments.map(\.text), ["First chapter text.", "Second chapter text."])
    }

    func testRenderPlanFallsBackToSentenceSegments() {
        let item = Item(
            id: "item-b",
            title: "Article",
            mediaType: "text",
            text: "One sentence. Two sentence? Three.",
            externalReference: nil,
            status: "ready"
        )

        let plan = WatchPackageRenderPlan.make(item: item, map: nil, createdAt: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(plan.segments.map(\.id), ["seg-001", "seg-002", "seg-003"])
        XCTAssertEqual(plan.segments.map(\.text), ["One sentence.", "Two sentence?", "Three."])
    }

    func testRenderPlanRejectsEmptyText() {
        let item = Item(
            id: "item-empty",
            title: "Empty",
            mediaType: "text",
            text: "   \n ",
            externalReference: nil,
            status: "ready"
        )

        let plan = WatchPackageRenderPlan.make(item: item, map: nil, createdAt: Date(timeIntervalSince1970: 14))

        XCTAssertTrue(plan.segments.isEmpty)
    }

    func testPackageManifestUsesRenderedDurationsForTimelineAndChapters() {
        let item = Item(
            id: "item-c",
            title: "Article",
            mediaType: "text",
            text: "First chapter text. Second chapter text.",
            externalReference: "manual",
            status: "ready"
        )
        let map = ListeningMap(
            id: "map-c",
            itemId: item.id,
            overview: "Overview",
            chapters: [
                Chapter(id: "ch-first", title: "First", startChar: 0, endChar: 19, percent: 0),
                Chapter(id: "ch-second", title: "Second", startChar: 20, endChar: 40, percent: 50)
            ]
        )
        let createdAt = Date(timeIntervalSince1970: 20)
        let plan = WatchPackageRenderPlan.make(item: item, map: map, createdAt: createdAt)

        let package = WatchPackageRenderPlan.makePackage(
            item: item,
            map: map,
            plan: plan,
            segmentDurationsMs: [1_200, 2_300],
            audioSHA256: "abc123",
            createdAt: createdAt
        )

        XCTAssertEqual(package.id, "watch-package-item-c-20")
        XCTAssertEqual(package.primaryAudioAsset?.fileName, "watch-package-item-c-20.m4a")
        XCTAssertEqual(package.primaryAudioAsset?.durationMs, 3_500)
        XCTAssertEqual(package.primaryAudioAsset?.sha256, "abc123")
        XCTAssertEqual(package.transcript.segments.map(\.startMs), [0, 1_200])
        XCTAssertEqual(package.transcript.segments.map(\.endMs), [1_200, 3_500])
        XCTAssertEqual(package.chapters.map(\.startMs), [0, 1_200])
        XCTAssertEqual(package.chapters.map(\.transcriptSegmentId), ["seg-ch-first", "seg-ch-second"])
    }
}
