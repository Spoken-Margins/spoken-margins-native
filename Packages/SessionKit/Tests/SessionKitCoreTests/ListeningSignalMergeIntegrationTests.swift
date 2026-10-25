import Foundation
import XCTest
import SessionKitTestInputs

/// Host-only wiring checks for #567's overlapping edits with #273 and #466.
/// These catch merge omissions; app builds and journeys still verify the runtime boundary.
final class ListeningSignalMergeIntegrationTests: XCTestCase {
    func testPlaybackTickerPassesConfirmedStatusToTheSignalCollector() throws {
        let source = try appSource("Gate1AppModel.swift")
        let tick = try functionBody(source, signature: "func tickPlaybackProgress()")
        let call = try XCTUnwrap(
            tick.range(of: #"listeningSignals\s*\.\s*playbackProgress\(\s*itemId:\s*updated\.itemId,\s*status:\s*updated\.status,\s*transport:\s*engine\.currentPlaybackTransportState\(\)\s*\)"#,
                       options: .regularExpression),
            "starting playback is not confirmed listening, and a stalled player is not listening: the tick must pass the synced status and the transport state"
        )
        // The call sits directly in the tick's `do` block: not behind `if`, `guard` or a loop,
        // and not compiled out.
        XCTAssertEqual(braceDepth(of: tick, at: call.lowerBound), 1, "the collector call must run on every tick")
        XCTAssertFalse(tick.contains("#if"), "the tick must not compile the collector call out")
        XCTAssertFalse(source.contains("listeningSignals.listened(itemId: updated.itemId)"))

        // And the tick is what the 500 ms ticker runs, and playback starting starts the ticker.
        let ticker = try functionBody(source, signature: "func startPlaybackProgressTicker()")
        XCTAssertTrue(ticker.contains("Task {") && ticker.contains("tickPlaybackProgress()"),
                      "the ticker must run the tick")
        XCTAssertEqual(braceDepth(of: ticker, at: try XCTUnwrap(ticker.range(of: "tickPlaybackProgress()")).lowerBound), 4,
                       "the ticker's Task loop (Task, while, MainActor.run, the tick's hang label) must be the caller")
        XCTAssertTrue(ticker.contains("hangTelemetry.labels.scoped("), "a stuck tick holds play at starting, so a hang names it (#2255)")
        let reconcile = try functionBody(source, signature: "func reconcilePlaybackProgressTicker()")
        let starts = try XCTUnwrap(reconcile.range(of: "startPlaybackProgressTicker()"), "playback starting must start the ticker")
        let otherBranch = try XCTUnwrap(reconcile.range(of: "else"))
        XCTAssertLessThan(starts.lowerBound, otherBranch.lowerBound, "the ticker starts when playback is active, not when it stops")
    }

    func testAllSpokenMarginCompletionRoutesShareTheSignalHook() throws {
        for (file, start, end) in [
            ("Gate1AppModel+MarginCapture.swift", "func finishInterjection()", "func cancelInterjection()"),
            ("Gate1AppModel.swift", "func performGate2CompactCommand(", "private func compactSkipUnit(")
        ] {
            let route = try body(appSource(file), from: start, to: end)
            XCTAssertTrue(route.contains("transcribeAndRecordSavedSpokenMargin()"), start)
            XCTAssertTrue(route.contains("recordSpokenMarginSavedBeforeFailure(engine"),
                          "\(start): a Margin saved before resuming playback failed still counts")
        }
        let helper = try appSource("Gate1AppModel+ListeningSignals.swift")
        XCTAssertTrue(helper.contains("listeningSignals.spokenMargin(sessionId: interjection.sessionId, interjectionId:"))
        XCTAssertTrue(helper.contains("scheduleTranscription(for:"))
    }

    /// The coordinator's recording is proven in FollowedSourceSignalTests; this keeps the app from handing it no
    /// recorder (#1896).
    func testTheAppBuildsEveryFollowedSourceCoordinatorWithTheAppSignalLog() throws {
        for file in ["Gate1AppModel.swift", "Gate1AppModel+LazyServices.swift"] {
            let source = try appSource(file)
            let builds = source.components(separatedBy: "FollowedSourceCoordinator(repository:").dropFirst()
            XCTAssertFalse(builds.isEmpty, "\(file) no longer builds the coordinator: update this guard")
            for build in builds {
                let line = String(build.prefix { $0 != "\n" })
                XCTAssertTrue(line.contains("signals: .app)"), "\(file): the coordinator needs the app's signal log, got: \(line)")
            }
        }
    }

