import Foundation

public final class SessionEngine {
    public private(set) var profile: RuntimeCapabilityProfile
    public private(set) var snapshot = SessionSnapshot()
    public private(set) var currentSession: Session?
    public private(set) var currentItem: Item?
    public private(set) var currentMap: ListeningMap?
    public private(set) var lastExport: SessionExport?
    public private(set) var lastSummaryCandidates: [Interjection] = []
    public private(set) var lastSpokenText: String?
    public private(set) var lastScheduledTranscriptionInterjectionId: String?

    private let repository: SessionRepository
    private let audio: AudioPlaybackClient
    private let recorder: RecordingClient
    private let transcriber: TranscriptionClient
    private let aiProvider: AIProviderClient
    private var recordingAnchor: Anchor?
    private var recordingTargetType: InterjectionTargetType?
    private var recordingTargetId: String?
    private var priorPhase: SessionPhase?
    private var streamingBuffers: [String: String] = [:]
    private var spokenPrefixes: [String: Int] = [:]

    private struct PlaybackPlan {
        var text: String
        var audioOffset: Int
    }

    private struct PlaybackProgress {
        var sourcePercent: Int
        var currentPercent: Int
        var chapterTitle: String?
    }

    public init(
        profile: RuntimeCapabilityProfile,
        repository: SessionRepository,
        audio: AudioPlaybackClient = NoopAudioPlaybackClient(),
        recorder: RecordingClient = NoopRecordingClient(),
        transcriber: TranscriptionClient = DeferredTranscriptionClient(),
        aiProvider: AIProviderClient = DeterministicAIProvider()
    ) {
        self.profile = profile
        self.repository = repository
        self.audio = audio
        self.recorder = recorder
        self.transcriber = transcriber
        self.aiProvider = aiProvider
    }

    @discardableResult
    public func startSession(itemId: String) throws -> SessionSnapshot {
        try require("startSession", category: "sync", capabilities: ["canonical_persistence", "receive_prepared_packages", "browser_session_handoff"])
        let item = try repository.loadItem(id: itemId)
        currentItem = item
        currentMap = try repository.loadListeningMap(itemId: itemId)
        let session = Session(
            id: nextSessionId(itemId: itemId),
            itemId: itemId,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .itemTextTTS,
            currentTargetId: itemId,
            position: Position(charOffset: 0, chapterId: nil),
            completionPercent: 0,
            playbackRate: 1
        )
        currentSession = session
        try repository.saveSession(session)
        try playCurrentTarget(session)
        publish(status: .playing, phase: .itemPlayback)
        return snapshot
    }

    @discardableResult
    public func togglePlayPause() throws -> SessionSnapshot {
        if snapshot.status == .playing {
            return try pause()
        }
        return try resumePlayback()
    }

