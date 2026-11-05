"""#3438: the Type III Audio narration lookup runs only on a listener's action.

The owner's 2026-10-21 call: a publisher's page (and, from 2026-11-05, Type III's find call) is asked for only when the
listener opens, plays, shares, pastes or clips a post, never from a refresh, an auto-add, an import or a scheduled job.
The lookup is reachable from exactly these files; a new file that names it or starts a lookup fails here until someone
has decided it is such a path (as #2368 did for the Substack page read).
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

# Files that name the lookup, and why each is allowed.
NAMES_THE_LOOKUP = {
    'TypeIIIAudioNarration.swift': 'the lookup itself',
    'SharedPostVoiceoverLookup.swift': 'the one caller; reached only through SharedLinkVoiceover',
    'VoiceoverLookupDecision.swift': 'whether an opened or played item is looked up',
    'SharedLinkVoiceover.swift': 'runs the lookup; the network fetch lives here',
    'Gate1AppModel+PublisherAudio.swift': 'open, play and clip entry points',
}
# Files that call SharedPostVoiceoverLookup.find.
CALLS_FIND = {'SharedLinkVoiceover.swift'}
# Files that start a lookup (rememberSharedLinkVoiceover / lookUpVoiceover): a shared or pasted link, a clipped
# page, and opening or playing an item.
STARTS_A_LOOKUP = {
    'Gate1AppModel+SourceLinkBackground.swift', 'Gate1AppModel+SourceLinkForeground.swift', 'Gate1AppModel+PublisherAudio.swift',
}


def swift_sources():
    for folder in ('App', 'Packages'):
        for path in sorted((ROOT / folder).rglob('*.swift')):
            parts = path.relative_to(ROOT).parts
            if '.build' in parts or 'Tests' in parts or any(part.endswith('Tests') for part in parts):
                continue
            yield path


class Type3LookupGateTests(unittest.TestCase):
    def test_only_the_listener_gated_files_name_or_start_the_lookup(self):
        named, callers, starters = set(), set(), set()
        for path in swift_sources():
            text = path.read_text(errors='replace')
            if 'TypeIIIAudioNarration' in text:
                named.add(path.name)
            if 'SharedPostVoiceoverLookup.find' in text:
                callers.add(path.name)
            if 'rememberSharedLinkVoiceover(' in text or 'lookUpVoiceover(' in text:
                starters.add(path.name)
        self.assertEqual(named, set(NAMES_THE_LOOKUP), 'a file names the Type III lookup that is not a listener-gated path')
        self.assertEqual(callers, CALLS_FIND)
        self.assertEqual(starters, STARTS_A_LOOKUP)

    def test_the_find_call_never_creates_a_narration(self):
        source = (ROOT / 'Packages/SessionKit/Sources/SessionKitFeeds/TypeIIIAudioNarration.swift').read_text()
        self.assertIn('narration/find', source)
        for forbidden in ('create-from-url', 'create_narration', 'httpMethod'):
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
