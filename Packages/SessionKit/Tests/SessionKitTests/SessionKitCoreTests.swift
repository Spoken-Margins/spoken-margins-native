import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SessionKitAudio
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

final class SessionKitCoreTests: XCTestCase {
    func testMediaSeekLifecycleTreatsDeclinedCurrentSeekAsTerminal() {
        var lifecycle = MediaSeekLifecycle()
        let generation = lifecycle.begin(
            targetId: "episode",
            mediaTimeMs: 120_000,
            purpose: .navigation
        )
        let requestId = lifecycle.pending?.requestId

        // AVPlayer's `finished == false` is terminal for this generation. The
        // adapter gives the still-current intent one bounded replacement seek.
        let retry = lifecycle.finish(generation: generation, targetId: "episode", completed: false)
        guard case .retry(let replacement) = retry else {
            return XCTFail("Expected one bounded retry for a declined current seek")
        }
        XCTAssertEqual(replacement.mediaTimeMs, 120_000)
        XCTAssertEqual(replacement.retryCount, 1)
        XCTAssertEqual(replacement.requestId, requestId, "A retry must acknowledge the original seek request")
        XCTAssertEqual(replacement.purpose, .navigation)
        XCTAssertEqual(lifecycle.pending, replacement)

        XCTAssertEqual(
            lifecycle.finish(generation: replacement.generation, targetId: "episode", completed: false),
            .failed(replacement)
        )
        XCTAssertNil(lifecycle.pending)
    }

