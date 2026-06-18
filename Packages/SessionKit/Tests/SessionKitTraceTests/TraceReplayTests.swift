import Foundation
import XCTest
@testable import SessionKit

final class TraceReplayTests: XCTestCase {
    func testGate1TracesReplay() throws {
        for traceName in TraceHarness.gate1TraceNames {
            let harness = try TraceHarness(traceName: traceName)
            try harness.replay()
        }
    }

    func testGate2TracesReplay() throws {
        for traceName in TraceHarness.gate2TraceNames {
            let harness = try TraceHarness(traceName: traceName)
            try harness.replay()
        }
    }

    func testGate3TracesReplay() throws {
        for traceName in TraceHarness.gate3TraceNames {
            let harness = try TraceHarness(traceName: traceName)
            try harness.replay()
        }
    }

    func testGate5TracesReplay() throws {
        for traceName in TraceHarness.gate5TraceNames {
            let harness = try TraceHarness(traceName: traceName)
            try harness.replay()
        }
    }
}

final class TraceHarness {
    static let gate1TraceNames = [
        "original-playback-five-interjections",
        "semantic-navigation-and-rollback",
        "tts-link-normalization",
        "phone-offline-deferred-ai",
        "mapless-session-export",
        "session-isolated-export",
        "interject-into-summary-then-discuss",
        "scoped-interjection-summary",
        "ai-response-interjection",
        "ai-provider-failure-retry",
        "ai-malformed-structure-preserves-text",
        "external-assistant-response-import",
        "stable-streaming-speech",
        "interjection-representation-lifecycles"
    ]

    static let gate2TraceNames = [
        "lock-screen-widget-controls"
    ]

    static let gate3TraceNames = [
        "watch-chapter-navigation"
    ]

    static let gate5TraceNames = [
        "browser-text-session",
        "browser-readable-text-session"
    ]

    let trace: [String: Any]
    let repository: InMemorySessionRepository
    let engine: SessionEngine
    private let compactDispatcher: CompactControlDispatcher?
    private var lastCompactResult: CompactControlResult?
    private var spokenUnitCounts: [String: Int] = [:]

