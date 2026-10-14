# Gate 1 Playback Transition Table

This table makes the current playback behavior explicit. The goal is not to declare the final architecture; it is to lock down the user-visible behavior that is working now so future state-machine cleanup can move deliberately.

## Scope

This table covers `SessionEngine` playback transitions for Gate 1 source, generated turns, and interjection recording. App-level provider completion and pending autoplay queue behavior remain in `Gate1AppModel`; those are documented in `gate1-playback-state-inventory.md` and should move into a coordinator later.

## States

| State | Status | Phase | Target |
| --- | --- | --- | --- |
| `SourcePlaying` | `playing` | `itemPlayback` | `item_text_tts` |
| `SourcePaused` | `paused` | `itemPlayback` | `item_text_tts` |
| `SourceFinished` | `paused` | `finished` | `item_text_tts` |
| `SummaryPlaying` | `playing` | `summaryPlayback` | `summary_turn_tts` |
| `SummaryPaused` | `paused` | `summaryPlayback` | `summary_turn_tts` |
| `AssistantPlaying` | `playing` | `aiResponsePlayback` | `assistant_turn_tts` |
| `AssistantPaused` | `paused` | `aiResponsePlayback` | `assistant_turn_tts` |
| `RecordingInterjection` | `recording` | `recordingInterjection` | target captured before recording |

## Transitions