    // #166: a pending seek the player has already passed is abandoned; one still in flight is kept.
    func testMediaSeekLifecycleAbandonsOnlyASeekThePlayerHasPassed() {
        var lifecycle = MediaSeekLifecycle()
        // Resume at 5:46.9 from where the player paused: the seek lands where it already was.
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 346_922, originMediaTimeMs: 346_915, uptimeMs: 10_000)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 347_500, uptimeMs: 10_600, playbackRate: 1), "not yet 1 s past the target")
        XCTAssertNotNil(lifecycle.pending)
        let abandoned = lifecycle.abandonIfOverrun(playerMediaTimeMs: 348_400, uptimeMs: 11_500, playbackRate: 1)
        XCTAssertEqual(abandoned?.mediaTimeMs, 346_922)
        XCTAssertNil(lifecycle.pending)

        // A skip back 5 s whose completion hasn't arrived: the player is still playing on from where it was.
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 100_000, purpose: .navigation, originMediaTimeMs: 105_000, uptimeMs: 20_000)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 107_000, uptimeMs: 22_000, playbackRate: 1))
        XCTAssertEqual(lifecycle.pending?.mediaTimeMs, 100_000, "a seek still in flight keeps reporting its target")

        // A jump forward 50 s still in flight: the player is short of the target.
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 200_000, purpose: .navigation, originMediaTimeMs: 150_000, uptimeMs: 30_000)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 151_000, uptimeMs: 31_000, playbackRate: 1))
        // A player far past the target, further than playback since the seek could take it, isn't this seek landing.
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 290_000, uptimeMs: 32_000, playbackRate: 1))
        // Landed and played on.
        XCTAssertEqual(lifecycle.abandonIfOverrun(playerMediaTimeMs: 203_000, uptimeMs: 33_000, playbackRate: 1)?.purpose, .navigation)
        XCTAssertNil(lifecycle.pending)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 203_000, uptimeMs: 33_000, playbackRate: 1), "nothing pending")

        // A jump forward 15 s still in flight while the player plays on from where it was.
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 115_000, purpose: .navigation, originMediaTimeMs: 100_000, uptimeMs: 0)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 117_000, uptimeMs: 17_000, playbackRate: 1))
        XCTAssertEqual(lifecycle.pending?.mediaTimeMs, 115_000)

        // A skip back 2 s that landed and played on past where it started is still abandoned.
        _ = lifecycle.begin(targetId: "episode", mediaTimeMs: 100_000, purpose: .navigation, originMediaTimeMs: 102_000, uptimeMs: 0)
        XCTAssertNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 101_000, uptimeMs: 1_000, playbackRate: 1), "observe the backward landing before playback passes the old origin")
        XCTAssertNotNil(lifecycle.abandonIfOverrun(playerMediaTimeMs: 103_500, uptimeMs: 3_500, playbackRate: 1))
    }

    func testMediaSeekLifecycleIgnoresSupersededSeekCompletion() {
        var lifecycle = MediaSeekLifecycle()
        let first = lifecycle.begin(targetId: "episode", mediaTimeMs: 120_000)
        let second = lifecycle.begin(targetId: "episode", mediaTimeMs: 240_000)

        XCTAssertEqual(lifecycle.finish(generation: first, targetId: "episode", completed: false), .ignored)
        XCTAssertEqual(lifecycle.pending?.generation, second)
        XCTAssertEqual(lifecycle.pending?.mediaTimeMs, 240_000)
        XCTAssertEqual(lifecycle.finish(generation: second, targetId: "episode", completed: true), .completed)
        XCTAssertNil(lifecycle.pending)
    }

    func testRoutedAudioClientPreservesMediaSeekTransactionThroughProductionBoundary() throws {
        let speech = RecordingAudioClient()
        let media = DelayedPositionAudioClient()
        let routed = RoutedAudioPlaybackClient(speech: speech, media: media)

        try routed.play(targetId: "episode", fromMediaTimeMs: 0)
        media.confirmLatestRequest()
        let request = try routed.requestMediaSeek(toMediaTimeMs: 120_000)

        XCTAssertEqual(request.targetId, "episode")
        XCTAssertEqual(request.requestedMediaTimeMs, 120_000)
        XCTAssertEqual(routed.mediaSeekResolution(for: request), .pending)

        media.confirmLatestRequest()
        XCTAssertEqual(routed.mediaSeekResolution(for: request), .accepted(mediaTimeMs: 120_000))
    }

    #if canImport(AVFoundation)
    /// A callback from a synthesizer the client has retired must not move the current playback,
    /// even when it names an utterance the current playback has registered (#1129, BIG-08). Each
    /// callback names a registered utterance, so only the `synthesizer === self.synthesizer`
    /// guards can reject it; the current synthesizer then shows the same utterances are live.
    func testRetiredSpeechSynthesizerCannotConfirmOrCancelCurrentPlayback() throws {
        let client = SystemSpeechPlaybackClient(voiceIdentifier: nil, speechRate: AVSpeechUtteranceDefaultSpeechRate)
        var queued: [(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance)] = []
        client.speakNarration = { queued.append(($0, $1)) } // nothing is spoken, so no real callback races the test
        _ = try client.prepareSpeechText(String(repeating: "Keep the current speech request intact. ", count: 30))
        try client.play(targetId: "earlier", from: 0)
        let retired = try XCTUnwrap(queued.first?.synthesizer)
        queued.removeAll()
        try client.play(targetId: "current", from: 40)
        let current = try XCTUnwrap(queued.first?.synthesizer)
        XCTAssertFalse(retired === current, "playing again retires the earlier synthesizer")
        let first = try XCTUnwrap(queued.first?.utterance)
        let last = try XCTUnwrap(queued.last?.utterance)
        let position = try XCTUnwrap(client.currentCharOffset())
        XCTAssertEqual(client.playbackStartStatus(targetId: "current"), .pending)

        client.speechSynthesizer(retired, didStart: first)
        XCTAssertEqual(client.playbackStartStatus(targetId: "current"), .pending, "a retired start doesn't confirm playback")
        client.speechSynthesizer(retired, willSpeakRangeOfSpeechString: NSRange(location: 5, length: 4), utterance: first)
        XCTAssertEqual(client.currentCharOffset(), position, "a retired word marker doesn't move the place")
        client.speechSynthesizer(retired, didFinish: last)
        XCTAssertFalse(client.isPlaybackComplete(targetId: "current"), "a retired finish doesn't end playback")
        XCTAssertEqual(client.currentCharOffset(), position)
        client.speechSynthesizer(retired, didCancel: first)
        XCTAssertEqual(client.playbackStartStatus(targetId: "current"), .pending, "a retired cancel doesn't fail the start")

        // The same utterances, from the current synthesizer, start and finish playback.
        client.speechSynthesizer(current, didStart: first)
        XCTAssertEqual(client.playbackStartStatus(targetId: "current"), .confirmed)
        client.speechSynthesizer(current, didFinish: last)
        XCTAssertTrue(client.isPlaybackComplete(targetId: "current"))
        try client.stop()
    }

    /// #1109 (Codex audit): with the iOS voice chosen, the client says what it intends in the same words the
    /// on-device voice uses, so a pause record from system-voice narration carries the client's state too. It
    /// ran in the app against the real synthesizer and hung past the 2-minute allowance in 2 of 31 lane runs
    /// (pr1804, pr2067); the intent is the client's own bookkeeping, so nothing is spoken here.
    func testSystemVoiceClientReportsItsIntentForPlaybackRecords() throws {
        let client = SystemSpeechPlaybackClient(voiceIdentifier: nil, speechRate: 0.5)
        var queued: [AVSpeechUtterance] = []
        client.speakNarration = { queued.append($1) }
        XCTAssertEqual(client.diagnosticIntent, "stopped")
        _ = try client.prepareSpeechText(String(repeating: "The iOS voice reads this long enough to pause. ", count: 20))
        try client.play(targetId: "system-intent", from: 0)
        XCTAssertFalse(queued.isEmpty, "playing hands the passage to the synthesizer")
        XCTAssertEqual(client.diagnosticIntent, "playing")
        try client.pause()
        XCTAssertEqual(client.diagnosticIntent, "paused")
        try client.stop()
        XCTAssertEqual(client.diagnosticIntent, "stopped")
    }

    /// #1291 APO-14: the emoji-article soak (`EmojiArticlePlaybackUITests`, retired SpeechCanary
    /// plan) accepted a run that returned Home at 90 percent, so a voice queue missing the
    /// article's tail could pass. This holds the same claim where it runs: every spoken word of a
    /// long article with emoji and links reaches the voice, its last sentence is in the final
    /// utterance, and playback completes only when that utterance finishes.
    func testLongEmojiArticleQueuesEveryWordAndCompletesOnlyAfterItsLastSentence() throws {
        let paragraph = "Meaning keeps shifting 💪🏿 as people find new ways to say what they mean, "
            + "and [the guide](https://example.com/emoji-guide) explains why. Tone meets range ⛲ "
            + "when the artwork has to read at every size on every screen. "
        let lastSentence = "Symbols only stay alive when people use them."
        let source = Array(repeating: paragraph, count: 24).joined(separator: "\n\n") + "\n\n" + lastSentence
        let client = SystemSpeechPlaybackClient(voiceIdentifier: nil, speechRate: AVSpeechUtteranceDefaultSpeechRate)
        var queued: [(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance)] = []
        client.speakNarration = { queued.append(($0, $1)) } // nothing is spoken, so the test delivers the callbacks
        let spoken = try client.prepareSpeechText(source)
        try client.play(targetId: "emoji-article", from: 0)

        let utterances = queued.map(\.utterance)
        XCTAssertGreaterThan(utterances.count, 2, "a long article is spoken in several utterances")
        XCTAssertEqual(
            utterances.map(\.speechString).joined(), spoken,
            "every spoken word of the article reaches the voice, in order, with nothing dropped"
        )
        XCTAssertTrue(utterances.allSatisfy { SpeechTextNormalizer.isSystemSpeechSafe($0.speechString) })
        let final = try XCTUnwrap(utterances.last)
        XCTAssertTrue(final.speechString.hasSuffix(lastSentence), "the article's last sentence is the last thing spoken")

        let synthesizer = try XCTUnwrap(queued.first?.synthesizer)
        client.speechSynthesizer(synthesizer, didStart: utterances[0])
        for utterance in utterances.dropLast() {
            client.speechSynthesizer(synthesizer, didFinish: utterance)
            XCTAssertFalse(
                client.isPlaybackComplete(targetId: "emoji-article"),
                "playback completed before the article's last sentence was spoken"
            )
        }
        client.speechSynthesizer(synthesizer, didFinish: final)
        XCTAssertTrue(client.isPlaybackComplete(targetId: "emoji-article"))
        XCTAssertEqual(client.currentCharOffset(), source.count)
        try client.stop()
    }

    /// #221 lane FAIL: with the iOS voice, changing the speed mid-session restarted playback with
    /// the session's old 1× rate, so "1.50×" played at 1× and Now Playing reported rate 1.
    /// Rate is one number (I14): the session's rate follows the listener's speech rate.
    func testChangingSpeechSettingsMidSessionPlaysAtTheListenersRate() throws {
        let audio = RecordingAudioClient()
        let item = Item(id: "item-rate", title: "Rate", mediaType: "text", text: "One. Two. Three. Four.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-offline",
            displayName: "Phone/Tablet Offline",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
        )
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        _ = try engine.startSession(itemId: item.id)

        let faster = try engine.updateSpeechPlaybackSettings(voiceIdentifier: nil, rate: 0.75) // the app's stored 1.5×
        XCTAssertEqual(audio.playbackRate, 1.5, accuracy: 0.001, "the restart plays at the listener's speed")
        XCTAssertEqual(faster.playbackRate, 1.5, accuracy: 0.001, "Now Playing reports the same rate")

        let slower = try engine.updateSpeechPlaybackSettings(voiceIdentifier: nil, rate: 0.375) // 0.75×
        XCTAssertEqual(audio.playbackRate, 0.75, accuracy: 0.001)
        XCTAssertEqual(slower.playbackRate, 0.75, accuracy: 0.001)
    }

    func testSystemSpeechPlaybackRateReportsEffectiveTransportMultiplier() throws {
        let client = SystemSpeechPlaybackClient(
            voiceIdentifier: nil,
            speechRate: AVSpeechUtteranceDefaultSpeechRate
        )
        _ = try client.prepareSpeechText("System speech should retain an observable playback rate.")
        try client.play(targetId: "system-rate", from: 0)

        try client.setPlaybackRate(1.5)

        XCTAssertEqual(client.currentPlaybackPosition()?.playbackRate ?? 0, 1.5, accuracy: 0.001)
        try client.stop()
    }
    #endif

    func testAudioInterruptionResumePolicyOnlyResumesUntouchedPlayingAudio() {
        var policy = AudioPlaybackInterruptionResumePolicy()

        XCTAssertFalse(policy.began(wasPlaying: false))
        XCTAssertFalse(policy.ended(shouldResume: true))

        XCTAssertTrue(policy.began(wasPlaying: true))
        XCTAssertFalse(policy.ended(shouldResume: false))

        XCTAssertTrue(policy.began(wasPlaying: true))
        policy.cancelAutomaticResume()
        XCTAssertFalse(policy.ended(shouldResume: true))

        XCTAssertTrue(policy.began(wasPlaying: true))
        XCTAssertTrue(policy.ended(shouldResume: true))
        XCTAssertFalse(policy.ended(shouldResume: true))
    }

    func testRoutedPlaybackGivesRemoteCommandOwnershipOnlyToActiveMediaRoute() throws {
        let speech = RecordingAudioClient()
        let media = RecordingAudioClient()
        let routed = RoutedAudioPlaybackClient(speech: speech, media: media)

        XCTAssertEqual(media.remoteCommandHandlingStates, [false])

        _ = try routed.prepareSpeechText("Speech owns playback.")
        try routed.play(targetId: "speech", from: 0)
        XCTAssertEqual(media.remoteCommandHandlingStates.last, false)

        try routed.configureMediaContext(PlaybackMediaContext(
            itemId: "item",
            targetType: .transcriptBackedMedia,
            targetId: "media",
            title: "Media"
        ))
        try routed.play(targetId: "media", fromMediaTimeMs: 0)
        XCTAssertEqual(media.remoteCommandHandlingStates.last, true)

        try routed.configureMediaContext(nil)
        try routed.play(targetId: "speech", from: 0)
        XCTAssertEqual(media.remoteCommandHandlingStates.last, false)
    }

    func testRoutedPlaybackAppliesMixingAndVolumeToEveryRouteWithoutReclaimingRemoteCommands() throws {
        let speech = RecordingAudioClient()
        let media = RecordingAudioClient()
        let routed = RoutedAudioPlaybackClient(speech: speech, media: media)

        try routed.setMixesWithOtherAudio(true)
        try routed.setLowersBackgroundAudio(true)
        try routed.setPlaybackVolume(0.35)
        routed.setRemoteCommandHandlingEnabled(false)
        try routed.configureMediaContext(PlaybackMediaContext(
            itemId: "item",
            targetType: .transcriptBackedMedia,
            targetId: "media",
            title: "Media"
        ))
        try routed.play(targetId: "media", fromMediaTimeMs: 0)

        XCTAssertEqual(speech.backgroundAudioStates, [true])
        XCTAssertEqual(media.backgroundAudioStates, [true])
        XCTAssertEqual(speech.mixingStates, [true])
        XCTAssertEqual(media.mixingStates, [true])
        XCTAssertEqual(speech.playbackVolumes, [0.35])
        XCTAssertEqual(media.playbackVolumes, [0.35])
        XCTAssertEqual(media.remoteCommandHandlingStates.last, false)
    }

    #if canImport(Speech)
    func testSpeechRecognitionRequestsAreAlwaysOnDeviceOnly() {
        let request = makeOnDeviceSpeechRecognitionRequest(url: URL(fileURLWithPath: "/tmp/context.m4a"))
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertFalse(request.shouldReportPartialResults)
    }

    func testLongFormSpeechAccumulatorPreservesEveryFinalizedPassage() {
        var accumulator = SpeechAnalyzerFinalResultAccumulator()
        accumulator.record("The opening idea explains why the rendered audio should remain cached. ")
        accumulator.record("The middle passage contains the minute that the legacy strategy lost. ")
        accumulator.record("The closing passage describes the storage limit and eviction policy.")

        XCTAssertEqual(accumulator.resultCount, 3)
        XCTAssertEqual(
            accumulator.normalizedTranscript,
            "The opening idea explains why the rendered audio should remain cached. "
                + "The middle passage contains the minute that the legacy strategy lost. "
                + "The closing passage describes the storage limit and eviction policy."
        )
    }

    func testLongFormSpeechAccumulatorIgnoresEmptyResultsWithoutReplacingPriorPassages() {
        var accumulator = SpeechAnalyzerFinalResultAccumulator()
        accumulator.record("First finalized passage. ")
        accumulator.record("")
        accumulator.record("Second finalized passage.")

        XCTAssertEqual(accumulator.resultCount, 2)
        XCTAssertEqual(accumulator.normalizedTranscript, "First finalized passage. Second finalized passage.")
    }

    func testLegacySpeechChunksUseNearbySustainedSilenceWithoutOverlapOrGaps() {
        let ranges = silenceAwareSpeechAudioChunkRanges(
            durationMs: 100_000,
            silenceRanges: [
                SpeechAudioSilenceRange(startMs: 28_000, endMs: 29_000),
                SpeechAudioSilenceRange(startMs: 59_000, endMs: 60_000)
            ]
        )

        XCTAssertEqual(ranges.map(\.startMs), [0, 28_500, 59_500])
        XCTAssertEqual(ranges.map(\.lengthMs), [28_500, 31_000, 40_500])
        XCTAssertTrue(ranges.allSatisfy { $0.lengthMs < 45_000 })
        XCTAssertEqual(ranges.last.map { $0.startMs + $0.lengthMs }, 100_000)
        XCTAssertEqual(
            zip(ranges, ranges.dropFirst()).map { $0.startMs + $0.lengthMs == $1.startMs },
            [true, true]
        )
    }

    func testLegacySpeechChunksFallBackToThirtySecondsWhenNoSilenceExists() {
        let ranges = silenceAwareSpeechAudioChunkRanges(
            durationMs: 100_000,
            silenceRanges: []
        )

        XCTAssertEqual(ranges.map(\.startMs), [0, 30_000, 60_000])
        XCTAssertEqual(ranges.map(\.lengthMs), [30_000, 30_000, 40_000])
        XCTAssertTrue(ranges.allSatisfy { $0.lengthMs < 45_000 })
    }

    #if canImport(AVFoundation)
    func testSustainedSilenceDetectorFindsPauseBetweenSpokenAudio() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "speech-silence-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampleRate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let second = Double(frame) / sampleRate
            samples[frame] = second >= 1 && second < 2
                ? 0
                : Float(sin(2 * Double.pi * 220 * second) * 0.2)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let ranges = try sustainedSilenceRanges(in: url)

        let pause = try XCTUnwrap(ranges.first)
        XCTAssertLessThanOrEqual(abs(pause.startMs - 1_000), 100)
        XCTAssertLessThanOrEqual(abs(pause.endMs - 2_000), 100)
    }
    #endif
    #endif

    func testDefangedDomainsSpeakSeparatorsWithoutLosingSourceIdentity() throws {
        let source = "Indicators: meridian-protocol[.]org\nmeridiangroup-corp[.]com. End."
        let speech = SpeechTextNormalizer.normalizeWithSourceOffsets(source)
        XCTAssertTrue(speech.text.contains("domain meridian hyphen protocol dot org"))
        XCTAssertTrue(speech.text.contains("domain meridiangroup hyphen corp dot com"))
        XCTAssertEqual(speech.sourceOffsets, speech.sourceOffsets.sorted())
        XCTAssertEqual(speech.sourceLength, source.count)
        XCTAssertEqual(SpeechTextNormalizer.projectForSystemSpeech(source).text, speech.text)
        let imported = try ObsidianMarkdownParser.parse(fileName: "Indicators.md", contents: source)
        XCTAssertTrue(imported.text.contains("meridian-protocol[.]org"))
    }

    func testReferenceSpeechKeepsOrdinaryParentheticalNumbers() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("Evidence [17] and note [^3]. Cost (17), year (2026), range (2–4)."),
                       "Evidence citation 17 and note footnote 3. Cost (17), year (2026), range (2–4).")
    }

    func testPastedSetextAndBoldHeadingsRetainCanonicalBoundaries() throws {
        let parsed = try ObsidianMarkdownParser.parse(fileName: "Notes.md", contents: "First heading\n===\nFirst paragraph.\n\n**Second heading**\n\nSecond paragraph.")
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "notes", policy: .canonicalHeadings))
        XCTAssertEqual(map.chapters.map(\.title), ["First heading", "Second heading"])
        XCTAssertEqual(map.chapters.last?.endChar, parsed.text.count)
    }

    func testSpeechNormalizationPreservesSource() {
        let source = "A [reference](https://example.com/x) and https://example.org/raw plus example.net/path."
        let spoken = SpeechTextNormalizer.normalize(source)
        XCTAssertEqual(spoken, "A reference and plus.")
        XCTAssertTrue(source.contains("https://example.com/x"))
    }

    func testSpeechNormalizationPreservesDecimalClaimAndSectionReferences() {
        let source = "Claim 2.5: evidence. See [Claim 3.2.1](https://example.com/claim) and Section 4.7."

        XCTAssertEqual(
            SpeechTextNormalizer.normalize(source),
            "Claim 2.5: evidence. See Claim 3.2.1 and Section 4.7."
        )
    }

    func testSpeechNormalizationPreservesDottedAbbreviationsAndTheirSourceOffsets() throws {
        let source = "The U.S. economy, i.e. output, and U.K. policy. A Ph.D. at 9 a.m. See example.net/path and https://example.com."
        let normalized = SpeechTextNormalizer.normalizeWithSourceOffsets(source)
        for abbreviation in ["U.S.", "i.e.", "U.K.", "Ph.D.", "a.m."] {
            let spokenRange = try XCTUnwrap(normalized.text.range(of: abbreviation))
            let sourceRange = try XCTUnwrap(source.range(of: abbreviation))
            XCTAssertEqual(
                normalized.sourceOffset(atSpokenCharacterOffset: normalized.text.distance(from: normalized.text.startIndex, to: spokenRange.lowerBound)),
                source.distance(from: source.startIndex, to: sourceRange.lowerBound)
            )
        }
        XCTAssertFalse(normalized.text.contains("example"))
        let parsed = try ObsidianMarkdownParser.parse(fileName: "Article", contents: "# U.S. policy\n\nThe U.S. economy (i.e. output).")
        XCTAssertTrue(parsed.text.contains("The U.S. economy (i.e. output)."))
        XCTAssertEqual(parsed.title, "U.S. policy")
    }

    func testCorrectedReadableArticleCreatesSeparateEditionAndPreservesOriginalSession() throws {
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "browser", displayName: "Browser", capabilities: ["sync": ["canonical_persistence"]]), repository: repo)
        var handoff = BrowserTextHandoff(captureMode: .readablePage, source: BrowserTextSource(url: "https://example.com/article", title: "Article"), text: "A quote. A quote.", requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app"))
        let original = try engine.importBrowserTextInBackground(handoff)
        let session = Session(id: "original-session", itemId: original.id, status: "finished", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: original.id, position: Position(charOffset: 10), completionPercent: 100, playbackRate: 1)
        try repo.saveSession(session)
        let oldMap = ListeningMap(id: "old-map", itemId: original.id, overview: "Original map", chapters: [])
        try repo.saveListeningMap(oldMap)
        handoff.text = "A quote."
        let corrected = try engine.importBrowserTextInBackground(handoff)
        XCTAssertNotEqual(corrected.id, original.id)
        XCTAssertEqual(corrected.text, "A quote.")
        XCTAssertNil(try repo.loadListeningMap(itemId: corrected.id))
        XCTAssertEqual(try repo.loadItem(id: original.id), original)
        XCTAssertEqual(try repo.loadSession(id: session.id), session)
        XCTAssertEqual(try repo.loadListeningMap(itemId: original.id), oldMap)
        XCTAssertEqual(try engine.importBrowserTextInBackground(handoff).id, corrected.id)
        var trashed = corrected
        trashed.deletedAt = Date(timeIntervalSince1970: 100)
        try repo.saveItem(trashed)
        XCTAssertNil(try engine.importBrowserTextInBackground(handoff).deletedAt)
        XCTAssertEqual(try repo.loadItem(id: original.id), original)
    }

    func testReextractedPDFKeepsTheTextUnderExistingWrittenMargins() throws {
        // A new PDF extractor (C1 M3) changes the text a written Margin's offsets
        // point into. Re-importing must not replace it (I13 rule 1).
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        for url in ["shared-file://share-sheet/Paper.pdf", "https://journal.example/paper.pdf"] {
            var handoff = BrowserTextHandoff(captureMode: .markdownFile, source: BrowserTextSource(url: url, title: "Paper"), text: "# Paper\n\nJ Biol 12 (2020) 1-9. The body begins here and goes on.", contentFormat: .markdown)
            let original = try engine.importBrowserTextInBackground(handoff)
            let originalText = try XCTUnwrap(original.text)
            let marked = try XCTUnwrap(originalText.range(of: "body begins"))
            let session = Session(id: "session-\(original.id)", itemId: original.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: original.id, position: Position(), completionPercent: 0, playbackRate: 1)
            try store.saveSession(session)
            let margin = Interjection(
                id: "margin-\(original.id)",
                itemId: original.id,
                sessionId: session.id,
                targetType: .item,
                targetId: original.id,
                createdAt: Date(timeIntervalSince1970: 1),
                roughPercent: 50,
                anchor: Anchor(anchorType: .text, startChar: originalText.distance(from: originalText.startIndex, to: marked.lowerBound), endChar: originalText.distance(from: originalText.startIndex, to: marked.upperBound), anchorBefore: "The", anchorAfter: "here"),
                audioPath: nil,
                audioStatus: "none",
                transcriptionStatus: "complete",
                transcript: nil,
                cleanedTranscript: nil,
                displayText: "Written Margin",
                status: "active"
            )
            try store.saveInterjection(margin)

            handoff.text = "# Paper\n\nThe body begins here and goes on."
            let reextracted = try engine.importBrowserTextInBackground(handoff)

            XCTAssertNotEqual(reextracted.id, original.id, url)
            XCTAssertEqual(reextracted.text, "Paper\n\nThe body begins here and goes on.", url)
            let kept = Array(try XCTUnwrap(store.loadItem(id: original.id).text))
            XCTAssertEqual(String(kept), originalText, url)
            let anchor = try XCTUnwrap(store.loadInterjections(sessionId: session.id).first?.anchor)
            XCTAssertEqual(anchor.endChar <= kept.count ? String(kept[anchor.startChar..<anchor.endChar]) : nil, "body begins", url)
            XCTAssertEqual(try engine.importBrowserTextInBackground(handoff).id, reextracted.id, "the same re-extraction is one edition: \(url)")
        }
    }

    /// Imports a PDF's v1 text, writes Margins on the given words and a position, then
    /// re-imports it with a v2 document. Returns the store, the v1 item and the result.
    private func reimportV1PDFWithV2(
        v2Lines: [StructuredDocumentLine],
        marginWords: [String],
        positionWords: String
    ) throws -> (store: SQLiteSessionStore, v1: Item, reimported: Item, margins: [Interjection], session: Session, path: String) {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let url = "shared-file://share-sheet/Paper.pdf"
        let v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: "# Paper\n\n## Methods\n\nWe measured sleep in adults.\nThe effect held across cohorts.\n\n## Results\n\nSleep improved with morning light.",
            contentFormat: .markdown
        ))
        let text = try XCTUnwrap(v1.text)
        func offset(_ words: String) throws -> Int {
            text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: words)).lowerBound)
        }
        let session = Session(id: "session-v1", itemId: v1.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: v1.id, position: Position(charOffset: try offset(positionWords)), completionPercent: 40, playbackRate: 1)
        try store.saveSession(session)
        let margins = try marginWords.enumerated().map { index, words -> Interjection in
            let start = try offset(words)
            let margin = Interjection(
                id: "margin-\(index)", itemId: v1.id, sessionId: session.id, targetType: .item, targetId: v1.id,
                createdAt: Date(timeIntervalSince1970: Double(index)), roughPercent: 10,
                anchor: Anchor(anchorType: .text, startChar: start, endChar: start + words.count, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: "Margin \(index)", status: "active"
            )
            try store.saveInterjection(margin)
            return margin
        }
        let document = StructuredDocumentBuilder.build(lines: v2Lines, engine: "pdfkit_baseline", version: 2, pageCount: 2)
        let reimported = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: document.text,
            contentFormat: .plainText
        ), structuredDocument: document)
        return (store, v1, reimported, margins, session, path)
    }

    private func words(_ margin: Interjection, in text: String) -> String? {
        let characters = Array(text)
        guard margin.anchor.endChar <= characters.count else { return nil }
        return String(characters[margin.anchor.startChar..<margin.anchor.endChar])
    }

    func testReimportMovesAV1PDFToV2WhenEveryMarginLandsOnTheSameWords() throws {
        let marginWords = ["Methods", "The effect held across cohorts", "morning light"]
        let result = try reimportV1PDFWithV2(v2Lines: [
            StructuredDocumentLine(text: "Paper", role: .title, pageIndex: 0),
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "We measured sleep in adults.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "The effect held across cohorts.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "Results", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "Sleep improved with morning light.", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "References", role: .reference, pageIndex: 1),
            StructuredDocumentLine(text: "[1] A. Author. Title. 2020.", role: .reference, pageIndex: 1),
        ], marginWords: marginWords, positionWords: "Sleep improved")
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        XCTAssertEqual(result.reimported.id, result.v1.id, "the same item moves; no second Library row")
        let newText = try XCTUnwrap(try result.store.loadItem(id: result.v1.id).text)
        XCTAssertTrue(newText.contains("J Biol 12"))
        XCTAssertNotNil(try result.store.loadStructuredDocument(itemId: result.v1.id))
        let moved = try result.store.loadInterjections(sessionId: result.session.id).sorted { $0.id < $1.id }
        XCTAssertEqual(moved.map { words($0, in: newText) }, marginWords, "every Margin opens at the same words")
        let position = try XCTUnwrap(try result.store.loadSession(id: result.session.id)?.position.charOffset)
        XCTAssertEqual(String(Array(newText)[position...].prefix(14)), "Sleep improved")
        XCTAssertEqual(try result.store.listItems().count, 1)
    }

    /// A v1 PDF with the given sessions (each with one Margin on `words`), re-imported
    /// with a v2 document that inserts a running head before the body.
    private func reimportWithSessions(_ sessions: [(session: Session, marginId: String, words: String)]) throws -> (store: SQLiteSessionStore, v1: Item, path: String, reimported: Item) {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let url = "shared-file://share-sheet/Paper.pdf"
        let v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: "# Paper\n\n## Methods\n\nWe measured sleep in adults.\nThe effect held across cohorts.\n\n## Results\n\nSleep improved with morning light.",
            contentFormat: .markdown
        ))
        let text = try XCTUnwrap(v1.text)
        for entry in sessions {
            var session = entry.session
            session.itemId = v1.id
            session.currentTargetId = session.currentTargetType == .itemTextTTS ? v1.id : session.currentTargetId
            try store.saveSession(session)
            let start = text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: entry.words)).lowerBound)
            try store.saveInterjection(Interjection(
                id: entry.marginId, itemId: v1.id, sessionId: session.id, targetType: .item, targetId: v1.id,
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
                anchor: Anchor(anchorType: .text, startChar: start, endChar: start + entry.words.count, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: "Margin", status: "active"
            ))
        }
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Paper", role: .title, pageIndex: 0),
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "We measured sleep in adults.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "The effect held across cohorts.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "Results", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "Sleep improved with morning light.", role: .body, pageIndex: 1),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 2)
        let reimported = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: document.text,
            contentFormat: .plainText
        ), structuredDocument: document)
        return (store, v1, path, reimported)
    }

    func testReimportMovesEachSessionsMarginWhenTwoSessionsShareAMarginId() throws {
        // #220 audit 1: Margin ids are numbered per session ("ij-001" in each), and the
        // upgrade keyed moved ranges by id alone, so one Margin took the other's passage.
        func session(_ id: String) -> Session {
            Session(id: id, itemId: "", status: "finished", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: "", position: Position(), completionPercent: 100, playbackRate: 1)
        }
        let result = try reimportWithSessions([
            (session("session-a"), "ij-001", "measured sleep"),
            (session("session-b"), "ij-001", "morning light"),
        ])
        defer { try? FileManager.default.removeItem(atPath: result.path) }
        XCTAssertEqual(result.reimported.id, result.v1.id, "the item moves to v2")
        let text = try XCTUnwrap(try result.store.loadItem(id: result.v1.id).text)
        XCTAssertEqual(try result.store.loadInterjections(sessionId: "session-a").map { words($0, in: text) }, ["measured sleep"])
        XCTAssertEqual(try result.store.loadInterjections(sessionId: "session-b").map { words($0, in: text) }, ["morning light"])
    }

    func testReimportLeavesAPositionInASummaryOrReplyWhereItIs() throws {
        // #220 audit 2: a session paused in a summary or AI reply keeps its position in
        // the reply's text, not the PDF's; the upgrade moved it as if it were a PDF offset.
        let reply = Session(id: "session-reply", itemId: "", status: "paused", phase: .aiResponsePlayback, currentTargetType: .assistantTurnTTS, currentTargetId: "turn-1", position: Position(charOffset: 40, chapterId: "turn-chapter"), completionPercent: 30, playbackRate: 1)
        let listening = Session(id: "session-listen", itemId: "", status: "paused", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "", position: Position(), completionPercent: 0, playbackRate: 1)
        let result = try reimportWithSessions([
            (reply, "ij-001", "measured sleep"),
            (listening, "ij-001", "morning light"),
        ])
        defer { try? FileManager.default.removeItem(atPath: result.path) }
        XCTAssertEqual(result.reimported.id, result.v1.id, "a reply position doesn't block the move")
        let kept = try XCTUnwrap(try result.store.loadSession(id: "session-reply"))
        XCTAssertEqual(kept.position, reply.position, "the reply position is untouched")
    }

    func testAV2DocumentSavedForThePlayingTextIsUsedOnTheNextPlay() throws {
        // #220 audit 5: the projection cache kept "no document" for an item after a
        // re-import saved a document for the same text, so "[12]" was still spoken.
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: [
            "sync": ["browser_session_handoff", "canonical_persistence"],
            "playback": ["realtime_tts"],
        ]), repository: store, audio: audio)
        let url = "shared-file://share-sheet/Paper.pdf"
        let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: "The effect held [12] in every cohort.",
            contentFormat: .markdown
        ))
        _ = try engine.startSession(itemId: item.id)
        XCTAssertTrue(try XCTUnwrap(audio.preparedTexts.last).contains("[12]"), "v1: no document yet")
        _ = try engine.pause()

        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: try XCTUnwrap(item.text), role: .body, pageIndex: 0),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 1)
        XCTAssertEqual(document.text, item.text)
        _ = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: document.text,
            contentFormat: .plainText
        ), structuredDocument: document)
        _ = try engine.resumePlayback()
        XCTAssertFalse(try XCTUnwrap(audio.preparedTexts.last).contains("[12]"), "the new document's I14 projection is used")
    }

    func testReimportLeavesAV1PDFAloneWhenAMarginsWordsChange() throws {
        // v1 removed a running head from the middle of a sentence that crossed a page;
        // v2 keeps the head there, so "effect held across" is no longer one run of text.
        let marginWords = ["Methods", "effect held across", "morning light"]
        let result = try reimportV1PDFWithV2(v2Lines: [
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "We measured sleep in adults.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "The effect held", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 1),
            StructuredDocumentLine(text: "across cohorts.", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "Results", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "Sleep improved with morning light.", role: .body, pageIndex: 1),
        ], marginWords: marginWords, positionWords: "Sleep improved")
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        XCTAssertNotEqual(result.reimported.id, result.v1.id, "the new text becomes its own edition")
        let kept = try result.store.loadItem(id: result.v1.id)
        XCTAssertEqual(kept.text, result.v1.text, "the v1 item keeps its text")
        XCTAssertNil(try result.store.loadStructuredDocument(itemId: result.v1.id))
        XCTAssertEqual(try result.store.loadInterjections(sessionId: result.session.id).sorted { $0.id < $1.id }, result.margins, "its Margins are untouched")
        XCTAssertEqual(try result.store.loadSession(id: result.session.id)?.position, result.session.position)
    }

    func testAPDFSharedFromAURLWithoutAPdfExtensionKeepsItsV2Document() throws {
        // #220 T4: Safari's share of https://arxiv.org/pdf/2607.28282v1 imported v2 text
        // without its document (no roles, no chapters), because the URL has no ".pdf".
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: repo)
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Introduction", role: .heading, pageIndex: 0, level: 1),
            StructuredDocumentLine(text: "Listening is slower than reading.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 1, level: 1),
            StructuredDocumentLine(text: "We asked twelve researchers.", role: .body, pageIndex: 1),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 2)
        let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "https://arxiv.org/pdf/2607.28282v1", title: "Scalable Evaluation"),
            text: document.text,
            contentFormat: .plainText,
            documentStructure: PDFDocumentStructure(extractionEngine: .pdfKit, analysisStatus: .partial, pageCount: 2, analyzedPageCount: 0)
        ), structuredDocument: document)
        XCTAssertEqual(item.mediaType, "pdf")
        XCTAssertEqual(try repo.loadStructuredDocument(itemId: item.id), document)
        XCTAssertEqual(item.status, "ready")
        XCTAssertNotNil(try repo.loadListeningMap(itemId: item.id))
    }

    func testExtractionV2PDFIsSpokenPerI14WhilePositionsStayInItemText() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let audio = RecordingAudioClient()
        let profile = RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: [
            "sync": ["browser_session_handoff", "canonical_persistence"],
            "playback": ["realtime_tts"],
        ])
        let engine = SessionEngine(profile: profile, repository: store, audio: audio)
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Levels rose [12] as expected.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "Participant Sessions P1 14", role: .table, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "[12] A. Author. A cited title. 2019.", role: .reference, pageIndex: 1),
            StructuredDocumentLine(text: "Appendix", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "Supplementary methods are read.", role: .body, pageIndex: 1),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 2)
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "shared-file://share-sheet/Paper.pdf", title: "Paper"),
            text: "# Paper\n\nv1 markdown is ignored when a v2 document comes with it.",
            contentFormat: .markdown
        )

        let item = try engine.importBrowserTextInBackground(handoff, structuredDocument: document)

        XCTAssertEqual(item.text, document.text, "Item.text is the canonical v2 text, references and all")
        XCTAssertEqual(try store.loadStructuredDocument(itemId: item.id), document)
        XCTAssertEqual(try store.loadListeningMap(itemId: item.id)?.chapters.map(\.title).contains("Appendix"), true)

        _ = try engine.startSession(itemId: item.id)
        let spoken = try XCTUnwrap(audio.preparedTexts.last)
        // #336: prepared audio is planned from exactly what the player speaks after any preface.
        XCTAssertTrue(spoken.hasSuffix(try XCTUnwrap(PreparedSpeechText(item: item, document: document)).text))
        XCTAssertTrue(spoken.contains("References skipped."))
        XCTAssertTrue(spoken.contains("Table not read."))
        for unheard in ["A cited title", "P1 14", "J Biol", "[12]"] {
            XCTAssertFalse(spoken.contains(unheard), unheard)
        }

        // The engine reports its position in the spoken text; the session keeps Item.text's.
        let itemText = try XCTUnwrap(item.text)
        let spokenAppendix = spoken.distance(from: spoken.startIndex, to: try XCTUnwrap(spoken.range(of: "Appendix")).lowerBound)
        let sourceAppendix = itemText.distance(from: itemText.startIndex, to: try XCTUnwrap(itemText.range(of: "Appendix")).lowerBound)
        audio.currentOffset = spokenAppendix
        _ = try engine.pause()
        let sessionId = try XCTUnwrap(engine.snapshot.sessionId)
        XCTAssertEqual(try store.loadSession(id: sessionId)?.position.charOffset, sourceAppendix)

        _ = try engine.resumePlayback()
        XCTAssertEqual(audio.playedOffsets.last, spokenAppendix, "resuming starts at the same words")
    }

    func testPodcastIdentitySeparatesDefaultFilenamesAndTitlePrefixesAcrossPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "identity.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let profile = RuntimeCapabilityProfile(id: "identity", displayName: "Identity", capabilities: ["sync": ["canonical_persistence"]])
        let engine = SessionEngine(profile: profile, repository: store)
        func resolve(_ url: String, title: String = "default", identity: String? = nil, using importer: SessionEngine) throws -> Item {
            let request = LinkResolutionRequest(id: UUID().uuidString, inputURL: url, sourceSurface: "test", createdAt: Date(timeIntervalSince1970: 100))
            let candidate = LinkResolutionCandidate(sourceLink: SourceLink(url: url, role: "audio_file"), title: title, audioURL: url, confidence: 1)
            return try XCTUnwrap(importer.importResolvedSourceLinkInBackground(request, result: LinkResolutionResult(requestId: request.id, status: .playable, originalLink: candidate.sourceLink, selectedCandidate: candidate), sourceIdentity: identity))
        }
        let legacy = Item(id: "item-source-default", title: "Legacy episode", mediaType: "audio", text: nil, externalReference: nil, status: "ready")
        try store.saveItem(legacy)
        let legacyMap = ListeningMap(id: "legacy-map", itemId: legacy.id, overview: "Uncertain legacy ownership", chapters: [])
        try store.saveListeningMap(legacyMap)
        let firstURL = "https://audio.example/one/default.mp3?episode=1"
        var first = try resolve(firstURL, using: engine)
        first.transcriptId = "first-transcript"
        first.media?.nativeMediaId = "file:///local/first.mp3"
        try store.saveItem(first)
        let map = ListeningMap(id: "first-map", itemId: first.id, overview: "AI data centers", chapters: [])
        try store.saveListeningMap(map)
        let session = Session(id: "podcast-session", itemId: first.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: first.id, position: Position(mediaTimeMs: 12_000), completionPercent: 20, playbackRate: 1)
        try store.saveSession(session)
        let second = try resolve("https://audio.example/two/default.mp3?episode=2", using: engine)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(second.id, legacy.id)
        XCTAssertNil(try store.loadListeningMap(itemId: second.id))
        let reopened = try SQLiteSessionStore(path: path)
        let restored = SessionEngine(profile: profile, repository: reopened)
        XCTAssertEqual(try resolve(firstURL, title: "Renamed episode", using: restored), first)
        XCTAssertEqual(try reopened.loadListeningMap(itemId: first.id), map)
        XCTAssertEqual(try reopened.loadSession(id: session.id), session)
        XCTAssertEqual(try reopened.loadListeningMap(itemId: legacy.id), legacyMap)
        let longTitle = String(repeating: "Long title ", count: 12)
        let a = try resolve("https://audio.example/default.mp3?episode=A", title: longTitle + "A", using: restored)
        let b = try resolve("https://audio.example/default.mp3?episode=B", title: longTitle + "B", using: restored)
        XCTAssertNotEqual(a.id, b.id)
        let followed = try resolve(firstURL, identity: "subscription:entry", using: restored)
        XCTAssertEqual(try resolve("https://audio.example/new-signed-url.mp3", title: "Updated title", identity: "subscription:entry", using: restored), followed)
        XCTAssertNotEqual(try resolve(firstURL, identity: "subscription:other-entry", using: restored).id, followed.id)
    }

    func testSpeechNormalizationReducesDefuddleSocialCardToAuthoredPost() throws {
        let source = """
        Before the post.

        [

        ![X avatar for @netflix](https://cdn.example/avatar.jpg)

        Netflix@netflix

        DANG!, a new adult animated series, premieres September 8, until their high-achieving sister Ruthie wants

        <video controls="" src="https://video.example/trailer.mp4"></video>

        3:00 PM · Aug 11, 2026 · 29.7M Views

        ---

        1.42K Replies · 975 Reposts · 23.3K Likes

        ](https://x.com/netflix/status/2087192315823538471)

        After the post.
        """

        let normalized = SpeechTextNormalizer.normalizeWithSourceOffsets(source)

        XCTAssertEqual(
            normalized.text,
            "Before the post. Post from Netflix. DANG!, a new adult animated series, premieres September 8, until their high-achieving sister Ruthie wants. Media attached. After the post."
        )
        XCTAssertFalse(normalized.text.localizedCaseInsensitiveContains("video"))
        XCTAssertFalse(normalized.text.contains("29.7M"))
        XCTAssertFalse(normalized.text.localizedCaseInsensitiveContains("Replies"))
        XCTAssertFalse(normalized.text.localizedCaseInsensitiveContains("x.com"))
        let spokenAfter = try XCTUnwrap(normalized.text.range(of: "After the post."))
        let sourceAfter = try XCTUnwrap(source.range(of: "After the post."))
        let spokenOffset = normalized.text.distance(from: normalized.text.startIndex, to: spokenAfter.lowerBound)
        let sourceOffset = source.distance(from: source.startIndex, to: sourceAfter.lowerBound)
        XCTAssertEqual(normalized.sourceOffset(atSpokenCharacterOffset: spokenOffset), sourceOffset)
        XCTAssertTrue(zip(normalized.sourceOffsets, normalized.sourceOffsets.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testSpeechNormalizationLabelsQuotedSocialPostAndPreservesOrdinaryMetrics() {
        let source = """
        [

        Writer@writer

        This is the writer's response.

        ![](https://cdn.example/quoted-avatar.jpg)

        Netflix @netflix

        This is the quoted post.

        24 Replies · 30 Reposts · 401 Likes

        ](https://twitter.com/writer/status/1)

        The trailer received 29.7M Views in ordinary article prose.
        """

        XCTAssertEqual(
            SpeechTextNormalizer.normalize(source),
            "Post from Writer. This is the writer's response. Quoted post from Netflix. This is the quoted post. The trailer received 29.7M Views in ordinary article prose."
        )
    }

    func testSpeechNormalizationMapsSpokenTextBackToSourceOffsets() {
        let source = "Read [the reference](https://example.com/x) now."
        let normalized = SpeechTextNormalizer.normalizeWithSourceOffsets(source)
        let spokenOffset = normalized.text.distance(
            from: normalized.text.startIndex,
            to: normalized.text.range(of: "reference")!.lowerBound
        )
        let expectedSourceOffset = source.distance(
            from: source.startIndex,
            to: source.range(of: "reference")!.lowerBound
        )

        XCTAssertEqual(normalized.text, "Read the reference now.")
        XCTAssertEqual(normalized.sourceOffset(atSpokenCharacterOffset: spokenOffset), expectedSourceOffset)
        XCTAssertEqual(normalized.sourceOffset(atSpokenCharacterOffset: normalized.text.count), source.count)
    }

    func testSpeechNormalizationMapsSourceSeeksAcrossRemovedContent() throws {
        let source = "Opening.\n\nhttps://example.com/removed\n\nDestination sentence."
        let normalized = SpeechTextNormalizer.normalizeWithSourceOffsets(source)
        let destinationRange = try XCTUnwrap(source.range(of: "Destination"))
        let sourceOffset = source.distance(from: source.startIndex, to: destinationRange.lowerBound)
        let spokenOffset = normalized.spokenCharacterOffset(atOrAfterSourceOffset: sourceOffset)

        XCTAssertEqual(normalized.sourceOffset(atSpokenCharacterOffset: spokenOffset), sourceOffset)
        XCTAssertEqual(
            normalized.spokenCharacterOffset(atOrAfterSourceOffset: source.count),
            normalized.text.count
        )
    }

    func testLiveSpeechPlannerBoundsLongDocumentsWithoutTreatingFirstChunkAsCompletion() {
        let preface = "A short listening overview.\n\n"
        let paragraph = "This paragraph explains one part of the document in enough detail to exercise continuous spoken playback. "
        let source = preface + Array(repeating: paragraph, count: 40).joined()

        let chunks = SpeechPlaybackPlanner.chunks(in: source, from: 0, targetChunkCharacters: 360)

        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertLessThan(chunks[0].sourceEnd, source.count)
        XCTAssertEqual(chunks.last?.sourceEnd, source.count)
        XCTAssertTrue(chunks.allSatisfy { !$0.spokenText.isEmpty && $0.sourceStart < $0.sourceEnd })
        XCTAssertTrue(chunks.allSatisfy { $0.spokenText.count <= 720 })
        XCTAssertTrue(zip(chunks, chunks.dropFirst()).allSatisfy { $0.sourceEnd <= $1.sourceStart })
    }

    func testSystemSpeechChunkRemovesEmojiAndURLsBeforeMappingRanges() throws {
        let source = "Intro 😀 read [the reference](https://example.com/path) and finish."
        let chunk = try XCTUnwrap(SpeechPlaybackPlanner.chunks(in: source, from: 0).first)
        let spokenRange = (chunk.spokenText as NSString).range(of: "finish")
        let expected = source.distance(
            from: source.startIndex,
            to: try XCTUnwrap(source.range(of: "finish")).lowerBound
        )

        XCTAssertFalse(chunk.spokenText.contains("😀"))
        XCTAssertFalse(chunk.spokenText.contains("example.com"))
        XCTAssertTrue(SpeechTextNormalizer.isSystemSpeechSafe(chunk.spokenText))
        XCTAssertEqual(chunk.sourceOffset(atSpokenUTF16Offset: spokenRange.location), expected)
    }

    func testSystemSpeechProjectionRemovesMarkupAndUnsafeGraphemeClusters() throws {
        let source = """
        Start 💪🏿 ❤️ 👨‍👩‍👧‍👦 then [remove this URL](https://example.com/a).
        <video controls><source src=\">broken">Do not speak this fallback.</video>
        Finish “safely”—now. ⛲
        """
        let chunk = try XCTUnwrap(SpeechPlaybackPlanner.chunks(in: source, from: 0).first)
        let spokenRange = (chunk.spokenText as NSString).range(of: "Finish \"safely\"-now")
        let expected = source.distance(
            from: source.startIndex,
            to: try XCTUnwrap(source.range(of: "Finish")).lowerBound
        )

        XCTAssertEqual(
            chunk.spokenText,
            "Start then remove this URL. Finish \"safely\"-now."
        )
        XCTAssertFalse(chunk.spokenText.contains("fallback"))
        XCTAssertTrue(SpeechTextNormalizer.isSystemSpeechSafe(chunk.spokenText))
        XCTAssertEqual(chunk.sourceOffset(atSpokenUTF16Offset: spokenRange.location), expected)
        XCTAssertGreaterThanOrEqual(chunk.sourceOffset(atSpokenUTF16Offset: spokenRange.location + spokenRange.length), expected)
    }

    func testSystemSpeechPlannerReducesSocialCardBeforeChunkingLongPost() {
        let postBody = String(repeating: "This social post sentence remains audible and attributable. ", count: 24)
        let source = """
        Opening article prose.

        [

        Writer@writer

        \(postBody)

        <video controls="" src="https://video.example/post.mp4"></video>

        3:00 PM · Aug 11, 2026 · 29.7M Views

        1.42K Replies · 975 Reposts · 23.3K Likes

        ](https://x.com/writer/status/1)

        Closing article prose.
        """

        let chunks = SpeechPlaybackPlanner.chunks(in: source, from: 0, targetChunkCharacters: 300)
        let spoken = chunks.map(\.spokenText).joined(separator: " ")

        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(spoken.contains("Post from Writer."))
        XCTAssertTrue(spoken.contains("Media attached."))
        XCTAssertTrue(spoken.contains("Closing article prose."))
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("video"))
        XCTAssertFalse(spoken.contains("29.7M"))
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("Replies"))
        XCTAssertEqual(chunks.last?.sourceEnd, source.count)
        XCTAssertTrue(zip(chunks, chunks.dropFirst()).allSatisfy { $0.sourceEnd == $1.sourceStart })

        let metadataOffset = source.distance(
            from: source.startIndex,
            to: source.range(of: "3:00 PM")!.lowerBound
        )
        let resumedSpoken = SpeechPlaybackPlanner.chunks(in: source, from: metadataOffset)
            .map(\.spokenText)
            .joined(separator: " ")
        XCTAssertEqual(resumedSpoken, "Closing article prose.")
        XCTAssertFalse(resumedSpoken.contains("29.7M"))
        XCTAssertFalse(resumedSpoken.localizedCaseInsensitiveContains("Replies"))
        XCTAssertFalse(resumedSpoken.localizedCaseInsensitiveContains("x.com"))
    }

    func testSystemSpeechPreservesWhitespaceWordBoundariesAndSourceOffsets() {
        for separator in ["\n", "\r\n", "\t"] {
            let source = "First" + separator + "second"
            let projected = SpeechTextNormalizer.projectForSystemSpeech(source)
            XCTAssertEqual(projected.text, "First second")
            XCTAssertEqual(projected.sourceOffsets.last, source.count - 1)
            XCTAssertEqual(projected.text.count, projected.sourceOffsets.count)
        }
        let source = "meridian-protocol[.]org\nmeridiangroup-corp[.]com\nprojectnightcrawler[.]dev"
        let projected = SpeechTextNormalizer.projectForSystemSpeech(source)
        XCTAssertEqual(projected.text, "domain meridian hyphen protocol dot org. domain meridiangroup hyphen corp dot com. domain projectnightcrawler dot dev.")
        XCTAssertTrue(zip(projected.sourceOffsets, projected.sourceOffsets.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }

    func testSystemSpeechProjectionGuaranteesOneUTF16UnitPerSpokenCharacter() {
        let source = "Emoji evolve: 💅 💪💪🏻💪🏼💪🏽💪🏾💪🏿 ❤️ 👨‍👩‍👧‍👦. Café क् ⛲ \u{200D} remains readable."
        let projected = SpeechTextNormalizer.projectForSystemSpeech(source)

        XCTAssertTrue(SpeechTextNormalizer.isSystemSpeechSafe(projected.text))
        XCTAssertTrue(projected.text.allSatisfy { String($0).utf16.count == 1 })
        XCTAssertEqual(projected.text.count, projected.sourceOffsets.count)
        XCTAssertTrue(zip(projected.sourceOffsets, projected.sourceOffsets.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        XCTAssertTrue(projected.sourceOffsets.allSatisfy { 0...source.count ~= $0 })
        XCTAssertFalse(projected.text.contains("💅"))
        XCTAssertFalse(projected.text.contains("क्"))
        XCTAssertTrue(projected.text.contains("Café"))
    }

    func testObsidianWebClipperImportCleansTranscriptTimestampsAndMetadata() throws {
        let markdown = """
        ---
        title: "Sarah Paine - Why Putin and Xi can't escape geography"
        source: "https://www.youtube.com/watch?v=OS1NZLgKM2c&list=TLPQMTAwNjIwMjZENlo5qll1wg&index=11"
        tags:
          - "clippings"
        ---
        ![](https://www.youtube.com/watch?v=OS1NZLgKM2c)

        𝐓𝐈𝐌𝐄𝐒𝐓𝐀𝐌𝐏𝐒
        00:00:00 - Setting the stage
        00:12:10 - The continental powers

        ## Transcript

        ### Setting the stage

        **0:00** · Good evening. It's such a pleasure to be with you.
        **0:29** · Geopolitics is the influence of geography on politics.
        """

        let parsed = try ObsidianMarkdownParser.parse(fileName: "Sarah Paine.md", contents: markdown)

        XCTAssertEqual(parsed.title, "Sarah Paine - Why Putin and Xi can't escape geography")
        XCTAssertEqual(parsed.source, "https://www.youtube.com/watch?v=OS1NZLgKM2c&list=TLPQMTAwNjIwMjZENlo5qll1wg&index=11")
        XCTAssertFalse(parsed.text.contains("Timestamps"))
        XCTAssertFalse(parsed.text.contains("00:00:00"))
        XCTAssertFalse(parsed.text.contains("0:29"))
        XCTAssertFalse(parsed.text.contains("youtube.com"))
        XCTAssertTrue(parsed.text.contains("Good evening."))
        XCTAssertTrue(parsed.text.contains("Geopolitics is the influence"))
    }

    func testObsidianWebClipperImportCleansBlogMarkdownLinks() throws {
        let markdown = """
        ---
        title: "We’ve Been Thinking About AI All Wrong"
        source: "https://www.foursightonline.com/blog/weve-been-thinking-about-ai-all-wrong"
        ---
        Last May, someone said:

        > We think of AI as a tool.

        For more information go to [https://atdconference.td.org](https://atdconference.td.org/)
        [See the platform](https://www.foursightonline.com/the-platform-old)
        """

        let parsed = try ObsidianMarkdownParser.parse(fileName: "clip.md", contents: markdown)

        XCTAssertEqual(parsed.title, "We’ve Been Thinking About AI All Wrong")
        XCTAssertTrue(parsed.text.contains("We think of AI as a tool."))
        XCTAssertTrue(parsed.text.contains("See the platform"))
        XCTAssertFalse(parsed.text.contains("---"))
        XCTAssertFalse(parsed.text.contains("https://"))
    }

    func testObsidianHeadingsPrebuildDeterministicListeningMap() throws {
        let markdown = """
        ---
        title: "5 ways HSAs can help with your retirement"
        source: "https://example.com/hsa"
        ---
        ### Key takeaways

        HSAs can support long-term medical savings.

        ### 1\\. Understand the triple tax advantage

        Contributions and qualified withdrawals receive favorable treatment.

        ## Tax-deferred growth versus HSAs

        This section compares account outcomes.

        ### 2\\. Earmark savings for health care

        Set aside assets for future costs.
        """

        let parsed = try ObsidianMarkdownParser.parse(fileName: "hsa.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-hsa"))

        XCTAssertEqual(parsed.headings.map(\.title), [
            "Key takeaways",
            "1. Understand the triple tax advantage",
            "Tax-deferred growth versus HSAs",
            "2. Earmark savings for health care"
        ])
        // One heading level makes the chapters: the lone `##` section stays inside the chapter before it.
        XCTAssertEqual(map.chapters.map(\.title), [
            "Key takeaways",
            "1. Understand the triple tax advantage",
            "2. Earmark savings for health care"
        ])
        XCTAssertEqual(map.chapters.first?.startChar, 0)
        XCTAssertEqual(map.chapters.last?.endChar, parsed.text.count)
        XCTAssertTrue(zip(map.chapters, map.chapters.dropFirst()).allSatisfy { $0.endChar == $1.startChar })
    }

    func testDeterministicListeningMapStopsAtUsefulShallowHeadingDepth() throws {
        let filler = Array(repeating: "detail", count: 60).joined(separator: " ")
        var markdown = "---\ntitle: Header Happy\n---\n"
        for major in 1...6 {
            markdown += "\n## Major \(major)\n"
            for minor in 1...5 {
                markdown += "\n### Minor \(major).\(minor)\n\n\(filler)\n"
            }
        }

        let parsed = try ObsidianMarkdownParser.parse(fileName: "header-happy.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-header-happy"))

        XCTAssertEqual(map.chapters.map(\.title), (1...6).map { "Major \($0)" })
        XCTAssertLessThanOrEqual(map.chapters.count, 12)
    }

    func testTitleOverrideKeepsFirstPastedHeadingAsAChapter() throws {
        let parsed = try ObsidianMarkdownParser.parse(
            fileName: "Manual Paste.md",
            contents: "## Opening\n\nFirst section.\n\n## Next\n\nSecond section.",
            titleOverride: "User-entered title"
        )
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-manual-paste"))

        XCTAssertEqual(parsed.title, "User-entered title")
        XCTAssertEqual(map.chapters.map(\.title), ["Opening", "Next"])
        XCTAssertEqual(map.chapters.first?.startChar, 0)
    }

    func testHSAStyleMapKeepsNumberedSectionsAndFoldsOtherLevelCallouts() throws {
        func words(_ count: Int) -> String {
            Array(repeating: "content", count: count).joined(separator: " ")
        }
        let markdown = """
        ---
        title: 5 ways HSAs can help with your retirement
        ---
        ### Key takeaways
        \(words(285))
        ### 1\\. Understand the triple tax advantage and how HSAs work
        \(words(423))
        ### 2\\. Earmark savings just for health care
        \(words(298))
        ### 3\\. Consider putting your HSA dollars to work by investing them
        \(words(346))
        ## Tax-deferred growth versus HSAs
        \(words(46))
        ### 4\\. Plan to use your HSA in retirement
        \(words(267))
        ### 5\\. Let HSAs play a role in your estate plan
        \(words(259))
        ### Plan ahead
        \(words(60))
        """

        let parsed = try ObsidianMarkdownParser.parse(fileName: "hsa.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-hsa-realistic"))

        XCTAssertEqual(map.chapters.map(\.title), [
            "Key takeaways",
            "1. Understand the triple tax advantage and how HSAs work",
            "2. Earmark savings just for health care",
            "3. Consider putting your HSA dollars to work by investing them",
            "4. Plan to use your HSA in retirement",
            "5. Let HSAs play a role in your estate plan",
            "Plan ahead"
        ])
    }

    func testDeterministicListeningMapNeverMergesHeaderExplosion() throws {
        let filler = Array(repeating: "brief", count: 20).joined(separator: " ")
        var markdown = "---\ntitle: Deep Outline\n---\n"
        for major in 1...2 {
            markdown += "\n## Group \(major)\n\n\(filler)\n"
            for minor in 1...12 {
                markdown += "\n### Detail \(major).\(minor)\n\n\(filler)\n"
            }
        }

        let parsed = try ObsidianMarkdownParser.parse(fileName: "deep-outline.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-deep-outline"))

        // Every `###` is a chapter: the author's headings are never merged to meet a cap.
        XCTAssertEqual(map.chapters.count, 24)
        XCTAssertTrue(zip(map.chapters, map.chapters.dropFirst()).allSatisfy { $0.endChar == $1.startChar })
        XCTAssertEqual(map.chapters.first?.startChar, 0)
        XCTAssertEqual(map.chapters.last?.endChar, parsed.text.count)
    }

    func testDeterministicListeningMapSplitsVeryLongSectionsAtNaturalBoundaries() throws {
        let paragraph = Array(repeating: "substantive", count: 300).joined(separator: " ") + "."
        let short = Array(repeating: "brief", count: 100).joined(separator: " ") + "."
        let markdown = "---\ntitle: Long Read\n---\n\n## Setup\n\n\(short)\n\n## Main argument\n\n"
            + Array(repeating: paragraph, count: 14).joined(separator: "\n\n")
            + "\n\n## Wrap-up\n\n\(short)"

        let parsed = try ObsidianMarkdownParser.parse(fileName: "long-read.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-long-read"))

        XCTAssertEqual(map.chapters.map(\.title), ["Setup", "Main argument", "Main argument — part 2", "Wrap-up"])
        XCTAssertEqual(map.chapters[1].endChar, map.chapters[2].startChar)
    }

    func testDeterministicListeningMapNumbersRepeatedSplitsWithoutRecursiveLabels() throws {
        let body = Array(repeating: "substantive", count: 11_000).joined(separator: " ")
        let short = Array(repeating: "brief", count: 100).joined(separator: " ")
        let markdown = "---\ntitle: Long Chapter\n---\n\n## Opening\n\n\(short)\n\n## Chapter Text\n\n\(body)\n\n## Closing\n\n\(short)"

        let parsed = try ObsidianMarkdownParser.parse(fileName: "long-chapter.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-long-chapter"))

        let parts = map.chapters.filter { $0.title.hasPrefix("Chapter Text") }
        XCTAssertEqual(parts.map(\.title), ["Chapter Text"] + (2...parts.count).map { "Chapter Text — part \($0)" })
        XCTAssertGreaterThan(parts.count, 3)
        XCTAssertEqual(map.chapters.first?.title, "Opening")
        XCTAssertEqual(map.chapters.last?.title, "Closing")
        XCTAssertFalse(map.chapters.contains { $0.title.contains("continued — continued") })
    }

    func testCapabilityGateRejectsUnsupportedCommand() throws {
        let profile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: ["remoteControl": ["display_snapshot", "send_transport_commands"]],
            forbiddenCapabilities: ["record_audio"]
        )
        let repo = InMemorySessionRepository(items: [
            "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        ])
        let engine = SessionEngine(profile: profile, repository: repo)
        XCTAssertThrowsError(try engine.startSession(itemId: "item-pill"))
    }

    func testCompactControlSnapshotExposesOnlyDelegatedCommands() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: [
                "timeline": ["chapter_timing"],
                "interjection": ["delegate_interjection_to_canonical_runtime"],
                "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands"]
            ],
            forbiddenCapabilities: ["record_audio", "summarize_interjections", "continue_discussion"]
        )
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")

        let dispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine)
        let snapshot = dispatcher.snapshot()

        XCTAssertEqual(snapshot.title, "Pill")
        XCTAssertEqual(snapshot.chapterTitle, "Opening")
        XCTAssertTrue(snapshot.compactSurfaceReady)
        XCTAssertTrue(snapshot.exposedCommands.contains(.play))
        XCTAssertTrue(snapshot.exposedCommands.contains(.pause))
        XCTAssertTrue(snapshot.exposedCommands.contains(.togglePlayPause))
        XCTAssertTrue(snapshot.exposedCommands.contains(.jumpToChapter))
        XCTAssertTrue(snapshot.exposedCommands.contains(.beginInterjection))
        XCTAssertFalse(snapshot.exposedCommands.contains(.finishInterjection))
        XCTAssertFalse(snapshot.availableCommands.contains(.play))
        XCTAssertTrue(snapshot.availableCommands.contains(.pause))
        XCTAssertTrue(snapshot.availableCommands.contains(.togglePlayPause))
        XCTAssertTrue(snapshot.availableCommands.contains(.skipBack))
        XCTAssertTrue(snapshot.availableCommands.contains(.skipForward))
        XCTAssertTrue(snapshot.availableCommands.contains(.jumpToChapter))
        XCTAssertTrue(snapshot.availableCommands.contains(.beginInterjection))
        XCTAssertFalse(snapshot.availableCommands.contains(.finishInterjection))
        XCTAssertEqual(snapshot.timeline.first?.kind, "overview")
        XCTAssertEqual(snapshot.timeline.first?.title, "Summary")
        XCTAssertEqual(snapshot.timeline.filter { $0.kind == "source_chapter" }.map(\.title), ["Opening", "Middle"])
    }

    func testEndDetachesCompactSessionAndKeepsItResumable() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: [
                "timeline": ["chapter_timing"],
                "interjection": ["delegate_interjection_to_canonical_runtime"],
                "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands"]
            ],
            forbiddenCapabilities: ["record_audio", "summarize_interjections", "continue_discussion"]
        )
        let engine = try compactControlEngine()
        let started = try engine.startSession(itemId: "item-pill")
        let sessionID = try XCTUnwrap(started.sessionId)
        _ = try engine.endSession()

        let snapshot = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine).snapshot()

        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertFalse(snapshot.compactSurfaceReady)
        XCTAssertTrue(snapshot.availableCommands.isEmpty)

        let restored = try engine.inspectSession(sessionId: sessionID)
        XCTAssertEqual(restored.phase, .itemPlayback)
        XCTAssertEqual(restored.status, .paused)
    }

    func testInspectNormalizesLegacyPrematureFinishedSession() throws {
        let item = Item(id: "item-legacy", title: "Legacy", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let session = Session(
            id: "session-legacy",
            itemId: item.id,
            status: "finished",
            phase: .finished,
            currentTargetType: .itemTextTTS,
            currentTargetId: item.id,
            position: Position(charOffset: 4),
            completionPercent: 25,
            playbackRate: 1
        )
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-offline",
            displayName: "Phone/Tablet Offline",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
        )
        let engine = SessionEngine(profile: profile, repository: repo, audio: RecordingAudioClient())

        let snapshot = try engine.inspectSession(sessionId: session.id)
        let saved = try XCTUnwrap(repo.sessions[session.id])

        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(saved.status, "in_progress")
        XCTAssertEqual(saved.completionPercent, 25)
        XCTAssertEqual(saved.position.charOffset, 4)
    }

    func testCompactControlKeepsDiscussionAvailableAfterSkippingToSourceEnd() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "watch-tethered",
            displayName: "Watch Tethered",
            capabilities: [
                "timeline": ["chapter_timing"],
                "ai": ["continue_discussion"],
                "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_ai_commands"]
            ],
            forbiddenCapabilities: ["record_audio", "continue_discussion"]
        )
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")
        _ = try engine.skipForward(unit: "chapter")
        _ = try engine.skipForward(unit: "chapter")

        let dispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine)
        let snapshot = dispatcher.snapshot()

        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertTrue(snapshot.compactSurfaceReady)
        XCTAssertTrue(snapshot.availableCommands.contains(.submitFollowup))
        XCTAssertNoThrow(try dispatcher.dispatch(.submitFollowup, followUpText: "Discuss this."))
    }

    func testCompactControlCommandsDelegateToCanonicalRuntime() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: [
                "timeline": ["chapter_timing"],
                "interjection": ["delegate_interjection_to_canonical_runtime"],
                "ai": ["summarize_interjections", "continue_discussion"],
                "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands", "send_ai_commands"]
            ]
        )
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")
        let dispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine)

        let paused = try dispatcher.dispatch(.togglePlayPause)
        XCTAssertTrue(paused.delegatedToCanonicalRuntime)
        XCTAssertEqual(paused.snapshot.status, .paused)

        let played = try dispatcher.dispatch(.play)
        XCTAssertTrue(played.delegatedToCanonicalRuntime)
        XCTAssertEqual(played.snapshot.status, .playing)

        let pausedAgain = try dispatcher.dispatch(.pause)
        XCTAssertTrue(pausedAgain.delegatedToCanonicalRuntime)
        XCTAssertEqual(pausedAgain.snapshot.status, .paused)

        _ = try dispatcher.dispatch(.play)

        let jumped = try dispatcher.dispatch(.jumpToChapter, chapterId: "ch-middle")
        XCTAssertTrue(jumped.delegatedToCanonicalRuntime)
        XCTAssertEqual(jumped.snapshot.chapterTitle, "Middle")

        let recording = try dispatcher.dispatch(.beginInterjection)
        XCTAssertTrue(recording.delegatedToCanonicalRuntime)
        XCTAssertEqual(recording.snapshot.phase, .recordingInterjection)
        XCTAssertFalse(recording.snapshot.exposedCommands.contains(.beginInterjection))
        XCTAssertTrue(recording.snapshot.exposedCommands.contains(.finishInterjection))

        let finished = try dispatcher.dispatch(.finishInterjection)
        XCTAssertTrue(finished.delegatedToCanonicalRuntime)
        XCTAssertEqual(finished.snapshot.phase, .itemPlayback)
        XCTAssertEqual(finished.snapshot.status, .playing)
        XCTAssertEqual(engine.currentSession?.itemId, "item-pill")
        XCTAssertTrue(finished.snapshot.timeline.contains { $0.kind == "interjection" })

        let summary = try dispatcher.dispatch(.generateInterjectionSummary)
        XCTAssertTrue(summary.delegatedToCanonicalRuntime)
        XCTAssertEqual(summary.snapshot.pendingAiJobKind, "interjection_summary")
        XCTAssertEqual(summary.snapshot.pendingAiJobStatus, "pending")
        XCTAssertTrue(summary.snapshot.timeline.contains { $0.kind == "interjection_summary" && $0.title == "Margin Summary 1" })

        let discussion = try dispatcher.dispatch(.submitFollowup, followUpText: "Can you respond to my interjection?")
        XCTAssertTrue(discussion.delegatedToCanonicalRuntime)
        XCTAssertEqual(discussion.snapshot.phase, .conversation)
        XCTAssertEqual(discussion.snapshot.lastUserTurnType, "user_response")
        XCTAssertEqual(discussion.snapshot.pendingAiJobKind, "assistant_response")
    }

    /// #1030: the headphone click never reached the app while a Margin recorded, because every transport
    /// command was unavailable then. Now Playing enables its commands from this flag.
    func testTransportCommandsEndTheMarginOnlyWhileOneRecordsAndTheSurfaceMayFinishIt() throws {
        func profile(sendsInterjectionCommands: Bool) -> RuntimeCapabilityProfile {
            var remoteControl = ["display_snapshot", "send_transport_commands"]
            if sendsInterjectionCommands { remoteControl.append("send_interjection_commands") }
            return RuntimeCapabilityProfile(
                id: "lock-screen-widget",
                displayName: "Lock Screen / Widget",
                capabilities: [
                    "timeline": ["chapter_timing"],
                    "interjection": ["delegate_interjection_to_canonical_runtime"],
                    "remoteControl": remoteControl
                ]
            )
        }
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")
        let dispatcher = CompactControlDispatcher(surfaceProfile: profile(sendsInterjectionCommands: true), canonicalRuntime: engine)
        let withoutFinish = CompactControlDispatcher(surfaceProfile: profile(sendsInterjectionCommands: false), canonicalRuntime: engine)

        XCTAssertFalse(dispatcher.snapshot().transportCommandsEndMargin, "playing: the click pauses")

        _ = try dispatcher.dispatch(.pause)
        XCTAssertFalse(dispatcher.snapshot().transportCommandsEndMargin, "paused: the click plays")

        _ = try dispatcher.dispatch(.beginInterjection)
        let recording = dispatcher.snapshot()
        XCTAssertTrue(recording.isRecording)
        XCTAssertTrue(recording.transportCommandsEndMargin, "recording: the click ends the Margin")
        XCTAssertFalse(recording.availableCommands.contains(.togglePlayPause),
                       "the dispatcher still refuses transport while recording; the app turns the command into a finish")
        XCTAssertFalse(withoutFinish.snapshot().transportCommandsEndMargin,
                       "a surface that can't finish a Margin must not claim the click")

        _ = try dispatcher.dispatch(.finishInterjection)
        XCTAssertFalse(dispatcher.snapshot().transportCommandsEndMargin, "saved: transport is transport again")
    }

    func testCompactLockScreenDelegatesMediaSeekAndPlaybackRate() throws {
        let canonicalProfile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone / Tablet Online",
            capabilities: [
                "playback": ["native_media"],
                "timeline": ["media_time", "playback_rate_observation"],
                "sync": ["canonical_persistence"]
            ]
        )
        let lockScreenProfile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: [
                "timeline": ["media_time", "chapter_timing", "playback_rate_observation"],
                "remoteControl": ["display_snapshot", "send_transport_commands"]
            ]
        )
        let mediaURL = "https://cdn.example.com/episode.mp3"
        let item = Item(
            id: "item-media",
            title: "Media",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: mediaURL, durationMs: 120_000)
        )
        let audio = RecordingAudioClient()
        audio.currentDurationMs = 120_000
        let engine = SessionEngine(
            profile: canonicalProfile,
            repository: InMemorySessionRepository(items: [item.id: item]),
            audio: audio
        )
        _ = try engine.startSession(itemId: item.id)
        let dispatcher = CompactControlDispatcher(surfaceProfile: lockScreenProfile, canonicalRuntime: engine)

        XCTAssertTrue(dispatcher.snapshot().availableCommands.contains(.seekToMediaTime))
        XCTAssertTrue(dispatcher.snapshot().availableCommands.contains(.setPlaybackRate))

        let sought = try dispatcher.dispatch(.seekToMediaTime, mediaTimeMs: 45_000)
        let rated = try dispatcher.dispatch(.setPlaybackRate, playbackRate: 1.5)

        XCTAssertTrue(sought.delegatedToCanonicalRuntime)
        XCTAssertEqual(sought.snapshot.currentMediaTimeMs, 45_000)
        XCTAssertEqual(audio.playedTargets.last, mediaURL)
        XCTAssertEqual(audio.seekRequests.last, 45_000)
        XCTAssertEqual(audio.playedOffsets.last, 0, "Remote seeking must not restart the active player")
        XCTAssertTrue(rated.delegatedToCanonicalRuntime)
        XCTAssertEqual(rated.snapshot.playbackRate, 1.5)
        XCTAssertEqual(audio.playbackRates.last, 1.5)
    }

    func testCompactControlRejectsUnsupportedSurfaceCommands() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "car-basic",
            displayName: "Basic Car",
            capabilities: ["remoteControl": ["display_snapshot", "send_transport_commands"]]
        )
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")
        let dispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine)

        XCTAssertThrowsError(try dispatcher.dispatch(.jumpToChapter, chapterId: "ch-middle")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("jumpToChapter"))
        }
        XCTAssertThrowsError(try dispatcher.dispatch(.beginInterjection)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("beginInterjection"))
        }
        XCTAssertThrowsError(try dispatcher.dispatch(.generateInterjectionSummary)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("generateInterjectionSummary"))
        }
        XCTAssertThrowsError(try dispatcher.dispatch(.submitFollowup, followUpText: "Discuss this.")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("submitFollowup"))
        }
    }

    func testCompactControlSummaryOnlyProfileDoesNotExposeDiscussion() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "local-summary-surface",
            displayName: "Local Summary Surface",
            capabilities: [
                "ai": ["summarize_interjections"],
                "remoteControl": ["display_snapshot", "send_ai_commands"]
            ],
            forbiddenCapabilities: ["continue_discussion", "provider_diagnostics"]
        )
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")
        let dispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine)

        XCTAssertTrue(dispatcher.snapshot().exposedCommands.contains(.generateInterjectionSummary))
        XCTAssertFalse(dispatcher.snapshot().exposedCommands.contains(.submitFollowup))
        XCTAssertThrowsError(try dispatcher.dispatch(.submitFollowup, followUpText: "Discuss this.")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("submitFollowup"))
        }
    }

    func testDirectAICommandsRejectProfilesWithoutAIOrDeferralCapability() throws {
        let profile = RuntimeCapabilityProfile(
            id: "watch-untethered",
            displayName: "Watch Untethered",
            capabilities: [
                "playback": ["realtime_tts"],
                "timeline": ["text_char_offsets"],
                "interjection": ["record_audio", "capture_text_anchor"],
                "sync": ["canonical_persistence"]
            ],
            forbiddenCapabilities: ["summarize_interjections", "continue_discussion", "defer_ai_jobs"]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/watch.m4a")

        XCTAssertThrowsError(try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: engine.currentSession?.id))) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("generateInterjectionSummary"))
        }
        XCTAssertThrowsError(try engine.submitFollowup(text: "Discuss this.")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("submitFollowup"))
        }
    }

    /// #943: the system card shows Play while a start is pending (its clock must not run), so a Play tap
    /// there cancels the load like the Pause it replaced, and Pause still works.
    func testPlayTapWhilePlaybackIsStartingCancelsThePendingStart() throws {
        for command in [CompactControlCommand.play, .pause] {
            let audio = RecordingAudioClient()
            audio.startStatus = .pending
            let engine = SessionEngine(
                profile: phonePlaybackProfile(),
                repository: InMemorySessionRepository(items: [
                    "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
                ]),
                audio: audio
            )
            _ = try engine.startSession(itemId: "item-pill")
            XCTAssertEqual(engine.snapshot.status, .starting)
            let surface = RuntimeCapabilityProfile(
                id: "lock-screen-widget",
                displayName: "Lock Screen / Widget",
                capabilities: [
                    "timeline": ["chapter_timing"],
                    "remoteControl": ["display_snapshot", "send_transport_commands"]
                ],
                forbiddenCapabilities: []
            )
            let dispatcher = CompactControlDispatcher(surfaceProfile: surface, canonicalRuntime: engine)

            let result = try dispatcher.dispatch(command)
            XCTAssertEqual(result.snapshot.status, .paused, "\(command)")
            XCTAssertEqual(engine.snapshot.status, .paused, "\(command)")
        }
    }

    /// #943: a podcast that rebuffers keeps engine status `.playing` while the system card shows Play
    /// (rate 0). That Play tap pauses instead of failing; with audio really playing, Play is still refused.
    func testPlayTapWhileAudioIsWaitingForTheNetworkPauses() throws {
        let surface = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: [
                "timeline": ["chapter_timing"],
                "remoteControl": ["display_snapshot", "send_transport_commands"]
            ],
            forbiddenCapabilities: []
        )
        func makeDispatcher(transport: PlaybackTransportState) throws -> (CompactControlDispatcher, SessionEngine) {
            let audio = RecordingAudioClient()
            let engine = SessionEngine(
                profile: phonePlaybackProfile(),
                repository: InMemorySessionRepository(items: [
                    "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
                ]),
                audio: audio
            )
            _ = try engine.startSession(itemId: "item-pill")
            XCTAssertEqual(engine.snapshot.status, .playing)
            audio.transportState = transport
            return (CompactControlDispatcher(surfaceProfile: surface, canonicalRuntime: engine), engine)
        }

        let (stalled, stalledEngine) = try makeDispatcher(transport: .waiting)
        let result = try stalled.dispatch(.play)
        XCTAssertEqual(result.snapshot.status, .paused)
        XCTAssertEqual(stalledEngine.snapshot.status, .paused)

        let (running, runningEngine) = try makeDispatcher(transport: .playing)
        XCTAssertThrowsError(try running.dispatch(.play))
        XCTAssertEqual(runningEngine.snapshot.status, .playing)
    }

    /// #943: delayed start, failed start and replacing the item never publish a running clock.
    func testSystemClockStaysStillThroughDelayedFailedAndReplacedStarts() throws {
        func rate(_ engine: SessionEngine) -> Double {
            SystemPlaybackPresentation(status: engine.snapshot.status, selectedRate: 1.25, isNarration: true).playbackRate
        }
        let repo = InMemorySessionRepository(items: [
            "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready"),
            "item-two": Item(id: "item-two", title: "Two", mediaType: "text", text: "Three. Four.", externalReference: nil, status: "ready")
        ])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: phonePlaybackProfile(), repository: repo, audio: audio)

        // Confirmed playback earns the selected rate.
        _ = try engine.startSession(itemId: "item-pill")
        XCTAssertEqual(engine.snapshot.status, .playing)
        XCTAssertEqual(rate(engine), 1.25)

        // Replacing the item with one whose audio is still loading must not carry the old running clock.
        audio.startStatus = .pending
        _ = try engine.startSession(itemId: "item-two")
        XCTAssertEqual(engine.snapshot.status, .starting)
        XCTAssertEqual(rate(engine), 0)

        // Delayed start confirms: the clock may run.
        audio.startStatus = .confirmed
        _ = try engine.syncPlaybackProgress()
        XCTAssertEqual(engine.snapshot.status, .playing)
        XCTAssertEqual(rate(engine), 1.25)

        // A start that fails never runs it.
        audio.startStatus = .failed("native_audio_failed")
        _ = try engine.startSession(itemId: "item-pill")
        XCTAssertEqual(engine.snapshot.status, .failed)
        XCTAssertEqual(rate(engine), 0)
    }

    func testPlaybackStartRemainsStartingUntilAudioConfirms() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
            ]),
            audio: audio
        )

        let starting = try engine.startSession(itemId: "item-pill")
        XCTAssertEqual(starting.status, .starting)

        audio.startStatus = .confirmed
        let confirmed = try engine.syncPlaybackProgress()
        XCTAssertEqual(confirmed.status, .playing)
    }

    func testSystemInitiatedPauseReconcilesPendingStartWithoutRepause() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-route-loss": Item(
                    id: "item-route-loss",
                    title: "Route loss",
                    mediaType: "text",
                    text: "Playback is still preparing.",
                    externalReference: nil,
                    status: "ready"
                )
            ]),
            audio: audio
        )

        XCTAssertEqual(try engine.startSession(itemId: "item-route-loss").status, .starting)
        let paused = try engine.reconcileSystemInitiatedPause()

        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(audio.pauseCount, 0, "The audio client already applied the system pause")
    }

    func testPendingResumeDoesNotPublishPausedBeforePlaybackConfirms() throws {
        let audio = RecordingAudioClient()
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
            ]),
            audio: audio
        )

        _ = try engine.startSession(itemId: "item-pill")
        _ = try engine.pause()
        audio.startStatus = .pending
        audio.transportState = .paused

        let starting = try engine.resumePlayback()
        let stillStarting = try engine.syncPlaybackProgress()

        XCTAssertEqual(starting.status, .starting)
        XCTAssertEqual(stillStarting.status, .starting)

        audio.startStatus = .confirmed
        audio.transportState = .playing
        let confirmed = try engine.syncPlaybackProgress()
        XCTAssertEqual(confirmed.status, .playing)
    }

    func testPendingPlaybackStartStillPublishesAndPersistsLiveTextPosition() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        let item = Item(
            id: "item-buffered",
            title: "Buffered",
            mediaType: "text",
            text: "One. Two. Three.",
            externalReference: nil,
            status: "ready"
        )
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: repository,
            audio: audio
        )

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 9

        let updated = try engine.syncPlaybackProgress()

        XCTAssertEqual(updated.status, .starting)
        XCTAssertEqual(updated.currentTextStart, 9)
        XCTAssertEqual(engine.currentSession?.position.charOffset, 9)
        XCTAssertGreaterThan(updated.sourceProgressPercent, 0)
    }

    func testPlaybackStartFailurePublishesFailedWithoutClaimingPlaying() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .failed("native_audio_failed")
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
            ]),
            audio: audio
        )

        let failed = try engine.startSession(itemId: "item-pill")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastFailure, "playback_start_failed:native_audio_failed")
    }

    func testRemoteChapterStartupRecreatesTransportOnceAndPreservesDestination() throws {
        for failsImmediately in [false, true] {
            for retrySucceeds in [false, true] {
                let audio = RecordingAudioClient()
                var clock = Date(timeIntervalSince1970: 100)
                let item = Item(
                    id: "remote-chapter", title: "Podcast", mediaType: "audio",
                    text: nil, externalReference: nil, status: "ready",
                    media: ItemMedia(sourceType: .remoteStream,
                                     url: "https://example.com/episode.mp3", durationMs: 600_000)
                )
                let repo = InMemorySessionRepository(items: [item.id: item])
                try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
                    id: "chapters", itemId: item.id, createdAt: clock,
                    timeline: TranscriptTimeline(segments: [
                        MediaTimelineSegment(id: "seg-grabby", startMs: 18_000, endMs: 600_000, startChar: 0, endChar: 6, text: "Aliens")
                    ], chapters: [
                        MediaTimelineChapter(id: "grabby", title: "Grabby aliens", startMs: 18_000, transcriptSegmentId: "seg-grabby")
                    ], durationMs: 600_000)
                ))
                let profile = RuntimeCapabilityProfile(
                    id: "phone", displayName: "Phone",
                    capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"],
                                   "timeline": ["media_time", "chapter_timing"]]
                )
                let engine = SessionEngine(profile: profile, repository: repo, audio: audio,
                                           playbackStartTimeout: 10, now: { clock })
                _ = try engine.startSession(itemId: item.id)
                audio.startStatus = .pending
                _ = try engine.jumpToChapter(chapterId: "grabby")
                let stops = audio.stopCount
                // A cold player can still report the previous position while loading.
                audio.currentMediaTimeValue = 0
                if failsImmediately { audio.startStatus = .failed("network_failure") }
                clock = clock.addingTimeInterval(11)
                let recovering = try engine.syncPlaybackProgress()
                XCTAssertEqual(recovering.status, .starting)
                XCTAssertEqual(audio.stopCount, stops + 1)
                XCTAssertEqual(audio.playedOffsets.last, 18_000)
                XCTAssertEqual(engine.currentSession?.position.chapterId, "grabby")
                XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 18_000)
                audio.startStatus = retrySucceeds ? .confirmed : .pending
                clock = clock.addingTimeInterval(11)
                let result = try engine.syncPlaybackProgress()
                XCTAssertEqual(result.status, retrySucceeds ? .playing : .failed)
                _ = try engine.syncPlaybackProgress()
                XCTAssertEqual(audio.stopCount, stops + 1, "Never retry indefinitely")
                XCTAssertEqual(try repo.loadItem(id: item.id).media?.url, item.media?.url)
            }
        }
    }

    func testRemoteStartupRecoveryDoesNotRestartPausedPlaybackOrLocalFiles() throws {
        for localFile in [false, true] {
            let audio = RecordingAudioClient()
            audio.startStatus = .pending
            var clock = Date(timeIntervalSince1970: 100)
            let item = Item(
                id: "podcast", title: "Podcast", mediaType: "audio", text: nil,
                externalReference: nil, status: "ready",
                media: ItemMedia(sourceType: .remoteStream,
                                 url: localFile ? "file:///tmp/episode.mp3" : "https://example.com/episode.mp3")
            )
            let engine = SessionEngine(
                profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone",
                                                   capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]),
                repository: InMemorySessionRepository(items: [item.id: item]), audio: audio,
                playbackStartTimeout: 10, now: { clock }
            )
            _ = try engine.startSession(itemId: item.id)
            if !localFile { _ = try engine.pause() }
            let stops = audio.stopCount
            clock = clock.addingTimeInterval(11)
            let result = try engine.syncPlaybackProgress()
            XCTAssertEqual(result.status, localFile ? .failed : .paused)
            XCTAssertEqual(audio.stopCount, stops)
            XCTAssertEqual(audio.playedTargets.count, 1)
        }
    }

    func testPlaybackStartPendingTimesOutAsFailure() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        var now = Date(timeIntervalSince1970: 100)
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
            ]),
            audio: audio,
            playbackStartTimeout: 10,
            now: { now }
        )

        let starting = try engine.startSession(itemId: "item-pill")
        XCTAssertEqual(starting.status, .starting)

        now = Date(timeIntervalSince1970: 109)
        let stillStarting = try engine.syncPlaybackProgress()
        XCTAssertEqual(stillStarting.status, .starting)

        now = Date(timeIntervalSince1970: 111)
        let failed = try engine.syncPlaybackProgress()
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastFailure, "playback_start_failed:playback_start_timeout")
    }

    func testSameTargetPlaybackRestartResetsPendingStartTimeout() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        var now = Date(timeIntervalSince1970: 100)
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
            ]),
            audio: audio,
            playbackStartTimeout: 10,
            now: { now }
        )

        _ = try engine.startSession(itemId: "item-pill")
        now = Date(timeIntervalSince1970: 109)
        let restarted = try engine.resumePlayback()
        XCTAssertEqual(restarted.status, .starting)

        now = Date(timeIntervalSince1970: 111)
        let stillStarting = try engine.syncPlaybackProgress()
        XCTAssertEqual(stillStarting.status, .starting)

        now = Date(timeIntervalSince1970: 120)
        let failed = try engine.syncPlaybackProgress()
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastFailure, "playback_start_failed:playback_start_timeout")
    }

    func testSameTargetPlaybackRestartCanConfirmAfterOriginalDeadline() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        var now = Date(timeIntervalSince1970: 100)
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
            ]),
            audio: audio,
            playbackStartTimeout: 10,
            now: { now }
        )

        _ = try engine.startSession(itemId: "item-pill")
        now = Date(timeIntervalSince1970: 109)
        _ = try engine.resumePlayback()

        now = Date(timeIntervalSince1970: 111)
        audio.startStatus = .confirmed
        let confirmed = try engine.syncPlaybackProgress()
        XCTAssertEqual(confirmed.status, .playing)
        XCTAssertNotEqual(confirmed.lastFailure, "playback_start_failed:playback_start_timeout")
    }

    func testSQLiteStorePersistsCoreRecords() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        try store.seed(item: item)
        let session = Session(id: "session-1", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        try store.saveSession(session)
        let interjection = Interjection(
            id: "ij-1",
            itemId: item.id,
            sessionId: session.id,
            targetType: .item,
            targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 3, anchorBefore: "One.", anchorAfter: "Two."),
            audioPath: "ij.m4a",
            audioStatus: "saved",
            transcriptionStatus: "pending",
            transcript: nil,
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        try store.saveInterjection(interjection)
        let job = AIJob(id: "job-1", kind: "assistant_response", itemId: item.id, sessionId: session.id, turnId: "turn-1", providerType: "fixture", model: "fixture", status: "retryable", attempts: 1, lastError: "offline", messages: ["hello"], playbackMode: "item_text_tts")
        try store.saveAIJob(job)
        let transcript = SourceTranscriptTimeline(
            id: "transcript-1",
            itemId: item.id,
            createdAt: Date(timeIntervalSince1970: 2),
            timeline: TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 1_000, text: "One.")],
                chapters: [MediaTimelineChapter(id: "ch-1", title: "One", startMs: 0, transcriptSegmentId: "seg-1")],
                durationMs: 1_000
            )
        )
        try store.saveTranscriptTimeline(transcript)

        XCTAssertEqual(try store.loadItem(id: item.id), item)
        XCTAssertEqual(try store.loadSession(id: session.id), session)
        XCTAssertEqual(try store.loadInterjections(sessionId: session.id).first?.audioPath, "ij.m4a")
        XCTAssertEqual(try store.loadAIJobs(sessionId: session.id).first?.status, "retryable")
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: item.id)?.id, transcript.id)
    }

    func testSQLiteStorePersistsWatchPackageEventsAndRequests() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let package = WatchAudioPackage(
            id: "watch-package-1",
            itemId: "item-audio",
            sessionId: "session-watch-1",
            createdAt: Date(timeIntervalSince1970: 1),
            item: WatchPackageItem(title: "Audio Item", mediaType: "text", externalReference: "icloud://item-audio"),
            audioAssets: [WatchPackageAudioAsset(audioAssetId: "asset-1", fileName: "asset.m4a", durationMs: 60_000)],
            transcript: WatchPackageTranscript(
                transcriptId: "transcript-1",
                segments: [MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, startChar: 0, endChar: 12, text: "Opening line.")]
            ),
            chapters: [MediaTimelineChapter(id: "ch-1", title: "Opening", startMs: 0, transcriptSegmentId: "seg-1")],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let event = WatchSyncEvent(
            id: "watch-event-1",
            watchPackageId: package.id,
            sessionId: package.sessionId,
            itemId: package.itemId,
            eventType: "interjection_recorded",
            createdAt: Date(timeIntervalSince1970: 2),
            payload: WatchSyncEventPayload(mediaTimeMs: 1_000, transcriptSegmentId: "seg-1", audioFileName: "watch-ij-1.m4a")
        )
        let request = WatchPackageRequestEvent(
            id: "request-1",
            itemId: package.itemId,
            packageId: package.id,
            requestType: .watchTransferRequested,
            createdAt: Date(timeIntervalSince1970: 3)
        )

        try store.saveWatchAudioPackage(package)
        try store.saveWatchSyncEvent(event)
        try store.markWatchSyncEventImported(id: event.id)
        try store.saveWatchPackageRequest(request)

        XCTAssertEqual(try store.loadWatchAudioPackage(id: package.id)?.id, package.id)
        XCTAssertEqual(try store.loadWatchSyncEvent(id: event.id)?.payload.audioFileName, "watch-ij-1.m4a")
        XCTAssertEqual(try store.loadWatchSyncEvents(sessionId: package.sessionId).map(\.id), [event.id])
        XCTAssertEqual(try store.hasImportedWatchSyncEvent(id: event.id), true)
        XCTAssertEqual(try store.loadWatchPackageRequests(itemId: package.itemId).map(\.requestType), [.watchTransferRequested])
        XCTAssertEqual(try store.loadWatchAudioPackages(itemId: package.itemId).map(\.id), [package.id])
    }

    func testMediaTimelineResolverUsesBoundaryToleranceAndFallback() throws {
        let timeline = MediaTimeline(
            segments: [
                MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, startChar: 0, endChar: 10, text: "First"),
                MediaTimelineSegment(id: "seg-2", startMs: 10_000, endMs: 20_000, startChar: 11, endChar: 20, text: "Second")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-1", title: "One", startMs: 0, transcriptSegmentId: "seg-1"),
                MediaTimelineChapter(id: "ch-2", title: "Two", startMs: 10_000, transcriptSegmentId: "seg-2")
            ],
            durationMs: 20_000
        )

        let boundary = MediaTimelineAnchorResolver.resolve(mediaTimeMs: 9_900, timeline: timeline, boundaryToleranceMs: 250)
        XCTAssertEqual(boundary.transcriptSegmentId, "seg-1")
        XCTAssertEqual(boundary.chapterId, "ch-1")

        let toleratedNext = MediaTimelineAnchorResolver.resolve(mediaTimeMs: 10_020, timeline: timeline, boundaryToleranceMs: 250)
        XCTAssertEqual(toleratedNext.transcriptSegmentId, "seg-2")
        XCTAssertEqual(toleratedNext.chapterId, "ch-2")

        let fallback = MediaTimelineAnchorResolver.resolve(mediaTimeMs: 40_000, timeline: timeline, boundaryToleranceMs: 250)
        XCTAssertEqual(fallback.transcriptSegmentId, "seg-2")
        XCTAssertEqual(fallback.mediaTimeMs, 40_000)
    }

    func testTextPlaybackPositionMapsInterjectionToSourceContext() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"]
            ]
        )
        let text = "First sentence. Second sentence."
        let item = Item(id: "item-text", title: "Text", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let transcriber = RecordingTranscriptionClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio, transcriber: transcriber)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = "First ".count
        let progress = try engine.syncPlaybackProgress()

        XCTAssertEqual(progress.currentTextStart, "First ".count)
        XCTAssertEqual(progress.currentAnchorConfidence, .textRange)

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/text.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.anchorType, .text)
        XCTAssertEqual(interjection.anchor.startChar, "First ".count)
        XCTAssertEqual(interjection.anchor.anchorBefore, "First")
        XCTAssertEqual(interjection.anchor.anchorAfter, "sentence. Second sentence.")
        XCTAssertEqual(transcriber.scheduledInterjectionIds, [interjection.id])
        XCTAssertEqual(engine.currentSession?.position.charOffset, 0, "rejoins at the start of its sentence (#776)")
        XCTAssertEqual(audio.playedOffsets.last, 0)
    }

    /// #624: spoken Margins were stamped one second after 1970 per Margin, which Readwise and the
    /// notes folder took as the real date. They now carry the engine's clock, like written Margins.
    func testSpokenMarginCarriesTheTimeItWasRecorded() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"]
            ]
        )
        let item = Item(id: "item-text", title: "Text", mediaType: "text", text: "First sentence.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let recordedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let engine = SessionEngine(
            profile: profile, repository: repo, audio: RecordingAudioClient(),
            transcriber: RecordingTranscriptionClient(), now: { recordedAt }
        )

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/text.m4a")

        let margin = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(margin.createdAt, recordedAt)
    }

    func testNativeTextInterjectionsResumeAtExactBoundaryWithoutAccumulatingDrift() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let text = "First sentence. Second sentence continues. Third sentence."
        let item = Item(id: "item-exact-resume", title: "Exact Resume", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        let capturedOffset = "First sentence. ".count

        _ = try engine.startSession(itemId: item.id)
        for index in 0..<10 {
            audio.currentOffset = capturedOffset
            _ = try engine.beginInterjection()
            _ = try engine.finishInterjection(audioRef: "interjections/exact-\(index).m4a")

            XCTAssertEqual(engine.currentSession?.position.charOffset, capturedOffset)
            XCTAssertEqual(audio.playedOffsets.last, capturedOffset)
        }
    }

    func testTextInterjectionAnchorUsesFullWordsAndFourSentenceShoulders() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"]
            ]
        )
        let text = "One introduces the subject. Two supplies history. Three adds evidence. Four discusses music and its role. Five tests the consequence. Six offers a counterpoint. Seven closes the argument."
        let item = Item(id: "item-mid-word", title: "Text", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        let musicStart = try XCTUnwrap(text.range(of: "music")).lowerBound
        audio.currentOffset = text.distance(from: text.startIndex, to: musicStart) + 1
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/text.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(
            interjection.anchor.anchorBefore,
            "One introduces the subject. Two supplies history. Three adds evidence. Four discusses music"
        )
        XCTAssertEqual(
            interjection.anchor.anchorAfter,
            "and its role. Five tests the consequence. Six offers a counterpoint. Seven closes the argument."
        )
        XCTAssertFalse(interjection.anchor.anchorBefore.hasPrefix("usic"))
    }

    func testMediaPlaybackPositionPublishesTimelineAnchorAndDuration() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-offline",
            displayName: "Phone/Tablet Offline",
            capabilities: [
                "sync": ["receive_prepared_packages", "canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let package = WatchAudioPackage(
            id: "package-media",
            itemId: "item-media",
            sessionId: "session-media",
            createdAt: Date(timeIntervalSince1970: 1),
            item: WatchPackageItem(title: "Media", mediaType: "transcript_backed_media", externalReference: "https://example.com/audio.mp3"),
            audioAssets: [WatchPackageAudioAsset(audioAssetId: "asset-media", fileName: "media.m4a", durationMs: 20_000)],
            transcript: WatchPackageTranscript(
                transcriptId: "transcript-media",
                segments: [
                    MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, startChar: 0, endChar: 14, text: "First segment."),
                    MediaTimelineSegment(id: "seg-2", startMs: 10_000, endMs: 20_000, startChar: 15, endChar: 30, text: "Second segment.")
                ]
            ),
            chapters: [
                MediaTimelineChapter(id: "ch-1", title: "Opening", startMs: 0, transcriptSegmentId: "seg-1"),
                MediaTimelineChapter(id: "ch-2", title: "Middle", startMs: 10_000, transcriptSegmentId: "seg-2")
            ],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(watchPackages: [package.id: package])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.loadWatchPackage(watchPackageId: package.id)
        _ = try engine.resumePlayback()
        audio.currentMediaTimeValue = 12_000
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.currentMediaTimeMs, 12_000)
        XCTAssertEqual(snapshot.currentPlaybackDurationMs, 20_000)
        XCTAssertEqual(snapshot.currentTranscriptSegmentId, "seg-2")
        XCTAssertEqual(snapshot.currentAnchorConfidence, .transcriptSpan)
        XCTAssertEqual(snapshot.chapterTitle, "Middle")
    }

    func testImportSourceLinkCreatesPlayableNativeAudioItem() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let request = LinkResolutionRequest(
            id: "link-request-episode",
            inputURL: "https://open.spotify.com/episode/example",
            sourceSurface: "share_sheet",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", title: "Example Show", role: "canonical_feed"),
            title: "Episode Title",
            showTitle: "Example Show",
            durationMs: 1_800_000,
            publishedAt: "2026-06-19",
            audioURL: "https://cdn.example.com/episode.mp3",
            confidence: 0.96
        )
        let resolver = StaticLinkResolutionClient(result: LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, provider: "spotify", role: "discovery"),
            selectedCandidate: candidate,
            candidates: [candidate]
        ))
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repo, linkResolver: resolver)

        let snapshot = try engine.importSourceLink(request)

        XCTAssertEqual(snapshot.linkResolutionStatus, LinkResolutionStatus.playable.rawValue)
        XCTAssertNil(snapshot.linkResolutionFailureReason)
        XCTAssertEqual(snapshot.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(snapshot.currentPlaybackDurationMs, 1_800_000)
        XCTAssertEqual(snapshot.currentAnchorConfidence, .providerMetadata)

        let itemId = try XCTUnwrap(snapshot.itemId)
        let item = try repo.loadItem(id: itemId)
        XCTAssertEqual(item.title, "Episode Title")
        XCTAssertEqual(item.mediaType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(item.externalReference, request.inputURL)
        XCTAssertEqual(item.sourceTitle, "Example Show")
        XCTAssertEqual(item.sourceURL, "https://feeds.example.com/show.xml")
        XCTAssertEqual(item.externalReferenceType, "url")
        XCTAssertEqual(item.media?.sourceType, .remoteStream)
        XCTAssertEqual(item.media?.url, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(item.media?.durationMs, 1_800_000)
    }

    func testLegacyItemWithoutCanonicalSourceURLStillDecodes() throws {
        let data = Data(#"{"id":"legacy","title":"Legacy","mediaType":"text","status":"ready"}"#.utf8)

        let item = try JSONDecoder().decode(Item.self, from: data)

        XCTAssertEqual(item.id, "legacy")
        XCTAssertNil(item.sourceURL)
        XCTAssertNil(item.documentStructure)
    }

    func testPDFDocumentStructureRoundTripsAndSurvivesBrowserImport() throws {
        let structure = PDFDocumentStructure(
            extractionEngine: .appleVision,
            analysisStatus: .complete,
            pageCount: 2,
            analyzedPageCount: 2,
            tables: [PDFDocumentTable(
                id: "pdf-table-page-2-1",
                pageIndex: 1,
                rowCount: 2,
                columnCount: 2,
                bounds: PDFNormalizedRect(x: 0.1, y: 0.2, width: 0.8, height: 0.3),
                cells: [PDFDocumentTableCell(
                    rowStart: 0,
                    rowEnd: 0,
                    columnStart: 0,
                    columnEnd: 0,
                    text: "Metric"
                )]
            )],
            pageTitles: [PDFDocumentPageTitle(pageIndex: 0, text: "Report")]
        )
        let encoded = try JSONEncoder().encode(structure)
        XCTAssertEqual(try JSONDecoder().decode(PDFDocumentStructure.self, from: encoded), structure)

        let profile = RuntimeCapabilityProfile(
            id: "browser-pdf-structure",
            displayName: "Browser PDF Structure",
            capabilities: ["sync": ["browser_session_handoff"]]
        )
        let repository = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repository)
        _ = try engine.importBrowserText(BrowserTextHandoff(
            itemId: "structured-pdf",
            captureMode: .markdownFile,
            source: BrowserTextSource(url: "file:///Report.pdf", title: "Report"),
            text: "# Report\n\nBody.",
            contentFormat: .markdown,
            documentStructure: structure
        ))

        XCTAssertEqual(try repository.loadItem(id: "structured-pdf").documentStructure, structure)
    }

    func testLegacyFeedEntryWithoutAudioURLStillDecodes() throws {
        let data = Data(#"{"id":"entry-legacy","subscriptionId":"source-1","canonicalURL":"https://example.com/episode","title":"Legacy episode","state":"unseen"}"#.utf8)

        let entry = try JSONDecoder().decode(FeedEntry.self, from: data)

        XCTAssertEqual(entry.id, "entry-legacy")
        XCTAssertNil(entry.audioURL)
    }

    func testPodcastPublisherChaptersUsePrecedencePersistAndNavigateWithoutTranscript() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "timeline": ["chapter_timing"]
            ]
        )
        let request = LinkResolutionRequest(
            id: "link-request-publisher-chapters",
            inputURL: "https://feeds.example.com/show.xml",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: request.inputURL, provider: "rss", role: "canonical_feed"),
            title: "Chaptered Episode",
            durationMs: 1_200_000,
            audioURL: "https://cdn.example.com/chaptered.mp3",
            publisherChapterCollections: [
                PublisherChapterCollection(source: .timestampedDescription, chapters: [
                    PublisherChapter(title: "Description Intro", startMs: 0),
                    PublisherChapter(title: "Description Topic", startMs: 300_000)
                ]),
                PublisherChapterCollection(source: .podloveSimpleChapters, chapters: [
                    PublisherChapter(title: "Podlove Intro", startMs: 0),
                    PublisherChapter(title: "Podlove Topic", startMs: 240_000)
                ]),
                PublisherChapterCollection(source: .podcasting20JSON, chapters: [
                    PublisherChapter(title: "Publisher Intro", startMs: 0),
                    PublisherChapter(title: "Publisher Topic", startMs: 600_000)
                ])
            ],
            confidence: 0.96
        )
        let resolver = StaticLinkResolutionClient(result: LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, provider: "rss", role: "canonical_feed"),
            selectedCandidate: candidate,
            candidates: [candidate]
        ))
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio, linkResolver: resolver)

        let imported = try engine.importSourceLink(request, startSessionWhenPlayable: true)
        let itemId = try XCTUnwrap(imported.itemId)
        let map = try XCTUnwrap(try repo.loadListeningMap(itemId: itemId))
        let timeline = try XCTUnwrap(try repo.loadTranscriptTimeline(itemId: itemId)?.timeline)

        XCTAssertEqual(map.id, "map-\(itemId)-publisher-podcasting_2_json")
        XCTAssertEqual(map.chapters.map(\.title), ["Publisher Intro", "Publisher Topic"])
        XCTAssertEqual(timeline.segments, [])
        XCTAssertEqual(timeline.chapters.map(\.startMs), [0, 600_000])

        let jumped = try engine.jumpToChapter(chapterId: map.chapters[1].id)
        XCTAssertEqual(jumped.currentMediaTimeMs, 600_000)
        XCTAssertEqual(jumped.chapterTitle, "Publisher Topic")
        XCTAssertEqual(audio.playedOffsets.last, 600_000)

        _ = try engine.attachPublisherChapters(
            itemId: itemId,
            collection: PublisherChapterCollection(source: .embeddedMedia, chapters: [
                PublisherChapter(title: "Lower Priority", startMs: 0)
            ])
        )
        XCTAssertEqual(try repo.loadListeningMap(itemId: itemId)?.id, map.id)
    }

    func testPublisherChapterSourcesUpgradeInDeclaredOrder() throws {
        let profile = RuntimeCapabilityProfile(
            id: "publisher-chapter-import",
            displayName: "Publisher Chapter Import",
            capabilities: ["sync": ["canonical_persistence"]]
        )
        let item = Item(
            id: "item-publisher-order",
            title: "Publisher Order",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/episode.mp3", durationMs: 900_000)
        )
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        for source in [
            PublisherChapterSource.timestampedDescription,
            .embeddedMedia,
            .podloveSimpleChapters,
            .podcasting20JSON
        ] {
            _ = try engine.attachPublisherChapters(
                itemId: item.id,
                collection: PublisherChapterCollection(source: source, chapters: [
                    PublisherChapter(title: source.rawValue, startMs: 0)
                ])
            )
            XCTAssertEqual(
                try repo.loadListeningMap(itemId: item.id)?.id,
                "map-\(item.id)-publisher-\(source.rawValue)"
            )
        }

        _ = try engine.attachPublisherChapters(
            itemId: item.id,
            collection: PublisherChapterCollection(source: .timestampedDescription, chapters: [
                PublisherChapter(title: "Must not replace JSON", startMs: 0)
            ])
        )
        XCTAssertEqual(
            try repo.loadListeningMap(itemId: item.id)?.id,
            "map-\(item.id)-publisher-\(PublisherChapterSource.podcasting20JSON.rawValue)"
        )
    }

    func testImportSourceLinkUnsupportedDoesNotCreateItem() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"]]
        )
        let request = LinkResolutionRequest(
            id: "link-request-unsupported",
            inputURL: "https://example.com/not-a-podcast",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository())

        let snapshot = try engine.importSourceLink(request)

        XCTAssertEqual(snapshot.linkResolutionStatus, LinkResolutionStatus.unsupported.rawValue)
        XCTAssertEqual(snapshot.linkResolutionFailureReason, "no_link_resolver_configured")
        XCTAssertNil(snapshot.itemId)
        XCTAssertNil(engine.currentItem)
    }

    func testImportSourceLinkRequiresCanonicalPersistence() throws {
        let profile = RuntimeCapabilityProfile(
            id: "widget",
            displayName: "Widget",
            capabilities: ["remoteControl": ["display_snapshot"]]
        )
        let request = LinkResolutionRequest(
            id: "link-request-denied",
            inputURL: "https://example.com/episode",
            sourceSurface: "share_sheet",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository())

        XCTAssertThrowsError(try engine.importSourceLink(request)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("importSourceLink"))
        }
    }

    func testImportedNativeAudioItemStartsMediaPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let request = LinkResolutionRequest(
            id: "link-request-start",
            inputURL: "https://example.com/episode",
            sourceSurface: "share_sheet",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", role: "canonical_feed"),
            title: "Playable Episode",
            durationMs: 600_000,
            audioURL: "https://cdn.example.com/playable.mp3",
            confidence: 0.9
        )
        let resolver = StaticLinkResolutionClient(result: LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, role: "discovery"),
            selectedCandidate: candidate,
            candidates: [candidate]
        ))
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository(), audio: audio, linkResolver: resolver)

        let snapshot = try engine.importSourceLink(request, startSessionWhenPlayable: true)

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(snapshot.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(snapshot.targetId, "https://cdn.example.com/playable.mp3")
        XCTAssertEqual(snapshot.currentMediaTimeMs, 0)
        XCTAssertEqual(snapshot.currentPlaybackDurationMs, 600_000)
        XCTAssertEqual(audio.playedTargets, ["https://cdn.example.com/playable.mp3"])
        XCTAssertEqual(audio.playedOffsets, [0])
        XCTAssertEqual(audio.preparedTexts, [])
        let mediaContext = try XCTUnwrap(audio.mediaContexts.compactMap { $0 }.last)
        XCTAssertEqual(mediaContext.itemId, snapshot.itemId)
        XCTAssertEqual(mediaContext.title, "Playable Episode")
        XCTAssertEqual(mediaContext.durationMs, 600_000)
        XCTAssertEqual(mediaContext.sourceType, .remoteStream)
    }

    func testTranscriptlessNativeAudioInterjectionAnchorsToMediaTime() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-source-audio",
            title: "Native Audio",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 123_000
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/media.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.anchorType, .media)
        XCTAssertEqual(interjection.anchor.mediaTimeMs, 123_000)
        XCTAssertNil(interjection.anchor.transcriptSegmentId)
        XCTAssertEqual(interjection.anchor.playbackRateObserved, 1)
        XCTAssertEqual(interjection.roughPercent, 13)

        let export = try engine.buildExport(options: ExportOptions(
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true
        ))
        let markdown = SessionExportMarkdownRenderer.render(export)
        XCTAssertEqual(export.item.mediaSourceType, AudioSourceType.remoteStream.rawValue)
        XCTAssertEqual(export.interjections.first?.mediaTimeMs, 123_000)
        XCTAssertTrue(markdown.contains("2:03 — Listener interjection"))
        XCTAssertTrue(markdown.contains("Source Type: remote_stream"))
    }

    /// Paid feeds carry a subscriber secret in their links (#168); exports leave the device.
    func testMarginMarkdownAndJSONExportsCarryNoPrivateFeedSecret() throws {
        let secret = "pAtReOnSeCrEt7f3a9c2e41b8d6"
        let enclosureURL = "https://c10.patreonusercontent.com/4/patreon-media/p/post/98765/a1/episode.mp3?token-time=1790000000&token-hash=\(secret)"
        let item = Item(
            id: "item-private-feed",
            title: "Episode 12: The Private One",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://www.patreon.com/rss/someshow?auth=\(secret)",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: enclosureURL, durationMs: 3_600_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone-tablet-online",
                displayName: "Phone/Tablet Online",
                capabilities: [
                    "sync": ["canonical_persistence"],
                    "playback": ["native_media"],
                    "interjection": ["record_audio", "capture_media_anchor"]
                ]
            ),
            repository: repo,
            audio: audio
        )
        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 600_000
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/private.m4a")
        let noteId = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first?.id)

        let export = try engine.buildExport(options: ExportOptions(
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true
        ))
        let single = try engine.buildExport(options: ExportOptions(
            sessionId: engine.currentSession?.id,
            includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false,
            scope: "selected_interjections", interjectionIds: [noteId]
        ))
        let outputs = [
            SessionExportMarkdownRenderer.render(export),
            SessionExportMarkdownRenderer.renderMargin(single, createdAt: Date(timeIntervalSince1970: 1_777_000_000)),
            String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        ]
        XCTAssertFalse(outputs[1].isEmpty)
        for output in outputs {
            XCTAssertFalse(output.contains(secret), output)
        }
    }

    func testNativeAudioInterjectionFreezesClockBeforeSavingAndRejoinsJustBeforeTheAnchor() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-exact-media-anchor",
            title: "Exact Anchor",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 123_000
        audio.mediaTimeOnPause = 124_250

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/exact-anchor.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.mediaTimeMs, 124_250)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 121_250, "rejoins 3 s earlier (#776)")
        XCTAssertEqual(audio.playedOffsets.last, 121_250)
    }

    func testRecordingInterjectionRejectsTimelineNavigationAndPreservesMediaAnchor() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media", "assistant_turn_tts"],
                "timeline": ["chapter_timing"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-recording-navigation-guard",
            title: "Guarded Podcast",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/guarded",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: "https://cdn.example.com/guarded.mp3",
                durationMs: 900_000
            )
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 124_250
        let recording = try engine.beginInterjection()
        let playCountWhileRecording = audio.playedTargets.count

        for _ in 0..<3 {
            XCTAssertThrowsError(try engine.playSourceFromBeginning()) { error in
                XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("playSourceFromBeginning"))
            }
        }
        XCTAssertThrowsError(try engine.jumpToChapter(chapterId: "chapter-ignored")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("jumpToChapter"))
        }
        XCTAssertThrowsError(try engine.playTurn(turnId: "turn-ignored")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("playTurn"))
        }
        XCTAssertThrowsError(try engine.jumpToTurnChapter(turnId: "turn-ignored", chapterId: "chapter-ignored")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("jumpToTurnChapter"))
        }
        XCTAssertThrowsError(try engine.seekMedia(toMediaTimeMs: 0)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("seekMedia"))
        }
        XCTAssertThrowsError(try engine.togglePlayPause()) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("togglePlayPause"))
        }
        XCTAssertThrowsError(try engine.resumePlayback()) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("resumePlayback"))
        }
        XCTAssertThrowsError(try engine.stopPlayback()) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("stopPlayback"))
        }

        XCTAssertEqual(recording.status, .recording)
        XCTAssertEqual(engine.snapshot.status, .recording)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 124_250)
        XCTAssertEqual(audio.currentMediaTimeValue, 124_250)
        XCTAssertEqual(audio.playedTargets.count, playCountWhileRecording)

        let resumed = try engine.finishInterjection(audioRef: "interjections/guarded.m4a")
        let sessionID = try XCTUnwrap(engine.currentSession?.id)
        let saved = try XCTUnwrap(try repo.loadInterjections(sessionId: sessionID).first)
        XCTAssertEqual(saved.anchor.mediaTimeMs, 124_250)
        XCTAssertEqual(resumed.status, .playing)
        XCTAssertEqual(resumed.currentMediaTimeMs, 121_250, "rejoins 3 s earlier (#776)")
        XCTAssertEqual(audio.playedOffsets.last, 121_250)
    }

    func testInspectSessionRepairsMediaPercentagesFromDurableTimestamps() throws {
        let item = Item(
            id: "item-source-repair",
            title: "Repairable Podcast",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        )
        let session = Session(
            id: "session-source-repair",
            itemId: item.id,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia,
            currentTargetId: item.media?.url ?? item.id,
            position: Position(mediaTimeMs: 450_000),
            completionPercent: 0,
            playbackRate: 1
        )
        let interjection = Interjection(
            id: "ij-source-repair",
            itemId: item.id,
            sessionId: session.id,
            targetType: .item,
            targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 0,
            anchor: Anchor(
                anchorType: .media,
                startChar: 0,
                endChar: 0,
                anchorBefore: "",
                anchorAfter: "",
                mediaTimeMs: 225_000
            ),
            audioPath: "interjections/repair.m4a",
            audioStatus: "saved",
            transcriptionStatus: "complete",
            transcript: "Repair this position.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        let repo = InMemorySessionRepository(
            items: [item.id: item],
            sessions: [session.id: session],
            interjections: [interjection.id: interjection]
        )
        let engine = SessionEngine(profile: phonePlaybackProfile(), repository: repo, audio: RecordingAudioClient())

        let snapshot = try engine.inspectSession(sessionId: session.id)

        XCTAssertEqual(snapshot.sourceProgressPercent, 50)
        XCTAssertEqual(repo.sessions[session.id]?.completionPercent, 50)
        XCTAssertEqual(repo.interjections[interjection.id]?.roughPercent, 25)
    }

    func testStableMediaProgressDoesNotRepeatNotePercentageRepair() throws {
        for noteCount in [0, 100, 1000] {
            let item = Item(id: "measured-podcast", title: "Measured", mediaType: "audio", text: nil, externalReference: nil,
                status: "ready", media: ItemMedia(sourceType: .remoteStream,
                    url: "https://example.com/audio", durationMs: 900_000))
            let repo = CountingInterjectionRepository(items: [item.id: item])
            let audio = RecordingAudioClient()
            audio.currentDurationMs = 900_000
            let engine = SessionEngine(profile: phonePlaybackProfile(), repository: repo, audio: audio)
            _ = try engine.startSession(itemId: item.id)
            let sessionId = try XCTUnwrap(engine.currentSession?.id)
            for index in 0..<noteCount {
                try repo.saveInterjection(Interjection(id: "note-\(index)", itemId: item.id,
                    sessionId: sessionId, targetType: .item, targetId: item.id, createdAt: Date(),
                    roughPercent: 0, anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0,
                        anchorBefore: "", anchorAfter: "", mediaTimeMs: 225_000),
                    audioPath: nil, audioStatus: "discarded", transcriptionStatus: "transcribed",
                    transcript: "Saved note", cleanedTranscript: nil, displayText: nil, status: "active"))
            }
            _ = try engine.inspectSession(sessionId: sessionId)
            repo.noteLoads = 0
            for tick in 1...20 {
                audio.currentMediaTimeValue = tick * 500
                _ = try engine.syncPlaybackProgress()
            }
            // Publication reads note counts once; percentage repair must not add a second scan.
            XCTAssertEqual(repo.noteLoads, 20, "Repeated repair with \(noteCount) notes")
            XCTAssertTrue(repo.interjections.values.allSatisfy { $0.roughPercent == 25 })
            audio.currentDurationMs = 450_000
            _ = try engine.syncPlaybackProgress()
            XCTAssertEqual(repo.noteLoads, 22, "Changed duration must trigger one repair")
            XCTAssertTrue(repo.interjections.values.allSatisfy { $0.roughPercent == 50 })
        }
    }

    func testObservedPlayerDurationIsPersistedAndUsedForMediaInterjectionPercent() throws {
        let item = Item(
            id: "item-source-observed-duration",
            title: "Podcast Without Feed Duration",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3")
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: phonePlaybackProfile(), repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 225_000
        audio.currentDurationMs = 900_000
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/observed-duration.m4a")

        let saved = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(saved.anchor.mediaTimeMs, 225_000)
        XCTAssertEqual(saved.roughPercent, 25)
        XCTAssertEqual(repo.items[item.id]?.media?.durationMs, 900_000)
    }

    func testObservedPlayerDurationCorrectsUnderestimatedFeedDurationAndPercentages() throws {
        let item = Item(
            id: "item-source-short-feed-duration",
            title: "Podcast With Short Feed Duration",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: "https://cdn.example.com/episode.mp3",
                durationMs: 600_000
            )
        )
        let audio = RecordingAudioClient()
        audio.currentDurationMs = 900_000
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: phonePlaybackProfile(), repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 600_000
        let corrected = try engine.syncPlaybackProgress()

        XCTAssertEqual(corrected.currentPlaybackDurationMs, 900_000)
        XCTAssertEqual(corrected.currentPlaybackProgressPercent, 66)
        XCTAssertEqual(repo.items[item.id]?.media?.durationMs, 900_000)
    }

    func testTwentyFiveMinuteMediaPositionSurvivesInterjectionDismissAndResume() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-long-audio",
            title: "Long Audio",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/long-episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: "https://cdn.example.com/long-episode.mp3",
                durationMs: 3_600_000
            )
        )
        let audio = RecordingAudioClient()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)

        let started = try engine.startSession(itemId: item.id)
        let sessionID = try XCTUnwrap(started.sessionId)
        audio.currentMediaTimeValue = 1_500_000
        _ = try engine.pause()
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/at-25-minutes.m4a")

        let detached = try engine.endSession()
        let persisted = try XCTUnwrap(try repository.loadSession(id: sessionID))
        let interjection = try XCTUnwrap(try repository.loadInterjections(sessionId: sessionID).first)

        XCTAssertEqual(detached.status, .idle)
        XCTAssertNil(detached.sessionId)
        XCTAssertEqual(persisted.position.mediaTimeMs, 1_497_000, "rejoined 3 s earlier (#776)")
        XCTAssertEqual(persisted.status, "in_progress")
        XCTAssertEqual(interjection.anchor.mediaTimeMs, 1_500_000)

        let restored = try engine.inspectSession(sessionId: sessionID)
        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.currentMediaTimeMs, 1_497_000)

        let resumed = try engine.resumePlayback()
        XCTAssertEqual(resumed.status, .playing)
        XCTAssertEqual(audio.playedOffsets.last, 1_497_000)
    }

    func testRepeatedMediaSeekInterjectionResumeCyclesKeepOneAdvancingClock() throws {
        let durationMs = 1_800_000
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-repeated-media-cycles",
            title: "Repeated Media Cycles",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/repeated-cycles",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: "https://cdn.example.com/repeated-cycles.mp3",
                durationMs: durationMs
            )
        )
        let audio = RecordingAudioClient()
        audio.currentDurationMs = durationMs
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        for index in 0..<10 {
            let requested = 120_000 + (index * 120_000)
            _ = try engine.seekMedia(toMediaTimeMs: requested)

            let beforeInterjection = requested + 30_000
            audio.currentMediaTimeValue = beforeInterjection
            let advanced = try engine.syncPlaybackProgress()
            XCTAssertEqual(advanced.currentMediaTimeMs, beforeInterjection)

            let recording = try engine.beginInterjection()
            XCTAssertEqual(recording.currentMediaTimeMs, beforeInterjection)
            let resumed = try engine.finishInterjection(audioRef: "interjections/cycle-\(index).m4a")
            XCTAssertEqual(resumed.currentMediaTimeMs, beforeInterjection - MarginRejoin.mediaStepBackMs)
            XCTAssertEqual(audio.playedOffsets.last, beforeInterjection - MarginRejoin.mediaStepBackMs)

            audio.currentMediaTimeValue = beforeInterjection + 12_000
            let postResume = try engine.syncPlaybackProgress()
            XCTAssertEqual(postResume.currentMediaTimeMs, beforeInterjection + 12_000)
            XCTAssertEqual(postResume.currentPlaybackDurationMs, durationMs)
        }

        audio.currentMediaTimeValue = durationMs - 120_000
        let nearEnd = try engine.syncPlaybackProgress()
        XCTAssertEqual(nearEnd.currentMediaTimeMs, durationMs - 120_000)
        let observedDurationMs = try XCTUnwrap(nearEnd.currentPlaybackDurationMs)
        let observedMediaTimeMs = try XCTUnwrap(nearEnd.currentMediaTimeMs)
        XCTAssertEqual(observedDurationMs - observedMediaTimeMs, 120_000)
    }

    func testSourceWindowContextUpdatesMediaInterjectionAnchorWithoutChangingNoteTranscript() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-source-window",
            title: "Windowed Native Audio",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 123_000
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/media-window.m4a")
        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        let window = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "window-seg-1", startMs: 90_000, endMs: 122_000, text: "Context before the note."),
                MediaTimelineSegment(id: "window-seg-2", startMs: 122_000, endMs: 150_000, text: "Context at the note."),
                MediaTimelineSegment(id: "window-seg-3", startMs: 150_000, endMs: 180_000, text: "Context after the note.")
            ],
            chapters: [],
            durationMs: 900_000
        )

        _ = try engine.sourceWindowContextCompleted(interjectionId: interjection.id, timeline: window)

        let updated = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(updated.anchor.anchorType, .transcript)
        XCTAssertEqual(updated.anchor.mediaTimeMs, 123_000)
        XCTAssertEqual(updated.anchor.anchorBefore, "Context before the note. Context at the note.")
        XCTAssertEqual(updated.anchor.anchorAfter, "Context after the note.")
        XCTAssertNotNil(updated.anchor.transcriptSegmentId)
        XCTAssertNil(updated.transcript)
        XCTAssertEqual(updated.transcriptionStatus, "pending")

        let export = try engine.buildExport(options: ExportOptions(
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true
        ))
        let markdown = SessionExportMarkdownRenderer.render(export)
        XCTAssertTrue(markdown.contains("Context before the note. Context at the note."))
        XCTAssertTrue(markdown.contains("Context after the note."))
    }

    func testPodcastInterjectionArmsBoundedPostResumeSampleBeforePlaybackRestarts() throws {
        let profile = RuntimeCapabilityProfile(
            id: "post-resume-anchor",
            displayName: "Post-resume podcast anchor",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "episode-post-resume",
            title: "Post-resume episode",
            mediaType: "audio",
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: "https://cdn.example.com/episode.mp3",
                durationMs: 900_000
            )
        )
        let audio = RecordingAudioClient()
        audio.acceptsPostResumeSamples = true
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 321_000
        _ = try engine.beginInterjection()
        audio.eventLog.removeAll()
        _ = try engine.finishInterjection(audioRef: "interjections/post-resume.m4a")

        let request = try XCTUnwrap(audio.postResumeSampleRequests.first)
        XCTAssertEqual(request.itemId, item.id)
        XCTAssertEqual(request.anchorMediaTimeMs, 321_000)
        XCTAssertEqual(request.targetDurationMs, SparseFingerprintSchedule.targetDurationMs)
        XCTAssertEqual(audio.eventLog, ["arm_post_resume_sample", "play_media"])
        let interjection = try XCTUnwrap(
            try repository.loadInterjections(sessionId: request.sessionId).first
        )
        XCTAssertEqual(interjection.id, request.interjectionId)
        XCTAssertEqual(interjection.podcastAnchorEvidenceCaptureStatus, .pendingPostResumeSample)
        XCTAssertNil(interjection.podcastAnchorEvidenceFailureReason)
    }

    func testMissedPreWindowIsRecordedAndSurvivesALaterFailure() throws {
        let profile = RuntimeCapabilityProfile(
            id: "post-resume-anchor",
            displayName: "Post-resume podcast anchor",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "episode-pre-missed",
            title: "Pre-window missed",
            mediaType: "audio",
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        )
        let audio = RecordingAudioClient()
        audio.acceptsPostResumeSamples = true
        audio.acceptsPreInterjectionSamples = false
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 321_000
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/pre-missed.m4a")
        let request = try XCTUnwrap(audio.postResumeSampleRequests.first)
        var interjection = try XCTUnwrap(try repository.loadInterjections(sessionId: request.sessionId).first)
        XCTAssertEqual(interjection.podcastAnchorEvidenceCaptureStatus, .pendingPostResumeSample)
        XCTAssertEqual(interjection.podcastAnchorEvidenceFailureReason, "pre_window_not_captured")

        _ = try engine.podcastAnchorEvidenceFailed(
            interjectionId: interjection.id,
            sessionId: request.sessionId,
            reason: "post_resume_timeout"
        )
        interjection = try XCTUnwrap(try repository.loadInterjections(sessionId: request.sessionId).first)
        XCTAssertEqual(interjection.podcastAnchorEvidenceCaptureStatus, .unavailable)
        XCTAssertEqual(interjection.podcastAnchorEvidenceFailureReason, "pre_window_not_captured | post_resume_timeout")
    }

    func testSourceAnchorContextSlicesOneWholeEpisodeSegmentByMediaTime() throws {
        let words = (0..<600).map { String(format: "token%03d", $0) }
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(
                    id: "whole-episode",
                    startMs: 0,
                    endMs: 600_000,
                    startChar: 0,
                    endChar: words.joined(separator: " ").count,
                    text: words.joined(separator: " ")
                )
            ],
            chapters: [],
            durationMs: 600_000
        )

        let context = try XCTUnwrap(SourceAnchorContextResolver.resolve(
            mediaTimeMs: 300_000,
            timeline: timeline
        ))

        XCTAssertTrue(context.anchorBefore.contains("token210"))
        XCTAssertTrue(context.anchorBefore.contains("token299"))
        XCTAssertFalse(context.anchorBefore.contains("token050"))
        XCTAssertTrue(context.anchorAfter.contains("token300"))
        XCTAssertTrue(context.anchorAfter.contains("token419"))
        XCTAssertFalse(context.anchorAfter.contains("token550"))
        XCTAssertLessThan(context.anchorBefore.count + context.anchorAfter.count, words.joined(separator: " ").count / 2)
    }

    func testNativeAudioExportReResolvesLegacyOversizedAnchorsFromStoredTimeline() throws {
        let item = Item(
            id: "item-legacy-anchor",
            title: "Legacy Anchor Podcast",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 600_000)
        )
        let session = Session(
            id: "session-legacy-anchor",
            itemId: item.id,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia,
            currentTargetId: item.id,
            position: Position(mediaTimeMs: 300_000),
            completionPercent: 50,
            playbackRate: 1
        )
        let completeTranscript = (0..<600).map { String(format: "word%03d", $0) }.joined(separator: " ")
        let interjection = Interjection(
            id: "ij-legacy-anchor",
            itemId: item.id,
            sessionId: session.id,
            targetType: .item,
            targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 50,
            anchor: Anchor(
                anchorType: .transcript,
                startChar: 0,
                endChar: completeTranscript.count,
                anchorBefore: completeTranscript,
                anchorAfter: completeTranscript,
                mediaTimeMs: 300_000,
                transcriptSegmentId: "whole-episode"
            ),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "This is where I question the speaker's assumption.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        let transcript = SourceTranscriptTimeline(
            id: "transcript-legacy-anchor",
            itemId: item.id,
            createdAt: Date(timeIntervalSince1970: 1),
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(
                        id: "whole-episode",
                        startMs: 0,
                        endMs: 600_000,
                        startChar: 0,
                        endChar: completeTranscript.count,
                        text: completeTranscript
                    )
                ],
                chapters: [],
                durationMs: 600_000
            )
        )
        let repo = InMemorySessionRepository(
            items: [item.id: item],
            sessions: [session.id: session],
            interjections: [interjection.id: interjection],
            transcriptTimelines: [item.id: transcript]
        )
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone-tablet-online",
                displayName: "Phone/Tablet Online",
                capabilities: ["sync": ["canonical_persistence"]]
            ),
            repository: repo
        )

        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true
        ))
        let exported = try XCTUnwrap(export.interjections.first)

        XCTAssertLessThan(exported.anchorBefore.count + exported.anchorAfter.count, completeTranscript.count / 2)
        XCTAssertFalse(exported.anchorBefore.contains("word050"))
        XCTAssertFalse(exported.anchorAfter.contains("word550"))
        XCTAssertEqual(try repo.loadInterjections(sessionId: session.id).first?.anchor.anchorBefore, completeTranscript)
    }

    func testMarkdownEmbedsNearbyInterjectionsInOneSharedSourcePassage() throws {
        let first = ExportInterjection(
            id: "ij-1",
            sessionId: "session",
            targetType: InterjectionTargetType.item.rawValue,
            targetId: "item",
            roughPercent: 20,
            anchorBefore: "Lead-in source context.",
            anchorAfter: "one two three four five six source after both notes",
            mediaTimeMs: 120_000,
            transcriptionStatus: "transcribed",
            transcript: "First listener thought.",
            audioPath: nil
        )
        let second = ExportInterjection(
            id: "ij-2",
            sessionId: "session",
            targetType: InterjectionTargetType.item.rawValue,
            targetId: "item",
            roughPercent: 21,
            anchorBefore: "Earlier context one two three four five six",
            anchorAfter: "Source after the second note.",
            mediaTimeMs: 130_000,
            transcriptionStatus: "transcribed",
            transcript: "Second listener thought.",
            audioPath: nil
        )
        let export = SessionExport(
            item: ExportItem(id: "item", title: "Source", includedFullText: false),
            session: ExportSession(id: "session", status: "in_progress", completionPercent: 21),
            listeningMap: nil,
            turns: [],
            timeline: [
                ExportTimelineEntry(type: "interjection", interjectionId: first.id, targetType: first.targetType),
                ExportTimelineEntry(type: "interjection", interjectionId: second.id, targetType: second.targetType)
            ],
            interjections: [first, second]
        )

        let markdown = SessionExportMarkdownRenderer.render(export)

        XCTAssertTrue(markdown.contains("Source Context and Listener Interjections"))
        XCTAssertTrue(markdown.contains("2:00 — Listener interjection"))
        XCTAssertTrue(markdown.contains("2:10 — Listener interjection"))
        XCTAssertEqual(markdown.components(separatedBy: "one two three four five six").count - 1, 1)
        XCTAssertLessThan(
            markdown.range(of: "First listener thought.")!.lowerBound,
            markdown.range(of: "Second listener thought.")!.lowerBound
        )
    }

    func testMarkdownPreservesContextBetweenTextInterjectionsWithoutMediaTimestamps() throws {
        let first = ExportInterjection(
            id: "ij-text-1",
            sessionId: "session",
            targetType: InterjectionTargetType.item.rawValue,
            targetId: "item",
            roughPercent: 20,
            anchorBefore: "Context before the first note.",
            anchorAfter: "Context after the first note.",
            mediaTimeMs: nil,
            transcriptionStatus: "transcribed",
            transcript: "First listener thought.",
            audioPath: nil
        )
        let second = ExportInterjection(
            id: "ij-text-2",
            sessionId: "session",
            targetType: InterjectionTargetType.item.rawValue,
            targetId: "item",
            roughPercent: 60,
            anchorBefore: "Context before the second note.",
            anchorAfter: "Context after the second note.",
            mediaTimeMs: nil,
            transcriptionStatus: "transcribed",
            transcript: "Second listener thought.",
            audioPath: nil
        )
        let export = SessionExport(
            item: ExportItem(id: "item", title: "Text Source", includedFullText: false),
            session: ExportSession(id: "session", status: "in_progress", completionPercent: 60),
            listeningMap: nil,
            turns: [],
            timeline: [
                ExportTimelineEntry(type: "interjection", interjectionId: first.id, targetType: first.targetType),
                ExportTimelineEntry(type: "interjection", interjectionId: second.id, targetType: second.targetType)
            ],
            interjections: [first, second]
        )

        let markdown = SessionExportMarkdownRenderer.render(export)

        XCTAssertTrue(markdown.contains("Context before the first note."))
        XCTAssertTrue(markdown.contains("Context after the first note."))
        XCTAssertTrue(markdown.contains("Context before the second note."))
        XCTAssertTrue(markdown.contains("Context after the second note."))
        XCTAssertLessThan(
            markdown.range(of: "First listener thought.")!.lowerBound,
            markdown.range(of: "Context after the first note.")!.lowerBound
        )
        XCTAssertLessThan(
            markdown.range(of: "Context before the second note.")!.lowerBound,
            markdown.range(of: "Second listener thought.")!.lowerBound
        )
    }

    func testNativeAudioSkipWorksWithoutWatchPackage() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let item = Item(
            id: "item-native-skip",
            title: "Native Skip",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 90_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 30_000
        let forward = try engine.skipForward(unit: "time_15s")
        XCTAssertEqual(forward.currentMediaTimeMs, 45_000)
        XCTAssertEqual(audio.seekRequests.last, 45_000)

        audio.currentMediaTimeValue = 45_000
        let back = try engine.skipBack(unit: "time_15s")
        XCTAssertEqual(back.currentMediaTimeMs, 30_000)
        XCTAssertEqual(audio.seekRequests.last, 30_000)
        XCTAssertEqual(audio.playedTargets.count, 1)
    }

    func testNativeAudioSkipAcceptsConfiguredTimeUnits() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let item = Item(
            id: "item-native-configured-skip",
            title: "Configured Native Skip",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 120_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 40_000
        let forward = try engine.skipForward(unit: "time_45s")
        XCTAssertEqual(forward.currentMediaTimeMs, 85_000)

        audio.currentMediaTimeValue = 85_000
        let back = try engine.skipBack(unit: "time_30s")
        XCTAssertEqual(back.currentMediaTimeMs, 55_000)
    }

    func testNativeAudioSkipForwardAtCompletedEndStaysAtEndAndPauses() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let item = Item(
            id: "item-native-complete-skip",
            title: "Completed Native Skip",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 120_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        let playCount = audio.playedOffsets.count
        audio.currentMediaTimeValue = 0 // AVPlayer may report a reset position after completion.
        audio.completedTargetIds.insert(item.media?.url ?? "")

        let snapshot = try engine.skipForward(unit: "time_60s")

        XCTAssertEqual(snapshot.currentMediaTimeMs, 120_000)
        XCTAssertEqual(snapshot.progressPercent, 100)
        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(audio.seekRequests.last, 120_000)
        XCTAssertEqual(audio.playedOffsets.count, playCount)
        XCTAssertEqual(audio.pauseCount, 1)
    }

    func testNativeAudioSkipForwardThatReachesEndClampsWithoutRestartingPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let item = Item(
            id: "item-native-clamped-skip",
            title: "Clamped Native Skip",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 90_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        let playCount = audio.playedOffsets.count
        audio.currentMediaTimeValue = 75_000

        let snapshot = try engine.skipForward(unit: "time_30s")

        XCTAssertEqual(snapshot.currentMediaTimeMs, 90_000)
        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(audio.seekRequests.last, 90_000)
        XCTAssertEqual(audio.playedOffsets.count, playCount)
    }

    func testNativeAudioPlaybackRatePropagatesToAudioClientAndSnapshot() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let item = Item(
            id: "item-native-rate",
            title: "Native Rate",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 120_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        let snapshot = try engine.setPlaybackRate(1.5)

        XCTAssertEqual(snapshot.playbackRate, 1.5)
        XCTAssertEqual(engine.currentSession?.playbackRate, 1.5)
        XCTAssertEqual(audio.playbackRates.last, 1.5)

        let quarterSpeed = try engine.setPlaybackRate(0.25)
        XCTAssertEqual(quarterSpeed.playbackRate, 0.25)
        XCTAssertEqual(engine.currentSession?.playbackRate, 0.25)
        XCTAssertEqual(audio.playbackRates.last, 0.25)
    }

    func testRestartPlaybackFromCurrentPositionReplaysTextFromSyncedOffset() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(
            id: "item-text-restart",
            title: "Text Restart",
            mediaType: "text",
            text: "One. Two. Three.",
            externalReference: nil,
            status: "ready"
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = "One. ".count
        let snapshot = try engine.restartPlaybackFromCurrentPosition()

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(snapshot.currentTextStart, "One. ".count)
        XCTAssertEqual(engine.currentSession?.position.charOffset, "One. ".count)
        XCTAssertEqual(audio.playedOffsets.last, "One. ".count)
    }

    func testMissingPreparedTextAudioCacheFallsBackToLiveTextPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "prerendered_audio", "native_media"]
            ]
        )
        let missingURL = FileManager.default.temporaryDirectory
            .appending(path: "missing-prepared-\(UUID().uuidString).caf")
        let item = Item(
            id: "item-missing-prepared-audio",
            title: "Recoverable Text",
            mediaType: "text",
            text: "This text must remain playable after its generated audio cache is purged.",
            externalReference: nil,
            status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: missingURL.absoluteString,
                durationMs: 2_000,
                nativeMediaId: missingURL.absoluteString
            )
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        let started = try engine.startSession(itemId: item.id)

        XCTAssertEqual(started.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(started.targetId, item.id)
        XCTAssertEqual(audio.playedTargets.last, item.id)
        XCTAssertEqual(audio.preparedTexts.last, item.text)
        XCTAssertNil(try repo.loadItem(id: item.id).media)
    }

    func testPreparedTextAudioUsesMediaPlaybackAndTranscriptAnchors() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"],
                "interjection": ["record_audio", "capture_transcript_anchor"]
            ]
        )
        let item = Item(
            id: "item-text-audio",
            title: "Prepared Text",
            mediaType: "text",
            text: "First sentence. Second sentence.",
            externalReference: nil,
            status: "ready"
        )
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: 32, text: "Second sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1"),
                MediaTimelineChapter(id: "ch-tts-2", title: "Second", startMs: 1_000, transcriptSegmentId: "tts-2")
            ],
            durationMs: 2_300
        )
        let prepared = PreparedTextAudio(
            normalizedText: "First sentence. Second sentence.",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/generated-text.caf",
                durationMs: 2_300,
                nativeMediaId: "file:///tmp/generated-text.caf"
            ),
            timeline: timeline
        )
        let audio = RecordingAudioClient()
        let textAudio = RecordingTextAudioPreparationClient(prepared: prepared)
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio, textAudio: textAudio)

        let started = try engine.startSession(itemId: item.id)

        XCTAssertEqual(started.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(started.targetId, "file:///tmp/generated-text.caf")
        XCTAssertEqual(started.currentPlaybackDurationMs, 2_300)
        XCTAssertEqual(audio.playedTargets.last, "file:///tmp/generated-text.caf")
        XCTAssertEqual(audio.playedOffsets.last, 0)
        XCTAssertEqual(audio.playbackRates.last, 1)
        let mediaContext = try XCTUnwrap(audio.mediaContexts.compactMap { $0 }.last)
        XCTAssertEqual(mediaContext.title, "Prepared Text")
        XCTAssertEqual(mediaContext.sourceType, .generatedTTSPrerendered)
        XCTAssertEqual(mediaContext.chapters.map(\.id), ["ch-tts-1", "ch-tts-2"])
        XCTAssertEqual(try repo.loadItem(id: item.id).media?.sourceType, .generatedTTSPrerendered)
        XCTAssertEqual(try repo.loadTranscriptTimeline(itemId: item.id)?.timeline.segments.map(\.id), ["tts-1", "tts-2"])

        audio.currentMediaTimeValue = 1_200
        let progress = try engine.syncPlaybackProgress()
        XCTAssertEqual(progress.currentTranscriptSegmentId, "tts-2")
        XCTAssertEqual(progress.currentAnchorConfidence, .transcriptSpan)
        XCTAssertEqual(progress.chapterTitle, "Second")

        _ = try engine.setPlaybackRate(1.5)
        XCTAssertEqual(audio.playbackRates.last, 1.5)

        let playCountBeforeSeek = audio.playedOffsets.count
        _ = try engine.seekMedia(toMediaTimeMs: 1_000)
        XCTAssertEqual(audio.seekRequests.last, 1_000)
        XCTAssertEqual(audio.playedOffsets.count, playCountBeforeSeek)

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/generated-text.m4a")
        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.anchorType, .transcript)
        XCTAssertEqual(interjection.anchor.transcriptSegmentId, "tts-2")
        XCTAssertEqual(interjection.anchor.anchorBefore, "Second sentence.")
    }

    func testPreparedTextAudioAttachmentDoesNotReplaceActiveLiveTextSession() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let item = Item(
            id: "item-live-to-media",
            title: "Live To Media",
            mediaType: "text",
            text: "First sentence. Second sentence.",
            externalReference: nil,
            status: "ready"
        )
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: 32, text: "Second sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1"),
                MediaTimelineChapter(id: "ch-tts-2", title: "Second", startMs: 1_000, transcriptSegmentId: "tts-2")
            ],
            durationMs: 2_300
        )
        let prepared = PreparedTextAudio(
            normalizedText: item.text ?? "",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/live-to-media.caf",
                durationMs: 2_300,
                nativeMediaId: "file:///tmp/live-to-media.caf"
            ),
            timeline: timeline
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(engine.currentSession?.currentTargetType, .itemTextTTS)
        audio.currentOffset = 16

        let retained = try engine.attachPreparedTextAudio(itemId: item.id, prepared: prepared)

        XCTAssertEqual(retained.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(retained.currentTextStart, 16)
        XCTAssertEqual(engine.currentSession?.currentTargetType, .itemTextTTS)
        XCTAssertNotEqual(audio.playedTargets.last, "file:///tmp/live-to-media.caf")
        XCTAssertEqual(try repo.loadItem(id: item.id).media?.url, "file:///tmp/live-to-media.caf")

        let promoted = try engine.attachPreparedTextAudio(
            itemId: item.id,
            prepared: prepared,
            replaceActivePlayback: true
        )

        XCTAssertEqual(promoted.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(promoted.targetId, "file:///tmp/live-to-media.caf")
        XCTAssertEqual(promoted.currentMediaTimeMs, 1_000)
        XCTAssertEqual(engine.currentSession?.currentTargetType, .transcriptBackedMedia)
        XCTAssertEqual(audio.playedTargets.last, "file:///tmp/live-to-media.caf")
        XCTAssertEqual(audio.playedOffsets.last, 1_000)
    }

    func testInspectSessionPromotesRestoredLiveTextToCompletePreparedAudio() throws {
        let audioFile = FileManager.default.temporaryDirectory
            .appending(path: "restored-prepared-\(UUID().uuidString).caf")
        try Data().write(to: audioFile)
        defer { try? FileManager.default.removeItem(at: audioFile) }
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let text = "First sentence. Second sentence."
        let item = Item(
            id: "item-restored-prepared",
            title: "Restored Prepared",
            mediaType: "text",
            text: text,
            externalReference: nil,
            status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: audioFile.absoluteString,
                durationMs: 2_300,
                nativeMediaId: audioFile.absoluteString
            ),
            transcriptId: "generated-transcript-item-restored-prepared"
        )
        let session = Session(
            id: "session-restored-prepared",
            itemId: item.id,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .itemTextTTS,
            currentTargetId: item.id,
            position: Position(charOffset: 16, chapterId: "ch-tts-2"),
            completionPercent: 50,
            playbackRate: 1.25
        )
        let timeline = SourceTranscriptTimeline(
            id: "generated-transcript-item-restored-prepared",
            itemId: item.id,
            createdAt: Date(),
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                    MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: text.count, text: "Second sentence.")
                ],
                chapters: [
                    MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1"),
                    MediaTimelineChapter(id: "ch-tts-2", title: "Second", startMs: 1_000, transcriptSegmentId: "tts-2")
                ],
                durationMs: 2_300
            )
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        try repo.saveTranscriptTimeline(timeline)
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        let inspected = try engine.inspectSession(sessionId: session.id)

        XCTAssertEqual(inspected.status, .paused)
        XCTAssertEqual(inspected.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(inspected.targetId, audioFile.absoluteString)
        XCTAssertEqual(inspected.currentMediaTimeMs, 1_000)
        XCTAssertEqual(inspected.playbackRate, 1.25)
        XCTAssertEqual(engine.currentSession?.position.charOffset, 16)
        XCTAssertEqual(try repo.loadSession(id: session.id)?.currentTargetType, .transcriptBackedMedia)

        let resumed = try engine.resumePlayback()
        XCTAssertEqual(resumed.currentMediaTimeMs, 1_000)
        XCTAssertEqual(audio.playedTargets.last, audioFile.absoluteString)
        XCTAssertEqual(audio.playedOffsets.last, 1_000)
    }

    // #237: an article that had been pre-rendered and half-read. Its saved session points at the
    // rendered file. If that file is gone or won't play, resume must read the text with on-device
    // speech from the same place, not fail twice and stay failed.
    private func halfReadPreparedArticle(fileExists: Bool) throws -> (
        repo: InMemorySessionRepository, item: Item, session: Session, fileURL: URL
    ) {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "prepared-\(UUID().uuidString).m4a")
        if fileExists {
            // Not audio: an unreadable file, as a truncated or corrupt render would be.
            try Data("not audio".utf8).write(to: fileURL)
            addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        }
        let text = "First sentence. Second sentence."
        let item = Item(
            id: "item-half-read-prepared",
            title: "Half-read article",
            mediaType: "text",
            text: text,
            externalReference: nil,
            status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: fileURL.absoluteString,
                durationMs: 2_300,
                nativeMediaId: fileURL.absoluteString
            ),
            transcriptId: "generated-transcript-item-half-read-prepared"
        )
        // 1,650 ms is halfway through the second sentence's audio: character 24 of the text.
        let session = Session(
            id: "session-half-read-prepared",
            itemId: item.id,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia,
            currentTargetId: fileURL.absoluteString,
            position: Position(charOffset: 24, mediaTimeMs: 1_650, chapterId: nil),
            completionPercent: 75,
            playbackRate: 1.25
        )
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "generated-transcript-item-half-read-prepared",
            itemId: item.id,
            createdAt: Date(),
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                    MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: text.count, text: "Second sentence.")
                ],
                chapters: [],
                durationMs: 2_300
            )
        ))
        return (repo, item, session, fileURL)
    }

    private var preparedArticleProfile: RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
    }

    private func assertResumedWithLiveSpeech(
        _ snapshot: SessionSnapshot,
        engine: SessionEngine,
        audio: RecordingAudioClient,
        repo: InMemorySessionRepository,
        fixture: (repo: InMemorySessionRepository, item: Item, session: Session, fileURL: URL),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(snapshot.status, .playing, file: file, line: line)
        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue, file: file, line: line)
        XCTAssertEqual(audio.playedTargets.last, fixture.item.id, "reads the article text", file: file, line: line)
        XCTAssertEqual(audio.preparedTexts.last, fixture.item.text, file: file, line: line)
        XCTAssertEqual(engine.currentSession?.position.charOffset, 24, "from the saved position", file: file, line: line)
        XCTAssertEqual(snapshot.playbackRate, 1.25, file: file, line: line)
        let saved = try XCTUnwrap(try repo.loadSession(id: fixture.session.id), file: file, line: line)
        XCTAssertEqual(saved.currentTargetType, .itemTextTTS, file: file, line: line)
        XCTAssertEqual(saved.currentTargetId, fixture.item.id, file: file, line: line)
        XCTAssertNil(try repo.loadItem(id: fixture.item.id).media, "the unusable file is detached so it can be rendered again", file: file, line: line)
        XCTAssertEqual(snapshot.preparedTextAudioStatus, "live_fallback", file: file, line: line)
    }

    func testResumingHalfReadArticleWhosePreparedAudioIsMissingReadsTextFromSavedPosition() throws {
        let fixture = try halfReadPreparedArticle(fileExists: false)
        let audio = RecordingAudioClient()
        audio.startStatusByTarget[fixture.fileURL.absoluteString] = .failed("The operation could not be completed")
        let engine = SessionEngine(profile: preparedArticleProfile, repository: fixture.repo, audio: audio)

        // The app's resume path: open the saved session, then play.
        _ = try engine.inspectSession(sessionId: fixture.session.id)
        let resumed = try engine.resumePlayback()

        XCTAssertFalse(audio.playedTargets.contains(fixture.fileURL.absoluteString), "never hands the player a missing file")
        try assertResumedWithLiveSpeech(resumed, engine: engine, audio: audio, repo: fixture.repo, fixture: fixture)
    }

    func testResumingHalfReadArticleWhosePreparedAudioWontPlayReadsTextFromSavedPosition() throws {
        let fixture = try halfReadPreparedArticle(fileExists: true)
        let audio = RecordingAudioClient()
        audio.startStatusByTarget[fixture.fileURL.absoluteString] = .failed("The operation could not be completed")
        let engine = SessionEngine(profile: preparedArticleProfile, repository: fixture.repo, audio: audio)

        _ = try engine.inspectSession(sessionId: fixture.session.id)
        let resumed = try engine.resumePlayback()

        XCTAssertEqual(audio.playedTargets.first, fixture.fileURL.absoluteString, "the file exists, so it is tried first")
        try assertResumedWithLiveSpeech(resumed, engine: engine, audio: audio, repo: fixture.repo, fixture: fixture)
        XCTAssertEqual(resumed.lastFailure, "prepared_audio_unavailable:The operation could not be completed")
    }

    func testResumingHalfReadArticleWhosePreparedAudioNeverStartsReadsTextAfterTheStartTimeout() throws {
        let fixture = try halfReadPreparedArticle(fileExists: true)
        let audio = RecordingAudioClient()
        audio.startStatusByTarget[fixture.fileURL.absoluteString] = .pending
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SessionEngine(
            profile: preparedArticleProfile, repository: fixture.repo, audio: audio,
            playbackStartTimeout: 10, now: { clock }
        )

        _ = try engine.inspectSession(sessionId: fixture.session.id)
        XCTAssertEqual(try engine.resumePlayback().status, .starting)
        clock = clock.addingTimeInterval(11)
        let resumed = try engine.syncPlaybackProgress()

        try assertResumedWithLiveSpeech(resumed, engine: engine, audio: audio, repo: fixture.repo, fixture: fixture)
        XCTAssertEqual(resumed.lastFailure, "prepared_audio_unavailable:playback_start_timeout")
    }

    func testLiveSpeechThatAlsoFailsAfterPreparedAudioFallbackStaysFailedWithoutLooping() throws {
        let fixture = try halfReadPreparedArticle(fileExists: true)
        let audio = RecordingAudioClient()
        audio.startStatus = .failed("speech_unavailable")
        let engine = SessionEngine(profile: preparedArticleProfile, repository: fixture.repo, audio: audio)

        _ = try engine.inspectSession(sessionId: fixture.session.id)
        let resumed = try engine.resumePlayback()
        _ = try engine.syncPlaybackProgress()

        XCTAssertEqual(resumed.status, .failed)
        XCTAssertEqual(resumed.lastFailure, "playback_start_failed:speech_unavailable")
        XCTAssertEqual(audio.playedTargets, [fixture.fileURL.absoluteString, fixture.item.id], "one fallback, then stop")
    }

    // #235: a live-speech start waiting on audio that is still rendering isn't a stalled start.
    func testStartWatchdogWaitsWhileTheClientIsRenderingThenCapsTheWait() throws {
        let item = Item(id: "item-slow-render", title: "Slow render", mediaType: "text",
                        text: "First sentence. Second sentence.", externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        audio.awaitingRenderedAudio = true
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone",
                                              capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]),
            repository: InMemorySessionRepository(items: [item.id: item]),
            audio: audio, playbackStartTimeout: 10, now: { clock }
        )
        XCTAssertEqual(try engine.startSession(itemId: item.id).status, .starting)
        for _ in 0..<3 {
            clock = clock.addingTimeInterval(11)
            XCTAssertEqual(try engine.syncPlaybackProgress().status, .starting, "still rendering at \(clock.timeIntervalSince1970 - 1_000) s")
        }
        audio.startStatus = .confirmed
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing, "plays when the audio lands")

        // A start the client never resolves still ends at the cap.
        _ = try engine.pause()
        audio.startStatus = .pending
        XCTAssertEqual(try engine.resumePlayback().status, .starting)
        for _ in 0..<3 {
            clock = clock.addingTimeInterval(11)
            _ = try engine.syncPlaybackProgress()
        }
        clock = clock.addingTimeInterval(11)
        let capped = try engine.syncPlaybackProgress()
        XCTAssertEqual(capped.status, .failed)
        XCTAssertEqual(capped.lastFailure, "playback_start_failed:playback_start_timeout")
    }

    func testStartWatchdogStillFailsAStartThatIsNotWaitingOnRendering() throws {
        let item = Item(id: "item-stalled", title: "Stalled", mediaType: "text",
                        text: "First sentence.", externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone",
                                              capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]),
            repository: InMemorySessionRepository(items: [item.id: item]),
            audio: audio, playbackStartTimeout: 10, now: { clock }
        )
        _ = try engine.startSession(itemId: item.id)
        clock = clock.addingTimeInterval(11)
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .failed)
    }

    // #278: after the fallback detaches an article's narration, its prepared-audio manifest said
    // "ready offline", so Prepare answered "already available offline" and never rendered again.
    func testDetachingUnplayableNarrationMarksItsManifestForRepreparation() throws {
        let fixture = try halfReadPreparedArticle(fileExists: true)
        let signature = TTSRenderSignature(
            engine: "supertonic", modelRevision: "3", assetManifestHash: "assets", voiceStyleHash: "voice",
            synthesisParametersHash: "parameters", normalizationVersion: "n", chunkingVersion: "c", digest: "digest-278"
        )
        try fixture.repo.savePreparedAudioManifest(PreparedAudioManifest(
            id: "prepared-\(fixture.item.id)-digest-278", itemId: fixture.item.id, sourcePackageId: "source",
            signature: signature, state: .readyOffline, plannedChunkCount: 2
        ))
        let audio = RecordingAudioClient()
        audio.startStatusByTarget[fixture.fileURL.absoluteString] = .failed("The operation could not be completed")
        let engine = SessionEngine(profile: preparedArticleProfile, repository: fixture.repo, audio: audio)

        _ = try engine.inspectSession(sessionId: fixture.session.id)
        _ = try engine.resumePlayback()

        let manifest = try XCTUnwrap(try fixture.repo.loadPreparedAudioManifests(itemId: fixture.item.id).first)
        XCTAssertEqual(manifest.state, .needsRepreparation)
    }

    func testCompleteButUnassembledManifestIsRecognised() {
        let signature = TTSRenderSignature(
            engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
            synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"
        )
        func chunk(_ index: Int) -> PreparedAudioChunk {
            PreparedAudioChunk(id: "c\(index)", index: index,
                               sourceRange: SourceLocator(documentId: "s", segmentId: "g", utf8Start: 0, utf8End: 1),
                               relativePath: "c\(index).wav", byteCount: 1, checksumSHA256: "x", durationMs: 1, committedAt: Date())
        }
        var manifest = PreparedAudioManifest(id: "m", itemId: "i", sourcePackageId: "s", signature: signature,
                                             state: .preparing, plannedChunkCount: 2, chunks: [chunk(0), chunk(1)])
        XCTAssertTrue(manifest.isCompleteButUnassembled)
        manifest.state = .readyOffline
        XCTAssertFalse(manifest.isCompleteButUnassembled)
        manifest.state = .preparing
        manifest.chunks = [chunk(0)]
        XCTAssertFalse(manifest.isCompleteButUnassembled)
    }

    // #277: the article was prepared again, so it now plays narration B (present), while the saved
    // session still targets the older narration A (gone). Opening it must not clear B, and must
    // resume B at the character the listener had reached.
    func testOpeningASessionOnAnOlderMissingRenderKeepsTheItemsCurrentRender() throws {
        let missingA = FileManager.default.temporaryDirectory.appending(path: "narration-a-\(UUID().uuidString).m4a")
        let presentB = FileManager.default.temporaryDirectory.appending(path: "narration-b-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: presentB)
        defer { try? FileManager.default.removeItem(at: presentB) }
        let text = "First sentence. Second sentence."
        let mediaB = ItemMedia(sourceType: .generatedTTSPrerendered, url: presentB.absoluteString,
                               durationMs: 4_600, nativeMediaId: presentB.absoluteString)
        let item = Item(id: "item-rerendered", title: "Re-rendered article", mediaType: "text", text: text,
                        externalReference: nil, status: "ready", media: mediaB,
                        transcriptId: "generated-transcript-item-rerendered")
        // Saved while playing A: A's 1,650 ms was character 24.
        let session = Session(
            id: "session-on-a", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: missingA.absoluteString,
            position: Position(charOffset: 24, mediaTimeMs: 1_650, chapterId: nil),
            completionPercent: 75, playbackRate: 1
        )
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        // B is a slower voice: twice A's timings.
        try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "generated-transcript-item-rerendered", itemId: item.id, createdAt: Date(),
            timeline: TranscriptTimeline(segments: [
                MediaTimelineSegment(id: "b-1", startMs: 0, endMs: 2_000, startChar: 0, endChar: 15, text: "First sentence."),
                MediaTimelineSegment(id: "b-2", startMs: 2_000, endMs: 4_600, startChar: 16, endChar: text.count, text: "Second sentence.")
            ], chapters: [], durationMs: 4_600)
        ))
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: preparedArticleProfile, repository: repo, audio: audio)

        let opened = try engine.inspectSession(sessionId: session.id)

        XCTAssertEqual(try repo.loadItem(id: item.id).media, mediaB, "the healthy current render is kept")
        XCTAssertEqual(opened.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(opened.targetId, presentB.absoluteString, "the session moves to B")
        XCTAssertEqual(engine.currentSession?.position.charOffset, 24, "at the character the listener reached")
        XCTAssertEqual(opened.currentMediaTimeMs, 3_300, "B's time for character 24")
        XCTAssertFalse(audio.playedTargets.contains(missingA.absoluteString))
    }

    func testMediaChapterJumpKeepsRequestedPositionWhileTransportReportsOldPosition() throws {
        let audioFile = FileManager.default.temporaryDirectory
            .appending(path: "delayed-media-seek-\(UUID().uuidString).caf")
        try Data().write(to: audioFile)
        defer { try? FileManager.default.removeItem(at: audioFile) }
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let text = "First sentence. Second sentence. Third sentence."
        let item = Item(
            id: "item-delayed-media-seek",
            title: "Delayed Media Seek",
            mediaType: "text",
            text: text,
            externalReference: nil,
            status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: audioFile.absoluteString,
                durationMs: 3_600,
                nativeMediaId: audioFile.absoluteString
            ),
            transcriptId: "generated-transcript-item-delayed-media-seek"
        )
        let timeline = SourceTranscriptTimeline(
            id: "generated-transcript-item-delayed-media-seek",
            itemId: item.id,
            createdAt: Date(),
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                    MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: 32, text: "Second sentence."),
                    MediaTimelineSegment(id: "tts-3", startMs: 2_300, endMs: 3_600, startChar: 33, endChar: text.count, text: "Third sentence.")
                ],
                chapters: [
                    MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1"),
                    MediaTimelineChapter(id: "ch-tts-2", title: "Second", startMs: 1_000, transcriptSegmentId: "tts-2"),
                    MediaTimelineChapter(id: "ch-tts-3", title: "Third", startMs: 2_300, transcriptSegmentId: "tts-3")
                ],
                durationMs: 3_600
            )
        )
        let audio = DelayedPositionAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveTranscriptTimeline(timeline)
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.confirmLatestRequest()
        _ = try engine.syncPlaybackProgress()
        audio.reportMediaPosition(400)
        _ = try engine.syncPlaybackProgress()

        let jumped = try engine.jumpToChapter(chapterId: "ch-tts-2")
        XCTAssertEqual(audio.requestedMediaPositions.last, 1_000)
        XCTAssertEqual(jumped.status, .starting)
        XCTAssertEqual(jumped.currentMediaTimeMs, 1_000)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 1_000)

        let whileOldTransportPositionRemains = try engine.syncPlaybackProgress()
        XCTAssertEqual(whileOldTransportPositionRemains.currentMediaTimeMs, 1_000)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 1_000)

        let pausedBeforeSeekConfirmation = try engine.pause()
        XCTAssertEqual(pausedBeforeSeekConfirmation.status, .paused)
        XCTAssertEqual(pausedBeforeSeekConfirmation.currentMediaTimeMs, 1_000)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 1_000)

        let resumedFromRequestedPosition = try engine.resumePlayback()
        XCTAssertEqual(resumedFromRequestedPosition.status, .starting)
        XCTAssertEqual(audio.requestedMediaPositions.last, 1_000)

        let soughtAgain = try engine.seekMedia(toMediaTimeMs: 2_300)
        XCTAssertEqual(soughtAgain.currentMediaTimeMs, 2_300)
        audio.reportMediaPosition(0)
        XCTAssertEqual(try engine.syncPlaybackProgress().currentMediaTimeMs, 2_300)

        audio.confirmLatestRequest()
        let confirmed = try engine.syncPlaybackProgress()
        XCTAssertEqual(confirmed.status, .playing)
        XCTAssertEqual(confirmed.currentMediaTimeMs, 2_300)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 2_300)

        audio.reportMediaPosition(0)
        let stalePostConfirmationSample = try engine.syncPlaybackProgress()
        XCTAssertEqual(stalePostConfirmationSample.currentMediaTimeMs, 2_300)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 2_300)

        audio.reportMediaPosition(2_800)
        let forwardProgress = try engine.syncPlaybackProgress()
        XCTAssertEqual(forwardProgress.currentMediaTimeMs, 2_800)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 2_800)
    }

    func testActiveMediaSeekAcknowledgesThenRejoinsAdvancingPlayerClockWithoutRestartingPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-transactional-seek",
            title: "Transactional Seek",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/transactional-seek",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: "https://cdn.example.com/transactional-seek.mp3",
                durationMs: 1_800_000
            )
        )
        let audio = DelayedPositionAudioClient()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.confirmLatestRequest()
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing)
        audio.reportMediaPosition(90_000)
        _ = try engine.syncPlaybackProgress()
        let playCount = audio.mediaPlayPositions.count

        let requested = try engine.seekMedia(toMediaTimeMs: 600_000)
        XCTAssertEqual(requested.status, .playing)
        XCTAssertEqual(requested.currentMediaTimeMs, 600_000)
        XCTAssertEqual(audio.mediaPlayPositions.count, playCount, "An in-target seek must not restart playback")
        XCTAssertEqual(audio.navigationSeekPositions, [600_000])
        XCTAssertEqual(engine.lastMediaSeekResolution, .pending)

        audio.reportMediaPosition(91_000)
        let whilePending = try engine.syncPlaybackProgress()
        XCTAssertEqual(whilePending.status, .playing)
        XCTAssertEqual(whilePending.currentMediaTimeMs, 600_000)

        audio.confirmLatestRequest()
        XCTAssertEqual(try engine.syncPlaybackProgress().currentMediaTimeMs, 600_000)
        XCTAssertEqual(engine.lastMediaSeekResolution, .accepted(mediaTimeMs: 600_000))

        for expected in [600_500, 601_000, 601_500] {
            audio.reportMediaPosition(expected)
            let advanced = try engine.syncPlaybackProgress()
            XCTAssertEqual(advanced.status, .playing)
            XCTAssertEqual(advanced.currentMediaTimeMs, expected)
            XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, expected)
        }

        _ = try engine.seekMedia(toMediaTimeMs: 900_000)
        audio.failLatestMediaSeek(actualMediaTimeMs: 602_000)
        let recovered = try engine.syncPlaybackProgress()
        XCTAssertEqual(recovered.status, .playing, "A declined navigation seek must not stop an audible player")
        XCTAssertEqual(recovered.currentMediaTimeMs, 602_000)
        XCTAssertEqual(recovered.lastFailure, "media_seek_failed:test_seek_declined")

        audio.reportMediaPosition(602_500)
        let postFailureTick = try engine.syncPlaybackProgress()
        XCTAssertEqual(postFailureTick.status, .playing)
        XCTAssertEqual(postFailureTick.currentMediaTimeMs, 602_500)
    }

    func testRoutedPodcastCaptureForwardsOnlyOnActiveMediaRoute() throws {
        let speech = RecordingAudioClient()
        let media = RecordingAudioClient()
        media.acceptsPostResumeSamples = true
        // Call through the protocol type, as SessionEngine does, so a missing
        // forwarding method would dispatch to the silent protocol default.
        let routed: any AudioPlaybackClient = RoutedAudioPlaybackClient(speech: speech, media: media)
        let first = PostResumeAudioSampleRequest(interjectionId: "ij-001", sessionId: "first", itemId: "episode", anchorMediaTimeMs: 20_000, targetDurationMs: 12_000)
        let second = PostResumeAudioSampleRequest(interjectionId: "ij-001", sessionId: "second", itemId: "episode", anchorMediaTimeMs: 40_000, targetDurationMs: 12_000)

        XCTAssertFalse(routed.captureBufferedPreInterjectionAudioSample(first))
        XCTAssertFalse(routed.armPostResumeAudioSample(first))
        XCTAssertTrue(media.postResumeSampleRequests.isEmpty)
        try routed.play(targetId: "episode", fromMediaTimeMs: 20_000)
        XCTAssertTrue(routed.captureBufferedPreInterjectionAudioSample(first))
        XCTAssertTrue(routed.armPostResumeAudioSample(first))
        XCTAssertTrue(routed.armPostResumeAudioSample(second))
        XCTAssertEqual(media.preInterjectionSampleRequests, [first])
        XCTAssertEqual(media.postResumeSampleRequests, [first, second])
        XCTAssertTrue(speech.postResumeSampleRequests.isEmpty)
        try routed.play(targetId: "speech", from: 0)
        XCTAssertFalse(routed.armPostResumeAudioSample(first))
        XCTAssertEqual(media.postResumeSampleRequests, [first, second])
        media.acceptsPostResumeSamples = false
        try routed.play(targetId: "episode", fromMediaTimeMs: 40_000)
        XCTAssertFalse(routed.armPostResumeAudioSample(second))
    }

    func testPausedMediaDestinationCanBeStagedWithoutPlayerSeekAndResumedThere() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
        )
        let item = Item(
            id: "item-paused-margin-seek", title: "Paused Margin Seek",
            mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 600_000)
        )
        let audio = DelayedPositionAudioClient()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.pause()
        let staged = try engine.stagePausedMediaPosition(toMediaTimeMs: 240_000)
        XCTAssertEqual(staged.status, .paused)
        XCTAssertEqual(staged.currentMediaTimeMs, 240_000)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 240_000)
        XCTAssertTrue(audio.navigationSeekPositions.isEmpty, "No player seek should be requested for a deferred source start")
        _ = try engine.resumePlayback()
        XCTAssertEqual(audio.mediaPlayPositions.last, 240_000)
        XCTAssertThrowsError(try engine.stagePausedMediaPosition(toMediaTimeMs: 300_000))
    }
    func testLiveTextSeekKeepsRequestedOffsetWhileSpeechReportsOldOffset() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let text = "First sentence. Second sentence. Third sentence."
        let item = Item(
            id: "item-delayed-text-seek",
            title: "Delayed Text Seek",
            mediaType: "text",
            text: text,
            externalReference: nil,
            status: "ready"
        )
        let audio = DelayedPositionAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.confirmLatestRequest()
        _ = try engine.syncPlaybackProgress()
        audio.reportTextPosition(6)
        _ = try engine.syncPlaybackProgress()

        let requestedOffset = 32
        let sought = try engine.seekText(toCharOffset: requestedOffset)
        XCTAssertEqual(audio.requestedTextPositions.last, requestedOffset)
        XCTAssertEqual(sought.status, .starting)
        XCTAssertEqual(sought.currentTextStart, requestedOffset)
        XCTAssertEqual(engine.currentSession?.position.charOffset, requestedOffset)

        let whileOldSpeechPositionRemains = try engine.syncPlaybackProgress()
        XCTAssertEqual(whileOldSpeechPositionRemains.currentTextStart, requestedOffset)
        XCTAssertEqual(engine.currentSession?.position.charOffset, requestedOffset)

        audio.confirmLatestRequest()
        let confirmed = try engine.syncPlaybackProgress()
        XCTAssertEqual(confirmed.status, .playing)
        XCTAssertEqual(confirmed.currentTextStart, requestedOffset)
        XCTAssertEqual(engine.currentSession?.position.charOffset, requestedOffset)
    }

    func testPreparedTextAudioAttachmentReplacesStarterMediaWithoutLosingPlayhead() throws {
        let starterFile = URL(fileURLWithPath: "/tmp/generated-starter.caf")
        try Data().write(to: starterFile)
        defer { try? FileManager.default.removeItem(at: starterFile) }
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let item = Item(
            id: "item-starter-to-full",
            title: "Starter To Full",
            mediaType: "text",
            text: "First sentence. Second sentence. Third sentence.",
            externalReference: nil,
            status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/generated-starter.caf",
                durationMs: 1_000,
                nativeMediaId: "file:///tmp/generated-starter.caf"
            ),
            transcriptId: "generated-transcript-item-starter-to-full"
        )
        let starterTimeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1")
            ],
            durationMs: 1_000
        )
        let fullTimeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: 32, text: "Second sentence."),
                MediaTimelineSegment(id: "tts-3", startMs: 2_300, endMs: 3_600, startChar: 33, endChar: 48, text: "Third sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1"),
                MediaTimelineChapter(id: "ch-tts-2", title: "Second", startMs: 1_000, transcriptSegmentId: "tts-2"),
                MediaTimelineChapter(id: "ch-tts-3", title: "Third", startMs: 2_300, transcriptSegmentId: "tts-3")
            ],
            durationMs: 3_600
        )
        let prepared = PreparedTextAudio(
            normalizedText: item.text ?? "",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/generated-full.caf",
                durationMs: 3_600,
                nativeMediaId: "file:///tmp/generated-full.caf"
            ),
            timeline: fullTimeline
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "generated-transcript-item-starter-to-full",
            itemId: item.id,
            createdAt: Date(),
            timeline: starterTimeline
        ))
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.playedTargets.last, "file:///tmp/generated-starter.caf")
        audio.currentMediaTimeValue = 700

        let replaced = try engine.attachPreparedTextAudio(itemId: item.id, prepared: prepared)

        XCTAssertEqual(replaced.targetId, "file:///tmp/generated-full.caf")
        XCTAssertEqual(replaced.currentMediaTimeMs, 733)
        XCTAssertEqual(replaced.currentPlaybackDurationMs, 3_600)
        XCTAssertEqual(audio.playedTargets.last, "file:///tmp/generated-full.caf")
        XCTAssertEqual(audio.playedOffsets.last, 733)
        XCTAssertEqual(engine.currentSession?.currentTargetId, "file:///tmp/generated-full.caf")
        XCTAssertEqual(try repo.loadItem(id: item.id).media?.url, "file:///tmp/generated-full.caf")
        XCTAssertEqual(try repo.loadTranscriptTimeline(itemId: item.id)?.timeline.segments.map(\.id), ["tts-1", "tts-2", "tts-3"])
    }

    func testPartialStarterGeneratedTextAudioCompletionDoesNotCompleteSource() throws {
        let starterFile = URL(fileURLWithPath: "/tmp/generated-partial-starter.caf")
        try Data().write(to: starterFile)
        defer { try? FileManager.default.removeItem(at: starterFile) }
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let item = Item(
            id: "item-partial-starter",
            title: "Partial Starter",
            mediaType: "text",
            text: "First sentence. Second sentence. Third sentence.",
            externalReference: nil,
            status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/generated-partial-starter.caf",
                durationMs: 1_000,
                nativeMediaId: "file:///tmp/generated-partial-starter.caf"
            ),
            transcriptId: "generated-transcript-item-partial-starter"
        )
        let starterTimeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1")
            ],
            durationMs: 1_000
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "generated-transcript-item-partial-starter",
            itemId: item.id,
            createdAt: Date(),
            timeline: starterTimeline
        ))
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 1_000
        audio.completedTargetIds.insert("file:///tmp/generated-partial-starter.caf")
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(snapshot.preparedTextAudioStatus, "starter_ready")
        XCTAssertLessThan(snapshot.sourceProgressPercent, 100)
        XCTAssertLessThan(snapshot.currentPlaybackProgressPercent, 100)
    }

    func testSourceTranscriptTimelineAnchorsNativeAudioAndGeneratesListeningMap() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"],
                "ai": ["generate_listening_map"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-native-transcript",
            title: "Native Transcript",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 30_000)
        )
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, text: "Opening thought."),
                MediaTimelineSegment(id: "seg-2", startMs: 10_000, endMs: 20_000, text: "Important middle point."),
                MediaTimelineSegment(id: "seg-3", startMs: 20_000, endMs: 30_000, text: "Closing thought.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-1", title: "Opening", startMs: 0, transcriptSegmentId: "seg-1"),
                MediaTimelineChapter(id: "ch-2", title: "Middle", startMs: 10_000, transcriptSegmentId: "seg-2")
            ],
            durationMs: 30_000
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.attachTranscriptTimeline(itemId: item.id, timeline: timeline)
        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 12_000
        let progress = try engine.syncPlaybackProgress()

        XCTAssertEqual(progress.currentTranscriptSegmentId, "seg-2")
        XCTAssertEqual(progress.currentAnchorConfidence, .transcriptSpan)
        XCTAssertEqual(progress.chapterTitle, "Middle")

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/native-transcript.m4a")
        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.anchorType, .transcript)
        XCTAssertEqual(interjection.anchor.transcriptSegmentId, "seg-2")
        XCTAssertEqual(interjection.anchor.anchorBefore, "Important middle point.")

        let mapSnapshot = try engine.generateListeningMap(itemId: item.id)
        let map = try XCTUnwrap(try repo.loadListeningMap(itemId: item.id))
        XCTAssertEqual(mapSnapshot.itemId, item.id)
        XCTAssertFalse(map.chapters.isEmpty)
        XCTAssertTrue((try repo.loadItem(id: item.id).text ?? "").contains("Important middle point."))

        let handoff = try engine.buildExport(options: ExportOptions(
            includeFullText: true,
            includeReference: true,
            includeListeningMap: true,
            includeInterjections: true
        ))
        XCTAssertFalse(handoff.item.includedFullText)
        XCTAssertNil(handoff.item.text)
        XCTAssertNil(handoff.item.sourceTranscript)
        XCTAssertEqual(handoff.schemaVersion, "spoken-margins.export.v1")
    }

    func testTechnicalTranscriptSegmentsDoNotBecomePlaybackChapterTitles() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let item = Item(
            id: "item-word-segments",
            title: "Why Apple Is Heading Into a Pivotal Moment",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 30_000)
        )
        let segments = [
            MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, text: "we"),
            MediaTimelineSegment(id: "seg-2", startMs: 10_000, endMs: 20_000, text: "have"),
            MediaTimelineSegment(id: "seg-3", startMs: 20_000, endMs: 30_000, text: "questions")
        ]
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.attachTranscriptTimeline(
            itemId: item.id,
            timeline: TranscriptTimeline(segments: segments, chapters: [], durationMs: 30_000)
        )
        XCTAssertTrue(try XCTUnwrap(repo.loadTranscriptTimeline(itemId: item.id)).timeline.chapters.isEmpty)

        try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "legacy-word-transcript",
            itemId: item.id,
            createdAt: Date(),
            timeline: TranscriptTimeline(
                segments: segments,
                chapters: [
                    MediaTimelineChapter(id: "ch-transcript-01", title: "we", startMs: 0, transcriptSegmentId: "seg-1"),
                    MediaTimelineChapter(id: "chunk-0000-ch-transcript-02", title: "have", startMs: 10_000, transcriptSegmentId: "seg-2")
                ],
                durationMs: 30_000
            )
        ))

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 12_000
        let progress = try engine.syncPlaybackProgress()

        XCTAssertEqual(progress.currentTranscriptSegmentId, "seg-2")
        XCTAssertEqual(progress.chapterTitle, item.title)
    }

    func testInMemoryRepositoryListsWatchPackagesByItem() throws {
        let first = WatchAudioPackage(
            id: "package-1",
            itemId: "item-a",
            sessionId: "session-1",
            createdAt: Date(timeIntervalSince1970: 1),
            item: WatchPackageItem(title: "First", mediaType: "text"),
            audioAssets: [],
            transcript: WatchPackageTranscript(transcriptId: "transcript-1", segments: []),
            chapters: [],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let second = WatchAudioPackage(
            id: "package-2",
            itemId: "item-a",
            sessionId: "session-2",
            createdAt: Date(timeIntervalSince1970: 2),
            item: WatchPackageItem(title: "Second", mediaType: "text"),
            audioAssets: [],
            transcript: WatchPackageTranscript(transcriptId: "transcript-2", segments: []),
            chapters: [],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let other = WatchAudioPackage(
            id: "package-3",
            itemId: "item-b",
            sessionId: "session-3",
            createdAt: Date(timeIntervalSince1970: 3),
            item: WatchPackageItem(title: "Other", mediaType: "text"),
            audioAssets: [],
            transcript: WatchPackageTranscript(transcriptId: "transcript-3", segments: []),
            chapters: [],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let repository = InMemorySessionRepository(
            watchPackages: [
                first.id: first,
                second.id: second,
                other.id: other
            ]
        )

        XCTAssertEqual(try repository.loadWatchAudioPackages(itemId: "item-a").map(\.id), ["package-1", "package-2"])
    }

    private func compactControlEngine() throws -> SessionEngine {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone / Tablet Online",
            capabilities: [
                "playback": ["realtime_tts", "assistant_turn_tts", "summary_turn_tts"],
                "timeline": ["text_char_offsets", "chapter_timing"],
                "interjection": ["record_audio", "capture_text_anchor", "capture_turn_anchor"],
                "ai": ["summarize_interjections", "continue_discussion"],
                "sync": ["canonical_persistence"],
                "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands", "send_ai_commands"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four.", externalReference: nil, status: "ready")
        let map = ListeningMap(
            id: "map-pill",
            itemId: item.id,
            overview: "Overview.",
            chapters: [
                Chapter(id: "ch-opening", title: "Opening", startChar: 0, endChar: 8, percent: 0),
                Chapter(id: "ch-middle", title: "Middle", startChar: 10, endChar: 22, percent: 50)
            ]
        )
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        return SessionEngine(profile: profile, repository: repo)
    }

    private func phonePlaybackProfile() -> RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone / Tablet Online",
            capabilities: [
                "playback": ["realtime_tts", "assistant_turn_tts", "summary_turn_tts"],
                "timeline": ["text_char_offsets", "chapter_timing"],
                "interjection": ["record_audio", "capture_text_anchor", "capture_turn_anchor"],
                "ai": ["summarize_interjections", "continue_discussion", "defer_ai_jobs"],
                "sync": ["canonical_persistence"]
            ]
        )
    }

    func testSQLiteStoreListsAndDeletesItemScopedRecords() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let keep = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One.", externalReference: nil, status: "ready")
        let remove = Item(id: "item-import-1", title: "Import", mediaType: "text", text: "Two.", externalReference: nil, status: "ready")
        try store.seed(item: keep)
        try store.seed(item: remove)
        try store.saveSession(Session(id: "session-import", itemId: remove.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: remove.id, position: Position(), completionPercent: 0, playbackRate: 1))

        XCTAssertEqual(Set(try store.listItems().map(\.id)), ["item-pill", "item-import-1"])

        try store.deleteItem(id: remove.id)

        XCTAssertEqual(try store.listItems().map(\.id), ["item-pill"])
        XCTAssertNil(try store.loadSession(id: "session-import"))
    }

    func testSQLiteStoreTrashRestoreAndPermanentDeleteLifecycle() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-trash", title: "Recoverable", mediaType: "text", text: "Keep the related records.", externalReference: nil, status: "ready")
        let session = Session(id: "session-trash", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 10, playbackRate: 1)
        try store.saveItem(item)
        try store.saveSession(session)

        let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.moveItemToTrash(id: item.id, at: deletedAt)

        XCTAssertTrue(try store.listItems().isEmpty)
        XCTAssertEqual(try store.listDeletedItems().first?.deletedAt, deletedAt)
        XCTAssertNotNil(try store.loadSession(id: session.id), "Moving an item to trash must preserve its related records")

        try store.restoreItem(id: item.id)

        XCTAssertEqual(try store.listItems().map(\.id), [item.id])
        XCTAssertTrue(try store.listDeletedItems().isEmpty)

        try store.moveItemToTrash(id: item.id, at: deletedAt)
        try store.deleteItem(id: item.id)

        XCTAssertTrue(try store.listItems(includeDeleted: true).isEmpty)
        XCTAssertNil(try store.loadSession(id: session.id))
    }

    func testSQLiteStoreBulkDeleteRemovesTrashedGraphsAndPreservesActiveItems() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let active = Item(id: "item-active", title: "Active", mediaType: "text", text: "Keep.", externalReference: nil, status: "ready")
        let first = Item(id: "item-trash-one", title: "One", mediaType: "text", text: "Remove one.", externalReference: nil, status: "ready")
        let second = Item(id: "item-trash-two", title: "Two", mediaType: "text", text: "Remove two.", externalReference: nil, status: "ready")
        try store.saveItem(active)
        try store.saveItem(first)
        try store.saveItem(second)
        try store.saveSession(Session(id: "session-trash-one", itemId: first.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: first.id, position: Position(), completionPercent: 10, playbackRate: 1))
        try store.saveSession(Session(id: "session-trash-two", itemId: second.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: second.id, position: Position(), completionPercent: 20, playbackRate: 1))
        try store.moveItemToTrash(id: first.id)
        try store.moveItemToTrash(id: second.id)

        try store.deleteItems(ids: [first.id, second.id, first.id])

        XCTAssertEqual(try store.listItems().map(\.id), [active.id])
        XCTAssertTrue(try store.listDeletedItems().isEmpty)
        XCTAssertNil(try store.loadSession(id: "session-trash-one"))
        XCTAssertNil(try store.loadSession(id: "session-trash-two"))
    }

    func testSQLiteStoreReplacesListeningMapForItem() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        try store.seed(item: item)
        try store.saveListeningMap(ListeningMap(
            id: "map-original",
            itemId: item.id,
            overview: "Original",
            chapters: [Chapter(id: "original", title: "Original", startChar: 0, endChar: 4, percent: 0)]
        ))
        try store.saveListeningMap(ListeningMap(
            id: "map-manual",
            itemId: item.id,
            overview: "Manual",
            chapters: [Chapter(id: "manual-process", title: "Manual Process", startChar: 5, endChar: 9, percent: 50)]
        ))

        let loaded = try XCTUnwrap(try store.loadListeningMap(itemId: item.id))
        XCTAssertEqual(loaded.id, "map-manual")
        XCTAssertEqual(loaded.chapters.map(\.id), ["manual-process"])
    }

    func testManualListeningMapGenerationPersistsMapAndEnablesChapterJump() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"],
                "ai": ["generate_listening_map"]
            ]
        )
        let item = Item(
            id: "item-generated",
            title: "Generated",
            mediaType: "text",
            text: "Opening context is first. The middle explains the claim. The ending gives the consequence.",
            externalReference: nil,
            status: "needs_listening_map"
        )
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.generateListeningMap(itemId: item.id)

        let map = try XCTUnwrap(try repo.loadListeningMap(itemId: item.id))
        XCTAssertEqual(map.chapters.count, 3)
        XCTAssertEqual(try repo.loadItem(id: item.id).status, "ready")

        let target = map.chapters[1]
        let snapshot = try engine.jumpToChapter(chapterId: target.id)
        XCTAssertEqual(snapshot.chapterTitle, target.title)
        XCTAssertEqual(engine.currentSession?.position.charOffset, target.startChar)
    }

    func testAttachingProviderListeningMapUpdatesActiveSessionChapterNavigation() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(
            id: "item-provider-map",
            title: "Provider Map",
            mediaType: "text",
            text: "Opening context. A navigable middle section. A final conclusion.",
            externalReference: nil,
            status: "needs_listening_map"
        )
        let map = ListeningMap(
            id: "map-provider-map",
            itemId: item.id,
            overview: "A provider-generated map.",
            chapters: [
                Chapter(id: "ch-opening", title: "Opening", startChar: 0, endChar: 17, percent: 0),
                Chapter(id: "ch-middle", title: "Middle", startChar: 17, endChar: 46, percent: 27)
            ]
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.attachListeningMap(map)
        let jumped = try engine.jumpToChapter(chapterId: "ch-middle")

        XCTAssertEqual(jumped.chapterTitle, "Middle")
        XCTAssertEqual(engine.currentSession?.position.charOffset, 17)
        XCTAssertEqual(try repo.loadItem(id: item.id).status, "ready")
    }

    func testSeekTextMovesAndRestartsActiveNativeTextPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let text = "First paragraph. Second paragraph. Third paragraph."
        let item = Item(id: "item-text-seek", title: "Seekable", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        let sought = try engine.seekText(toCharOffset: 28)

        XCTAssertEqual(sought.currentTextStart, 28)
        XCTAssertEqual(engine.currentSession?.position.charOffset, 28)
        XCTAssertEqual(audio.playedOffsets.last, 28)
        XCTAssertEqual(sought.phase, .itemPlayback)
    }

    // #346 audit: a seek while speaking reached the client as a plain play, which a playing client
    // treats as "keep going" when it's near the live position. It must say it's a seek; a restart
    // (a rate change) must not.
    func testASeekWhileSpeakingIsMarkedAsASeekButARestartIsNot() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
        )
        let text = "First paragraph. Second paragraph. Third paragraph."
        let item = Item(id: "item-text-seek-mark", title: "Seekable", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository(items: [item.id: item]), audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.seekText(toCharOffset: 28)
        XCTAssertEqual(audio.seekingPlays, [28])
        audio.currentOffset = 30
        _ = try engine.restartPlaybackFromCurrentPosition()
        XCTAssertEqual(audio.seekingPlays, [28], "a restart is a plain play")
        _ = try engine.resumePlayback()
        XCTAssertEqual(audio.seekingPlays.count, 1, "so is a second play")

        // #346 re-audit: every explicit move is a seek, not only seekText.
        audio.currentOffset = 38
        _ = try engine.skipBack(unit: "sentence")
        XCTAssertEqual(audio.seekingPlays.count, 2, "skip back: \(audio.seekingPlays)")
        audio.currentOffset = 5
        _ = try engine.skipForward(unit: "sentence")
        XCTAssertEqual(audio.seekingPlays.count, 3, "skip forward: \(audio.seekingPlays)")
        _ = try engine.playSourceFromBeginning()
        XCTAssertEqual(audio.seekingPlays.last, 0, "play from the beginning: \(audio.seekingPlays)")
    }

    func testRoutedClientForwardsASeekToTheSpeechClient() throws {
        let speech = RecordingAudioClient()
        let routed = RoutedAudioPlaybackClient(speech: speech, media: RecordingAudioClient())
        try routed.play(targetId: "item", seekingTo: 12)
        XCTAssertEqual(speech.seekingPlays, [12])
    }

    func testStartSessionSpeaksListeningMapOverviewBeforeItemText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let map = ListeningMap(id: "map-pill", itemId: item.id, overview: "This item contrasts one with two.", chapters: [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: 5, percent: 0)
        ])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)

        XCTAssertEqual(audio.preparedTexts.last, "Overview. This item contrasts one with two.\n\nOne. Two.")
        XCTAssertEqual(audio.playedOffsets.last, 0)
        XCTAssertEqual(engine.lastSpokenText, "Overview. This item contrasts one with two. One. Two.")
    }

    func testPauseAndResumePreserveSourcePosition() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.skipForward(unit: "sentence")
        let offsetBeforePause = try XCTUnwrap(engine.currentSession?.position.charOffset)
        let paused = try engine.pause()
        let offsetAfterPause = try XCTUnwrap(engine.currentSession?.position.charOffset)
        let resumed = try engine.resumePlayback()

        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(resumed.status, .playing)
        XCTAssertEqual(offsetAfterPause, offsetBeforePause)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), offsetBeforePause)
        XCTAssertEqual(audio.playedTargets, [item.id, item.id, item.id])
        XCTAssertEqual(audio.playedOffsets, [0, offsetBeforePause, offsetBeforePause])
    }

    func testStopPlaybackPersistsLatestSourcePositionForResume() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let text = "One. Two. Three."
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = "One. Two. ".count
        let stopped = try engine.stopPlayback()
        let sessionId = try XCTUnwrap(stopped.sessionId)
        let persisted = try XCTUnwrap(try repo.loadSession(id: sessionId))

        XCTAssertEqual(stopped.status, .paused)
        XCTAssertEqual(persisted.position.charOffset, "One. Two. ".count)

        let resumed = try engine.resumePlayback()

        XCTAssertEqual(resumed.status, .playing)
        XCTAssertEqual(audio.playedOffsets, [0, "One. Two. ".count])
    }

    func testSkipForwardUsesCurrentAudioPositionWhenAvailable() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 10
        let snapshot = try engine.skipForward(unit: "sentence")

        XCTAssertGreaterThanOrEqual(snapshot.progressPercent, 50)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 17)
        XCTAssertEqual(audio.playedOffsets.last, 17)
    }

    func testSkipForwardCanRequireMinimumDistanceForChunkedPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four. Five. Six.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 2
        let snapshot = try engine.skipForward(unit: "sentence", minimumDistance: 12)

        XCTAssertGreaterThan(snapshot.progressPercent, 50)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 17)
        XCTAssertEqual(audio.playedOffsets.last, 17)
    }

    func testParagraphSkipFallsBackToSentenceForSingleParagraphText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 0
        let forward = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(forward.progressPercent, 31)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 5)
        XCTAssertEqual(audio.playedOffsets.last, 5)

        audio.currentOffset = 10
        let back = try engine.skipBack(unit: "paragraph")

        XCTAssertEqual(back.progressPercent, 31)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 5)
    }

    func testSkipBackUsesCurrentAudioPositionAndPreviousBoundaryIsStrict() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 10
        let snapshot = try engine.skipBack(unit: "sentence")

        XCTAssertEqual(snapshot.progressPercent, 31)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 5)
        XCTAssertEqual(audio.playedOffsets.last, 5)
    }

    func testSyncPlaybackProgressPublishesCurrentAudioPosition() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 10
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.progressPercent, 45)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 10)
        XCTAssertEqual(audio.playedOffsets, [0])
    }

    func testSyncPlaybackProgressMarksItemFinishedWhenAudioCompletes() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.completedTargetIds.insert(item.id)
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(snapshot.progressPercent, 100)
        XCTAssertEqual(engine.currentSession?.status, "finished")
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), try XCTUnwrap(item.text).count)
    }

    func testAIJobCompletedPreservesActivePlaybackPhase() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "ai": ["summarize_interjections"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 0
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: engine.currentSession?.id))
        _ = try engine.aiStreamDelta(turnId: "turn-summary-001", content: "<sm_response>Summary text.</sm_response>")
        let snapshot = try engine.aiJobCompleted(turnId: "turn-summary-001")

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue)
    }

    func testFailedInterjectionSummaryBecomesRetryableWithoutRemainingPending() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "ai": ["summarize_interjections"]
            ]
        )
        let item = Item(id: "item-summary-retry", title: "Summary Retry", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let session = Session(id: "session-summary-retry", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 20, playbackRate: 1)
        let interjection = Interjection(
            id: "ij-summary-retry",
            itemId: item.id,
            sessionId: session.id,
            targetType: .item,
            targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 20,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 3, anchorBefore: "One.", anchorAfter: "Two."),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "I want to keep this qualification.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        let repo = InMemorySessionRepository(
            items: [item.id: item],
            sessions: [session.id: session],
            interjections: [interjection.id: interjection]
        )
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))
        let failed = try engine.aiProviderFailed(error: "invalid_interjection_summary")

        XCTAssertEqual(try repo.loadAIJobs(sessionId: session.id).last?.status, "retryable")
        XCTAssertEqual(try repo.loadTurns(sessionId: session.id).last?.status, "failed")
        XCTAssertEqual(failed.turnStatus, "failed")
        XCTAssertNoThrow(try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id)))
        XCTAssertEqual(try repo.loadTurns(sessionId: session.id).last?.status, "pending")
    }

    func testFinishInterjectionSchedulesTranscriptionAfterAudioIsSaved() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let transcriber = RecordingTranscriptionClient()
        let engine = SessionEngine(profile: profile, repository: repo, transcriber: transcriber)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/ij-001.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).first)
        XCTAssertEqual(interjection.audioPath, "interjections/ij-001.m4a")
        XCTAssertEqual(interjection.transcriptionStatus, "pending")
        XCTAssertEqual(transcriber.scheduledInterjectionIds, [interjection.id])
        XCTAssertEqual(engine.lastScheduledTranscriptionInterjectionId, interjection.id)
    }

    func testWrittenInterjectionPreservesExactTextAndUsesNoAudioCaptureServices() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-written", title: "Written", mediaType: "text", text: "First sentence. Second sentence.", externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let recorder = CountingRecordingClient()
        let transcriber = RecordingTranscriptionClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio, recorder: recorder, transcriber: transcriber)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = "First sentence. ".count
        let capture = try engine.beginWrittenInterjection()
        XCTAssertTrue(capture.wasPlaying)
        XCTAssertEqual(capture.targetType, .item)
        XCTAssertEqual(capture.anchor.anchorBefore, "First sentence.")
        XCTAssertThrowsError(try engine.stopPlayback())
        XCTAssertThrowsError(try engine.beginInterjection())

        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: " Keep  this exact thought. ")

        let note = try XCTUnwrap(try repo.loadInterjections(sessionId: capture.sessionId).first)
        XCTAssertEqual(note.captureKind, .written)
        XCTAssertNil(note.audioPath)
        XCTAssertEqual(note.audioStatus, "discarded")
        XCTAssertEqual(note.transcriptionStatus, "transcribed")
        XCTAssertEqual(note.transcript, " Keep  this exact thought. ")
        XCTAssertEqual(note.displayText, " Keep  this exact thought. ")
        XCTAssertEqual(recorder.beginCount, 0)
        XCTAssertEqual(recorder.finishCount, 0)
        XCTAssertEqual(recorder.cancelCount, 0)
        XCTAssertTrue(transcriber.scheduledInterjectionIds.isEmpty)
        XCTAssertEqual(audio.playedOffsets.last, "First sentence. ".count)
    }

    func testWrittenInterjectionCancelKeepsAPrepausedSourcePausedAndRejectsStaleRequests() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
        )
        let item = Item(id: "item-written-paused", title: "Written", mediaType: "text", text: "A source sentence.", externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.pause()
        let playCountBeforeCapture = audio.playedTargets.count
        let capture = try engine.beginWrittenInterjection()
        XCTAssertFalse(capture.wasPlaying)
        XCTAssertThrowsError(try engine.cancelWrittenInterjection(captureId: "stale"))
        _ = try engine.cancelWrittenInterjection(captureId: capture.id)

        XCTAssertEqual(try repo.loadInterjections(sessionId: capture.sessionId).count, 0)
        XCTAssertEqual(audio.playedTargets.count, playCountBeforeCapture)
        XCTAssertEqual(engine.snapshot.status, .paused)
        XCTAssertThrowsError(try engine.cancelWrittenInterjection(captureId: capture.id))
    }

    func testWrittenInterjectionOnExternallyStreamedTurnKeepsGeneratedAnchorAndDoesNotDoublePlay() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-written-stream", title: "Written stream", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-written-stream", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.aiStreamDelta(turnId: "turn-written-stream", content: "First response. Second point has the detail.")
        _ = try engine.activateStreamingTurn(turnId: "turn-written-stream")
        let offset = "First response. ".count
        _ = try engine.updateStreamingTurnPosition(turnId: "turn-written-stream", charOffset: offset)
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A generated-margin note.")

        let note = try XCTUnwrap(try repo.loadInterjections(sessionId: session.id).first)
        XCTAssertEqual(note.targetType, .assistantTurn)
        XCTAssertEqual(note.targetId, "turn-written-stream")
        XCTAssertEqual(note.anchor.anchorType, .turn)
        XCTAssertEqual(note.anchor.startChar, offset)
        XCTAssertEqual(engine.snapshot.status, .starting)
        XCTAssertTrue(audio.playedTargets.isEmpty)
    }

    func testTranscriptlessMediaWrittenInterjectionDoesNotClaimReadySourceContext() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
        )
        let item = Item(
            id: "item-written-media",
            title: "Written media",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 123_000
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A media-margin note.")

        let note = try XCTUnwrap(try repo.loadInterjections(sessionId: capture.sessionId).first)
        XCTAssertEqual(note.audioStatus, "discarded")
        XCTAssertEqual(note.anchor.anchorType, .media)
        XCTAssertEqual(note.anchorContextStatus, .unavailable, "No transcription or context job is scheduled for written capture")
    }

    func testWrittenInterjectionRejectsDoubleSaveWithoutCreatingADuplicate() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
        )
        let item = Item(id: "item-written-once", title: "Written once", mediaType: "text", text: "A source sentence.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        let capture = try engine.beginWrittenInterjection()
        XCTAssertThrowsError(try engine.saveWrittenInterjection(captureId: "stale", text: "Note"))
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Note")
        XCTAssertThrowsError(try engine.saveWrittenInterjection(captureId: capture.id, text: "Note"))
        XCTAssertEqual(try repo.loadInterjections(sessionId: capture.sessionId).map(\.id), ["ij-written-\(capture.id)"])
    }

    func testWrittenInterjectionRetainsItsCaptureAfterStoreFailureAndWritesOnceOnRetry() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
        )
        let item = Item(id: "item-written-retry", title: "Written retry", mediaType: "text", text: "A source sentence.", externalReference: nil, status: "ready")
        let repo = FailingWrittenInterjectionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        let capture = try engine.beginWrittenInterjection()
        repo.failNextInterjectionSave = true
        XCTAssertThrowsError(try engine.saveWrittenInterjection(captureId: capture.id, text: "Retry this exact text."))
        XCTAssertEqual(try repo.loadInterjections(sessionId: capture.sessionId).count, 0)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Retry this exact text.")

        XCTAssertEqual(try repo.loadInterjections(sessionId: capture.sessionId).map(\.transcript), ["Retry this exact text."])
        XCTAssertThrowsError(try engine.saveWrittenInterjection(captureId: capture.id, text: "Retry this exact text."))
    }

    func testWrittenInterjectionBeginFailureRestoresPlayingSourceWithoutCreatingADraft() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
        )
        let item = Item(id: "item-written-begin-failure", title: "Written begin failure", mediaType: "text", text: "A source sentence.", externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let repo = FailingWrittenInterjectionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        repo.failNextSessionSave = true
        XCTAssertThrowsError(try engine.beginWrittenInterjection())
        XCTAssertEqual(engine.snapshot.status, .playing)
        XCTAssertEqual(audio.playedTargets.last, item.id)

        let capture = try engine.beginWrittenInterjection()
        _ = try engine.cancelWrittenInterjection(captureId: capture.id)
    }

    func testWrittenInterjectionCommitDoesNotRemainRetryableWhenResumeFails() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
        )
        let item = Item(id: "item-written-resume-failure", title: "Written resume failure", mediaType: "text", text: "A source sentence.", externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        let capture = try engine.beginWrittenInterjection()
        audio.failNextPlay = true
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Committed before transport recovery.")

        XCTAssertEqual(try repo.loadInterjections(sessionId: capture.sessionId).count, 1)
        XCTAssertEqual(engine.snapshot.status, .paused)
        XCTAssertThrowsError(try engine.saveWrittenInterjection(captureId: capture.id, text: "Committed before transport recovery."))
        _ = try engine.stopPlayback()
    }

    func testSessionQualifiedCleanupAndDeletionDoNotMutateSameIDMarginInAnotherSQLiteSession() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-scoped-margin", title: "Scoped", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let first = Session(id: "session-scoped-A", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let second = Session(id: "session-scoped-B", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        func margin(sessionId: String, transcript: String, cleaned: String?) -> Interjection {
            Interjection(
                id: "same-margin-id", itemId: item.id, sessionId: sessionId,
                targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1),
                roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
                audioPath: "interjections/\(sessionId).m4a", audioStatus: "saved", transcriptionStatus: "transcribed",
                transcript: transcript, cleanedTranscript: cleaned, displayText: cleaned ?? transcript, status: "active"
            )
        }
        try store.saveItem(item)
        try store.saveSession(first)
        try store.saveSession(second)
        try store.saveInterjection(margin(sessionId: first.id, transcript: "First original", cleaned: "First cleaned"))
        try store.saveInterjection(margin(sessionId: second.id, transcript: "Second original", cleaned: nil))
        let engine = SessionEngine(profile: phonePlaybackProfile(), repository: store)

        _ = try engine.cleanupCompleted(interjectionId: "same-margin-id", sessionId: second.id, cleanedTranscript: "Second cleaned")
        XCTAssertEqual(try store.loadInterjections(sessionId: first.id).first?.cleanedTranscript, "First cleaned")
        XCTAssertEqual(try store.loadInterjections(sessionId: second.id).first?.cleanedTranscript, "Second cleaned")

        _ = try engine.deleteRepresentation(interjectionId: "same-margin-id", sessionId: second.id, representation: "transcript")
        XCTAssertEqual(try store.loadInterjections(sessionId: first.id).first?.transcript, "First original")
        XCTAssertNil(try store.loadInterjections(sessionId: second.id).first?.transcript)

        _ = try engine.deleteInterjection(interjectionId: "same-margin-id", sessionId: second.id)
        XCTAssertEqual(try store.loadInterjections(sessionId: first.id).first?.status, "active")
        XCTAssertEqual(try store.loadInterjections(sessionId: second.id).first?.status, "deleted")

        XCTAssertThrowsError(try engine.cleanupCompleted(interjectionId: "same-margin-id", sessionId: "unknown-session", cleanedTranscript: "must not fallback"))
        XCTAssertEqual(try store.loadInterjections(sessionId: first.id).first?.cleanedTranscript, "First cleaned")
    }

    func testPlayInterjectionAnchorSwitchesToForeignTextSessionAtSavedOffset() throws {
        let profile = phonePlaybackProfile()
        let oldItem = Item(id: "item-anchor-old", title: "Old", mediaType: "text", text: "Old source text.", externalReference: nil, status: "ready")
        let targetItem = Item(id: "item-anchor-target", title: "Target", mediaType: "text", text: "First sentence. Second sentence.", externalReference: nil, status: "ready")
        let oldSession = Session(id: "session-anchor-old", itemId: oldItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: oldItem.id, position: Position(charOffset: 3), completionPercent: 20, playbackRate: 1)
        let targetSession = Session(id: "session-anchor-target", itemId: targetItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: targetItem.id, position: Position(charOffset: 2), completionPercent: 10, playbackRate: 1)
        let note = Interjection(id: "ij-anchor-text", itemId: targetItem.id, sessionId: targetSession.id, targetType: .item, targetId: targetItem.id, createdAt: Date(), roughPercent: 50, anchor: Anchor(anchorType: .text, startChar: "First sentence. ".count, endChar: targetItem.text!.count, anchorBefore: "First sentence.", anchorAfter: "Second sentence."), audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: "Note", status: "active")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [oldItem.id: oldItem, targetItem.id: targetItem], sessions: [oldSession.id: oldSession, targetSession.id: targetSession], interjections: [note.id: note])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: oldSession.id)
        _ = try engine.resumePlayback()
        let snapshot = try engine.playInterjectionAnchor(note)

        XCTAssertEqual(snapshot.sessionId, targetSession.id)
        XCTAssertEqual(snapshot.itemId, targetItem.id)
        XCTAssertEqual(audio.playedTargets.last, targetItem.id)
        XCTAssertEqual(audio.playedOffsets.last, "First sentence. ".count)
    }

    func testPlayInterjectionAnchorRejectsInvalidForeignAnchorWithoutChangingCurrentPlayback() throws {
        let profile = phonePlaybackProfile()
        let oldItem = Item(id: "item-anchor-invalid-old", title: "Old", mediaType: "text", text: "Old source text.", externalReference: nil, status: "ready")
        let targetItem = Item(id: "item-anchor-invalid-target", title: "Target", mediaType: "text", text: "Short.", externalReference: nil, status: "ready")
        let oldSession = Session(id: "session-anchor-invalid-old", itemId: oldItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: oldItem.id, position: Position(charOffset: 3), completionPercent: 20, playbackRate: 1)
        let targetSession = Session(id: "session-anchor-invalid-target", itemId: targetItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: targetItem.id, position: Position(charOffset: 2), completionPercent: 10, playbackRate: 1)
        let note = Interjection(id: "ij-anchor-invalid", itemId: targetItem.id, sessionId: targetSession.id, targetType: .item, targetId: targetItem.id, createdAt: Date(), roughPercent: 50, anchor: Anchor(anchorType: .text, startChar: 99, endChar: 100, anchorBefore: "", anchorAfter: ""), audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: "Note", status: "active")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [oldItem.id: oldItem, targetItem.id: targetItem], sessions: [oldSession.id: oldSession, targetSession.id: targetSession], interjections: [note.id: note])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: oldSession.id)
        _ = try engine.resumePlayback()
        XCTAssertThrowsError(try engine.playInterjectionAnchor(note))

        XCTAssertEqual(engine.currentSession?.id, oldSession.id)
        XCTAssertEqual(engine.snapshot.status, .playing)
        XCTAssertEqual(audio.playedTargets.last, oldItem.id)
        XCTAssertEqual(try repo.loadSession(id: targetSession.id)?.position.charOffset, 2)
    }

    func testPlayInterjectionAnchorRestoresOldSessionAndForeignPersistenceAfterAdapterFailure() throws {
        let profile = phonePlaybackProfile()
        let oldItem = Item(id: "item-anchor-rollback-old", title: "Old", mediaType: "text", text: "Old source text.", externalReference: nil, status: "ready")
        let targetItem = Item(id: "item-anchor-rollback-target", title: "Target", mediaType: "text", text: "First. Second.", externalReference: nil, status: "ready")
        let oldSession = Session(id: "session-anchor-rollback-old", itemId: oldItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: oldItem.id, position: Position(charOffset: 3), completionPercent: 20, playbackRate: 1)
        let targetSession = Session(id: "session-anchor-rollback-target", itemId: targetItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: targetItem.id, position: Position(charOffset: 4), completionPercent: 30, playbackRate: 1)
        let note = Interjection(id: "ij-anchor-rollback", itemId: targetItem.id, sessionId: targetSession.id, targetType: .item, targetId: targetItem.id, createdAt: Date(), roughPercent: 50, anchor: Anchor(anchorType: .text, startChar: 7, endChar: 13, anchorBefore: "First.", anchorAfter: "Second."), audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: "Note", status: "active")
        let audio = RecordingAudioClient()
        let repo = FailingWrittenInterjectionRepository(items: [oldItem.id: oldItem, targetItem.id: targetItem], sessions: [oldSession.id: oldSession, targetSession.id: targetSession], interjections: [note.id: note])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: oldSession.id)
        _ = try engine.resumePlayback()
        repo.failNextSessionSave = true
        XCTAssertThrowsError(try engine.playInterjectionAnchor(note))
        XCTAssertEqual(engine.currentSession?.id, oldSession.id)
        XCTAssertEqual(try repo.loadSession(id: targetSession.id)?.position.charOffset, 4)
        audio.failNextPlay = true
        XCTAssertThrowsError(try engine.playInterjectionAnchor(note))

        XCTAssertEqual(engine.currentSession?.id, oldSession.id)
        XCTAssertEqual(engine.snapshot.status, .playing)
        XCTAssertEqual(try repo.loadSession(id: targetSession.id)?.position.charOffset, 4)
        XCTAssertEqual(audio.playedTargets.last, oldItem.id)
    }

    func testPlayInterjectionAnchorStartsMediaAndPreparedTextAtSavedMediaTime() throws {
        let profile = RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media", "prerendered_audio"]])
        let mediaItem = Item(id: "item-anchor-media", title: "Media", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil, externalReference: nil, status: "ready", media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/media.mp3", durationMs: 10_000))
        let preparedItem = Item(id: "item-anchor-prepared", title: "Prepared", mediaType: TargetType.transcriptBackedMedia.rawValue, text: "Prepared narration.", externalReference: nil, status: "ready", media: ItemMedia(sourceType: .generatedTTSPrerendered, url: "memory://prepared", durationMs: 10_000))
        let mediaSession = Session(id: "session-anchor-media", itemId: mediaItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: "old-media", position: Position(mediaTimeMs: 100), completionPercent: 1, playbackRate: 1)
        let preparedSession = Session(id: "session-anchor-prepared", itemId: preparedItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: "old-prepared", position: Position(mediaTimeMs: 200), completionPercent: 2, playbackRate: 1)
        let mediaNote = Interjection(id: "ij-anchor-media", itemId: mediaItem.id, sessionId: mediaSession.id, targetType: .item, targetId: mediaItem.id, createdAt: Date(), roughPercent: 50, anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 5_000), audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: "Note", status: "active")
        let preparedNote = Interjection(id: "ij-anchor-prepared", itemId: preparedItem.id, sessionId: preparedSession.id, targetType: .item, targetId: preparedItem.id, createdAt: Date(), roughPercent: 60, anchor: Anchor(anchorType: .media, startChar: 4, endChar: 9, anchorBefore: "", anchorAfter: "", mediaTimeMs: 6_000), audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: "Note", status: "active")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [mediaItem.id: mediaItem, preparedItem.id: preparedItem], sessions: [mediaSession.id: mediaSession, preparedSession.id: preparedSession], interjections: [mediaNote.id: mediaNote, preparedNote.id: preparedNote])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playInterjectionAnchor(mediaNote)
        XCTAssertEqual(audio.playedTargets.last, mediaItem.media?.url)
        XCTAssertEqual(audio.playedOffsets.last, 5_000)
        _ = try engine.playInterjectionAnchor(preparedNote)
        XCTAssertEqual(audio.playedTargets.last, preparedItem.media?.url)
        XCTAssertEqual(audio.playedOffsets.last, 6_000)
    }

    /// A podcast in progress at 5% with a voice Margin at 2:00, as Build 29 left it.
    private func podcastMarginFixture(durationMs: Int?) -> (item: Item, session: Session, note: Interjection) {
        let item = Item(id: "item-podcast-293", title: "The Daily", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil, externalReference: nil, status: "ready", media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/daily.mp3", durationMs: durationMs))
        let session = Session(id: "session-podcast-293", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: "https://cdn.example.com/daily.mp3", position: Position(mediaTimeMs: 90_000), completionPercent: 5, playbackRate: 1)
        let note = Interjection(id: "ij-001", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(), roughPercent: 5, anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 120_000), audioPath: "ij-001.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: "Note", status: "active")
        return (item, session, note)
    }

    func testPlayThisMomentOnAPodcastWithNoKnownDurationDoesNotCompleteIt() throws {
        // #293: after the Build 29 upgrade no player had a duration yet, and an unknown
        // duration fell back to the seek target itself, so 2:00 of 2:00 was 100% and
        // persistSession stamped the episode completed.
        let (item, session, note) = podcastMarginFixture(durationMs: nil)
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [note.id: note])
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]), repository: repo, audio: audio)

        _ = try engine.playInterjectionAnchor(note)

        XCTAssertEqual(audio.playedOffsets.last, 120_000, "the moment still plays")
        XCTAssertNil(try repo.loadItem(id: item.id).sourceCompletedAt, "the episode is not completed")
        XCTAssertLessThanOrEqual(try XCTUnwrap(repo.loadSession(id: session.id)).completionPercent, 98)
    }

    func testAMomentAtTheVeryEndOfAKnownLengthEpisodeStillCompletesIt() throws {
        // #293 must not break completion: with the length known, 59:30 of 60:00 is 99%.
        var (item, session, note) = podcastMarginFixture(durationMs: 3_600_000)
        note.anchor.mediaTimeMs = 3_570_000
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [note.id: note])
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]), repository: repo, audio: RecordingAudioClient())

        _ = try engine.playInterjectionAnchor(note)

        XCTAssertEqual(try XCTUnwrap(repo.loadSession(id: session.id)).completionPercent, 99)
        XCTAssertNotNil(try repo.loadItem(id: item.id).sourceCompletedAt)
    }

    func testAMomentInTheLastSecondOfAStaleShortStoredLengthStillPlays() throws {
        // #2414: the stored length is truncated to whole seconds (#2189), so up to 999 ms under the real file.
        // A Margin recorded in that last stretch used to be refused as past the end.
        var (item, session, note) = podcastMarginFixture(durationMs: 3_600_000)
        note.anchor.mediaTimeMs = 3_600_999
        var beyond = note
        beyond.id = "ij-beyond"
        beyond.anchor.mediaTimeMs = 3_601_000
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [note.id: note, beyond.id: beyond])
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]), repository: repo, audio: audio)

        _ = try engine.playInterjectionAnchor(note)
        XCTAssertEqual(audio.playedOffsets.last, 3_600_000, "it plays from the end of the stored length")

        // #293: a Margin well past the real end stays refused.
        XCTAssertThrowsError(try engine.playInterjectionAnchor(beyond))
    }

    func testPlayThisMomentUsesThePodcastsOwnDurationNotThePlayingItems() throws {
        // #293: the anchor was planned before currentItem became the podcast, so the
        // duration came from whatever was playing: a text item (none, so the fallback
        // above) or another episode (its shorter length clamped 45:00 to 100%).
        let (item, session, note) = podcastMarginFixture(durationMs: 3_600_000)
        let text = Item(id: "item-text-293", title: "Article", mediaType: "text", text: "An article being read aloud.", externalReference: nil, status: "ready")
        let shortEpisode = Item(id: "item-short-293", title: "Short", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil, externalReference: nil, status: "ready", media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/short.mp3", durationMs: 1_200_000))
        var lateNote = note
        lateNote.id = "ij-002"
        lateNote.anchor.mediaTimeMs = 2_700_000
        for (playing, marginAt, noteToPlay) in [(text, 120_000, note), (shortEpisode, 2_700_000, lateNote)] {
            let audio = RecordingAudioClient()
            let repo = InMemorySessionRepository(items: [item.id: item, playing.id: playing], sessions: [session.id: session], interjections: [note.id: note, lateNote.id: lateNote])
            let engine = SessionEngine(profile: phonePlaybackProfile(), repository: repo, audio: audio)
            _ = try engine.startSession(itemId: playing.id)
            audio.currentDurationMs = playing.media?.durationMs

            _ = try engine.playInterjectionAnchor(noteToPlay)

            XCTAssertEqual(audio.playedOffsets.last, marginAt, playing.title)
            XCTAssertNil(try repo.loadItem(id: item.id).sourceCompletedAt, "\(playing.title) was playing: the episode is not completed")
            XCTAssertEqual(try XCTUnwrap(repo.loadSession(id: session.id)).completionPercent, marginAt * 100 / 3_600_000, playing.title)
        }
    }

    func testPlayInterjectionAnchorStartsGeneratedTurnAtSavedOffset() throws {
        let profile = phonePlaybackProfile()
        let item = Item(id: "item-anchor-turn", title: "Turn", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-anchor-turn", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-anchor-response", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief.", text: "First response. Second response.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let offset = "First response. ".count
        let note = Interjection(id: "ij-anchor-turn", itemId: item.id, sessionId: session.id, targetType: .assistantTurn, targetId: turn.id, createdAt: Date(), roughPercent: 50, anchor: Anchor(anchorType: .turn, startChar: offset, endChar: turn.text!.count, anchorBefore: "First response.", anchorAfter: "Second response."), audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: "Note", status: "active")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [note.id: note], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playInterjectionAnchor(note)

        XCTAssertEqual(engine.snapshot.targetType, TargetType.assistantTurnTTS.rawValue)
        XCTAssertEqual(audio.playedTargets.last, turn.id)
        XCTAssertEqual(audio.playedOffsets.last, "Brief.\n\n".count + offset)
    }

    func testExplicitSessionAsyncMarginUpdateDoesNotCrossMutateCollidingSQLiteNoteIDs() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-anchor-collision-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let firstItem = Item(id: "item-anchor-collision-one", title: "One", mediaType: "text", text: "One.", externalReference: nil, status: "ready")
        let secondItem = Item(id: "item-anchor-collision-two", title: "Two", mediaType: "text", text: "Two.", externalReference: nil, status: "ready")
        let firstSession = Session(id: "session-anchor-collision-one", itemId: firstItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: firstItem.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let secondSession = Session(id: "session-anchor-collision-two", itemId: secondItem.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: secondItem.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let firstNote = Interjection(id: "shared-note-id", itemId: firstItem.id, sessionId: firstSession.id, targetType: .item, targetId: firstItem.id, createdAt: Date(), roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""), audioPath: "one.m4a", audioStatus: "saved", transcriptionStatus: "pending", transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active")
        let secondNote = Interjection(id: "shared-note-id", itemId: secondItem.id, sessionId: secondSession.id, targetType: .item, targetId: secondItem.id, createdAt: Date(timeIntervalSince1970: 2), roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""), audioPath: "two.m4a", audioStatus: "saved", transcriptionStatus: "pending", transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active")
        try store.saveItem(firstItem)
        try store.saveItem(secondItem)
        try store.saveSession(firstSession)
        try store.saveSession(secondSession)
        try store.saveInterjection(firstNote)
        try store.saveInterjection(secondNote)
        let engine = SessionEngine(profile: phonePlaybackProfile(), repository: store)

        _ = try engine.transcriptionCompleted(interjectionId: "shared-note-id", sessionId: secondSession.id, transcript: "Only second updates.")

        XCTAssertNil(try store.loadInterjections(sessionId: firstSession.id).first?.transcript)
        XCTAssertEqual(try store.loadInterjections(sessionId: secondSession.id).first?.transcript, "Only second updates.")
    }

    func testRecordingInterjectionIgnoresPausedSpeechCompletion() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let text = "One. Two. Three."
        let item = Item(id: "item-interject-pause-complete", title: "Pause Complete", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        audio.completeActiveTargetOnPause = true
        audio.completionOffsetOnPause = text.count
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = "One. ".count
        _ = try engine.beginInterjection()
        let recording = try engine.syncPlaybackProgress()
        _ = try engine.finishInterjection(audioRef: "interjections/ij-001.m4a")

        XCTAssertEqual(recording.status, .recording)
        XCTAssertLessThan(recording.sourceProgressPercent, 100)
        XCTAssertLessThan(engine.currentSession?.position.charOffset ?? text.count, text.count)
        XCTAssertEqual(audio.playedOffsets.last, "One. ".count)
    }

    func testPlayTurnPreparesTurnTextInsteadOfReusingItemText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "summary_turn_tts", "assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Original item text.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let summary = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary text should be spoken.", rawText: nil, sourceInterjectionIds: [])
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Response text should be spoken.", rawText: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [summary.id: summary, response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: summary.id)
        XCTAssertEqual(audio.preparedTexts.last, "Summary text should be spoken.")
        XCTAssertEqual(engine.snapshot.targetType, "summary_turn_tts")

        _ = try engine.playTurn(turnId: response.id)
        XCTAssertEqual(audio.preparedTexts.last, "Response text should be spoken.")
        XCTAssertEqual(engine.snapshot.targetType, "assistant_turn_tts")
    }

    func testJumpToChapterFromSummaryPlaybackReturnsToItemText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "summary_turn_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let map = ListeningMap(id: "map-pill", itemId: item.id, overview: "Map", chapters: [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: 5, percent: 0),
            Chapter(id: "ch-2", title: "Two", startChar: 5, endChar: 16, percent: 31)
        ])
        let summary = ConversationTurn(id: "turn-summary-001", sessionId: "session-\(item.id)-gate1-001", role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary text.", rawText: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map], turns: [summary.id: summary])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.playTurn(turnId: summary.id)
        let snapshot = try engine.jumpToChapter(chapterId: "ch-2")

        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(audio.preparedTexts.last, "Overview. Map\n\nOne. Two. Three.")
        XCTAssertEqual(audio.playedOffsets.last, "Overview. Map\n\n".count + 5)
    }

    /// #356: the first spoken unit of a fresh start is the item's title, including for a map an
    /// older build stored with the "Structured into … listening chapters" sentence.
    func testFreshStartSpeaksTheTitleFirstEvenForAStoredLegacyOverview() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-agents", title: "Evaluation Agents", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let chapters = [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: 5, percent: 0),
            Chapter(id: "ch-2", title: "Two", startChar: 5, endChar: 16, percent: 31)
        ]
        for overview in [
            "Structured into 2 listening chapters from canonical document headings in Evaluation Agents.",
            ListeningMapOverviewText.appGenerated(title: item.title, chapterCount: chapters.count)
        ] {
            let map = ListeningMap(id: "map-agents", itemId: item.id, overview: overview, chapters: chapters)
            let audio = RecordingAudioClient()
            let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
            let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

            _ = try engine.startSession(itemId: item.id)

            let spoken = try XCTUnwrap(audio.preparedTexts.last, overview)
            XCTAssertEqual(spoken, "Evaluation Agents. 2 chapters.\n\nOne. Two. Three.", overview)
            XCTAssertEqual(spoken.components(separatedBy: ". ").first, "Evaluation Agents", "the first spoken unit is the title")
        }
    }

    /// #1144: a text that opens with its own title (a PDF's printed title) is not preceded by the
    /// title again; the preface says only the chapter count, and offsets still line up with it.
    func testFreshStartSkipsTheTitleInThePrefaceWhenTheTextOpensWithIt() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let text = "Evaluation Agents\nOne. Two."
        let item = Item(id: "item-agents", title: "Evaluation Agents", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let chapters = [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: 22, percent: 0),
            Chapter(id: "ch-2", title: "Two", startChar: 22, endChar: 27, percent: 81)
        ]
        let map = ListeningMap(
            id: "map-agents",
            itemId: item.id,
            overview: ListeningMapOverviewText.appGenerated(title: item.title, chapterCount: chapters.count),
            chapters: chapters
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.preparedTexts.last, "2 chapters.\n\n\(text)")

        _ = try engine.jumpToChapter(chapterId: "ch-2")
        XCTAssertEqual(audio.playedOffsets.last, "2 chapters.\n\n".count + 22)
    }

    func testInspectSessionDoesNotStartPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let session = Session(id: "session-existing", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: 5), completionPercent: 45, playbackRate: 1)
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        let snapshot = try engine.inspectSession(sessionId: session.id)

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.progressPercent, 45)
        XCTAssertEqual(snapshot.targetId, item.id)
        XCTAssertTrue(audio.playedOffsets.isEmpty)
    }

    func testInterjectionsOnAssistantTurnCanBeSummarizedAfterItemSummary() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "assistant_turn_tts"],
                "interjection": ["record_audio"],
                "ai": ["summarize_interjections"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Assistant response text.", rawText: nil, sourceInterjectionIds: [])
        let itemInterjection = Interjection(id: "ij-item", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "One.", anchorAfter: "Two."), audioPath: "item.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "item note", cleanedTranscript: nil, displayText: "item note", status: "active")
        let turnInterjection = Interjection(id: "ij-turn", itemId: item.id, sessionId: session.id, targetType: .assistantTurn, targetId: response.id, createdAt: Date(timeIntervalSince1970: 2), roughPercent: 0, anchor: Anchor(anchorType: .turn, startChar: 0, endChar: 8, anchorBefore: "Assistant response text.", anchorAfter: ""), audioPath: "turn.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "turn note", cleanedTranscript: nil, displayText: "turn note", status: "active")
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [itemInterjection.id: itemInterjection, turnInterjection.id: turnInterjection], turns: [response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "turn", sessionId: session.id, turnId: response.id))

        let summaries = try repo.loadTurns(sessionId: session.id).filter { $0.turnType == "interjection_summary" }.sorted { $0.id < $1.id }
        XCTAssertEqual(summaries.map(\.sourceInterjectionIds), [["ij-item"], ["ij-turn"]])
        XCTAssertEqual(summaries.map(\.id), ["turn-summary-001", "turn-summary-002"])
    }

    func testInterjectionSummaryRegenerationRequiresNewInterjectionAndReplacesCurrentTargetSummary() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "ai": ["summarize_interjections"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let firstInterjection = Interjection(id: "ij-001", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "One.", anchorAfter: "Two."), audioPath: "one.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "first note", cleanedTranscript: nil, displayText: "first note", status: "active")
        let secondInterjection = Interjection(id: "ij-002", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 2), roughPercent: 25, anchor: Anchor(anchorType: .text, startChar: 5, endChar: 9, anchorBefore: "Two.", anchorAfter: "Three."), audioPath: "two.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "second note", cleanedTranscript: nil, displayText: "second note", status: "active")
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [firstInterjection.id: firstInterjection])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))
        var interruptedSummary = try XCTUnwrap(try repo.loadTurns(sessionId: session.id).first { $0.id == "turn-summary-001" })
        interruptedSummary.status = "failed_partial"
        try repo.saveTurn(interruptedSummary)

        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))
        XCTAssertEqual(try repo.loadTurns(sessionId: session.id).first { $0.id == "turn-summary-001" }?.status, "pending")

        _ = try engine.aiStreamDelta(turnId: "turn-summary-001", content: "<sm_response>Current summary.</sm_response>")
        _ = try engine.aiJobCompleted(turnId: "turn-summary-001")
        XCTAssertThrowsError(try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("interjection_summary_already_current"))
        }

        try repo.saveInterjection(secondInterjection)
        _ = try engine.aiStreamDelta(turnId: "turn-summary-001", content: "<sm_response>Old summary.</sm_response>")
        _ = try engine.aiJobCompleted(turnId: "turn-summary-001")
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))

        let summaries = try repo.loadTurns(sessionId: session.id).filter { $0.turnType == "interjection_summary" }
        XCTAssertEqual(summaries.map(\.id), ["turn-summary-001"])
        XCTAssertEqual(summaries.first?.sourceInterjectionIds, ["ij-001", "ij-002"])
        XCTAssertEqual(summaries.first?.status, "pending")
        XCTAssertNil(summaries.first?.text)
    }

    func testCancelInterjectionDoesNotCreateInterjectionAndResumes() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.beginInterjection()
        let snapshot = try engine.cancelInterjection()

        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(try repo.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).count, 0)
    }

    func testRepeatedStartsCreateDistinctSessionsForSameItem() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        let first = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.startSession(itemId: item.id)
        let second = try XCTUnwrap(engine.currentSession?.id)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set(repo.sessions.keys), [first, second])
    }

    func testRepeatedFollowupsCreateDistinctAssistantTurnsAndJobs() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "ai": ["continue_discussion"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.submitFollowup(text: "First")
        _ = try engine.submitFollowup(text: "Second")

        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        let responseTurns = try repo.loadTurns(sessionId: sessionId).filter { $0.turnType == "assistant_response" }.map(\.id).sorted()
        let jobs = try repo.loadAIJobs(sessionId: sessionId).filter { $0.kind == "assistant_response" }.map(\.id).sorted()
        XCTAssertEqual(responseTurns, ["turn-response-001", "turn-response-002"])
        XCTAssertEqual(jobs, ["job-assistant-response-001", "job-assistant-response-002"])
    }

    func testAssistantPlayableTextSpeaksSummaryBeforeResponse() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: "Full response.", rawText: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: response.id)

        XCTAssertEqual(audio.preparedTexts.last, "Brief intro.\n\nFull response.")
        XCTAssertEqual(audio.playedOffsets.last, 0)
    }

    func testAICompletionParsesSummaryResponseAndChapters() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: "<sm_summary>Two parts.</sm_summary><sm_response>Hello world. Second point.</sm_response><sm_chapters_json>{\"schemaVersion\":\"assistant-response-map.v1\",\"chapters\":[{\"id\":\"ch-1\",\"title\":\"Opening\",\"anchor\":\"Hello world.\"}]}</sm_chapters_json>"
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")

        let turn = try XCTUnwrap(try repo.loadTurns(sessionId: session.id).first)
        XCTAssertEqual(turn.summary, "Two parts.")
        XCTAssertEqual(turn.text, "Hello world. Second point.")
        XCTAssertEqual(turn.chapters?.first?.id, "ch-1")
    }

    func testAIStreamingEmitsEachStableSentenceOnceAndFlushesFinalFragment() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"]]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo)

        let first = try engine.aiStreamDelta(turnId: "turn-response-stream", content: "First sentence. Final")
        let second = try engine.aiStreamDelta(turnId: "turn-response-stream", content: " fragment")
        let completed = try engine.aiJobCompleted(turnId: "turn-response-stream")

        XCTAssertEqual(first.spokenUnits, ["First sentence."])
        XCTAssertTrue(second.spokenUnits.isEmpty)
        XCTAssertEqual(completed.spokenUnits, ["Final fragment"])
        XCTAssertEqual(try repo.loadTurns(sessionId: session.id).first?.text, "First sentence. Final fragment")
    }

    func testStreamingTurnPausesPriorAudioAndFinishesAtItsOwnEnd() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-stream", title: "Stream", mediaType: "text", text: "Source text continues.", externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 7
        _ = try engine.aiStreamDelta(turnId: "turn-response-stream", content: "First response. Final fragment")
        let active = try engine.activateStreamingTurn(turnId: "turn-response-stream")
        let stillStarting = try engine.syncPlaybackProgress()
        let observed = try engine.streamingTurnPlaybackStarted(turnId: "turn-response-stream", charOffset: 0)
        _ = try engine.aiJobCompleted(turnId: "turn-response-stream")
        let finished = try engine.finishStreamingTurnPlayback(turnId: "turn-response-stream")

        XCTAssertEqual(audio.pauseCount, 1)
        XCTAssertEqual(active.targetId, "turn-response-stream")
        XCTAssertEqual(active.status, .starting)
        XCTAssertEqual(stillStarting.status, .starting)
        XCTAssertEqual(observed.status, .playing)
        XCTAssertEqual(finished.status, .paused)
        XCTAssertEqual(finished.phase, .aiResponsePlayback)
        XCTAssertEqual(finished.currentPlaybackProgressPercent, 100)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(engine.currentSession?.position.charOffset, "First response. Final fragment".count)
    }

    func testCompactControlsCanonicallyPauseAndResumeStreamingAssistantPlayback() throws {
        let runtimeProfile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "assistant_turn_tts"]
            ]
        )
        let compactProfile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen",
            capabilities: [
                "remoteControl": ["display_snapshot", "send_transport_commands"],
                "timeline": ["playback_rate_observation"]
            ]
        )
        let item = Item(
            id: "item-stream-compact",
            title: "Stream Compact",
            mediaType: "text",
            text: "Source text.",
            externalReference: nil,
            status: "ready"
        )
        let audio = RecordingAudioClient()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: runtimeProfile, repository: repository, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        _ = try engine.aiStreamDelta(turnId: "turn-stream-compact", content: "A streamed assistant response.")
        _ = try engine.activateStreamingTurn(turnId: "turn-stream-compact")
        _ = try engine.streamingTurnPlaybackStarted(turnId: "turn-stream-compact", charOffset: 4)
        let dispatcher = CompactControlDispatcher(surfaceProfile: compactProfile, canonicalRuntime: engine)

        let paused = try dispatcher.dispatch(.pause)

        XCTAssertEqual(paused.snapshot.targetType, TargetType.assistantTurnTTS.rawValue)
        XCTAssertEqual(paused.snapshot.targetId, "turn-stream-compact")
        XCTAssertEqual(paused.snapshot.status, .paused)
        XCTAssertEqual(engine.snapshot.status, .paused)
        XCTAssertTrue(paused.snapshot.availableCommands.contains(.play))

        let resumed = try dispatcher.dispatch(.play)

        XCTAssertEqual(resumed.snapshot.status, .playing)
        XCTAssertEqual(engine.snapshot.status, .playing)
        XCTAssertTrue(resumed.snapshot.availableCommands.contains(.pause))
    }

    func testInterjectionDuringExternallyStreamedSpeechTargetsCurrentAssistantSentenceWithoutDoubleResume() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-stream", title: "Stream", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-stream", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.aiStreamDelta(turnId: "turn-response-stream", content: "First response. Second point has the detail.")
        _ = try engine.activateStreamingTurn(turnId: "turn-response-stream")
        let secondSentenceStart = "First response. ".count
        _ = try engine.updateStreamingTurnPosition(turnId: "turn-response-stream", charOffset: secondSentenceStart)
        _ = try engine.beginInterjection()
        let resumed = try engine.finishInterjection(audioRef: "interjections/ij-ai-001.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: session.id).first)
        XCTAssertEqual(interjection.targetType, .assistantTurn)
        XCTAssertEqual(interjection.targetId, "turn-response-stream")
        XCTAssertEqual(interjection.anchor.anchorType, .turn)
        XCTAssertEqual(interjection.anchor.anchorBefore, "First response.")
        XCTAssertEqual(interjection.anchor.anchorAfter, "Second point has the detail.")
        XCTAssertEqual(engine.currentSession?.position.charOffset, secondSentenceStart)
        XCTAssertEqual(resumed.status, .starting)
        XCTAssertTrue(audio.playedOffsets.isEmpty)
    }

    func testImportAssistantResponseCreatesCompletedPlayableTurn() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        let snapshot = try engine.importAssistantResponse(
            text: "<sm_summary>Short setup.</sm_summary><sm_response>External response. Second point.</sm_response>",
            autoPlay: true
        )

        let turn = try XCTUnwrap(try repo.loadTurns(sessionId: session.id).first)
        XCTAssertEqual(turn.status, "complete")
        XCTAssertEqual(turn.summary, "Short setup.")
        XCTAssertEqual(turn.text, "External response. Second point.")
        XCTAssertEqual(snapshot.phase, .aiResponsePlayback)
        XCTAssertEqual(audio.preparedTexts.last, "Short setup.\n\nExternal response. Second point.")
    }

    func testImportedAssistantResponseInterjectionResumesAtExactCapturedOffset() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-imported-response", title: "Imported Response", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-imported-response", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 100, playbackRate: 1)
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.importAssistantResponse(
            text: "First imported sentence. Second imported sentence continues.",
            autoPlay: true
        )
        let capturedOffset = "First imported sentence. Second".count
        audio.currentOffset = capturedOffset
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/imported-response.m4a")

        XCTAssertEqual(engine.currentSession?.position.charOffset, capturedOffset)
        XCTAssertEqual(audio.playedOffsets.last, capturedOffset)
    }

    func testScopedExportFiltersTargetInterjectionsAndMarkdown() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: "[[Pill]]", status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 20, playbackRate: 1)
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief.", text: "Response text.", rawText: nil, sourceInterjectionIds: [])
        let itemInterjection = Interjection(id: "ij-item", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 6, anchorBefore: "Source.", anchorAfter: ""), audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "source note", cleanedTranscript: "clean source note", displayText: nil, status: "active")
        let turnInterjection = Interjection(id: "ij-turn", itemId: item.id, sessionId: session.id, targetType: .assistantTurn, targetId: response.id, createdAt: Date(timeIntervalSince1970: 2), roughPercent: 30, anchor: Anchor(anchorType: .turn, startChar: 0, endChar: 8, anchorBefore: "Response", anchorAfter: "text."), audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "turn note", cleanedTranscript: nil, displayText: nil, status: "active")
        let deletedInterjection = Interjection(id: "ij-deleted", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 3), roughPercent: 40, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 6, anchorBefore: "Source.", anchorAfter: ""), audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "deleted note", cleanedTranscript: nil, displayText: nil, status: "deleted")
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [itemInterjection.id: itemInterjection, turnInterjection.id: turnInterjection, deletedInterjection.id: deletedInterjection], turns: [response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo)

        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true,
            includeTurns: true,
            scope: "target",
            targetType: InterjectionTargetType.assistantTurn.rawValue,
            targetId: response.id
        ))
        let markdown = SessionExportMarkdownRenderer.render(export)

        XCTAssertEqual(export.interjections.map(\.id), ["ij-turn"])
        XCTAssertEqual(export.turns.map(\.id), [response.id])
        XCTAssertTrue(markdown.contains("turn note"))
        XCTAssertFalse(markdown.contains("source note"))
        XCTAssertFalse(markdown.contains("deleted note"))

        let selected = try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true,
            includeTurns: true,
            scope: "selected_interjections",
            interjectionIds: [turnInterjection.id]
        ))
        let selectedMarkdown = SessionExportMarkdownRenderer.render(selected)

        XCTAssertEqual(selected.interjections.map(\.id), [turnInterjection.id])
        XCTAssertTrue(selectedMarkdown.contains("turn note"))
        XCTAssertTrue(selectedMarkdown.contains("Response"))
        XCTAssertTrue(selectedMarkdown.contains("text."))
        XCTAssertFalse(selectedMarkdown.contains("source note"))
        XCTAssertFalse(selectedMarkdown.contains("deleted note"))
    }

    func testDeletedInterjectionInvalidatesItsDerivedSummaryAndCannotBeResummarized() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"]]
        )
        let item = Item(id: "item-summary-delete", title: "Summary Deletion", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-summary-delete", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 20, playbackRate: 1)
        let active = Interjection(id: "ij-active", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 3, anchorBefore: "Source.", anchorAfter: ""), audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "Keep this note", cleanedTranscript: nil, displayText: nil, status: "active")
        let deleted = Interjection(id: "ij-deleted", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 2), roughPercent: 15, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 3, anchorBefore: "Source.", anchorAfter: ""), audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "Delete this note", cleanedTranscript: nil, displayText: nil, status: "deleted")
        let staleSummary = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Keep this note. Delete this note.", rawText: nil, sourceInterjectionIds: [active.id, deleted.id])
        let repo = InMemorySessionRepository(
            items: [item.id: item],
            sessions: [session.id: session],
            interjections: [active.id: active, deleted.id: deleted],
            turns: [staleSummary.id: staleSummary]
        )
        let engine = SessionEngine(profile: profile, repository: repo)

        let candidates = try engine.selectSummaryCandidates(scope: SummaryScope(targetType: "item", sessionId: session.id))
        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true,
            includeTurns: true,
            scope: "full_session"
        ))

        XCTAssertEqual(candidates.map(\.id), [active.id])
        XCTAssertTrue(engine.hasSummaryCandidates(scope: SummaryScope(targetType: "item", sessionId: session.id)))
        XCTAssertTrue(export.turns.isEmpty)
        XCTAssertFalse(SessionExportMarkdownRenderer.render(export).contains("Delete this note"))
    }

    func testFullSessionExportAndCompactTimelinePreserveInterjectionsWhoseTurnRecordIsMissing() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"]]
        )
        let item = Item(id: "item-orphan", title: "Orphan Recovery", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-orphan", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let survivingTurn = ConversationTurn(id: "turn-response-003", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Surviving response.", rawText: nil, sourceInterjectionIds: [])
        let orphanedInterjection = Interjection(
            id: "ij-ai-001",
            itemId: item.id,
            sessionId: session.id,
            targetType: .assistantTurn,
            targetId: "turn-response-001",
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 100,
            anchor: Anchor(anchorType: .turn, startChar: 0, endChar: 8, anchorBefore: "Missing response context.", anchorAfter: "Next sentence."),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "Recovered listener note.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        let repo = InMemorySessionRepository(
            items: [item.id: item],
            sessions: [session.id: session],
            interjections: [orphanedInterjection.id: orphanedInterjection],
            turns: [survivingTurn.id: survivingTurn]
        )
        let engine = SessionEngine(profile: profile, repository: repo)

        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false,
            includeReference: false,
            includeListeningMap: false,
            includeInterjections: true,
            includeTurns: true
        ))
        let markdown = SessionExportMarkdownRenderer.render(export)
        _ = try engine.inspectSession(sessionId: session.id)
        let compactTimeline = engine.compactTimelineEntries()

        XCTAssertEqual(export.interjections.map(\.id), [orphanedInterjection.id])
        XCTAssertTrue(export.timeline.contains(where: { $0.interjectionId == orphanedInterjection.id }))
        XCTAssertTrue(markdown.contains("Recovered listener note."))
        XCTAssertTrue(markdown.contains("Missing response context."))
        XCTAssertTrue(compactTimeline.contains(where: { $0.id == "interjection-\(orphanedInterjection.id)" }))
    }

    func testMalformedAIChaptersPreserveResponseText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: "<sm_summary>Intro.</sm_summary><sm_response>Keep this usable response.</sm_response><sm_chapters_json>{bad json</sm_chapters_json>"
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")

        let turn = try XCTUnwrap(try repo.loadTurns(sessionId: session.id).first)
        XCTAssertEqual(turn.summary, "Intro.")
        XCTAssertEqual(turn.text, "Keep this usable response.")
        XCTAssertEqual(turn.chapters, [])
    }

    func testJumpToAssistantTurnChapterUsesSummaryPrefaceOffset() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let chapter = Chapter(id: "ch-2", title: "Second", startChar: 16, endChar: 29, percent: 50)
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: "First response. Second point.", rawText: nil, chapters: [chapter], sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.jumpToTurnChapter(turnId: response.id, chapterId: chapter.id)

        XCTAssertEqual(audio.preparedTexts.last, "Brief intro.\n\nFirst response. Second point.")
        XCTAssertEqual(audio.playedOffsets.last, "Brief intro.\n\n".count + chapter.startChar)
    }

    func testSummaryPlaybackPublishesCurrentTargetProgressSeparateFromSourceProgress() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["summary_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source complete.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: item.text?.count ?? 0), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "This summary is still playing.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.playTurn(turnId: turn.id)
        audio.currentOffset = 5
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.sourceProgressPercent, 100)
        XCTAssertLessThan(snapshot.currentPlaybackProgressPercent, 100)
        XCTAssertEqual(snapshot.chapterTitle, "Margin Summary 1")
    }

    func testAssistantSeekAndPausedSkipPreserveSourceCompletionAndPersistTarget() throws {
        let profile = RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"], "playback": ["assistant_turn_tts", "skip_sentence"]])
        let item = Item(id: "source", title: "Source", mediaType: "text", text: "Source complete.", externalReference: nil, status: "ready")
        let session = Session(id: "session", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 100, playbackRate: 1)
        let text = "First sentence. Second sentence. Third sentence. Fourth sentence."
        let turn = ConversationTurn(id: "response", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: text, rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.playTurn(turnId: turn.id)
        _ = try engine.pause()
        let sought = try engine.seekText(toCharOffset: 18)
        XCTAssertEqual(sought.status, .paused)
        XCTAssertEqual(sought.currentTextStart, 18)
        XCTAssertEqual(sought.sourceProgressPercent, 100)
        let skipped = try engine.skipForward(unit: "sentence")
        XCTAssertEqual(skipped.status, .paused)
        XCTAssertGreaterThan(skipped.currentTextStart ?? 0, 18)
        XCTAssertEqual(try repo.loadSession(id: session.id)?.position.charOffset, skipped.currentTextStart)
        XCTAssertEqual(try repo.loadSession(id: session.id)?.completionPercent, 100)
        XCTAssertNotNil(try repo.loadItem(id: item.id).sourceCompletedAt)
        _ = try engine.seekText(toCharOffset: 4)
        XCTAssertEqual(try repo.loadSession(id: session.id)?.position.charOffset, 4)
    }

    func testSummaryTurnCompletionPausesWithoutChangingSourceCompletion() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["summary_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source complete.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: item.text?.count ?? 0), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.playTurn(turnId: turn.id)
        audio.completedTargetIds.insert(turn.id)
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .summaryPlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.summaryTurnTTS.rawValue)
        XCTAssertEqual(snapshot.sourceProgressPercent, 100)
    }

    func testAssistantTurnCompletionPausesInAIResponsePlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source complete.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: item.text?.count ?? 0), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Response.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.playTurn(turnId: turn.id)
        audio.completedTargetIds.insert(turn.id)
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .aiResponsePlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.assistantTurnTTS.rawValue)
        XCTAssertEqual(snapshot.sourceProgressPercent, 100)
    }

    func testFirstChapterJumpSkipsListeningMapSummaryPreface() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "timeline": ["chapter_timing"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "First chapter starts here. Second chapter follows.", externalReference: nil, status: "ready")
        let map = ListeningMap(
            id: "map-pill",
            itemId: item.id,
            overview: "Short source summary.",
            chapters: [
                Chapter(id: "ch-1", title: "First", startChar: 0, endChar: 26, percent: 0),
                Chapter(id: "ch-2", title: "Second", startChar: 27, endChar: item.text?.count ?? 0, percent: 60)
            ]
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.jumpToChapter(chapterId: "ch-1")

        XCTAssertEqual(audio.playedOffsets.last, "Overview. Short source summary.\n\n".count)
    }

    func testChapterJumpAlwaysStartsSelectedChapterPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "timeline": ["chapter_timing"],
                "playback": ["realtime_tts"]
            ]
        )
        let text = "First chapter starts here. Second chapter follows. Third chapter ends."
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let map = ListeningMap(
            id: "map-pill",
            itemId: item.id,
            overview: "Short source summary.",
            chapters: [
                Chapter(id: "ch-1", title: "First", startChar: 0, endChar: 26, percent: 0),
                Chapter(id: "ch-2", title: "Second", startChar: 27, endChar: 51, percent: 45),
                Chapter(id: "ch-3", title: "Third", startChar: 52, endChar: text.count, percent: 80)
            ]
        )
        let prefixLength = "Overview. Short source summary.\n\n".count
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.pause()
        let snapshot = try engine.jumpToChapter(chapterId: "ch-2")

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(audio.playedOffsets.last, prefixLength + 27)

        _ = try engine.jumpToChapter(chapterId: "ch-1")

        XCTAssertEqual(audio.playedOffsets.last, prefixLength)
    }

    func testListeningMapSummaryPrefaceProgressIsSummaryLocal() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: String(repeating: "Long source text. ", count: 20), externalReference: nil, status: "ready")
        let overview = "Short source summary."
        let map = ListeningMap(id: "map-pill", itemId: item.id, overview: overview, chapters: [
            Chapter(id: "ch-1", title: "First Chapter", startChar: 0, endChar: 50, percent: 0)
        ])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = "Overview. \(overview)\n\n".count / 2
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.sourceProgressPercent, 0)
        XCTAssertGreaterThan(snapshot.currentPlaybackProgressPercent, 40)
        XCTAssertLessThan(snapshot.currentPlaybackProgressPercent, 60)
        XCTAssertEqual(snapshot.chapterTitle, "Summary")
    }

    func testGeneratedTurnPauseSavesOffsetForResume() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: "First response. Second point.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: turn.id)
        audio.currentOffset = "Brief intro.\n\nFirst".count
        _ = try engine.pause()
        _ = try engine.resumePlayback()

        XCTAssertEqual(audio.pauseCount, 1)
        XCTAssertEqual(audio.playedOffsets.last, "Brief intro.\n\nFirst".count)
    }

    func testAssistantInterjectionResumesAtExactRecordedTurnOffset() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 100, playbackRate: 1)
        let responseText = "First response. Second point has the detail. Third point closes."
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: responseText, rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: turn.id)
        let responseOffset = "First response. Second".count
        let playbackOffset = "Brief intro.\n\n".count + responseOffset
        audio.currentOffset = playbackOffset
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/ij-ai-001.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: session.id).first)
        XCTAssertEqual(interjection.targetType, .assistantTurn)
        XCTAssertEqual(interjection.anchor.anchorBefore, "First response. Second")
        XCTAssertEqual(interjection.anchor.anchorAfter, "point has the detail. Third point closes.")
        XCTAssertGreaterThan(interjection.roughPercent, 0)
        XCTAssertEqual(engine.currentSession?.position.charOffset, responseOffset)
        XCTAssertEqual(audio.playedOffsets.last, playbackOffset)
    }

    func testAssistantTurnExportRehydratesLegacyAnchorsAndUsesContextualLayout() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"]]
        )
        let item = Item(id: "item-turn-export", title: "Turn Export", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-turn-export", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let responseText = "One opens. Two expands. Three qualifies. Four tests. Five is interrupted. Six continues. Seven compares. Eight concludes. Nine adds an appendix."
        let fiveRange = try XCTUnwrap(responseText.range(of: "Five is interrupted."))
        let fiveStart = responseText.distance(from: responseText.startIndex, to: fiveRange.lowerBound)
        let fiveEnd = responseText.distance(from: responseText.startIndex, to: fiveRange.upperBound)
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: responseText, rawText: responseText, sourceInterjectionIds: [])
        let interjection = Interjection(
            id: "ij-ai-001",
            itemId: item.id,
            sessionId: session.id,
            targetType: .assistantTurn,
            targetId: turn.id,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 0,
            anchor: Anchor(
                anchorType: .turn,
                startChar: fiveStart,
                endChar: fiveEnd,
                anchorBefore: "Five is interrupted.",
                anchorAfter: "Six continues."
            ),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "Listener note.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        let repo = InMemorySessionRepository(
            items: [item.id: item],
            sessions: [session.id: session],
            interjections: [interjection.id: interjection],
            turns: [turn.id: turn]
        )
        let engine = SessionEngine(profile: profile, repository: repo)

        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false,
            includeReference: false,
            includeListeningMap: false,
            includeInterjections: true,
            includeTurns: false
        ))
        let exported = try XCTUnwrap(export.interjections.first)
        let markdown = SessionExportMarkdownRenderer.render(export)

        XCTAssertTrue(exported.anchorBefore.contains("Two expands."))
        XCTAssertTrue(exported.anchorBefore.contains("Five is interrupted."))
        XCTAssertTrue(exported.anchorAfter.contains("Nine adds an appendix."))
        XCTAssertGreaterThan(exported.roughPercent, 0)
        XCTAssertTrue(markdown.contains("AI Response Context and Listener Interjections"))
        XCTAssertTrue(markdown.contains("Turn context:"))
        XCTAssertTrue(markdown.contains("Turn continues:"))
        XCTAssertFalse(markdown.contains("Anchor before:"))
    }

    func testCancelAssistantInterjectionResumesAtExactRecordedTurnOffsetWithoutSavingInterjection() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 100, playbackRate: 1)
        let responseText = "First response. Second point has the detail. Third point closes."
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: responseText, rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: turn.id)
        let responseOffset = "First response. Second".count
        let playbackOffset = "Brief intro.\n\n".count + responseOffset
        audio.currentOffset = playbackOffset
        _ = try engine.beginInterjection()
        let snapshot = try engine.cancelInterjection()

        XCTAssertEqual(snapshot.phase, .aiResponsePlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.assistantTurnTTS.rawValue)
        XCTAssertEqual(try repo.loadInterjections(sessionId: session.id).count, 0)
        XCTAssertEqual(engine.currentSession?.position.charOffset, responseOffset)
        XCTAssertEqual(audio.playedOffsets.last, playbackOffset)
    }

    func testPlaySourceFromBeginningWorksWithoutListeningMap() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-mapless", title: "Mapless", mediaType: "text", text: "First. Second.", externalReference: nil, status: "ready")
        let session = Session(id: "session-mapless", itemId: item.id, status: "in_progress", phase: .summaryPlayback, currentTargetType: .summaryTurnTTS, currentTargetId: "turn-summary-001", position: Position(charOffset: item.text?.count ?? 0), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: session.id)
        let snapshot = try engine.playSourceFromBeginning()

        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(snapshot.targetId, item.id)
        XCTAssertEqual(snapshot.sourceProgressPercent, 0)
        XCTAssertEqual(audio.playedTargets.last, item.id)
        XCTAssertEqual(audio.playedOffsets.last, 0)
    }

    func testBrowserTextImportCreatesURLBackedTextItem() throws {
        let profile = RuntimeCapabilityProfile(
            id: "browser-text",
            displayName: "Browser Text",
            capabilities: [
                "sync": ["browser_session_handoff"],
                "playback": ["realtime_tts"]
            ]
        )
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repo)
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-selected",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/pill", title: "Browser Pill"),
            text: "Selected browser text."
        )

        let snapshot = try engine.importBrowserText(handoff)
        let item = try repo.loadItem(id: "item-browser-selected")

        XCTAssertEqual(snapshot.itemId, item.id)
        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(item.title, "Browser Pill")
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertEqual(item.text, "Selected browser text.")
        XCTAssertEqual(item.externalReference, "https://example.com/pill")
        XCTAssertEqual(item.externalReferenceType, "url")
        XCTAssertEqual(item.status, "needs_listening_map")
    }

    func testBrowserTextImportCanStartSessionWhenRequested() throws {
        let profile = RuntimeCapabilityProfile(
            id: "browser-text",
            displayName: "Browser Text",
            capabilities: [
                "sync": ["browser_session_handoff"],
                "playback": ["realtime_tts"]
            ]
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-readable",
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://example.com/readable", title: "Readable Page"),
            text: "Readable page text.",
            requestedContinuation: BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "browser_or_app")
        )

        let snapshot = try engine.importBrowserText(handoff)

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.itemId, "item-browser-readable")
        XCTAssertEqual(audio.playedTargets.last, "item-browser-readable")
    }

    func testMarkdownBrowserImportCreatesDeterministicListeningMap() throws {
        let profile = RuntimeCapabilityProfile(
            id: "browser-markdown",
            displayName: "Browser Markdown",
            capabilities: ["sync": ["browser_session_handoff"]]
        )
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repo)
        let sectionBody = String(repeating: "Useful retirement guidance and supporting detail. ", count: 80)
        let markdown = """
        # Retirement Guide
        ### First strategy
        \(sectionBody)
        ### Second strategy
        \(sectionBody)
        ### Third strategy
        \(sectionBody)
        ### Fourth strategy
        \(sectionBody)
        ### Fifth strategy
        \(sectionBody)
        """
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-markdown",
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://example.com/retirement", title: "Retirement Guide"),
            text: markdown,
            contentFormat: .markdown
        )

        let snapshot = try engine.importBrowserText(handoff)
        let item = try repo.loadItem(id: "item-browser-markdown")
        let map = try XCTUnwrap(repo.loadListeningMap(itemId: item.id))

        XCTAssertEqual(snapshot.itemId, item.id)
        XCTAssertEqual(item.status, "ready")
        XCTAssertFalse(item.text?.contains("###") == true)
        XCTAssertEqual(map.chapters.first?.title, "First strategy")
        XCTAssertGreaterThanOrEqual(map.chapters.count, 5)
    }

    func testBackgroundBrowserImportDoesNotReplaceActiveSession() throws {
        let profile = RuntimeCapabilityProfile(
            id: "browser-background",
            displayName: "Browser Background",
            capabilities: [
                "sync": ["browser_session_handoff"],
                "playback": ["realtime_tts"]
            ]
        )
        let active = Item(id: "item-active", title: "Active", mediaType: "text", text: "Keep listening.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [active.id: active])
        let engine = SessionEngine(profile: profile, repository: repo, audio: RecordingAudioClient())
        _ = try engine.startSession(itemId: active.id)
        let snapshotBeforeImport = engine.snapshot

        let imported = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            itemId: "item-shared-background",
            captureMode: .plainTextFile,
            source: BrowserTextSource(url: "file:///shared.txt", title: "Shared"),
            text: "Shared while listening.",
            contentFormat: .plainText
        ))

        XCTAssertEqual(imported.id, "item-shared-background")
        XCTAssertEqual(engine.snapshot, snapshotBeforeImport)
        XCTAssertEqual(engine.currentItem?.id, active.id)
        XCTAssertEqual(try repo.loadItem(id: imported.id).title, "Shared")
    }

    func testPlaybackProgressReconcilesSystemInitiatedPause() throws {
        let profile = RuntimeCapabilityProfile(
            id: "physical-pause",
            displayName: "Physical Pause",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-physical-pause", title: "Pause", mediaType: "text", text: "Keep this position.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        audio.transportState = .paused

        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.itemId, item.id)
        XCTAssertEqual(snapshot.phase, .itemPlayback)
    }

    func testBrowserTextImportRequiresSyncImportCapability() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "playback": ["realtime_tts"]
            ]
        )
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository())
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-denied",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/denied", title: "Denied"),
            text: "Denied text."
        )

        XCTAssertThrowsError(try engine.importBrowserText(handoff)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("importBrowserText"))
        }
    }

    func testPodcastDownloadPolicyNeverAutomaticallyDownloadsOnCellular() {
        XCTAssertEqual(PodcastDownloadPolicy.action(for: .wifi, userInitiated: false), .download)
        XCTAssertEqual(PodcastDownloadPolicy.action(for: .cellular, userInitiated: false), .streamOnly)
        XCTAssertEqual(PodcastDownloadPolicy.action(for: .unavailable, userInitiated: false), .waitForWiFi)
        XCTAssertEqual(PodcastDownloadPolicy.action(for: .cellular, userInitiated: true), .download)
        XCTAssertEqual(PodcastDownloadPolicy.action(for: .other, userInitiated: true), .download)
        XCTAssertEqual(PodcastDownloadPolicy.action(for: .unavailable, userInitiated: true), .waitForWiFi)
        XCTAssertEqual(PodcastCacheLimitGB.defaultValue, .five)
    }

    func testPodcastCacheEvictionIsLRUAndProtectsActiveAndDownloadingItems() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 300)
        let records = [
            PodcastDownloadRecord(id: "a", itemId: "active", remoteURL: "https://example.com/a", state: .availableOffline, bytesWritten: 3_000, lastPlayedAt: old),
            PodcastDownloadRecord(id: "b", itemId: "old", remoteURL: "https://example.com/b", state: .availableOffline, bytesWritten: 3_000, lastPlayedAt: old),
            PodcastDownloadRecord(id: "c", itemId: "recent", remoteURL: "https://example.com/c", state: .availableOffline, bytesWritten: 3_000, lastPlayedAt: recent),
            PodcastDownloadRecord(id: "d", itemId: "downloading", remoteURL: "https://example.com/d", state: .downloading, bytesWritten: 8_000)
        ]

        let evictions = PodcastCacheEvictionPlanner.recordsToEvict(
            from: records,
            limitBytes: 6_000,
            protectedItemIds: ["active", "downloading"]
        )

        XCTAssertEqual(evictions.map(\.itemId), ["old"])
    }

    func testLocalPodcastTransportSwitchPreservesCanonicalTargetTimeAndRate() throws {
        let profile = RuntimeCapabilityProfile(
            id: "podcast",
            displayName: "Podcast",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
        )
        let remote = "https://example.com/episode.mp3"
        let item = Item(
            id: "episode",
            title: "Episode",
            mediaType: "audio",
            text: nil,
            externalReference: remote,
            status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: remote, durationMs: 120_000)
        )
        let repository = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        _ = try engine.setPlaybackRate(1.5)
        audio.currentMediaTimeValue = 42_000

        let snapshot = try engine.updatePlaybackTransport(
            itemId: item.id,
            playbackURL: URL(fileURLWithPath: "/tmp/episode.mp3").absoluteString
        )

        XCTAssertEqual(snapshot.targetId, remote)
        XCTAssertEqual(snapshot.currentMediaTimeMs, 42_000)
        XCTAssertEqual(snapshot.playbackRate, 1.5)
        XCTAssertEqual(audio.playedTargets.last, remote)
        XCTAssertEqual(audio.playedOffsets.last, 42_000)
        XCTAssertEqual(audio.mediaContexts.last??.sourceURL, remote)
        XCTAssertEqual(audio.mediaContexts.last??.playbackURL, "file:///tmp/episode.mp3")
    }

    func testCompletedPodcastDownloadKeepsEditionAcrossSkipAndResumeUntilNewSession() throws {
        let profile = RuntimeCapabilityProfile(
            id: "podcast-deferred-cache",
            displayName: "Podcast deferred cache",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
        )
        let remote = "https://example.com/episode.mp3"
        let local = URL(fileURLWithPath: "/tmp/episode-cached.mp3").absoluteString
        let item = Item(
            id: "episode-deferred",
            title: "Episode",
            mediaType: "audio",
            text: nil,
            externalReference: remote,
            status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: remote, durationMs: 120_000)
        )
        let repository = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 42_000
        let playCountBeforeDownload = audio.playedTargets.count

        let unchanged = try engine.updatePlaybackTransport(
            itemId: item.id,
            playbackURL: local,
            replaceActivePlayback: false
        )

        XCTAssertEqual(unchanged.status, .playing)
        XCTAssertEqual(audio.playedTargets.count, playCountBeforeDownload)
        XCTAssertNil(audio.mediaContexts.last??.playbackURL)

        // A transport skip must not adopt the newly downloaded edition.
        let skipped = try engine.skipForward(unit: "time_60s")
        XCTAssertEqual(skipped.currentMediaTimeMs, 102_000)
        XCTAssertEqual(audio.seekRequests.last, 102_000)
        XCTAssertEqual(audio.playedTargets.count, playCountBeforeDownload)
        XCTAssertNil(audio.mediaContexts.last??.playbackURL)
        _ = try engine.skipBack(unit: "time_15s")
        XCTAssertEqual(audio.seekRequests.last, 87_000)
        XCTAssertEqual(audio.playedTargets.count, playCountBeforeDownload)

        _ = try engine.pause()
        _ = try engine.resumePlayback()

        XCTAssertEqual(audio.playedOffsets.last, 87_000)
        XCTAssertEqual(audio.mediaContexts.last??.sourceURL, remote)
        XCTAssertNil(audio.mediaContexts.last??.playbackURL)

        // Completion while already paused must also preserve this edition.
        _ = try engine.pause()
        _ = try engine.updatePlaybackTransport(itemId: item.id, playbackURL: local, replaceActivePlayback: false)
        _ = try engine.resumePlayback()
        XCTAssertNil(audio.mediaContexts.last??.playbackURL)
        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.mediaContexts.last??.playbackURL, local)
    }

    /// #914: shared Margins are placed against the edition the listener hears, so the engine says which file a session plays.
    func testMediaSessionReportsWhichEditionItPlays() throws {
        let profile = RuntimeCapabilityProfile(
            id: "podcast-edition-report",
            displayName: "Podcast edition report",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
        )
        let remote = "https://example.com/episode.mp3"
        let local = URL(fileURLWithPath: "/tmp/episode-edition.mp3").absoluteString
        let item = Item(
            id: "episode-edition",
            title: "Episode",
            mediaType: "audio",
            text: nil,
            externalReference: remote,
            status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: remote, durationMs: 120_000)
        )
        let engine = SessionEngine(
            profile: profile, repository: InMemorySessionRepository(items: [item.id: item]), audio: RecordingAudioClient()
        )
        XCTAssertNil(engine.mediaSessionPlays(itemId: item.id, playbackURL: local), "no session")

        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(engine.mediaSessionPlays(itemId: item.id, playbackURL: local), false, "streaming")
        XCTAssertNil(engine.mediaSessionPlays(itemId: "another-item", playbackURL: local))

        _ = try engine.updatePlaybackTransport(itemId: item.id, playbackURL: local, replaceActivePlayback: false)
        XCTAssertEqual(engine.mediaSessionPlays(itemId: item.id, playbackURL: local), false, "the download finished mid-session")

        _ = try engine.updatePlaybackTransport(itemId: item.id, playbackURL: local)
        XCTAssertEqual(engine.mediaSessionPlays(itemId: item.id, playbackURL: local), true, "Download Again moved the session")

        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(engine.mediaSessionPlays(itemId: item.id, playbackURL: local), true, "a new session starts on the download")
        XCTAssertEqual(engine.mediaSessionPlays(itemId: item.id, playbackURL: "file:///tmp/other.mp3"), false)
        XCTAssertEqual(
            engine.mediaSessionPlays(itemId: item.id, playbackURL: "file:///tmp/../tmp/episode-edition.mp3"), true,
            "the same file spelled another way is the same edition"
        )
    }
}

