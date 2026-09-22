# Simulator recordings

These are recordings of real automated simulator navigation using synthetic seeded data. Test start/finish and pass/fail outcomes are indexed in `index.json` and `preparation-index.json`. They are verification evidence, not product-owner acceptance.

- `testMarginsItemShareOpensItemExportAndChapterJumpUpdatesTimeline.mp4`: next-chapter jump, active Timeline cue, written Margin, item-level Share → item export screen.
- `testLibraryUnfinishedCompletionUndoAndSearchDiscovery.mp4`: completion, Undo, completed-item search, automatic notice expiry.
- `testPrivateExperienceRootsPreserveNowPlayingAndStateConsentBoundaries.mp4`: Following → Settings and root navigation with Now Playing retained.
- `testBatchExportOffersPersistentJumpToDestination.mp4`: Export Sessions on Margins.
- `testBuild23RecipientMissingSourceReturnsWithoutAutoplayAndShowsProvenance.mp4`: shared Margin provenance/review (#68).
- `testNativeTextPublishesVisibleSimulatorSystemPlaybackState.mp4`: generated-audio playback, preparation track, system controls (#116); the track is already fully prepared in the reviewed player frame.
- `testPlaybackScrubberAcceptsPhysicalDrag.mp4`: generated-audio scrubber operation.
- `testWrittenMarginSaveSearchStarAndDiscardPreserveTheSource.mp4`: written Margin actions and contextual return.
- `system-speech-canary-excerpt.mp4`: excerpt of the longer real-speech regression route.

The root `testBuild23LayoutRegressionsRemainOperableAtAccessibilityType.mp4` records the first-run failure and must not be presented as passing evidence. Corrected recordings are under `final-phone/`, with their own index.

#115 also has passing canonical destination/landing tests (`LocalAudioListeningPackageTests` and `PlaybackQualityTests`); these clips do not establish a dedicated Skim-preview visual acceptance result.