    @discardableResult
    public func pause() throws -> SessionSnapshot {
        try requirePlayback("pause")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("pause")
        }
        if session.currentTargetType == .itemTextTTS {
            session = syncSessionPositionFromAudio(session, item: currentItem)
        } else if session.currentTargetType == .summaryTurnTTS || session.currentTargetType == .assistantTurnTTS {
            session = try syncGeneratedTurnPositionFromAudio(session)
        }
        currentSession = session
        try repository.saveSession(session)
        try audio.pause()
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func resumePlayback() throws -> SessionSnapshot {
        try requirePlayback("resumePlayback")
        guard let session = currentSession else {
            throw SessionKitError.invalidCommandForState("resumePlayback")
        }
        try playCurrentTarget(session)
        publish(status: .playing, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func stopPlayback() throws -> SessionSnapshot {
        guard let session = currentSession else {
            throw SessionKitError.invalidCommandForState("stopPlayback")
        }
        try audio.stop()
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func syncPlaybackProgress() throws -> SessionSnapshot {
        guard var session = currentSession else {
            return snapshot
        }
        let playbackCompleted = audio.isPlaybackComplete(targetId: session.currentTargetId)
        var updated = syncSessionPositionFromAudio(session, item: currentItem)
        if playbackCompleted {
            updated = markPlaybackComplete(updated, item: currentItem)
        }
        if updated.position != session.position
            || updated.completionPercent != session.completionPercent
            || updated.phase != session.phase {
            session = updated
            currentSession = session
            try repository.saveSession(session)
        }
        publish(status: playbackCompleted ? .paused : snapshot.status, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func prepareSpeechText(itemId: String, targetType: TargetType) throws -> SessionSnapshot {
        let item = try repository.loadItem(id: itemId)
        lastSpokenText = SpeechTextNormalizer.normalize(item.text ?? "")
        currentItem = item
        snapshot.title = item.title
        return snapshot
    }

    @discardableResult
    public func generateListeningMap(itemId: String) throws -> SessionSnapshot {
        try require("generateListeningMap", category: "ai", capabilities: ["generate_listening_map"])
        var item = try repository.loadItem(id: itemId)
        let map = generatedListeningMap(for: item)
        try repository.saveListeningMap(map)
        if item.status == "needs_listening_map" {
            item.status = "ready"
            try repository.saveItem(item)
        }
        if currentItem?.id == itemId || currentSession?.itemId == itemId {
            currentItem = item
            currentMap = map
            if var session = currentSession, session.itemId == itemId {
                session.position.chapterId = chapterId(for: session.position.charOffset)
                currentSession = session
                try repository.saveSession(session)
                publish(status: snapshot.status, phase: session.phase)
            } else {
                snapshot.title = item.title
            }
        }
        return snapshot
    }

    @discardableResult
    public func skipForward(unit: String) throws -> SessionSnapshot {
        return try skipForward(unit: unit, minimumDistance: 0)
    }

    @discardableResult
    public func skipForward(unit: String, minimumDistance: Int) throws -> SessionSnapshot {
        try requirePlayback("skipForward")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("skipForward")
        }
        guard session.currentTargetType == .itemTextTTS else {
            return try skipGeneratedTurnForward(session: session, unit: unit)
        }
        guard let item = currentItem else {
            throw SessionKitError.invalidCommandForState("skipForward")
        }
        session = syncSessionPositionFromAudio(session, item: item)
        let text = item.text ?? ""
        let baseline = session.position.charOffset
        let firstBoundary = nextBoundary(after: baseline, unit: unit, text: text)
        if minimumDistance > 0, firstBoundary < min(text.count, baseline + minimumDistance) {
            session.position.charOffset = nextBoundary(after: min(text.count, baseline + minimumDistance), unit: unit, text: text)
        } else {
            session.position.charOffset = firstBoundary
        }
        session.completionPercent = percent(for: session.position.charOffset, text: text)
        session.position.chapterId = chapterId(for: session.position.charOffset)
        if session.position.charOffset >= text.count {
            session.phase = .finished
        }
        currentSession = session
        try repository.saveSession(session)
        if snapshot.status == .playing, session.position.charOffset < text.count {
            try playCurrentTarget(session)
        } else if session.position.charOffset >= text.count {
            try audio.stop()
        }
        publish(status: session.phase == .finished ? .paused : snapshot.status, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func skipBack(unit: String) throws -> SessionSnapshot {
        try requirePlayback("skipBack")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("skipBack")
        }
        guard session.currentTargetType == .itemTextTTS else {
            return try skipGeneratedTurnBack(session: session, unit: unit)
        }
        guard let item = currentItem else {
            throw SessionKitError.invalidCommandForState("skipBack")
        }
        session = syncSessionPositionFromAudio(session, item: item)
        session.position.charOffset = previousBoundary(before: session.position.charOffset, unit: unit, text: item.text ?? "")
        session.completionPercent = percent(for: session.position.charOffset, text: item.text ?? "")
        session.position.chapterId = chapterId(for: session.position.charOffset)
        if session.phase == .finished {
            session.phase = .itemPlayback
        }
        currentSession = session
        try repository.saveSession(session)
        if snapshot.status == .playing {
            try playCurrentTarget(session)
        }
        publish(status: snapshot.status, phase: session.phase)
        return snapshot
    }

    private func skipGeneratedTurnForward(session: Session, unit: String) throws -> SessionSnapshot {
        var updated = try syncGeneratedTurnPositionFromAudio(session)
        guard let turn = try repository.loadTurns(sessionId: updated.id).first(where: { $0.id == updated.currentTargetId }) else {
            throw SessionKitError.invalidCommandForState("skipForward")
        }
        let text = generatedTurnNavigationText(for: turn)
        guard !text.isEmpty else {
            throw SessionKitError.invalidCommandForState("skipForward")
        }
        updated.position.charOffset = nextBoundary(after: updated.position.charOffset, unit: unit, text: text)
        updated.position.charOffset = max(0, min(updated.position.charOffset, text.count))
        updated.position.chapterId = turn.chapters?.last(where: { $0.startChar <= updated.position.charOffset })?.id
        currentSession = updated
        try repository.saveSession(updated)
        if snapshot.status == .playing, updated.position.charOffset < text.count {
            try playCurrentTarget(updated)
        } else if updated.position.charOffset >= text.count {
            try audio.stop()
        }
        publish(status: updated.position.charOffset >= text.count ? .paused : snapshot.status, phase: updated.phase)
        return snapshot
    }

    private func skipGeneratedTurnBack(session: Session, unit: String) throws -> SessionSnapshot {
        var updated = try syncGeneratedTurnPositionFromAudio(session)
        guard let turn = try repository.loadTurns(sessionId: updated.id).first(where: { $0.id == updated.currentTargetId }) else {
            throw SessionKitError.invalidCommandForState("skipBack")
        }
        let text = generatedTurnNavigationText(for: turn)
        guard !text.isEmpty else {
            throw SessionKitError.invalidCommandForState("skipBack")
        }
        updated.position.charOffset = previousBoundary(before: updated.position.charOffset, unit: unit, text: text)
        updated.position.charOffset = max(0, min(updated.position.charOffset, text.count))
        updated.position.chapterId = turn.chapters?.last(where: { $0.startChar <= updated.position.charOffset })?.id
        currentSession = updated
        try repository.saveSession(updated)
        if snapshot.status == .playing {
            try playCurrentTarget(updated)
        }
        publish(status: snapshot.status, phase: updated.phase)
        return snapshot
    }

    @discardableResult
    public func jumpToChapter(chapterId: String) throws -> SessionSnapshot {
        try require("jumpToChapter", category: "timeline", capabilities: ["chapter_timing"])
        try requirePlayback("jumpToChapter")
        guard var session = currentSession, let chapter = currentMap?.chapters.first(where: { $0.id == chapterId }) else {
            throw SessionKitError.invalidCommandForState("jumpToChapter")
        }
        session.currentTargetType = .itemTextTTS
        session.currentTargetId = session.itemId
        session.phase = .itemPlayback
        session.position.charOffset = chapter.startChar
        session.position.chapterId = chapter.id
        session.completionPercent = chapter.percent
        currentSession = session
        try repository.saveSession(session)
        try playCurrentTarget(session)
        publish(status: .playing, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func playSourceFromBeginning() throws -> SessionSnapshot {
        try requirePlayback("playSourceFromBeginning")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("playSourceFromBeginning")
        }
        if currentItem?.id != session.itemId {
            currentItem = try repository.loadItem(id: session.itemId)
        }
        currentMap = try repository.loadListeningMap(itemId: session.itemId)
        session.currentTargetType = .itemTextTTS
        session.currentTargetId = session.itemId
        session.phase = .itemPlayback
        session.position = Position(charOffset: 0, chapterId: nil)
        session.completionPercent = 0
        currentSession = session
        try repository.saveSession(session)
        try playCurrentTarget(session)
        publish(status: .playing, phase: .itemPlayback)
        return snapshot
    }

    @discardableResult
    public func inspectSession(sessionId: String) throws -> SessionSnapshot {
        guard let session = try repository.loadSession(id: sessionId) else {
            throw SessionKitError.invalidCommandForState("inspectSession")
        }
        currentSession = session
        currentItem = try repository.loadItem(id: session.itemId)
        currentMap = try repository.loadListeningMap(itemId: session.itemId)
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func beginInterjection() throws -> SessionSnapshot {
        try require("beginInterjection", category: "interjection", capabilities: ["record_audio", "delegate_interjection_to_canonical_runtime"])
        guard var session = currentSession else { throw SessionKitError.invalidCommandForState("beginInterjection") }
        session = try syncCurrentPositionFromAudio(session)
        currentSession = session
        try repository.saveSession(session)
        priorPhase = session.phase
        let target = currentInterjectionTarget(for: session)
        recordingTargetType = target.type
        recordingTargetId = target.id
        recordingAnchor = buildAnchor(for: session, targetType: target.type, targetId: target.id)
        try audio.pause()
        try recorder.beginRecording()
        session.phase = .recordingInterjection
        currentSession = session
        snapshot.recordingTargetId = target.id
        publish(status: .recording, phase: .recordingInterjection)
        return snapshot
    }

    @discardableResult
    public func finishInterjection(audioRef: String?) throws -> SessionSnapshot {
        guard var session = currentSession,
              let anchor = recordingAnchor,
              let targetType = recordingTargetType,
              let targetId = recordingTargetId else {
            throw SessionKitError.invalidCommandForState("finishInterjection")
        }
        let savedAudioRef = try recorder.finishRecording(audioRef: audioRef)
        let count = try repository.loadInterjections(sessionId: session.id).count + 1
        let interjection = Interjection(
            id: targetType == .assistantTurn ? "ij-ai-\(String(format: "%03d", count))" : "ij-\(String(format: "%03d", count))",
            itemId: session.itemId,
            sessionId: session.id,
            targetType: targetType,
            targetId: targetId,
            createdAt: Date(timeIntervalSince1970: Double(count)),
            roughPercent: session.completionPercent,
            anchor: anchor,
            audioPath: savedAudioRef,
            audioStatus: "saved",
            transcriptionStatus: "pending",
            transcript: nil,
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        try repository.saveInterjection(interjection)
        try transcriber.scheduleTranscription(interjection: interjection)
        lastScheduledTranscriptionInterjectionId = interjection.id
        snapshot.lastInterjectionAnchorType = anchor.anchorType
        snapshot.lastInterjectionTargetType = targetType
        session.phase = priorPhaseForResume(targetType: targetType)
        if let item = currentItem, targetType == .item {
            session.position.charOffset = max(0, previousBoundary(before: session.position.charOffset, unit: "sentence", text: item.text ?? ""))
            session.completionPercent = percent(for: session.position.charOffset, text: item.text ?? "")
            session.position.chapterId = chapterId(for: session.position.charOffset)
        } else if let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == targetId }) {
            let text = generatedTurnNavigationText(for: turn)
            session.position.charOffset = max(0, previousBoundary(before: session.position.charOffset, unit: "sentence", text: text))
            session.position.chapterId = turn.chapters?.last(where: { $0.startChar <= session.position.charOffset })?.id
        }
        currentSession = session
        try repository.saveSession(session)
        try playCurrentTarget(session)
        publish(status: .playing, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func cancelInterjection() throws -> SessionSnapshot {
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("cancelInterjection")
        }
        try recorder.cancelRecording()
        session.phase = priorPhase ?? priorPhaseForResume(targetType: recordingTargetType ?? .item)
        if let item = currentItem, recordingTargetType ?? .item == .item {
            session.position.charOffset = max(0, previousBoundary(before: session.position.charOffset, unit: "sentence", text: item.text ?? ""))
            session.completionPercent = percent(for: session.position.charOffset, text: item.text ?? "")
            session.position.chapterId = chapterId(for: session.position.charOffset)
        } else if let targetId = recordingTargetId,
                  let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == targetId }) {
            let text = generatedTurnNavigationText(for: turn)
            session.position.charOffset = max(0, previousBoundary(before: session.position.charOffset, unit: "sentence", text: text))
            session.position.chapterId = turn.chapters?.last(where: { $0.startChar <= session.position.charOffset })?.id
        }
        recordingAnchor = nil
        recordingTargetType = nil
        recordingTargetId = nil
        currentSession = session
        try repository.saveSession(session)
        try playCurrentTarget(session)
        publish(status: .playing, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func generateInterjectionSummary(scope: SummaryScope) throws -> SessionSnapshot {
        let session = try resolveSession(scope.sessionId)
        lastSummaryCandidates = try selectSummaryCandidates(scope: scope)
        let shouldCall = aiProvider.shouldStartProviderCall(profile: profile, kind: "interjection_summary")
        let status = shouldCall ? "pending" : "deferred"
        let turns = try repository.loadTurns(sessionId: session.id)
        let interjections = try repository.loadInterjections(sessionId: session.id)
        let existingTurn = replacementSummaryTurn(scope: scope, session: session, turns: turns, interjections: interjections)
        if let existingTurn,
           Set(existingTurn.sourceInterjectionIds) == Set(lastSummaryCandidates.map(\.id)) {
            throw SessionKitError.invalidCommandForState("interjection_summary_already_current")
        }
        let summaryIndex = existingTurn.flatMap { turnSequenceNumber($0.id) } ?? turns.filter { $0.turnType == "interjection_summary" }.count + 1
        let turnId = existingTurn?.id ?? "turn-summary-\(String(format: "%03d", summaryIndex))"
        let turn = ConversationTurn(
            id: turnId,
            sessionId: session.id,
            role: "assistant",
            turnType: "interjection_summary",
            status: status,
            summary: nil,
            text: nil,
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: lastSummaryCandidates.map(\.id)
        )
        try repository.saveTurn(turn)
        let job = aiJob(id: "job-interjection-summary-\(String(format: "%03d", summaryIndex))", kind: "interjection_summary", session: session, turnId: turn.id, status: status)
        try repository.saveAIJob(job)
        snapshot.pendingAiJobKind = job.kind
        snapshot.pendingAiJobStatus = job.status
        snapshot.providerCallStarted = shouldCall
        snapshot.pendingAiJobCount = try repository.loadAIJobs(sessionId: session.id).filter { $0.status != "complete" }.count
        return snapshot
    }

    private func replacementSummaryTurn(scope: SummaryScope, session: Session, turns: [ConversationTurn], interjections: [Interjection]) -> ConversationTurn? {
        let target = summaryTarget(scope: scope, session: session)
        return turns
            .filter { $0.turnType == "interjection_summary" && summaryTurn($0, matches: target, interjections: interjections) }
            .sorted { $0.id < $1.id }
            .last
    }

    private func summaryTarget(scope: SummaryScope, session: Session) -> (type: InterjectionTargetType, id: String) {
        if scope.targetType == "turn", let turnId = scope.turnId {
            return (.assistantTurn, turnId)
        }
        return (.item, session.itemId)
    }

    private func summaryTurn(
        _ turn: ConversationTurn,
        matches target: (type: InterjectionTargetType, id: String),
        interjections: [Interjection]
    ) -> Bool {
        guard !turn.sourceInterjectionIds.isEmpty else { return false }
        let byId = Dictionary(uniqueKeysWithValues: interjections.map { ($0.id, $0) })
        let sourceInterjections = turn.sourceInterjectionIds.compactMap { byId[$0] }
        guard sourceInterjections.count == turn.sourceInterjectionIds.count else { return false }
        switch target.type {
        case .item:
            return sourceInterjections.allSatisfy { $0.targetType == .item && $0.targetId == target.id }
        case .assistantTurn, .summaryTurn:
            return sourceInterjections.allSatisfy { $0.targetType != .item && $0.targetId == target.id }
        }
    }

    @discardableResult
    public func playTurn(turnId: String) throws -> SessionSnapshot {
        var session = try resolveSession(nil)
        let turns = try repository.loadTurns(sessionId: session.id)
        let targetType: TargetType
        let phase: SessionPhase
        if let turn = turns.first(where: { $0.id == turnId }), turn.turnType == "interjection_summary" {
            try require("playTurn", category: "playback", capabilities: ["summary_turn_tts"])
            targetType = .summaryTurnTTS
            phase = .summaryPlayback
        } else {
            try require("playTurn", category: "playback", capabilities: ["assistant_turn_tts"])
            targetType = .assistantTurnTTS
            phase = .aiResponsePlayback
        }
        session.currentTargetType = targetType
        session.currentTargetId = turnId
        session.phase = phase
        session.position = Position(charOffset: 0)
        currentSession = session
        try repository.saveSession(session)
        try playCurrentTarget(session)
        publish(status: .playing, phase: phase)
        return snapshot
    }

    @discardableResult
    public func jumpToTurnChapter(turnId: String, chapterId: String) throws -> SessionSnapshot {
        var session = try resolveSession(nil)
        let turns = try repository.loadTurns(sessionId: session.id)
        guard let turn = turns.first(where: { $0.id == turnId }),
              let chapter = turn.chapters?.first(where: { $0.id == chapterId }) else {
            throw SessionKitError.invalidCommandForState("jumpToTurnChapter")
        }
        if turn.turnType == "interjection_summary" {
            try require("jumpToTurnChapter", category: "playback", capabilities: ["summary_turn_tts"])
            session.currentTargetType = .summaryTurnTTS
            session.phase = .summaryPlayback
        } else {
            try require("jumpToTurnChapter", category: "playback", capabilities: ["assistant_turn_tts"])
            session.currentTargetType = .assistantTurnTTS
            session.phase = .aiResponsePlayback
        }
        session.currentTargetId = turnId
        session.position = Position(charOffset: chapter.startChar, chapterId: chapter.id)
        currentSession = session
        try repository.saveSession(session)
        try playCurrentTarget(session)
        publish(status: .playing, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func submitFollowup(text: String) throws -> SessionSnapshot {
        var session = try resolveSession(nil)
        session.phase = .conversation
        currentSession = session
        let userTurn = ConversationTurn(
            id: "turn-addendum-\(UUID().uuidString.prefix(8))",
            sessionId: session.id,
            role: "user",
            turnType: "user_response",
            status: "complete",
            summary: nil,
            text: text,
            rawText: text,
            chapters: nil,
            sourceInterjectionIds: []
        )
        try repository.saveTurn(userTurn)
        let shouldCall = aiProvider.shouldStartProviderCall(profile: profile, kind: "assistant_response")
        let status = shouldCall ? "pending" : "deferred"
        let responseIndex = try repository.loadTurns(sessionId: session.id).filter { $0.turnType == "assistant_response" }.count + 1
        let responseTurnId = "turn-response-\(String(format: "%03d", responseIndex))"
        let responseTurn = ConversationTurn(
            id: responseTurnId,
            sessionId: session.id,
            role: "assistant",
            turnType: "assistant_response",
            status: status,
            summary: nil,
            text: nil,
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: []
        )
        try repository.saveTurn(responseTurn)
        let job = aiJob(id: "job-assistant-response-\(String(format: "%03d", responseIndex))", kind: "assistant_response", session: session, turnId: responseTurn.id, status: status, messages: [text])
        try repository.saveAIJob(job)
        snapshot.lastUserTurnType = userTurn.turnType
        snapshot.pendingAiJobKind = job.kind
        snapshot.pendingAiJobStatus = job.status
        snapshot.providerCallStarted = shouldCall
        publish(status: snapshot.status, phase: .conversation)
        return snapshot
    }

    @discardableResult
    public func aiProviderFailed(error: String) throws -> SessionSnapshot {
        let session = try resolveSession(nil)
        var jobs = try repository.loadAIJobs(sessionId: session.id)
        guard var job = jobs.last(where: { $0.status == "pending" || $0.status == "deferred" }) else {
            throw SessionKitError.invalidCommandForState("aiProviderFailed")
        }
        job.status = "retryable"
        job.lastError = error
        job.attempts = max(1, job.attempts)
        try repository.updateAIJob(job)
        snapshot.pendingAiJobKind = job.kind
        snapshot.pendingAiJobStatus = job.status
        snapshot.lastFailure = "ai_provider_unreachable"
        snapshot.turnStatus = "pending"
        jobs = try repository.loadAIJobs(sessionId: session.id)
        snapshot.pendingAiJobCount = jobs.filter { $0.status != "complete" }.count
        return snapshot
    }

    @discardableResult
    public func retryAIJob(jobId: String) throws -> SessionSnapshot {
        let session = try resolveSession(nil)
        guard var job = try repository.loadAIJobs(sessionId: session.id).first(where: { $0.id == jobId }) else {
            throw SessionKitError.invalidCommandForState("retryAiJob")
        }
        job.status = "pending"
        job.attempts += 1
        try repository.updateAIJob(job)
        if let turnId = job.turnId {
            var turns = try repository.loadTurns(sessionId: session.id)
            if let idx = turns.firstIndex(where: { $0.id == turnId }) {
                turns[idx].status = "streaming"
                try repository.saveTurn(turns[idx])
            }
        }
        snapshot.pendingAiJobKind = job.kind
        snapshot.pendingAiJobStatus = job.status
        snapshot.turnStatus = "streaming"
        return snapshot
    }

    @discardableResult
    public func aiStreamDelta(turnId: String, content: String) throws -> SessionSnapshot {
        let session = try resolveSession(nil)
        let previous = streamingBuffers[turnId] ?? ""
        let combined = previous + content
        streamingBuffers[turnId] = combined
        let parsed = parseSectionedResponse(from: combined)
        let text = parsed.response
        let alreadySpoken = spokenPrefixes[turnId] ?? 0
        let completeUnits = completeSentenceUnits(in: text)
        let unitsToSpeak = completeUnits.dropFirst(alreadySpoken)
        spokenPrefixes[turnId] = completeUnits.count
        var turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == turnId }) ?? ConversationTurn(
            id: turnId,
            sessionId: session.id,
            role: "assistant",
            turnType: "assistant_response",
            status: "streaming",
            summary: nil,
            text: nil,
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: []
        )
        turn.status = "streaming"
        turn.summary = parsed.summary
        turn.text = text
        turn.rawText = combined
        try repository.saveTurn(turn)
        snapshot.turnStatus = "streaming"
        snapshot.spokenUnits = Array(unitsToSpeak)
        return snapshot
    }

    @discardableResult
    public func aiJobCompleted(turnId: String) throws -> SessionSnapshot {
        let session = try resolveSession(nil)
        var turns = try repository.loadTurns(sessionId: session.id)
        var turn = turns.first(where: { $0.id == turnId }) ?? ConversationTurn(
            id: turnId,
            sessionId: session.id,
            role: "assistant",
            turnType: turnId.contains("summary") ? "interjection_summary" : "assistant_response",
            status: "complete",
            summary: nil,
            text: nil,
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: []
        )
        turn.status = "complete"
        let parsed = parseSectionedResponse(from: turn.rawText ?? "")
        if turn.summary == nil || turn.summary?.isEmpty == true {
            turn.summary = parsed.summary
        }
        if turn.text == nil {
            turn.text = parsed.response
            if turn.text?.isEmpty != false {
                turn.text = turn.turnType == "interjection_summary" ? "Summary ready." : "AI response ready."
            }
        }
        if turn.chapters == nil || turn.chapters?.isEmpty == true {
            turn.chapters = parsed.chapters
        }
        try repository.saveTurn(turn)
        for var job in try repository.loadAIJobs(sessionId: session.id) where job.turnId == turnId {
            job.status = "complete"
            try repository.updateAIJob(job)
        }
        turns = try repository.loadTurns(sessionId: session.id)
        let pendingJobs = try repository.loadAIJobs(sessionId: session.id).filter { $0.status != "complete" }
        snapshot.turnStatus = "complete"
        snapshot.pendingAiJobCount = pendingJobs.count
        let nextPhase: SessionPhase
        if snapshot.status == .playing, audio.currentCharOffset() != nil {
            nextPhase = session.phase
        } else if turn.turnType == "interjection_summary" {
            nextPhase = .interjectionSummary
        } else {
            nextPhase = .conversation
        }
        publish(status: snapshot.status, phase: nextPhase)
        _ = turns
        return snapshot
    }

    @discardableResult
    public func transcriptionCompleted(interjectionId: String, transcript: String) throws -> SessionSnapshot {
        try updateInterjection(interjectionId) { interjection in
            interjection.transcript = transcript
            interjection.transcriptionStatus = "transcribed"
            interjection.cleanedTranscript = nil
            interjection.displayText = transcript
        }
        return snapshot
    }

    @discardableResult
    public func transcriptionFailed(interjectionId: String, error: String) throws -> SessionSnapshot {
        try updateInterjection(interjectionId) { interjection in
            interjection.transcriptionStatus = "failed"
            interjection.displayText = "Audio saved. Transcript failed."
        }
        snapshot.lastFailure = "transcription_failed:\(error)"
        return snapshot
    }

    @discardableResult
    public func cleanupCompleted(interjectionId: String, cleanedTranscript: String) throws -> SessionSnapshot {
        try updateInterjection(interjectionId) { interjection in
            interjection.cleanedTranscript = cleanedTranscript
            interjection.displayText = cleanedTranscript
        }
        return snapshot
    }

    @discardableResult
    public func deleteRepresentation(interjectionId: String, representation: String) throws -> SessionSnapshot {
        try updateInterjection(interjectionId) { interjection in
            if representation == "cleanedTranscript" {
                interjection.cleanedTranscript = nil
                interjection.displayText = interjection.transcript
            } else if representation == "transcript" {
                interjection.transcript = nil
                interjection.cleanedTranscript = nil
                interjection.displayText = nil
                interjection.transcriptionStatus = interjection.audioPath == nil ? "failed" : "pending"
            }
        }
        return snapshot
    }

    @discardableResult
    public func deleteInterjection(interjectionId: String) throws -> SessionSnapshot {
        try updateInterjection(interjectionId) { interjection in
            interjection.status = "deleted"
        }
        publish(status: snapshot.status, phase: snapshot.phase)
        return snapshot
    }

    @discardableResult
    public func endSession() throws -> SessionSnapshot {
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("endSession")
        }
        try audio.stop()
        session.status = "finished"
        session.phase = .finished
        currentSession = session
        try repository.saveSession(session)
        publish(status: .idle, phase: .finished)
        return snapshot
    }

    @discardableResult
    public func selectSummaryCandidates(scope: SummaryScope) throws -> [Interjection] {
        let session = try resolveSession(scope.sessionId)
        let all = try repository.loadInterjections(sessionId: scope.sessionId ?? session.id)
        if let explicit = scope.interjectionIds {
            lastSummaryCandidates = all.filter { explicit.contains($0.id) }
        } else if scope.targetType == "turn", let turnId = scope.turnId {
            lastSummaryCandidates = all.filter { $0.targetId == turnId && $0.targetType != .item }
        } else {
            lastSummaryCandidates = all.filter { $0.targetType == .item }
        }
        return lastSummaryCandidates
    }

    @discardableResult
    public func buildExport(options: ExportOptions) throws -> SessionExport {
        let session = try resolveSession(options.sessionId)
        let item = try repository.loadItem(id: session.itemId)
        let interjections = options.includeInterjections ? try repository.loadInterjections(sessionId: session.id) : []
        let turns = try repository.loadTurns(sessionId: session.id)
        let export = SessionExport(
            item: ExportItem(
                id: item.id,
                title: item.title,
                externalReference: options.includeReference ? item.externalReference : nil,
                includedFullText: options.includeFullText,
                text: options.includeFullText ? item.text : nil
            ),
            session: ExportSession(id: session.id, status: session.status, completionPercent: session.completionPercent),
            listeningMap: options.includeListeningMap ? try repository.loadListeningMap(itemId: item.id) : nil,
            turns: turns,
            timeline: exportTimeline(interjections: interjections, turns: turns),
            interjections: interjections.map {
                ExportInterjection(
                    id: $0.id,
                    sessionId: $0.sessionId,
                    targetType: $0.targetType.rawValue,
                    targetId: $0.targetId,
                    roughPercent: $0.roughPercent,
                    anchorBefore: $0.anchor.anchorBefore,
                    anchorAfter: $0.anchor.anchorAfter,
                    mediaTimeMs: $0.anchor.mediaTimeMs,
                    transcriptionStatus: $0.transcriptionStatus,
                    transcript: $0.transcript,
                    audioPath: $0.audioPath
                )
            }
        )
        lastExport = export
        return export
    }

    private func exportTimeline(interjections: [Interjection], turns: [ConversationTurn]) -> [ExportTimelineEntry] {
        let sourceInterjections = interjections.filter { $0.targetType == .item }.map {
            ExportTimelineEntry(type: "interjection", interjectionId: $0.id, turnId: nil, targetType: $0.targetType.rawValue, targetId: $0.targetId, percent: $0.roughPercent, chapterId: nil)
        }
        let turnEntries = turns.flatMap { turn -> [ExportTimelineEntry] in
            let base = ExportTimelineEntry(type: "ai_turn", interjectionId: nil, turnId: turn.id, targetType: nil, targetId: nil, percent: nil, chapterId: nil)
            let chapters = (turn.chapters ?? []).map {
                ExportTimelineEntry(type: "ai_turn_chapter", interjectionId: nil, turnId: turn.id, targetType: nil, targetId: nil, percent: $0.percent, chapterId: $0.id)
            }
            let turnInterjections = interjections.filter { $0.targetId == turn.id && $0.targetType != .item }.map {
                ExportTimelineEntry(type: "interjection", interjectionId: $0.id, turnId: nil, targetType: $0.targetType.rawValue, targetId: $0.targetId, percent: $0.roughPercent, chapterId: nil)
            }
            return [base] + chapters + turnInterjections
        }
        return sourceInterjections + turnEntries
    }

    public func diagnostics() throws -> [String: String] {
        let sessionId = currentSession?.id ?? "none"
        return [
            "runtimeProfile": profile.id,
            "providerStatus": profile.has("ai", "provider_diagnostics") ? "available" : "unavailable",
            "pendingAiJobs": "\(try currentSession.map { try repository.loadAIJobs(sessionId: $0.id).filter { $0.status != "complete" }.count } ?? 0)",
            "recentFailure": snapshot.lastFailure ?? "none",
            "sessionId": sessionId
        ]
    }

    private func publish(status: PlaybackStatus, phase: SessionPhase) {
        snapshot.status = status
        snapshot.phase = phase
        snapshot.isRecording = status == .recording
        guard let session = currentSession else { return }
        snapshot.sessionId = session.id
        snapshot.itemId = session.itemId
        snapshot.targetType = session.currentTargetType.rawValue
        snapshot.targetId = session.currentTargetId
        snapshot.title = currentItem?.title
        snapshot.progressPercent = session.completionPercent
        let progress = playbackProgress(for: session)
        snapshot.sourceProgressPercent = progress.sourcePercent
        snapshot.currentPlaybackProgressPercent = progress.currentPercent
        snapshot.playbackRate = session.playbackRate
        snapshot.chapterTitle = progress.chapterTitle ?? currentItem?.title
        snapshot.activeInterjectionCount = (try? repository.loadInterjections(sessionId: session.id).filter { $0.status == "active" }.count) ?? snapshot.activeInterjectionCount
        snapshot.pendingAiJobCount = (try? repository.loadAIJobs(sessionId: session.id).filter { $0.status != "complete" }.count) ?? snapshot.pendingAiJobCount
    }

    private func playbackProgress(for session: Session) -> PlaybackProgress {
        let sourcePercent = session.completionPercent
        switch session.currentTargetType {
        case .itemTextTTS:
            let currentAudioOffset = audio.currentCharOffset()
            let prefixLength = itemPlaybackPreface().count
            let isInPreface = prefixLength > 0 && (currentAudioOffset ?? 0) <= prefixLength && session.position.chapterId == nil
            let currentPercent: Int
            if isInPreface, let offset = currentAudioOffset {
                currentPercent = percent(offset: offset, length: prefixLength)
            } else if let offset = currentAudioOffset {
                currentPercent = percent(for: itemSourceOffset(forAudioOffset: offset), text: currentItem?.text ?? "")
            } else {
                currentPercent = session.completionPercent
            }
            let title = isInPreface ? "Summary" : (currentMap?.chapters.first(where: { $0.id == session.position.chapterId })?.title ?? currentItem?.title)
            return PlaybackProgress(sourcePercent: sourcePercent, currentPercent: currentPercent, chapterTitle: title)
        case .summaryTurnTTS, .assistantTurnTTS:
            guard let turn = try? repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId }) else {
                return PlaybackProgress(sourcePercent: sourcePercent, currentPercent: 0, chapterTitle: currentItem?.title)
            }
            let playable = playableText(for: turn)
            let audioOffset = audio.currentCharOffset() ?? turnAudioOffset(for: turn, responseOffset: session.position.charOffset)
            let currentPercent = playable.isEmpty ? 0 : percent(for: max(0, min(audioOffset, playable.count)), text: playable)
            let responseOffset = turnResponseOffset(for: turn, audioOffset: audioOffset)
            let title = turn.chapters?.last(where: { $0.startChar <= responseOffset })?.title ?? turnTitle(for: turn)
            return PlaybackProgress(sourcePercent: sourcePercent, currentPercent: currentPercent, chapterTitle: title)
        case .transcriptBackedMedia, .browserOwnedMedia:
            return PlaybackProgress(sourcePercent: sourcePercent, currentPercent: sourcePercent, chapterTitle: currentItem?.title)
        }
    }

    private func require(_ command: String, category: String, capabilities: [String]) throws {
        guard profile.hasAny(category, capabilities) else {
            throw SessionKitError.invalidCommandForCapability(command)
        }
    }

    private func requirePlayback(_ command: String) throws {
        guard profile.hasAny("playback", ["realtime_tts", "prerendered_audio", "native_media", "assistant_turn_tts", "summary_turn_tts"])
            || profile.has("remoteControl", "send_transport_commands") else {
            throw SessionKitError.invalidCommandForCapability(command)
        }
    }

    private func resolveSession(_ sessionId: String?) throws -> Session {
        if let sessionId, let session = try repository.loadSession(id: sessionId) {
            return session
        }
        if let currentSession { return currentSession }
        if let memory = repository as? InMemorySessionRepository, let session = memory.sessions.values.first {
            currentSession = session
            currentItem = try? repository.loadItem(id: session.itemId)
            currentMap = try? repository.loadListeningMap(itemId: session.itemId)
            publish(status: .playing, phase: session.phase)
            return session
        }
        if let item = currentItem {
            let session = Session(
                id: "session-\(item.id)-export",
                itemId: item.id,
                status: "in_progress",
                phase: .itemPlayback,
                currentTargetType: .itemTextTTS,
                currentTargetId: item.id,
                position: Position(),
                completionPercent: 0,
                playbackRate: 1
            )
            currentSession = session
            try repository.saveSession(session)
            publish(status: .playing, phase: session.phase)
            return session
        }
        throw SessionKitError.invalidCommandForState("buildExport")
    }

    private func nextSessionId(itemId: String) -> String {
        if let memory = repository as? InMemorySessionRepository {
            let next = memory.sessions.values.filter { $0.itemId == itemId }.count + 1
            return "session-\(itemId)-gate1-\(String(format: "%03d", next))"
        }
        return "session-\(itemId)-\(UUID().uuidString)"
    }

    private func currentInterjectionTarget(for session: Session) -> (type: InterjectionTargetType, id: String) {
        switch session.currentTargetType {
        case .assistantTurnTTS:
            return (.assistantTurn, session.currentTargetId)
        case .summaryTurnTTS:
            return (.summaryTurn, session.currentTargetId)
        default:
            return (.item, session.itemId)
        }
    }

    private func priorPhaseForResume(targetType: InterjectionTargetType) -> SessionPhase {
        switch targetType {
        case .assistantTurn: return .aiResponsePlayback
        case .summaryTurn: return .summaryPlayback
        case .item: return .itemPlayback
        }
    }

    private func buildAnchor(for session: Session, targetType: InterjectionTargetType, targetId: String) -> Anchor {
        if targetType != .item {
            let turn = try? repository.loadTurns(sessionId: session.id).first(where: { $0.id == targetId })
            let turnText = turn.map { generatedTurnNavigationText(for: $0) } ?? ""
            let start = max(0, min(session.position.charOffset, turnText.count))
            let sentenceStart = previousBoundary(before: start, unit: "sentence", text: turnText)
            let end = min(turnText.count, max(sentenceStart + 1, nextBoundary(after: start, unit: "sentence", text: turnText)))
            let segmentIndex = completeSentenceUnits(in: slice(turnText, start: 0, end: sentenceStart)).count
            return Anchor(
                anchorType: .turn,
                startChar: sentenceStart,
                endChar: end,
                anchorBefore: slice(turnText, start: sentenceStart, end: end),
                anchorAfter: slice(turnText, start: end, end: min(turnText.count, nextBoundary(after: end, unit: "sentence", text: turnText))),
                turnSegmentIndex: segmentIndex
            )
        }
        let text = currentItem?.text ?? ""
        let start = max(0, min(session.position.charOffset, text.count))
        let end = min(text.count, max(start + 1, nextBoundary(after: start, unit: "sentence", text: text)))
        return Anchor(
            anchorType: .text,
            startChar: start,
            endChar: end,
            anchorBefore: slice(text, start: start, end: end),
            anchorAfter: slice(text, start: end, end: min(text.count, nextBoundary(after: end, unit: "sentence", text: text)))
        )
    }

    private func aiJob(id: String, kind: String, session: Session, turnId: String?, status: String, messages: [String] = []) -> AIJob {
        AIJob(
            id: id,
            kind: kind,
            itemId: session.itemId,
            sessionId: session.id,
            turnId: turnId,
            providerType: aiProvider.providerType,
            model: aiProvider.model,
            status: status,
            attempts: 0,
            lastError: nil,
            messages: messages,
            playbackMode: session.currentTargetType.rawValue
        )
    }

    private func updateInterjection(_ id: String, mutate: (inout Interjection) -> Void) throws {
        if let memory = repository as? InMemorySessionRepository, var interjection = memory.interjections[id] {
            mutate(&interjection)
            try repository.saveInterjection(interjection)
            return
        }
        guard let session = currentSession else { throw SessionKitError.invalidCommandForState("updateInterjection") }
        var all = try repository.loadInterjections(sessionId: session.id)
        guard var interjection = all.first(where: { $0.id == id }) else {
            // Fixtures may use a mapless session while the current runtime session differs; preserve trace intent.
            all = try repository.loadInterjections(sessionId: "session-pill-mapless")
            guard var fallback = all.first(where: { $0.id == id }) else { throw SessionKitError.invalidCommandForState("updateInterjection") }
            mutate(&fallback)
            try repository.saveInterjection(fallback)
            return
        }
        mutate(&interjection)
        try repository.saveInterjection(interjection)
    }

    private func chapterId(for charOffset: Int) -> String? {
        currentMap?.chapters.last(where: { $0.startChar <= charOffset })?.id
    }

    private func playCurrentTarget(_ session: Session) throws {
        let plan = try playbackPlan(for: session)
        lastSpokenText = try audio.prepareSpeechText(plan.text)
        try audio.play(targetId: session.currentTargetId, from: plan.audioOffset)
    }

    private func syncSessionPositionFromAudio(_ session: Session, item: Item?) -> Session {
        guard session.currentTargetType == .itemTextTTS,
              let offset = audio.currentCharOffset(),
              offset >= 0 else {
            return session
        }
        let prefixLength = itemPlaybackPreface().count
        if prefixLength > 0, offset <= prefixLength {
            var updated = session
            updated.position.charOffset = 0
            updated.position.chapterId = nil
            updated.completionPercent = 0
            return updated
        }
        let sourceOffset = itemSourceOffset(forAudioOffset: offset)
        guard sourceOffset <= (item?.text ?? "").count else { return session }
        var updated = session
        updated.position.charOffset = max(0, min(sourceOffset, item?.text?.count ?? 0))
        updated.completionPercent = percent(for: updated.position.charOffset, text: item?.text ?? "")
        updated.position.chapterId = chapterId(for: updated.position.charOffset)
        return updated
    }

    private func syncGeneratedTurnPositionFromAudio(_ session: Session) throws -> Session {
        guard session.currentTargetType == .summaryTurnTTS || session.currentTargetType == .assistantTurnTTS,
              let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId }),
              let offset = audio.currentCharOffset(),
              offset >= 0 else {
            return session
        }
        let text = generatedTurnNavigationText(for: turn)
        var updated = session
        updated.position.charOffset = max(0, min(turnResponseOffset(for: turn, audioOffset: offset), text.count))
        updated.position.chapterId = turn.chapters?.last(where: { $0.startChar <= updated.position.charOffset })?.id
        return updated
    }

    private func syncCurrentPositionFromAudio(_ session: Session) throws -> Session {
        switch session.currentTargetType {
        case .itemTextTTS:
            return syncSessionPositionFromAudio(session, item: currentItem)
        case .summaryTurnTTS, .assistantTurnTTS:
            return try syncGeneratedTurnPositionFromAudio(session)
        case .transcriptBackedMedia, .browserOwnedMedia:
            return session
        }
    }

    private func markPlaybackComplete(_ session: Session, item: Item?) -> Session {
        var updated = session
        switch session.currentTargetType {
        case .itemTextTTS:
            let text = item?.text ?? ""
            updated.position.charOffset = text.count
            updated.position.chapterId = chapterId(for: text.count)
            updated.completionPercent = 100
            updated.phase = .finished
        case .transcriptBackedMedia, .browserOwnedMedia:
            updated.phase = .finished
        case .summaryTurnTTS:
            updated.phase = .summaryPlayback
        case .assistantTurnTTS:
            updated.phase = .aiResponsePlayback
        }
        return updated
    }

    private func playbackPlan(for session: Session) throws -> PlaybackPlan {
        let text = try playbackText(for: session)
        if session.currentTargetType == .summaryTurnTTS || session.currentTargetType == .assistantTurnTTS,
           let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId }) {
            let startsAtBeginning = session.position.charOffset == 0 && session.position.chapterId == nil
            return PlaybackPlan(text: text, audioOffset: startsAtBeginning ? 0 : turnAudioOffset(for: turn, responseOffset: session.position.charOffset))
        }
        guard session.currentTargetType == .itemTextTTS else {
            return PlaybackPlan(text: text, audioOffset: session.position.charOffset)
        }
        let prefixLength = itemPlaybackPreface().count
        let startsAtPreface = session.position.charOffset == 0 && session.position.chapterId == nil
        let audioOffset = startsAtPreface ? 0 : prefixLength + session.position.charOffset
        return PlaybackPlan(text: text, audioOffset: audioOffset)
    }