private final class DelayedPositionAudioClient: AudioPlaybackClient {
    private enum Request {
        case text(targetId: String, offset: Int)
        case media(targetId: String, timeMs: Int)
    }

    private var latestRequest: Request?
    private var observedTextPosition: Int?
    private var observedMediaPosition: Int?
    private var activeTargetId: String?
    private var startStatus = PlaybackStartStatus.pending
    private var playbackRate = 1.0
    private var nextMediaSeekRequestId = 0
    private var latestMediaSeekRequest: MediaSeekRequest?
    private var mediaSeekResolutions: [Int: MediaSeekResolution] = [:]

    private(set) var requestedTextPositions: [Int] = []
    private(set) var requestedMediaPositions: [Int] = []
    private(set) var navigationSeekPositions: [Int] = []
    private(set) var mediaPlayPositions: [Int] = []

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        activeTargetId = targetId
        latestRequest = .text(targetId: targetId, offset: charOffset)
        requestedTextPositions.append(charOffset)
        startStatus = .pending
    }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        latestRequest = .media(targetId: targetId, timeMs: mediaTimeMs)
        latestMediaSeekRequest = nil
        requestedMediaPositions.append(mediaTimeMs)
        mediaPlayPositions.append(mediaTimeMs)
        startStatus = .pending
    }

    func reportTextPosition(_ offset: Int) {
        observedTextPosition = offset
        observedMediaPosition = nil
    }

    func reportMediaPosition(_ mediaTimeMs: Int) {
        observedMediaPosition = mediaTimeMs
        observedTextPosition = nil
    }

    func confirmLatestRequest() {
        switch latestRequest {
        case .text(_, let offset):
            observedTextPosition = offset
            observedMediaPosition = nil
        case .media(_, let timeMs):
            observedMediaPosition = timeMs
            observedTextPosition = nil
            if let latestMediaSeekRequest {
                mediaSeekResolutions[latestMediaSeekRequest.id] = .accepted(mediaTimeMs: timeMs)
            }
        case nil:
            break
        }
        startStatus = .confirmed
    }

    func requestMediaSeek(toMediaTimeMs mediaTimeMs: Int) throws -> MediaSeekRequest {
        nextMediaSeekRequestId += 1
        let request = MediaSeekRequest(
            id: nextMediaSeekRequestId,
            targetId: activeTargetId,
            requestedMediaTimeMs: mediaTimeMs
        )
        latestRequest = .media(targetId: activeTargetId ?? "", timeMs: mediaTimeMs)
        latestMediaSeekRequest = request
        mediaSeekResolutions[request.id] = .pending
        requestedMediaPositions.append(mediaTimeMs)
        navigationSeekPositions.append(mediaTimeMs)
        return request
    }

    func mediaSeekResolution(for request: MediaSeekRequest) -> MediaSeekResolution {
        mediaSeekResolutions[request.id] ?? .failed(
            actualMediaTimeMs: observedMediaPosition,
            reason: "unknown_test_seek"
        )
    }

    func failLatestMediaSeek(actualMediaTimeMs: Int, reason: String = "test_seek_declined") {
        observedMediaPosition = actualMediaTimeMs
        guard let latestMediaSeekRequest else { return }
        mediaSeekResolutions[latestMediaSeekRequest.id] = .failed(
            actualMediaTimeMs: actualMediaTimeMs,
            reason: reason
        )
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        if let observedMediaPosition {
            return PlaybackPosition(
                targetId: activeTargetId,
                mediaTimeMs: observedMediaPosition,
                playbackRate: playbackRate,
                anchorConfidence: .mediaTime
            )
        }
        if let observedTextPosition {
            return PlaybackPosition(
                targetId: activeTargetId,
                textStart: observedTextPosition,
                textEnd: observedTextPosition + 1,
                playbackRate: playbackRate,
                anchorConfidence: .textRange
            )
        }
        return nil
    }

    func currentCharOffset() -> Int? { observedTextPosition }
    func currentMediaTimeMs() -> Int? { observedMediaPosition }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        guard activeTargetId == targetId else { return .pending }
        return startStatus
    }

    func playbackTransportState(targetId: String) -> PlaybackTransportState? {
        guard activeTargetId == targetId else { return .stopped }
        switch startStatus {
        case .confirmed: return .playing
        case .pending: return .waiting
        case .failed: return .failed
        }
    }

    func setPlaybackRate(_ rate: Double) throws {
        playbackRate = rate
    }

    func pause() throws {
        startStatus = .pending
    }

    func stop() throws {
        activeTargetId = nil
        latestRequest = nil
        latestMediaSeekRequest = nil
        startStatus = .pending
    }
}

