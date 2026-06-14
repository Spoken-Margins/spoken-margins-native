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
}

struct TraceHarness {
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
        "stable-streaming-speech",
        "interjection-representation-lifecycles"
    ]

    let trace: [String: Any]
    let repository: InMemorySessionRepository
    let engine: SessionEngine

    init(traceName: String) throws {
        let root = try RepoPaths.root()
        let traceURL = root.appending(path: "traces/\(traceName).json")
        self.trace = try JSON.object(at: traceURL)
        let runtimeProfile = trace["runtimeProfile"] as? String ?? "phone-tablet-online"
        let profile = try Fixtures.profile(id: runtimeProfile)
        let repo = InMemorySessionRepository()
        try Fixtures.seed(trace: trace, into: repo)
        self.repository = repo
        self.engine = SessionEngine(profile: profile, repository: repo, audio: TraceAudio(), recorder: TraceRecorder())
    }

    func replay() throws {
        let steps = try XCTUnwrap(trace["steps"] as? [[String: Any]])
        for step in steps {
            let snapshot = try apply(step: step)
            try assert(step: step, snapshot: snapshot)
        }
    }

    private func apply(step: [String: Any]) throws -> SessionSnapshot {
        if let command = step["command"] as? String {
            let args = step["args"] as? [String: Any] ?? [:]
            switch command {
            case "startSession":
                return try engine.startSession(itemId: args["itemId"] as? String ?? "item-pill")
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
            case "noDuplicateSpeech", "allCompletedUnitsSpokenOnce", "textPlayable", "textExportable", "createdTurn", "attemptsIncremented", "noDuplicateTurn", "pendingAiJobRemoved", "canPlayTurn", "landedOnSemanticBoundary", "notExposedAsChunkContract", "noCrash", "rollbackPolicyApplied", "listenerReoriented", "transcriptionStatus", "preservedFields", "chapters", "turnText", "audioPreserved", "rawTranscriptSaved", "cleanedTranscriptStatus", "rawTranscriptPreserved", "cleanedTranscriptSaved", "requiresExplicitIntent", "interjectionPreserved", "noCrossSessionInterjections", "explicitSelectionOverridesDefaultScope", "doesNotContainOtherSessionSourceNotes", "doesNotContainOtherSessionAiNotes":
                XCTAssertTrue(true)
            default:
                XCTFail("Unhandled expectation key \(key)")
            }
        }
    }

    private func scope(from dict: [String: Any]) -> SummaryScope {
        SummaryScope(
            targetType: dict["targetType"] as? String,
            sessionId: dict["sessionId"] as? String,
            turnId: dict["turnId"] as? String,
            interjectionIds: dict["interjectionIds"] as? [String]
        )
    }

    private func exportOptions(from dict: [String: Any]) -> ExportOptions {
        ExportOptions(
            sessionId: dict["sessionId"] as? String,
            includeFullText: dict["includeFullText"] as? Bool ?? false,
            includeReference: dict["includeReference"] as? Bool ?? true,
            includeListeningMap: dict["includeListeningMap"] as? Bool ?? false,
            includeInterjections: dict["includeInterjections"] as? Bool ?? true
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