    // The item_published signal itself is proven by a recorded row in FollowedSourceSignalTests (#1896).
    func testFeedSaveKeepsGUIDsAndAutomaticImportCandidates() throws {
        let source = try packageSource(at: "Sources/SessionKitFeeds/FollowedSourceCoordinator.swift")
        let save = try body(source, from: "private func save(entries:", to: "private static func entryID(")
        XCTAssertFalse(save.contains("<<<<<<<"), "The feed-save merge must be resolved")
        XCTAssertTrue(save.contains("episodeGUID: item.guid"), "Keep the feed GUID used by podcast anchors")
        try assertOrdered([
            "let seenAt = Date()",
            "var saved: [FeedEntry] = []",
            "try repository.saveFeedEntry(entry)",
            "saved.append(entry)",
            "return (saved, existingEntries)",
        ], in: save)
        XCTAssertFalse(save.contains("if existing[id] == nil {"),
                       "Entries already stored still publish once; the recorder deduplicates")
    }

    func testManualCompletionRecordsFinishOnlyAfterTheCompletionHelperChangesTheItem() throws {
        let source = try appSource("Gate1AppModel+CompletionMarking.swift")
        let completion = try body(source, from: "func markItemCompleted(id:", to: "func undoMarkedCompletion(")
        XCTAssertFalse(completion.contains("<<<<<<<"), "The completion merge must be resolved")
        try assertOrdered([
            "guard let item = try ManualItemCompletion.markComplete(itemId: id, in: store) else { return }",
            "listeningSignals.finish(itemId: id)",
            "refreshLibraryRowsInBackground(mustPublish: true)",
            "presentCompletionUndo(itemId: id, title: item.title, markedAt: item.sourceCompletedAt ?? Date())",
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

    /// App source with comments and string contents blanked, so a match cannot come from a comment
    /// or a string, and braces inside strings do not confuse `functionBody`.
    private func appSource(_ name: String) throws -> String {
        blankingCommentsAndStrings(try TestInputs.text(.appSources, name))
    }

    /// A SessionKit source file, blanked the same way.
    private func packageSource(at relativePath: String) throws -> String {
        let raw = try String(contentsOf: TestInputs.packageURL(relativePath), encoding: .utf8)
        return blankingCommentsAndStrings(raw)
    }

    private func blankingCommentsAndStrings(_ source: String) -> String {
        enum Mode { case code, lineComment, blockComment, string }
        var out = ""
        var mode = Mode.code
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch mode {
            case .code:
                if c == "/", next == "/" { mode = .lineComment; i += 1 }
                else if c == "/", next == "*" { mode = .blockComment; i += 1 }
                else if c == "\"" { mode = .string; out.append(c) }
                else { out.append(c) }
            case .lineComment:
                if c == "\n" { mode = .code; out.append(c) }
            case .blockComment:
                if c == "*", next == "/" { mode = .code; i += 1 } else if c == "\n" { out.append(c) }
            case .string:
                if c == "\\" { i += 1 }
                else if c == "\"" { mode = .code; out.append(c) }
            }
            i += 1
        }
        return out
    }

    /// The text from `signature`'s opening brace to its matching close, braces included.
    private func functionBody(_ source: String, signature: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "Missing \(signature)")
        let open = try XCTUnwrap(source.range(of: "{", range: start.upperBound..<source.endIndex))
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        XCTFail("Unbalanced braces in \(signature)")
        return ""
    }

    /// How many `{` are open at `position`, counting the body's own brace as 0.
    private func braceDepth(of body: String, at position: String.Index) -> Int {
        let open = body[body.startIndex..<position].filter { $0 == "{" }.count
        let close = body[body.startIndex..<position].filter { $0 == "}" }.count
        return open - close - 1
    }
}
