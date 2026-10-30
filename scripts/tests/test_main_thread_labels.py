"""#2512: the main-actor tasks named in the audit (#2256) carry a main-thread operation label.

A hang record names the work through `MainThreadOperationLabels.current` (the probe reads it while the main thread is
stuck; `MainThreadHangProbeTests` covers that a label reaches the record). The scanner cannot see a label that sits in an
awaited callee or after an `await`, so this table pins each site: dropping a label there turns a hang back into
`operation: none`. A label name is at most 40 characters; the stack keeps no more.
"""
import re
import unittest
from pathlib import Path

SOURCES = Path(__file__).resolve().parents[2] / 'App/SpokenMarginsApp/Sources/SpokenMarginsApp'

SITES = {
    'ExperienceItemDetailScreen.swift': ['episodeLinked'],
    'Gate1AppModel+AudioClients.swift': [
        'mediaInterruption', 'nowPlayingCommand', 'mediaStartTrace', 'mediaStallTrace', 'postResumeEvidence'],
    'Gate1AppModel+FileImport.swift': ['obsidianImportFinish'],
    'Gate1AppModel+ImportInbox.swift': ['pendingBrowserTextImport'],
    'Gate1AppModel+LibraryAudioQueue.swift': ['scheduleAudioPreparation', 'explicitAudioPreparationQueued'],
    'Gate1AppModel+MarginCapture.swift': [
        'marginSaveFinish', 'marginSave.onboarding', 'marginSave.transcription', 'marginSave.report', 'marginSave.signal'],
    'Gate1AppModel.swift': ['snapshotChanged'],
    'Gate1AppModel+HangTelemetry.swift': [
        'snapshot.playbackEvents', 'snapshot.listeningSignals', 'snapshot.audioPreparation',
        'snapshot.narrationProtection', 'snapshot.skimAvailability'],
    'Gate1AppModel+EngineInstall.swift': ['compactControls.update'],
    'Gate2CompactControlController.swift': [
        'nowPlaying.installCommands', 'nowPlaying.remoteEvents', 'nowPlaying.commandAvailability', 'nowPlaying.infoWrite'],
    'Gate1AppModel+MarginVoicePlayback.swift': ['importedCommentaryAutoPlay'],
    'Gate1AppModel+PackageImport.swift': ['pendingPackageHandoffs', 'restoreAudioCleanup'],
    'SpokenMarginsPackageImportCoordinator.swift': ['stagePackageFiles'],
    'Gate1AppModel+PodcastPlacementDeferral.swift': ['resumeDeferredPlacements'],
    'Gate1AppModel+SourceLinkBackground.swift': ['sharedLinkVoiceover'],
    'Gate1AppModel+SourceLinkForm.swift': ['sourceLinkFormFinish'],
    'Gate1AppModel+SourceWindowContext.swift': ['heardSourceWindow'],
    'Gate1AppModel+TranscriptionRecovery.swift': ['sourceTranscriptAttach', 'sourceTranscriptUnavailable', 'sourceTranscriptionFailed'],
    'ImportedPodcastPlacementCoordinator.swift': ['transientTranscriptResolve'],
    'LiveSessionLineUpView.swift': ['liveSessionLineUpSaved'],
    'LiveSessionView.swift': ['liveSessionSavedAsNotes'],
    'MarginOutputCoordinator.swift': ['marginOutputResolveFolder'],
    'PlaybackStartCue.swift': ['playbackStartChime', 'playbackWaitingCue'],
    'ReadwiseHighlightSync.swift': ['readwiseLedgerOpen'],
}

PACKAGES = Path(__file__).resolve().parents[2] / 'Packages/SessionKit/Sources'

# #2967: the steps of a Margin save that run on the main thread, so a slow one is named in the hang record.
PACKAGE_SITES = {
    'SessionKit/SessionEngine.swift': ['finish.recorder', 'finish.store', 'finish.resume'],
    'SessionKitAudio/AudioAdapters.swift': ['recorder.stop', 'audioSession.deactivate'],
    'SessionKitAudio/RecordingFileFinalizer.swift': ['recorder.measureFile'],
}


class LabelledSites(unittest.TestCase):
    def test_each_site_keeps_its_label(self):
        for name, labels in SITES.items():
            source = (SOURCES / name).read_text()
            for label in labels:
                with self.subTest(file=name, label=label):
                    self.assertRegex(source, r'scoped\(\s*"%s"' % re.escape(label))

    def test_label_names_fit_the_stack(self):
        for name, labels in SITES.items():
            for label in labels:
                with self.subTest(file=name, label=label):
                    self.assertLessEqual(len(label), 40)

    def test_each_package_site_keeps_its_label(self):
        for name, labels in PACKAGE_SITES.items():
            source = (PACKAGES / name).read_text()
            for label in labels:
                with self.subTest(file=name, label=label):
                    self.assertRegex(source, r'scoped\(\s*"%s"' % re.escape(label))
                    self.assertLessEqual(len(label), 40)

    def test_the_engine_run_label_names_its_caller(self):
        source = (SOURCES / 'Gate1AppModel.swift').read_text()
        self.assertRegex(source, r'func run\(caller: StaticString = #function,')
        self.assertRegex(source, r'scoped\(Self\.engineRunLabel\(caller: caller\)\)')
        self.assertNotRegex(source, r'scoped\("engine\.run"\)', 'a bare engine.run names none of its 200 callers (#2967)')

    def test_the_transcript_parse_runs_off_the_main_actor(self):
        source = (SOURCES / 'Gate1AppModel.swift').read_text()
        self.assertRegex(source, r'Task\.detached\([^)]*\)\s*\{\s*try SourceTranscriptParsing\.transcriptTimeline')


class SystemDaemonCallsStayOffTheMainThread(unittest.TestCase):
    """#2967: a play tap froze the app for 4.3 s with no operation named. Two calls on its path wait on system daemons."""

    def test_the_now_playing_audio_session_is_activated_on_its_own_queue(self):
        source = (SOURCES / 'Gate2CompactControlController.swift').read_text()
        body = source[source.index('private func activatePlaybackAudioSessionIfNeeded'):]
        body = body[:body.index('private func noteAudioSessionActivation')]
        self.assertIn('audioSessionActivation.submit', body)
        self.assertLess(body.index('audioSessionActivation.submit'), body.index('setActive(true)'),
                        'setActive(true) sits inside the submitted closure')

    def test_the_live_activity_permission_is_read_through_the_refreshed_flag(self):
        source = (SOURCES / 'Gate2CompactControlController.swift').read_text()
        self.assertRegex(source, r'areActivitiesEnabled: \{ activitiesEnabledFlag\.value \}')
        self.assertEqual(source.count('ActivityAuthorizationInfo().areActivitiesEnabled'), 1)

    def test_saving_a_margin_reloads_the_item_off_the_main_thread(self):
        source = (SOURCES / 'Gate1AppModel+MarginCapture.swift').read_text()
        body = source[source.index('    func finishInterjection() {'):]
        body = body[:body.index('    func recordSavedInterjectionForOnboarding')]
        self.assertIn('refreshSelectedItemInBackground()', body)
        self.assertNotRegex(body, r'\brefreshSelectedItem\(\)')


if __name__ == '__main__':
    unittest.main()