private final class RecordingAudioClient: AudioPlaybackClient {
    var playedTargets: [String] = []
    var playedOffsets: [Int] = []
    var preparedTexts: [String] = []
    var pauseCount = 0
    var stopCount = 0
    var currentOffset: Int?
    var currentMediaTimeValue: Int?
    var mediaTimeOnPause: Int?
    var currentDurationMs: Int?
    var activeTargetId: String?
    var completedTargetIds = Set<String>()
    var completeActiveTargetOnPause = false
    var completionOffsetOnPause: Int?
    var seekRequests: [Int] = []
    var playbackRates: [Double] = []
    var playbackRate = 1.0
    var mediaContexts: [PlaybackMediaContext?] = []
    var startStatus: PlaybackStartStatus = .confirmed
    var startStatusByTarget: [String: PlaybackStartStatus] = [:]
    var awaitingRenderedAudio = false
    var transportState: PlaybackTransportState?
    var configuredSpeechSettings: [(String?, Float)] = []
    var remoteCommandHandlingStates: [Bool] = []
    var mixingStates: [Bool] = []
    var backgroundAudioStates: [Bool] = []
    var playbackVolumes: [Float] = []
    var acceptsPostResumeSamples = false
    var acceptsPreInterjectionSamples: Bool?
    var postResumeSampleRequests: [PostResumeAudioSampleRequest] = []
    var preInterjectionSampleRequests: [PostResumeAudioSampleRequest] = []
    var eventLog: [String] = []
    var failNextPlay = false

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {
        mediaContexts.append(context)
    }

    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {
        configuredSpeechSettings.append((voiceIdentifier, rate))
    }