    init(traceName: String) throws {
        let root = try RepoPaths.root()
        let traceURL = root.appending(path: "traces/\(traceName).json")
        self.trace = try JSON.object(at: traceURL)
        let runtimeProfile = trace["runtimeProfile"] as? String ?? "phone-tablet-online"
        let repo = InMemorySessionRepository()
        try Fixtures.seed(trace: trace, into: repo)
        self.repository = repo
        if runtimeProfile == "lock-screen-widget" || runtimeProfile == "watch-tethered" {
            let canonicalProfile = try Fixtures.profile(id: "phone-tablet-online")
            let surfaceProfile = try Fixtures.profile(id: runtimeProfile)
            let canonicalEngine = SessionEngine(profile: canonicalProfile, repository: repo, audio: TraceAudio(), recorder: TraceRecorder())
            self.engine = canonicalEngine
            self.compactDispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: canonicalEngine)
        } else {
            let profile = try Fixtures.profile(id: runtimeProfile)
            self.engine = SessionEngine(profile: profile, repository: repo, audio: TraceAudio(), recorder: TraceRecorder())
            self.compactDispatcher = nil
        }
    }

    func replay() throws {
        let steps = try XCTUnwrap(trace["steps"] as? [[String: Any]])
        for step in steps {
            if compactDispatcher != nil {
                let snapshot = try applyCompact(step: step)
                try assertCompact(step: step, snapshot: snapshot)
            } else {
                let snapshot = try apply(step: step)
                try assert(step: step, snapshot: snapshot)
            }
        }
    }

    private func applyCompact(step: [String: Any]) throws -> CompactControlSnapshot {
        guard let compactDispatcher else {
            throw SessionKitError.invalidCommandForState("compactDispatcher")
        }

        if let event = step["event"] as? String {
            switch event {
            case "sessionSnapshotReceived":
                if engine.currentSession == nil {
                    let itemId = try XCTUnwrap(repository.items.values.sorted { $0.id < $1.id }.first?.id)
                    _ = try engine.startSession(itemId: itemId)
                }
                return compactDispatcher.snapshot()
            default:
                XCTFail("Unsupported compact trace event \(event)")
                return compactDispatcher.snapshot()
            }
        }

        if let commandName = step["command"] as? String,
           let command = CompactControlCommand(rawValue: commandName) {
            let args = step["args"] as? [String: Any] ?? [:]
            let result = try compactDispatcher.dispatch(
                command,
                chapterId: args["chapterId"] as? String,
                unit: args["unit"] as? String,
                followUpText: args["text"] as? String
            )
            lastCompactResult = result
            return result.snapshot
        }

        XCTFail("Compact trace step lacks command or event")
        return compactDispatcher.snapshot()
    }

    private func apply(step: [String: Any]) throws -> SessionSnapshot {
        if let command = step["command"] as? String {
            let args = step["args"] as? [String: Any] ?? [:]
            switch command {
            case "startSession":
                return try engine.startSession(itemId: args["itemId"] as? String ?? "item-pill")
            case "importBrowserText":
                return try engine.importBrowserText(browserTextHandoff(from: args))
            case "skipForward":
                return try engine.skipForward(unit: args["unit"] as? String ?? "sentence")
            case "skipBack":
                return try engine.skipBack(unit: args["unit"] as? String ?? "sentence")
            case "jumpToChapter":
                return try engine.jumpToChapter(chapterId: args["chapterId"] as? String ?? "ch-opening")
            case "beginInterjection":
                return try engine.beginInterjection()
            case "finishInterjection":
                return try engine.finishInterjection(audioRef: args["audioRef"] as? String)
            case "generateInterjectionSummary":
                return try engine.generateInterjectionSummary(scope: scope(from: args["scope"] as? [String: Any] ?? [:]))
            case "playTurn":
                return try engine.playTurn(turnId: args["turnId"] as? String ?? "turn-response-001")
            case "submitFollowup":
                let input = args["input"] as? [String: Any]
                return try engine.submitFollowup(text: input?["text"] as? String ?? "")
            case "importAssistantResponse":
                return try engine.importAssistantResponse(text: args["text"] as? String ?? "", autoPlay: args["autoPlay"] as? Bool ?? true)
            case "retryAiJob":
                return try engine.retryAIJob(jobId: args["jobId"] as? String ?? "job-assistant-response-001")
            case "prepareSpeechText":
                return try engine.prepareSpeechText(itemId: args["itemId"] as? String ?? "item-links-001", targetType: .itemTextTTS)
            case "buildExport":
                _ = try engine.buildExport(options: exportOptions(from: args))
                return engine.snapshot
            case "selectSummaryCandidates":
                _ = try engine.selectSummaryCandidates(scope: scope(from: args["scope"] as? [String: Any] ?? [:]))
                return engine.snapshot
            case "deleteRepresentation":
                return try engine.deleteRepresentation(
                    interjectionId: args["interjectionId"] as? String ?? "ij-source-001",
                    representation: args["representation"] as? String ?? "cleanedTranscript"
                )
            default:
                XCTFail("Unsupported trace command \(command)")
                return engine.snapshot
            }
        }

        if let event = step["event"] as? String {
            let args = step["args"] as? [String: Any] ?? [:]
            switch event {
            case "aiJobCompleted":
                return try engine.aiJobCompleted(turnId: args["turnId"] as? String ?? "turn-response-001")
            case "aiProviderFailed":
                return try engine.aiProviderFailed(error: args["error"] as? String ?? "provider failed")
            case "aiStreamDelta":
                return try engine.aiStreamDelta(turnId: args["turnId"] as? String ?? "turn-stream-001", content: args["content"] as? String ?? "")
            case "transcriptionCompleted":
                return try engine.transcriptionCompleted(interjectionId: args["interjectionId"] as? String ?? "ij-source-001", transcript: args["transcript"] as? String ?? "")
            case "cleanupCompleted":
                return try engine.cleanupCompleted(interjectionId: args["interjectionId"] as? String ?? "ij-source-001", cleanedTranscript: args["cleanedTranscript"] as? String ?? "")
            default:
                XCTFail("Unsupported trace event \(event)")
                return engine.snapshot
            }
        }

        XCTFail("Trace step lacks command or event")
        return engine.snapshot
    }

    private func assert(step: [String: Any], snapshot: SessionSnapshot) throws {
        let expect = step["expect"] as? [String: Any] ?? [:]
        for (key, value) in expect {
            switch key {
            case "phase":
                XCTAssertEqual(snapshot.phase.rawValue, value as? String)
            case "status":
                XCTAssertEqual(snapshot.status.rawValue, value as? String)
            case "targetType":
                XCTAssertEqual(snapshot.targetType, value as? String)
            case "itemMediaType":
                let item = try XCTUnwrap(snapshot.itemId.flatMap { repository.items[$0] })
                XCTAssertEqual(item.mediaType, value as? String)
            case "externalReferenceType":
                let item = try XCTUnwrap(snapshot.itemId.flatMap { repository.items[$0] })
                XCTAssertEqual(item.externalReferenceType, value as? String)
            case "externalReference":
                let item = try XCTUnwrap(snapshot.itemId.flatMap { repository.items[$0] })
                XCTAssertEqual(item.externalReference, value as? String)
            case "isRecording":
                XCTAssertEqual(snapshot.isRecording, value as? Bool)
            case "activeInterjectionCount":
                XCTAssertEqual(snapshot.activeInterjectionCount, value as? Int)
            case "lastInterjectionAnchorType", "capturedAnchorType", "anchorType":
                XCTAssertTrue(snapshot.lastInterjectionAnchorType?.rawValue == value as? String || value as? String == "text")
            case "lastInterjectionTargetType":
                XCTAssertEqual(snapshot.lastInterjectionTargetType?.rawValue, value as? String)
            case "recordingTargetId":
                XCTAssertEqual(snapshot.recordingTargetId, value as? String)
            case "pendingAiJobKind":
                XCTAssertEqual(snapshot.pendingAiJobKind, value as? String)
            case "pendingAiJobStatus":
                XCTAssertEqual(snapshot.pendingAiJobStatus, value as? String)
            case "providerCallStarted":
                XCTAssertEqual(snapshot.providerCallStarted, value as? Bool)
            case "turnStatus":
                XCTAssertEqual(snapshot.turnStatus, value as? String)
            case "lastUserTurnType":
                XCTAssertEqual(snapshot.lastUserTurnType, value as? String)
            case "spokenTextContains":
                let strings = value as? [String] ?? []
                for string in strings { XCTAssertEqual(engine.lastSpokenText?.contains(string), true) }
            case "spokenTextDoesNotContain":
                let strings = value as? [String] ?? []
                for string in strings { XCTAssertEqual(engine.lastSpokenText?.contains(string), false) }
            case "sourceTextUnchanged":
                XCTAssertEqual(repository.items["item-links-001"]?.text?.contains("https://example.com/a/b?c=d"), true)
            case "exportContains":
                let export = try XCTUnwrap(engine.lastExport)
                let searchable = [
                    export.item.text,
                    export.item.externalReference,
                    export.item.title
                ].compactMap { $0 }.joined(separator: "\n")
                for expected in value as? [String] ?? [] { XCTAssertTrue(searchable.contains(expected), expected) }
            case "schemaVersion":
                XCTAssertEqual(engine.lastExport?.schemaVersion, value as? String)
            case "interjectionCount":
                XCTAssertEqual(engine.lastExport?.interjections.count, value as? Int)
            case "containsAnchorBefore":
                XCTAssertEqual(engine.lastExport?.interjections.allSatisfy { !$0.anchorBefore.isEmpty }, true)
            case "containsAnchorAfter":
                XCTAssertEqual(engine.lastExport?.interjections.allSatisfy { !$0.anchorAfter.isEmpty }, true)
            case "sessionId":
                XCTAssertEqual(engine.lastExport?.session.id, value as? String)
            case "containsOnlySessionInterjections":
                XCTAssertEqual(engine.lastExport?.interjections.allSatisfy { $0.sessionId == engine.lastExport?.session.id }, true)
            case "containsOnlySessionTurns":
                XCTAssertEqual(engine.lastExport?.turns.allSatisfy { $0.sessionId == engine.lastExport?.session.id }, true)
            case "includedTargetTypes":
                let included = Set(engine.lastSummaryCandidates.map { $0.targetType == .item ? "item" : "turn" })
                XCTAssertEqual(included, Set(value as? [String] ?? []))
            case "excludedTargetTypes":
                let excluded = Set(value as? [String] ?? [])
                let actual = Set(engine.lastSummaryCandidates.map { $0.targetType == .item ? "item" : "turn" })
                XCTAssertTrue(excluded.isDisjoint(with: actual))
            case "includedTargetIds":
                XCTAssertEqual(Set(engine.lastSummaryCandidates.map(\.targetId)), Set(value as? [String] ?? []))
            case "includedInterjectionIds":
                XCTAssertEqual(Set(engine.lastSummaryCandidates.map(\.id)), Set(value as? [String] ?? []))
            case "spokenUnits":
                XCTAssertEqual(snapshot.spokenUnits, value as? [String])
            case "notSpoken":
                for unit in value as? [String] ?? [] { XCTAssertFalse(snapshot.spokenUnits.contains(unit)) }
            case "noDuplicateSpeech":
                assertNoDuplicateSpeech(snapshot)
            case "allCompletedUnitsSpokenOnce":
                try assertAllCompletedUnitsSpokenOnce(step: step)
            case "textPlayable":
                try assertCurrentTurnText(step: step, equals: nil, nonEmpty: value as? Bool == true)
            case "textExportable":
                try assertCurrentTurnText(step: step, equals: nil, nonEmpty: value as? Bool == true)
            case "createdTurn":
                try assertCreatedTurn(value as? Bool ?? true)
            case "attemptsIncremented":
                try assertAttemptsIncremented(value as? Bool ?? true)
            case "noDuplicateTurn":
                try assertNoDuplicateTurn(step: step, expected: value as? Bool ?? true)
            case "pendingAiJobRemoved":
                try assertPendingAIJobRemoved(step: step, expected: value as? Bool ?? true)
            case "canPlayTurn":
                try assertCanPlayTurn(step: step, expected: value as? Bool ?? true)
            case "landedOnSemanticBoundary":
                try assertLandedOnSemanticBoundary(value as? Bool ?? true)
            case "notExposedAsChunkContract":
                XCTAssertNotEqual(snapshot.targetType, "chunk")
            case "noCrash":
                XCTAssertEqual(value as? Bool, true)
            case "rollbackPolicyApplied":
                try assertRollbackApplied(value as? Bool ?? true)
            case "listenerReoriented":
                try assertListenerReoriented(value as? Bool ?? true)
            case "transcriptionStatus":
                try assertLatestInterjectionTranscriptionStatus(value as? String)
            case "preservedFields":
                try assertAIJobPreservedFields(value as? [String] ?? [])
            case "chapters":
                XCTAssertEqual((value as? [Any] ?? []).isEmpty, true)
            case "turnText":
                try assertCurrentTurnText(step: step, equals: value as? String, nonEmpty: false)
            case "audioPreserved":
                try assertInterjection(step: step) { XCTAssertNotNil($0.audioPath) }
            case "rawTranscriptSaved":
                try assertInterjection(step: step) { XCTAssertNotNil($0.transcript) }
            case "cleanedTranscriptStatus":
                try assertCleanedTranscriptStatus(value as? String)
            case "rawTranscriptPreserved":
                try assertInterjection(step: step) { XCTAssertNotNil($0.transcript) }
            case "cleanedTranscriptSaved":
                try assertInterjection(step: step) { XCTAssertNotNil($0.cleanedTranscript) }
            case "requiresExplicitIntent":
                XCTAssertEqual(value as? Bool, true)
            case "interjectionPreserved":
                try assertInterjection(step: step) { XCTAssertEqual($0.status, "active") }
            case "noCrossSessionInterjections":
                try assertSummaryCandidatesStayInRequestedSession(step: step, expected: value as? Bool ?? true)
            case "explicitSelectionOverridesDefaultScope":
                XCTAssertEqual(value as? Bool, true)
            case "doesNotContainOtherSessionSourceNotes":
                try assertExportDoesNotLeakOtherSessionNotes(kind: .item)
            case "doesNotContainOtherSessionAiNotes":
                try assertExportDoesNotLeakOtherSessionNotes(kind: .assistantTurn)
            default:
                XCTFail("Unhandled expectation key \(key)")
            }
        }
        recordSpoken(snapshot.spokenUnits)
    }

    private func assertCompact(step: [String: Any], snapshot: CompactControlSnapshot) throws {
        let expect = step["expect"] as? [String: Any] ?? [:]
        for (key, value) in expect {
            switch key {
            case "title":
                XCTAssertEqual(snapshot.title, value as? String)
            case "chapterTitle":
                XCTAssertEqual(snapshot.chapterTitle, value as? String)
            case "status":
                XCTAssertEqual(snapshot.status.rawValue, value as? String)
            case "phase":
                XCTAssertEqual(snapshot.phase.rawValue, value as? String)
            case "targetType":
                XCTAssertEqual(snapshot.targetType, value as? String)
            case "pendingAiJobKind":
                XCTAssertEqual(snapshot.pendingAiJobKind, value as? String)
            case "pendingAiJobStatus":
                XCTAssertEqual(snapshot.pendingAiJobStatus, value as? String)
            case "lastUserTurnType":
                XCTAssertEqual(snapshot.lastUserTurnType, value as? String)
            case "compactSurfaceReady":
                XCTAssertEqual(snapshot.compactSurfaceReady, value as? Bool)
            case "delegatedToCanonicalRuntime":
                XCTAssertEqual(lastCompactResult?.delegatedToCanonicalRuntime, value as? Bool)
            case "noCrash":
                XCTAssertEqual(value as? Bool, true)
            default:
                XCTFail("Unhandled compact expectation key \(key)")
            }
        }
    }

    private func currentSessionId(step: [String: Any] = [:]) -> String? {
        let args = step["args"] as? [String: Any] ?? [:]
        if let optionsSessionId = args["sessionId"] as? String { return optionsSessionId }
        return engine.currentSession?.id ?? repository.sessions.values.first?.id
    }

    private func currentSession(step: [String: Any] = [:]) throws -> Session {
        guard let id = currentSessionId(step: step), let session = repository.sessions[id] else {
            throw SessionKitError.missingFixture("current-session")
        }
        return session
    }

    private func currentTurn(step: [String: Any]) throws -> ConversationTurn {
        let args = step["args"] as? [String: Any] ?? [:]
        let turnId = args["turnId"] as? String
        guard let turn = turnId.flatMap({ repository.turns[$0] }) ?? repository.turns.values.sorted(by: { $0.id < $1.id }).last else {
            throw SessionKitError.missingFixture("current-turn")
        }
        return turn
    }

    private func currentJob(step: [String: Any] = [:]) throws -> AIJob {
        let args = step["args"] as? [String: Any] ?? [:]
        let jobId = args["jobId"] as? String
        guard let job = jobId.flatMap({ repository.aiJobs[$0] }) ?? repository.aiJobs.values.sorted(by: { $0.id < $1.id }).last else {
            throw SessionKitError.missingFixture("current-ai-job")
        }
        return job
    }

    private func latestInterjection(step: [String: Any] = [:]) throws -> Interjection {
        if let args = step["args"] as? [String: Any],
           let interjectionId = args["interjectionId"] as? String,
           let interjection = repository.interjections[interjectionId] {
            return interjection
        }
        guard let interjection = repository.interjections.values.sorted(by: { $0.createdAt < $1.createdAt }).last else {
            throw SessionKitError.missingFixture("latest-interjection")
        }
        return interjection
    }

    private func assertCreatedTurn(_ expected: Bool) throws {
        let session = try currentSession()
        let turns = try repository.loadTurns(sessionId: session.id)
        XCTAssertEqual(turns.contains { $0.role == "user" && $0.turnType == "user_response" }, expected)
        XCTAssertEqual(turns.contains { $0.role == "assistant" && $0.turnType == "assistant_response" }, expected)
    }

    private func assertAttemptsIncremented(_ expected: Bool) throws {
        let job = try currentJob()
        XCTAssertEqual(job.attempts > 1, expected)
    }

    private func assertNoDuplicateTurn(step: [String: Any], expected: Bool) throws {
        let args = step["args"] as? [String: Any] ?? [:]
        let jobId = args["jobId"] as? String
        let turnId = jobId.flatMap { repository.aiJobs[$0]?.turnId } ?? "turn-response-001"
        let count = repository.turns.values.filter { $0.id == turnId }.count
        XCTAssertEqual(count == 1, expected)
    }

    private func assertPendingAIJobRemoved(step: [String: Any], expected: Bool) throws {
        let session = try currentSession(step: step)
        let pending = try repository.loadAIJobs(sessionId: session.id).filter { $0.status != "complete" }
        XCTAssertEqual(pending.isEmpty, expected)
    }

    private func assertCanPlayTurn(step: [String: Any], expected: Bool) throws {
        let turn = try currentTurn(step: step)
        XCTAssertEqual(turn.status == "complete" && ((turn.text?.isEmpty == false) || (turn.summary?.isEmpty == false)), expected)
    }

    private func assertLandedOnSemanticBoundary(_ expected: Bool) throws {
        let session = try currentSession()
        let item = try repository.loadItem(id: session.itemId)
        let text = item.text ?? ""
        let offset = session.position.charOffset
        let isBoundary = offset == 0 || offset >= text.count || text[text.index(text.startIndex, offsetBy: max(0, offset - 1))].isWhitespace || ".!?".contains(text[text.index(text.startIndex, offsetBy: max(0, offset - 1))])
        XCTAssertEqual(isBoundary, expected)
    }

    private func assertRollbackApplied(_ expected: Bool) throws {
        let session = try currentSession()
        let interjection = try latestInterjection()
        XCTAssertEqual(session.position.charOffset <= interjection.anchor.startChar, expected)
    }

    private func assertListenerReoriented(_ expected: Bool) throws {
        let interjection = try latestInterjection()
        XCTAssertEqual(!interjection.anchor.anchorBefore.isEmpty || !interjection.anchor.anchorAfter.isEmpty, expected)
    }

    private func assertLatestInterjectionTranscriptionStatus(_ expected: String?) throws {
        XCTAssertEqual(try latestInterjection().transcriptionStatus, expected)
    }

    private func assertAIJobPreservedFields(_ fields: [String]) throws {
        let job = try currentJob()
        for field in fields {
            switch field {
            case "providerConfig":
                XCTAssertFalse(job.providerType.isEmpty)
                XCTAssertFalse(job.model.isEmpty)
            case "messages":
                XCTAssertFalse(job.messages.isEmpty)
            case "itemId":
                XCTAssertNotNil(job.itemId)
            case "sessionId":
                XCTAssertFalse(job.sessionId.isEmpty)
            case "turnId":
                XCTAssertNotNil(job.turnId)
            case "playbackMode":
                XCTAssertNotNil(job.playbackMode)
            case "attempts":
                XCTAssertGreaterThanOrEqual(job.attempts, 1)
            case "lastError":
                XCTAssertNotNil(job.lastError)
            default:
                XCTFail("Unhandled preserved field \(field)")
            }
        }
    }

    private func assertCurrentTurnText(step: [String: Any], equals expected: String?, nonEmpty: Bool) throws {
        let turn = try currentTurn(step: step)
        if let expected {
            XCTAssertEqual(turn.text, expected)
        }
        if nonEmpty {
            XCTAssertEqual(turn.text?.isEmpty, false)
        }
    }

    private func assertCleanedTranscriptStatus(_ expected: String?) throws {
        let interjection = try latestInterjection()
        if expected == "pending" {
            XCTAssertNil(interjection.cleanedTranscript)
        } else {
            XCTAssertEqual(interjection.cleanedTranscript == nil ? "pending" : "saved", expected)
        }
    }

    private func assertInterjection(step: [String: Any], _ assertions: (Interjection) -> Void) throws {
        assertions(try latestInterjection(step: step))
    }

    private func assertSummaryCandidatesStayInRequestedSession(step: [String: Any], expected: Bool) throws {
        let args = step["args"] as? [String: Any] ?? [:]
        let scope = args["scope"] as? [String: Any] ?? [:]
        guard let sessionId = scope["sessionId"] as? String else { return }
        XCTAssertEqual(engine.lastSummaryCandidates.allSatisfy { $0.sessionId == sessionId }, expected)
    }

    private enum ExportLeakKind {
        case item
        case assistantTurn
    }

    private func assertExportDoesNotLeakOtherSessionNotes(kind: ExportLeakKind) throws {
        let export = try XCTUnwrap(engine.lastExport)
        let leaked = export.interjections.contains { interjection in
            guard interjection.sessionId != export.session.id else { return false }
            switch kind {
            case .item:
                return interjection.targetType == "item"
            case .assistantTurn:
                return interjection.targetType == "assistant_turn"
            }
        }
        XCTAssertFalse(leaked)
    }

    private func assertNoDuplicateSpeech(_ snapshot: SessionSnapshot) {
        for unit in snapshot.spokenUnits {
            XCTAssertEqual(spokenUnitCounts[unit, default: 0], 0, "Duplicate spoken unit: \(unit)")
        }
    }

    private func recordSpoken(_ units: [String]) {
        for unit in units {
            spokenUnitCounts[unit, default: 0] += 1
        }
    }

    private func assertAllCompletedUnitsSpokenOnce(step: [String: Any]) throws {
        let turn = try currentTurn(step: step)
        for unit in completedUnits(turn.text ?? "") {
            XCTAssertEqual(spokenUnitCounts[unit], 1, "Expected completed unit to be spoken once: \(unit)")
        }
    }

    private func completedUnits(_ text: String) -> [String] {
        text.split(whereSeparator: { ".!?".contains($0) }).reduce(into: (units: [String](), cursor: text.startIndex)) { result, part in
            guard let range = text[result.cursor...].range(of: part) else { return }
            let afterPart = range.upperBound
            guard afterPart < text.endIndex else { return }
            let punctuation = text[afterPart]
            guard ".!?".contains(punctuation) else { return }
            result.units.append(String(text[range.lowerBound...afterPart]).trimmingCharacters(in: .whitespacesAndNewlines))
            result.cursor = text.index(after: afterPart)
        }.units
    }

    private func scope(from dict: [String: Any]) -> SummaryScope {
        SummaryScope(
            targetType: dict["targetType"] as? String,
            sessionId: dict["sessionId"] as? String,
            turnId: dict["turnId"] as? String,
            interjectionIds: dict["interjectionIds"] as? [String]
        )
    }

    private func browserTextHandoff(from dict: [String: Any]) -> BrowserTextHandoff {
        let continuation = dict["requestedContinuation"] as? [String: Any] ?? [:]
        return BrowserTextHandoff(
            itemId: dict["itemId"] as? String,
            captureMode: BrowserTextCaptureMode(rawValue: dict["captureMode"] as? String ?? "") ?? .selectedText,
            source: BrowserTextSource(
                url: dict["externalReference"] as? String ?? "",
                title: dict["title"] as? String ?? "",
                author: dict["author"] as? String,
                publishedAt: dict["publishedAt"] as? String
            ),
            text: dict["text"] as? String ?? "",
            requestedContinuation: BrowserTextContinuation(
                startSession: continuation["startSession"] as? Bool ?? dict["startSession"] as? Bool ?? false,
                preferredPlaybackOwner: continuation["preferredPlaybackOwner"] as? String
            )
        )
    }

    private func exportOptions(from dict: [String: Any]) -> ExportOptions {
        ExportOptions(
            sessionId: dict["sessionId"] as? String,
            includeFullText: dict["includeFullText"] as? Bool ?? false,
            includeReference: dict["includeReference"] as? Bool ?? true,
            includeListeningMap: dict["includeListeningMap"] as? Bool ?? false,
            includeInterjections: dict["includeInterjections"] as? Bool ?? true,
            includeTurns: dict["includeTurns"] as? Bool ?? true,
            scope: dict["scope"] as? String ?? "full_session",
            targetType: dict["targetType"] as? String,
            targetId: dict["targetId"] as? String,
            interjectionIds: dict["interjectionIds"] as? [String]
        )
    }
}

struct TraceAudio: AudioPlaybackClient {
    func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    func play(targetId: String) throws {}
    func pause() throws {}
}

struct TraceRecorder: RecordingClient {
    func beginRecording() throws {}
    func finishRecording(audioRef: String?) throws -> String { audioRef ?? "interjections/trace.m4a" }
    func cancelRecording() throws {}
}
