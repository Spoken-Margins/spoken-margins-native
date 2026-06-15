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