| ID | From | Event | To | Required Actions | Test |
| --- | --- | --- | --- | --- | --- |
| T01 | none/current | `startSession(item)` | `SourcePlaying` | Create unique session, load map, prepare overview preface + source text, play from offset 0. | `testStartSessionSpeaksListeningMapOverviewBeforeItemText`, `testRepeatedStartsCreateDistinctSessionsForSameItem` |
| T02 | `SourcePlaying` | progress tick while overview preface is active | `SourcePlaying` | Keep source progress at 0, publish current target progress against summary preface, title `Summary`. | `testListeningMapSummaryPrefaceProgressIsSummaryLocal` |
| T03 | `SourcePlaying` | source audio completes | `SourceFinished` | Mark source offset to item end, set source completion to 100, pause playback status. | `testSyncPlaybackProgressMarksItemFinishedWhenAudioCompletes` |
| T04 | `SourcePlaying` or `SourcePaused` | `pause()` | `SourcePaused` | Sync current audio offset to source position, save session, pause audio. | `testPauseAndResumePreserveSourcePosition` |
| T05 | `SourcePaused` | `resumePlayback()` | `SourcePlaying` | Replay current item target from saved source offset. | `testPauseAndResumePreserveSourcePosition` |
| T06 | any source/generated state | `jumpToChapter(chapter)` | `SourcePlaying` | Switch target to source item, skip overview preface, play selected source chapter. | `testJumpToChapterFromSummaryPlaybackReturnsToItemText`, `testFirstChapterJumpSkipsListeningMapSummaryPreface`, `testChapterJumpAlwaysStartsSelectedChapterPlayback` |
| T07 | generated/source state | `playSourceFromBeginning()` | `SourcePlaying` | Switch target to source item, reset source position and completion, play overview preface if present. | `testPlaySourceFromBeginningWorksWithoutListeningMap` |
| T08 | `SourcePlaying` | `beginInterjection()` | `RecordingInterjection` | Sync source audio offset, capture source target/anchor, pause audio, begin recording. | `testFinishInterjectionSchedulesTranscriptionAfterAudioIsSaved` |
| T09 | `RecordingInterjection` from source | `finishInterjection()` | `SourcePlaying` | Save interjection, schedule transcription, roll source resume point to prior sentence, resume source playback. | `testFinishInterjectionSchedulesTranscriptionAfterAudioIsSaved` |
| T10 | `RecordingInterjection` from source | `cancelInterjection()` | `SourcePlaying` | Save no interjection, roll source resume point to prior sentence, resume source playback. | `testCancelInterjectionDoesNotCreateInterjectionAndResumes` |
| T11 | `SourceFinished` or conversation context | `playTurn(summary)` | `SummaryPlaying` | Switch target to summary turn, prepare generated text, play from beginning. | `testPlayTurnPreparesTurnTextInsteadOfReusingItemText`, `testSummaryPlaybackPublishesCurrentTargetProgressSeparateFromSourceProgress` |
| T12 | `SummaryPlaying` | summary audio completes | `SummaryPaused` | Keep source completion unchanged, preserve summary target/phase, publish paused status. | `testSummaryTurnCompletionPausesWithoutChangingSourceCompletion` |
| T13 | `SourceFinished` or conversation context | `playTurn(assistant)` | `AssistantPlaying` | Switch target to assistant turn, prepare generated text, play from beginning. | `testPlayTurnPreparesTurnTextInsteadOfReusingItemText`, `testAssistantPlayableTextSpeaksSummaryBeforeResponse` |
| T14 | `AssistantPlaying` | assistant audio completes | `AssistantPaused` | Keep source completion unchanged, preserve assistant target/phase, publish paused status. | `testAssistantTurnCompletionPausesInAIResponsePlayback` |
| T15 | `AssistantPlaying` | `jumpToTurnChapter(chapter)` | `AssistantPlaying` | Seek within assistant response body while accounting for spoken summary preface. | `testJumpToAssistantTurnChapterUsesSummaryPrefaceOffset` |
| T16 | `AssistantPlaying` | `pause()` then `resumePlayback()` | `AssistantPlaying` | Sync generated response offset, save session, resume from matching spoken offset. | `testGeneratedTurnPauseSavesOffsetForResume` |
| T17 | `AssistantPlaying` | `beginInterjection()` | `RecordingInterjection` | Sync generated-turn offset, capture assistant target and local turn sentence anchor, pause audio, begin recording. | `testAssistantInterjectionResumesNearRecordedTurnOffset` |
| T18 | `RecordingInterjection` from assistant | `finishInterjection()` | `AssistantPlaying` | Save assistant-targeted interjection, schedule transcription, resume near recorded turn offset with sentence context. | `testAssistantInterjectionResumesNearRecordedTurnOffset` |
| T19 | `RecordingInterjection` from assistant | `cancelInterjection()` | `AssistantPlaying` | Save no interjection, resume near recorded turn offset with sentence context. | `testCancelAssistantInterjectionResumesNearRecordedTurnOffsetWithoutSavingInterjection` |
| T20 | any session with eligible interjections | `generateInterjectionSummary(scope)` | no playback change | Create or refresh one summary turn per playback target; reject if no new interjection is available for that target. | `testInterjectionSummaryRegenerationRequiresNewInterjectionAndReplacesCurrentTargetSummary`, `testInterjectionsOnAssistantTurnCanBeSummarizedAfterItemSummary` |
| T21 | assistant response completion job | `aiJobCompleted(turn)` | current playback state preserved | Parse response, summary, and chapters without interrupting active audio. | `testAIJobCompletedPreservesActivePlaybackPhase`, `testAICompletionParsesSummaryResponseAndChapters` |

## Open Debt

- App-level pending autoplay queue needs unit coverage outside XCUITest. Today it is documented and manually validated, but it is still owned by `Gate1AppModel`.
- Summary preface is modeled as part of `item_text_tts`; this preserves behavior but is conceptually awkward.
- Generated-turn navigation has two offset spaces: spoken text can include `summary + "\n\n" + text`, while chapters and anchors use response text. Conversion helpers are tested but should remain treated as a risk area.

## Shared Margin return claim (#997, model split T9)

This section covers one decision only: **who owes the source back after a shared Margin**, and whether it comes back. It does not cover the shared Margin voice's own phases (loading, playing, paused, failed, retry; `SharedMarginPlaybackHealth`, #941), the offer queue (`SharedMarginOfferQueue`, #918, #1238), or the Margin moment's return path (`MarginMomentConductor`). Those keep their owners.

### What was there and what replaces it

| | Before | After |
| --- | --- | --- |
| Stored resume flags in `Gate1AppModel` | 2 (`sourcePausedForImportedCommentaryPrompt`, `sourceShouldResumeAfterImportedCommentary`) | 0 |
| Stored values for the same decision | 2 booleans (4 combinations, none named) | 1 value, `SharedMarginReturnClaim` (SessionKit), with 4 named cases |
| Where the decision is made | five members in `Gate1AppModel+MarginVoicePlayback.swift`, inline | `SharedMarginReturnClaim` methods, host-tested on Linux |