    func prepareSpeechText(_ text: String) throws -> String {
        preparedTexts.append(text)
        return SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        activeTargetId = targetId
        playedTargets.append(targetId)
        playedOffsets.append(0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        if failNextPlay {
            failNextPlay = false
            throw SessionKitError.persistenceFailed("injected_play_failure")
        }
        activeTargetId = targetId
        currentMediaTimeValue = nil
        playedTargets.append(targetId)
        playedOffsets.append(charOffset)
    }

    var seekingPlays: [Int] = []

    func play(targetId: String, seekingTo charOffset: Int) throws {
        seekingPlays.append(charOffset)
        try play(targetId: targetId, from: charOffset)
    }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        currentOffset = nil
        currentMediaTimeValue = mediaTimeMs
        playedTargets.append(targetId)
        playedOffsets.append(mediaTimeMs)
        eventLog.append("play_media")
    }

    func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        currentMediaTimeValue = mediaTimeMs
        seekRequests.append(mediaTimeMs)
    }

    func setPlaybackRate(_ rate: Double) throws {
        playbackRate = rate
        playbackRates.append(rate)
    }

    func setMixesWithOtherAudio(_ enabled: Bool) throws {
        mixingStates.append(enabled)
    }

    func setLowersBackgroundAudio(_ enabled: Bool) throws {
        backgroundAudioStates.append(enabled)
    }

    func setPlaybackVolume(_ volume: Float) throws {
        playbackVolumes.append(volume)
    }

    func pause() throws {
        pauseCount += 1
        if let mediaTimeOnPause {
            currentMediaTimeValue = mediaTimeOnPause
        }
        if completeActiveTargetOnPause, let activeTargetId {
            completedTargetIds.insert(activeTargetId)
            if let completionOffsetOnPause {
                currentOffset = completionOffsetOnPause
            }
        }
    }

    func stop() throws {
        stopCount += 1
        activeTargetId = nil
        currentOffset = nil
        currentMediaTimeValue = nil
    }

    func currentCharOffset() -> Int? {
        currentOffset
    }

    func currentMediaTimeMs() -> Int? {
        currentMediaTimeValue
    }

    func currentPlaybackDurationMs() -> Int? {
        currentDurationMs
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        if let currentMediaTimeValue {
            return PlaybackPosition(
                targetId: activeTargetId,
                mediaTimeMs: currentMediaTimeValue,
                durationMs: currentDurationMs,
                playbackRate: playbackRate,
                anchorConfidence: .mediaTime
            )
        }
        if let currentOffset {
            return PlaybackPosition(
                targetId: activeTargetId,
                textStart: currentOffset,
                textEnd: currentOffset + 1,
                anchorConfidence: .textRange
            )
        }
        return nil
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        completedTargetIds.contains(targetId)
    }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        startStatusByTarget[targetId] ?? startStatus
    }

    func isAwaitingRenderedAudio(targetId: String) -> Bool {
        awaitingRenderedAudio
    }

    func playbackTransportState(targetId: String) -> PlaybackTransportState? {
        transportState
    }

    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {
        remoteCommandHandlingStates.append(enabled)
    }

    func armPostResumeAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
        postResumeSampleRequests.append(request)
        eventLog.append("arm_post_resume_sample")
        return acceptsPostResumeSamples
    }

    func captureBufferedPreInterjectionAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
        preInterjectionSampleRequests.append(request)
        return acceptsPreInterjectionSamples ?? acceptsPostResumeSamples
    }
}