    private func turnAudioOffset(for turn: ConversationTurn, responseOffset: Int) -> Int {
        let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty, !text.isEmpty else { return responseOffset }
        return summary.count + 2 + responseOffset
    }

    private func turnResponseOffset(for turn: ConversationTurn, audioOffset: Int) -> Int {
        let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty, !text.isEmpty else { return audioOffset }
        return max(0, audioOffset - summary.count - 2)
    }

    private func playbackText(for session: Session) throws -> String {
        switch session.currentTargetType {
        case .itemTextTTS, .transcriptBackedMedia, .browserOwnedMedia:
            if currentItem?.id != session.itemId {
                currentItem = try repository.loadItem(id: session.itemId)
            }
            let itemText = currentItem?.text ?? ""
            guard session.currentTargetType == .itemTextTTS else {
                return itemText
            }
            return itemPlaybackPreface() + itemText
        case .summaryTurnTTS, .assistantTurnTTS:
            guard let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId }) else {
                throw SessionKitError.invalidCommandForState("playTurn")
            }
            return playableText(for: turn)
        }
    }

    private func playableText(for turn: ConversationTurn) -> String {
        let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty, !text.isEmpty {
            return "\(summary)\n\n\(text)"
        }
        if !text.isEmpty { return text }
        if !summary.isEmpty { return summary }
        return turn.rawText ?? ""
    }

    private func generatedTurnNavigationText(for turn: ConversationTurn) -> String {
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        return playableText(for: turn)
    }

    private func itemPlaybackPreface() -> String {
        guard let overview = currentMap?.overview.trimmingCharacters(in: .whitespacesAndNewlines),
              !overview.isEmpty else {
            return ""
        }
        return "Overview. \(overview)\n\n"
    }

    private func turnTitle(for turn: ConversationTurn) -> String {
        switch turn.turnType {
        case "interjection_summary":
            return "Interjection Summary \(turnSequenceNumber(turn.id) ?? 1)"
        case "assistant_response":
            if let number = turnSequenceNumber(turn.id) {
                return "AI Response \(number)"
            }
            return "AI Response"
        case "user_response":
            return "Follow-up"
        default:
            return turn.turnType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func turnSequenceNumber(_ id: String) -> Int? {
        guard let raw = id.split(separator: "-").last else { return nil }
        return Int(raw)
    }

    private func itemSourceOffset(forAudioOffset audioOffset: Int) -> Int {
        let prefixLength = itemPlaybackPreface().count
        guard prefixLength > 0 else { return audioOffset }
        if audioOffset <= prefixLength {
            return 0
        }
        return audioOffset - prefixLength
    }

    private func generatedListeningMap(for item: Item) -> ListeningMap {
        let text = item.text ?? ""
        let starts = generatedChapterStarts(for: text)
        let chapters = starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : text.count
            let title = generatedChapterTitle(text: text, start: start, end: end, index: index)
            return Chapter(
                id: "ch-generated-\(String(format: "%02d", index + 1))",
                title: title,
                startChar: start,
                endChar: max(start, end),
                percent: percent(for: start, text: text)
            )
        }
        return ListeningMap(
            id: "map-\(item.id)-generated",
            itemId: item.id,
            overview: generatedOverview(for: item, chapters: chapters),
            chapters: chapters
        )
    }

    private func generatedChapterStarts(for text: String) -> [Int] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [0] }
        let sentenceStarts = sentenceStartOffsets(in: text)
        guard sentenceStarts.count > 8 else { return sentenceStarts }
        let targetCount = min(12, max(5, Int((Double(text.count) / 900.0).rounded(.up))))
        let stride = max(1, Int((Double(sentenceStarts.count) / Double(targetCount)).rounded(.up)))
        var starts = sentenceStarts.enumerated().compactMap { index, start in
            index % stride == 0 ? start : nil
        }
        if starts.first != 0 { starts.insert(0, at: 0) }
        return Array(starts.prefix(12))
    }

    private func sentenceStartOffsets(in text: String) -> [Int] {
        let chars = Array(text)
        var starts = [0]
        var index = 0
        while index < chars.count {
            if ".!?".contains(chars[index]) {
                let next = index + 1 + consumeSpaces(chars, from: index + 1)
                if next < chars.count {
                    starts.append(next)
                }
            }
            index += 1
        }
        return Array(NSOrderedSet(array: starts)) as? [Int] ?? starts
    }

    private func generatedChapterTitle(text: String, start: Int, end: Int, index: Int) -> String {
        let raw = slice(text, start: start, end: min(end, nextBoundary(after: start, unit: "sentence", text: text)))
        let words = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .prefix(6)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:,"))
        return words.isEmpty ? "Chapter \(index + 1)" : words
    }

    private func generatedOverview(for item: Item, chapters: [Chapter]) -> String {
        if chapters.isEmpty {
            return "Generated Listening Map for \(item.title)."
        }
        return "Generated Listening Map with \(chapters.count) chapter\(chapters.count == 1 ? "" : "s") for \(item.title)."
    }

    private func percent(for charOffset: Int, text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return min(100, max(0, Int((Double(charOffset) / Double(text.count)) * 100)))
    }

    private func percent(offset: Int, length: Int) -> Int {
        guard length > 0 else { return 0 }
        return min(100, max(0, Int((Double(offset) / Double(length)) * 100)))
    }

    private func nextBoundary(after offset: Int, unit: String, text: String) -> Int {
        guard offset < text.count else { return text.count }
        if unit == "paragraph" {
            return nextParagraphBoundary(after: offset, text: text)
        }
        if unit == "section" {
            return min(text.count, offset + max(500, text.count / 10))
        }
        let chars = Array(text)
        let boundaryCharacters: Set<Character> = [".", "?", "!"]
        for index in min(offset + 1, chars.count)..<chars.count where boundaryCharacters.contains(chars[index]) {
            return min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
        }
        return text.count
    }

    private func previousBoundary(before offset: Int, unit: String, text: String) -> Int {
        guard offset > 0 else { return 0 }
        if unit == "paragraph" {
            return previousParagraphBoundary(before: offset, text: text)
        }
        if unit == "section" {
            return max(0, offset - max(500, text.count / 10))
        }
        let chars = Array(text)
        let boundaryCharacters: Set<Character> = [".", "?", "!"]
        var index = min(offset - 1, chars.count - 1)
        while index > 0 {
            if boundaryCharacters.contains(chars[index]) {
                let boundary = min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
                if boundary < offset {
                    return boundary
                }
            }
            index -= 1
        }
        return 0
    }

    private func nextParagraphBoundary(after offset: Int, text: String) -> Int {
        let chars = Array(text)
        guard offset < chars.count else { return text.count }
        var index = min(offset + 1, chars.count - 1)
        while index < chars.count {
            if chars[index] == "\n" {
                return min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
            }
            index += 1
        }
        return text.count
    }

    private func previousParagraphBoundary(before offset: Int, text: String) -> Int {
        let chars = Array(text)
        guard offset > 0, !chars.isEmpty else { return 0 }
        var index = min(offset - 1, chars.count - 1)
        while index > 0 {
            if chars[index] == "\n" {
                let boundary = min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
                if boundary < offset {
                    return boundary
                }
            }
            index -= 1
        }
        return 0
    }

    private func consumeSpaces(_ chars: [Character], from start: Int) -> Int {
        var count = 0
        var idx = start
        while idx < chars.count, chars[idx].isWhitespace {
            count += 1
            idx += 1
        }
        return count
    }

    private func slice(_ text: String, start: Int, end: Int) -> String {
        let lower = text.index(text.startIndex, offsetBy: max(0, min(start, text.count)))
        let upper = text.index(text.startIndex, offsetBy: max(0, min(end, text.count)))
        return String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractResponseText(from raw: String) -> String {
        if let start = raw.range(of: "<sm_response>")?.upperBound {
            let body = raw[start...]
            if let end = body.range(of: "</sm_response>")?.lowerBound {
                return String(body[..<end])
            }
            if let malformedStart = body.range(of: "<sm_chapters_json>")?.lowerBound {
                return String(body[..<malformedStart])
            }
            return String(body)
        }
        return raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private struct ParsedAssistantResponse {
        var summary: String?
        var response: String
        var chapters: [Chapter]
    }

    private func parseSectionedResponse(from raw: String) -> ParsedAssistantResponse {
        let summary = extractTag("sm_summary", from: raw)
        let response = extractResponseText(from: raw)
        let chapters = extractAssistantChapters(from: raw, responseText: response)
        return ParsedAssistantResponse(summary: summary?.isEmpty == true ? nil : summary, response: response, chapters: chapters)
    }

    private func extractTag(_ tag: String, from raw: String) -> String? {
        guard let start = raw.range(of: "<\(tag)>")?.upperBound else { return nil }
        let body = raw[start...]
        guard let end = body.range(of: "</\(tag)>")?.lowerBound else {
            return String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(body[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAssistantChapters(from raw: String, responseText: String) -> [Chapter] {
        guard let json = extractTag("sm_chapters_json", from: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? String == "assistant-response-map.v1",
              let rawChapters = object["chapters"] as? [[String: Any]] else {
            return []
        }
        return rawChapters.enumerated().compactMap { _, object in
            guard let id = object["id"] as? String,
                  let title = object["title"] as? String,
                  let anchor = object["anchor"] as? String,
                  let range = responseText.range(of: anchor) else {
                return nil
            }
            let start = responseText.distance(from: responseText.startIndex, to: range.lowerBound)
            let end = responseText.distance(from: responseText.startIndex, to: range.upperBound)
            return Chapter(
                id: id,
                title: title,
                startChar: start,
                endChar: end,
                percent: percent(for: start, text: responseText)
            )
        }
    }

    private func completeSentenceUnits(in text: String) -> [String] {
        var units: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if [".", "?", "!"].contains(char) {
                let unit = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !unit.isEmpty { units.append(unit) }
                current = ""
            }
        }
        return units
    }
}

public struct SummaryScope: Equatable {
    public var targetType: String?
    public var sessionId: String?
    public var turnId: String?
    public var interjectionIds: [String]?

    public init(targetType: String? = nil, sessionId: String? = nil, turnId: String? = nil, interjectionIds: [String]? = nil) {
        self.targetType = targetType
        self.sessionId = sessionId
        self.turnId = turnId
        self.interjectionIds = interjectionIds
    }
}

public struct NoopAudioPlaybackClient: AudioPlaybackClient {
    public init() {}
    public func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    public func play(targetId: String) throws {}
    public func pause() throws {}
}

public struct NoopRecordingClient: RecordingClient {
    public init() {}
    public func beginRecording() throws {}
    public func finishRecording(audioRef: String?) throws -> String { audioRef ?? "interjections/generated.m4a" }
    public func cancelRecording() throws {}
}

public struct DeferredTranscriptionClient: TranscriptionClient {
    public init() {}
    public func scheduleTranscription(interjection: Interjection) throws {}
}

public struct DeterministicAIProvider: AIProviderClient {
    public let providerType: String
    public let model: String

    public init(providerType: String = "deterministic_test", model: String = "gate1-fixture-model") {
        self.providerType = providerType
        self.model = model
    }
}