The flags were two booleans. The claim is one enum value with four cases, so the number of stored booleans goes 2 → 0 and the number of stored values 2 → 1. The four cases are kept on purpose: see R18.

The two parts, which the claim holds independently of the card on screen and of the voice phase:

- **Prompt part.** A shared Margin was offered while the source was playing, and the offer paused the source. Answering the offer (Listen or Dismiss) owes the source back.
- **Voice part.** The shared Margin's voice is playing and the source was playing when it started, or the voice replaced a voice that already held the promise. The voice ending, or Return, owes the source back.

### Values and events

| Value | Prompt part | Voice part |
| --- | --- | --- |
| `none` | no | no |
| `prompt` | yes | no |
| `voice` | no | yes |
| `promptAndVoice` | yes | yes |

| Event (model member) | Claim call | Decision |
| --- | --- | --- |
| A prompt is shown (`presentImportedCommentaryPrompt`) | `promptShown(sourceWasPlaying:)` | none; the model then pauses the source if it was playing |
| The card is dismissed (`dismissPendingImportedCommentary`) | `promptDismissed()` | resume the source if owed (the model also requires the source to be `.paused`) |
| Listen starts (`listenToImportedCommentary(_:)`) | `listenRequested(sourceIsPlaying:voiceIsPlaying:)`, then `voiceStopped()`, then `voiceStarted(returnToSource:)` | the captured value is whether the source comes back when this voice ends |
| The common stop (`stopInterjectionAudioPlayback`) | `voiceStopped()` | none |
| The voice ends or Return (`stopImportedCommentaryPlayback(resumeSource:)`) | `returnsSourceWhenVoiceEnds(resumeSource:)` (read), then `voiceStopped()` twice (R16) | resume the source if owed and the model finds it `.paused` |

### Order, which the table and the code keep

`listenToImportedCommentary(_:)` is staged, and each stage can re-enter, so the claim is **not** one atomic transition:

1. **Capture** the return decision from the claim, the source state and the voice state, and release the prompt part (`listenRequested`).
2. **Pause** the source if it is playing. `snapshot.didSet` runs here and can drain a queued widget command synchronously (Listen, Dismiss, jump), so another transition may run between steps 2 and 4.
3. **Common stop** (`stopInterjectionAudioPlayback`): the voice part is released.
4. **Restore** the voice part from the captured value (`voiceStarted`). The prompt part is not touched by step 4.

Everywhere else the claim is changed before the model acts on the decision (pause, resume), as the booleans were, so a repeated completion cannot resume twice.

`dismissPendingImportedCommentary` clears the card first (`pendingImportedCommentary = nil`, whose `didSet` can drain a queued command) and reads and clears the prompt part after, as before.

`stopImportedCommentaryPlayback` clears the voice part twice: once inside the common stop, once after it. The second is redundant today. It stays, and R16 says so, until a test says it may go.

### Transitions

Claim values are named in the table above. "Model guard" means the rule lives in the model, not the claim.