private final class CountingInterjectionRepository: InMemorySessionRepository {
    var noteLoads = 0
    override func loadInterjections(sessionId: String) throws -> [Interjection] {
        noteLoads += 1
        return try super.loadInterjections(sessionId: sessionId)
    }
}

private final class FailingWrittenInterjectionRepository: InMemorySessionRepository {
    var failNextInterjectionSave = false
    var failNextSessionSave = false

    override func saveInterjection(_ interjection: Interjection) throws {
        if failNextInterjectionSave {
            failNextInterjectionSave = false
            throw SessionKitError.persistenceFailed("injected_interjection_save_failure")
        }
        try super.saveInterjection(interjection)
    }

    override func saveSession(_ session: Session) throws {
        if failNextSessionSave {
            failNextSessionSave = false
            throw SessionKitError.persistenceFailed("injected_session_save_failure")
        }
        try super.saveSession(session)
    }
}

private final class CountingRecordingClient: RecordingClient {
    var beginCount = 0
    var finishCount = 0
    var cancelCount = 0

    func beginRecording() throws {
        beginCount += 1
    }

    func finishRecording(audioRef: String?) throws -> String {
        finishCount += 1
        return audioRef ?? "interjections/counting.m4a"
    }

    func cancelRecording() throws {
        cancelCount += 1
    }
}

private final class RecordingTextAudioPreparationClient: TextAudioPreparationClient, @unchecked Sendable {
    var prepared: PreparedTextAudio?
    var requests: [(itemId: String, title: String, text: String)] = []

    init(prepared: PreparedTextAudio?) {
        self.prepared = prepared
    }

    func prepareTextAudio(itemId: String, title: String, text: String) throws -> PreparedTextAudio? {
        requests.append((itemId, title, text))
        return prepared
    }
}

private final class RecordingTranscriptionClient: TranscriptionClient {
    var scheduledInterjectionIds: [String] = []

    func scheduleTranscription(interjection: Interjection) throws {
        scheduledInterjectionIds.append(interjection.id)
    }
}

private struct StaticLinkResolutionClient: LinkResolutionClient {
    var result: LinkResolutionResult

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        result
    }
}
