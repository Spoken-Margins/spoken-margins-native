import Foundation
import XCTest

/// Host-only wiring checks for #567's overlapping edits with #273 and #466.
/// These catch merge omissions; app builds and journeys still verify the runtime boundary.
final class ListeningSignalMergeIntegrationTests: XCTestCase {
    func testPlaybackTickerPassesConfirmedStatusToTheSignalCollector() throws {
        let source = try appSource("Gate1AppModel.swift")
        XCTAssertTrue(source.contains("listeningSignals.playbackProgress(itemId: updated.itemId, status: updated.status, "
                                      + "transport: engine.currentPlaybackTransportState())"),
                      "starting playback is not confirmed listening, and a stalled player is not listening")
        XCTAssertFalse(source.contains("listeningSignals.listened(itemId: updated.itemId)"))
    }

    func testAllSpokenMarginCompletionRoutesShareTheSignalHook() throws {
        let source = try appSource("Gate1AppModel.swift")
        for (start, end) in [
            ("func finishInterjection()", "func cancelInterjection()"),
            ("private func performGate3WatchCommand(", "private func performGate2CompactCommand("),
            ("private func performGate2CompactCommand(", "private func compactSkipUnit(")
        ] {
            let route = try body(source, from: start, to: end)
            XCTAssertTrue(route.contains("transcribeAndRecordSavedSpokenMargin()"), start)
            XCTAssertTrue(route.contains("recordSpokenMarginSavedBeforeFailure(engine"),
                          "\(start): a Margin saved before resuming playback failed still counts")
        }
        let helper = try appSource("Gate1AppModel+ListeningSignals.swift")
        XCTAssertTrue(helper.contains("listeningSignals.spokenMargin(sessionId: interjection.sessionId, interjectionId:"))
        XCTAssertTrue(helper.contains("scheduleTranscription(for:"))
    }

    func testFeedSaveKeepsPublicationSignalsGUIDsAndAutomaticImportCandidates() throws {
        let source = try appSource("FollowedSourceCoordinator.swift")
        let save = try body(source, from: "private func save(entries:", to: "private static func entryID(")
        XCTAssertFalse(save.contains("<<<<<<<"), "The feed-save merge must be resolved")
        XCTAssertTrue(save.contains("episodeGUID: item.guid"), "Keep the feed GUID used by podcast anchors")
        try assertOrdered([
            "let seenAt = Date()",
            "var saved: [FeedEntry] = []",
            "try repository.saveFeedEntry(entry)",
            "saved.append(entry)",
            "signals?.record(.itemPublished",
            "return (saved, existingEntries)",
        ], in: save)
        XCTAssertFalse(save.contains("if existing[id] == nil {"),
                       "Entries already stored still publish once; the recorder deduplicates")
    }

    func testManualCompletionRecordsFinishOnlyAfterTheCompletionHelperChangesTheItem() throws {
        let source = try appSource("Gate1AppModel.swift")
        let completion = try body(source, from: "func markItemCompleted(id:", to: "func undoMarkedCompletion()")
        XCTAssertFalse(completion.contains("<<<<<<<"), "The completion merge must be resolved")
        try assertOrdered([
            "guard let item = try ManualItemCompletion.markComplete(itemId: id, in: store) else { return }",
            "listeningSignals.finish(itemId: id)",
            "try refreshLibraryRows(store: store)",
            "completionUndo = (id, item.title, item.sourceCompletedAt ?? Date())",
        ], in: completion)
        XCTAssertFalse(completion.contains("try store.saveItem"), "Completion stays in the host-tested helper")
    }

    private func assertOrdered(_ fragments: [String], in source: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var remaining = source[...]
        for fragment in fragments {
            let range = try XCTUnwrap(remaining.range(of: fragment), "Missing or out of order: \(fragment)", file: file, line: line)
            remaining = remaining[range.upperBound...]
        }
    }

    private func body(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SessionKitCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SessionKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository
        return try String(contentsOf: root.appendingPathComponent("App/SpokenMarginsApp/Sources/SpokenMarginsApp/\(name)"), encoding: .utf8)
    }
}
