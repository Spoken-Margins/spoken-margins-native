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
    'Gate1AppModel+ImportInbox.swift': ['pendingPackageHandoffs', 'pendingBrowserTextImport'],
    'Gate1AppModel+LibraryAudioQueue.swift': ['scheduleAudioPreparation', 'explicitAudioPreparationQueued'],
    'Gate1AppModel+MarginCapture.swift': ['marginSaveFinish'],
    'Gate1AppModel+MarginVoicePlayback.swift': ['importedCommentaryAutoPlay'],
    'Gate1AppModel+PackageImport.swift': ['restoreAudioCleanup'],
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
    'SpokenMarginsPackageImportCoordinator.swift': ['packageImportCommit'],
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

    def test_the_transcript_parse_runs_off_the_main_actor(self):
        source = (SOURCES / 'Gate1AppModel.swift').read_text()
        self.assertRegex(source, r'Task\.detached\([^)]*\)\s*\{\s*try SourceTranscriptParsing\.transcriptTimeline')


if __name__ == '__main__':
    unittest.main()