| ID | From | Event | To | Required actions | Test |
| --- | --- | --- | --- | --- | --- |
| R01 | `none` | prompt shown, source was playing | `prompt` | Pause the source (model). | Linux `testR01…`; app `testDismissingAPromptThatPausedThePlayingSourceResumesIt` |
| R02 | any | prompt shown, source was not playing | prompt part cleared, voice part kept | Replaces an earlier offer's part. Nothing is owed for the new offer. | Linux `testR02…`; app `testDismissingAPromptOverAnAlreadyPausedSourceLeavesItPaused` |
| R03 | `prompt` or `promptAndVoice` | card dismissed | `none` or `voice` | Release the prompt part, then resume the source if it is `.paused` (model guard). | Linux `testR03…`; app `testDismissingAPromptThatPausedThePlayingSourceResumesIt` |
| R04 | `none` or `voice` | card dismissed | unchanged | Nothing is owed; the source stays as it is. | Linux `testR04…`; app `testDismissingAPromptOverAnAlreadyPausedSourceLeavesItPaused` |
| R05 | `voice` or `promptAndVoice` | card dismissed | voice part kept | Dismissing answers the prompt part only. | Linux `testR05…` |
| R06 | `none` | Listen, source playing | `voice` | Capture true, pause the source, common stop, restore. | Linux `testR06…`; app `testListeningWhileTheSourcePlaysBringsItBackOnReturn` |
| R07 | `prompt` | Listen on the offer | `voice` | Capture true from the prompt part, release the prompt part at capture, then as R06. | Linux `testR07…`; app `testListeningToAnOfferThatPausedTheSourceBringsItBackOnceOnReturn` |
| R08 | `none` | Listen, source paused, no offer | `none` | Capture false; Return then leaves the source paused. | Linux `testR08…`; app `testListeningOverAPausedSourceWithNoOfferLeavesItPausedOnReturn` |
| R09 | `voice` | Listen or Retry while a voice holding the promise plays | `voice` | Capture true before the common stop clears it; restore it after. Retry reaches this row (`retryImportedCommentary` calls Listen with the voice still playing). | Linux `testR09…`; app `testRetryingAFailedVoiceKeepsThePromiseToBringTheSourceBack` |
| R10 | `none` | Listen replaces a voice that did not hold the promise | `none` | Capture false. | Linux `testR10…` |
| R11 | `voice` | Listen when no voice is playing | `none` | A voice part with no voice playing is not inherited. | Linux `testR11…` |
| R12 | any | common stop | voice part cleared, prompt part kept | The card's own answer is still owed after the voice stops. | Linux `testR12…`; app `testStoppingTheVoiceKeepsTheOffersPromise` |
| R13 | `voice` or `promptAndVoice` | voice ends or Return | prompt part kept, voice cleared | Read the voice part, clear it, then resume the source if it is `.paused` (model guard). A second Return finds nothing owed. | Linux `testR13…`; app `testListeningToAnOfferThatPausedTheSourceBringsItBackOnceOnReturn` |
| R14 | `none` or `prompt` | voice ends or Return | unchanged | Nothing is owed by the voice. | Linux `testR14…` |
| R15 | any | stop that must not return the source: session, item or target change, the source becoming active (`snapshot.didSet`), app terminate, own-Margin hand-off, `seekText`, Skim restore, Listen's failure path | voice cleared | Do not resume. The prompt part stays. | Linux `testR15…`; app `testStoppingTheVoiceDropsThePromiseToBringTheSourceBack`, existing `testCompactAddMarginWhileASharedMarginPlaysRecordsAtThatMargin` |
| R16 | any | second `voiceStopped()` right after the first | unchanged | The second clear inside `stopImportedCommentaryPlayback` is redundant. Kept. | Linux `testR16…` |
| R17 | `prompt` | session opened (`startNewSession`, `openSession`, `resumeSession`) | unchanged | The card is cleared without answering the offer. The prompt part is **not** consumed. Today's behaviour, see R19. | app `testAnOfferClearedWithoutAnswerStillOwesTheSourceToALaterListen` |
| R18 | `none` | prompt C shown over a playing source; source resumed by transport; jump to Margin A pauses the source; a queued widget Listen for C drains inside the jump's seek; the jump then shows A with the `sourceWasPlaying` it captured earlier | `promptAndVoice` | Capture, release the prompt part, common stop and restore for C; then A's `promptShown(true)` restores the prompt part. Dismissing A then answers the prompt part only; the voice part is answered by C's end or Return. Reached only through re-entry; the ordinary path does not show it. | Linux `testR18…`. No app test (see below) |
| R19 | `prompt` | Listen with no card on screen, over a paused source | `voice` | Inherits R17's stale prompt part, so Return resumes a source the listener had left paused. Characterized, not fixed here. | Linux `testR19…`; app `testAnOfferClearedWithoutAnswerStillOwesTheSourceToALaterListen` |
| R20 | any | dismiss with no card on screen | unchanged | Model guard (`pendingImportedCommentary != nil`): the claim is not called. | existing `Gate1TransportCharacterizationTests/testListenAndDismissWithNoPendingSharedMarginReturnFalseSilently` |
| R21 | any | Margin moment (`playSharedMarginMoment`) | unchanged | The conductor resumes the source itself (`Gate1AppModel.playSharedMarginMoment`, `MarginMomentConductor.finishVoice`), outside the claim. It moves onto the claim in T7 (#993), not here. It is a third return path, listed so nothing treats the claim as the only one. | existing `MediaPlaybackInterruptionTests/testTheEpisodePlaysOnAfterASharedMarginsMoment` |
| R22 | any | Listen cannot find the voice file | as R03 | `listenToImportedCommentary` calls `dismissPendingImportedCommentary`, so R03, R04 or (with no card) R20 applies, and the failure is reported. | covered by R03, R04 |

Not covered by an app test: R18. Reproducing it needs the widget command queue to be injected, and `Gate2CompactControlController` drains the production app-group queue (`Gate2CompactCommandQueue.drain()` with its default `defaults:`). Adding that seam is a production change outside a behaviour-preserving extraction, so the fourth case stays, and the claim's own test stages the sequence step by step as the model stages it. Until a test reproduces or disproves R18, `promptAndVoice` is not collapsed.

### Hazards from the call graph

- `Gate1RootView` (`InterjectionDetailView.onDisappear`) calls `stopInterjectionAudioPlayback()` unguarded, so it releases the voice part if a shared Margin is playing when an own-Margin detail view goes away. Unchanged here: the common stop releases the voice part exactly as it cleared the boolean.
- `pause()` and `resumePlayback()` redirect to the shared Margin voice while one plays. The conductor's closures use them, so a shared Margin voice playing during a Margin moment would be paused or resumed instead of the source. That is T7's, not the claim's.
- `snapshot.didSet` runs `stopImportedCommentaryPlayback(resumeSource: false)` before `updateGate2CompactState`, so by the time a queued command drains the voice part is already gone.

### Matrix from the 12 October system audit (finding 6)

The claim owns one cell column: "does the source come back after the shared Margin, and who owes it". The other columns are transport and interruption decisions that stay with their owners. For each cell the table says which.

| Cell | The claim's part | Where the rest is decided | Test layer |
| --- | --- | --- | --- |
| User pause (explicit) | none. A later pause while a voice plays is routed to the voice by the model (`setImportedCommentaryPaused`); the claim is untouched. | `pause()`, `playPause()` redirect in `Gate1AppModel` | existing `verifyImportedMarginTransport` (host, lane) |
| Temporary interruption, another app, a call | none. Resume after an interruption is not decided by the claim. #1434 (interruption does not resume) is open and phone-found. | the audio-session interruption path, and #1434 | phone pass |
| Foreground and background | none. | app lifecycle, `handleApplicationWillTerminate` (R15 for terminate) | phone pass |
| Source type: article voice, podcast, PDF | none by type. The decision uses `snapshot.status.isPlaybackActive` only. | `Gate1AppModel.snapshot` | app tests above use a native media source; article voice is the same call |
| Commentary in progress or not | R06 to R15. | claim | Linux and app tests above |
| Import arriving, or an offer arriving, in each state | R01, R02, R17, R18, R19. | `SharedMarginOfferQueue`, `reconcileImportedCommentary` | Linux and app tests above |
| Item replacement | R15, R17: the voice is dropped without resume; an unanswered offer's part survives (R19 records the consequence). | `snapshot.didSet`, `startNewSession` | app test above |
| Remote Play and Stop | none. While a voice plays, remote Play and Pause go to the voice; every other command warns "Return to Source before using source controls." | `performGate2CompactCommand` | existing `verifyImportedMarginTransport` |

For each: what is audible, which item and position, whether resume is allowed, and which screen is shown are checked on the phone for audio, and by the host and app tests named above for state. A later user pause or item switch cancels any stale voice intent (R15) but, today, **not** a stale prompt intent (R17, R19). Fixing that is a behaviour change, and gets its own issue and evidence.
