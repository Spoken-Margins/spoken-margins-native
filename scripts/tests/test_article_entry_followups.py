"""Every way an article enters the Library, and what each one does about the publisher's voiceover (#2363).

Build 35 played a Substack post clipped from Safari with the on-device voice, although the page lists Substack's own
voice: the clip path never ran the voiceover lookup, only the shared-link paths did (#810, #2024). The same class can
return whenever a new caller of the article import is written. This test fails when a source file gains an article
import that this inventory doesn't list, so the author has to decide, in the open, whether the new path runs the
lookup or leans on the open-time retry (`retryVoiceoverLookupIfNeeded`, which runs when an item is opened).

It reads Swift source as text, like the main-thread read scanner (#2257).
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'App' / 'SpokenMarginsApp' / 'Sources' / 'SpokenMarginsApp'

# A call that puts article text into the Library.
IMPORT_CALL = re.compile(r'\b(?:importBrowserTextItem|importBrowserTextInBackground|importBrowserTextInBackgroundOffMain|importClippedPage)\(')
# A call that looks for the publisher's own voice for the item just imported.
LOOKUP_CALL = re.compile(r'\b(?:rememberSharedLinkVoiceover|lookUpVoiceover|importClippedPage|publisherAudioLookup)\(')

# file -> (import call sites, status, why). Status:
#   lookup     the file runs the voiceover lookup itself, after the import.
#   open-time  no lookup at import; the article is looked up the first time the listener opens it (a gap if it is
#              played without being opened, which is what #2363 asks to close).
#   not-web    not a web article (PDF, file, edition): there is no post page to look up.
INVENTORY = {
    'Gate1AppModel+FollowedSources.swift': (2, 'lookup', 'Following: publisherAudioLookup on a tap; a refresh defers it to opening (#2368)'),
    'Gate1AppModel+ImportInbox.swift': (1, 'open-time', 'share-sheet text payloads drained at launch'),
    'Gate1AppModel+PublisherAudio.swift': (1, 'lookup', 'importClippedPage: Safari clip, lookup after the import (#810)'),
    'Gate1AppModel+RemotePDF.swift': (3, 'not-web', 'PDF imports'),
    'Gate1AppModel+SharedItemAcquisition.swift': (1, 'open-time', 'a shared item whose article is fetched later'),
    'Gate1AppModel+SourceLinkBackground.swift': (1, 'lookup', 'link imported in the background (#810)'),
    'Gate1AppModel+SourceLinkForeground.swift': (1, 'lookup', 'link imported with the app in front (#810)'),
    'Gate1AppModel.swift': (7, 'open-time', 'Safari clip entry points (these call importClippedPage), the import funnel itself, and Readwise read-later'),
}


def calls(text, pattern):
    count = 0
    for line in text.splitlines():
        code = line.split('//', 1)[0]
        code = re.sub(r'\bfunc\s+\w+\(', 'func declared(', code)  # a declaration is not a call
        count += len(pattern.findall(code))
    return count


class ArticleEntryFollowUpTests(unittest.TestCase):
    def test_every_article_import_is_listed(self):
        found = {}
        for path in sorted(SOURCES.glob('*.swift')):
            count = calls(path.read_text(encoding='utf-8'), IMPORT_CALL)
            if count:
                found[path.name] = count
        problems = []
        for name, count in found.items():
            if name not in INVENTORY:
                problems.append(f'{name} imports an article ({count} call(s)) but is not in INVENTORY')
            elif count != INVENTORY[name][0]:
                problems.append(f'{name} has {count} article imports, the inventory lists {INVENTORY[name][0]}')
        for name in INVENTORY:
            if name not in found:
                problems.append(f'{name} is in INVENTORY but no longer imports an article: remove it')
        self.assertEqual(problems, [], 'Decide whether each new article import runs the publisher voiceover lookup '
                         '(see this file), then record it in INVENTORY.')

    def test_files_marked_lookup_really_run_it(self):
        for name, (_, status, why) in INVENTORY.items():
            if status != 'lookup':
                continue
            text = (SOURCES / name).read_text(encoding='utf-8')
            self.assertGreater(calls(text, LOOKUP_CALL), 0, f'{name} is marked lookup ({why}) but no longer calls it')

    def test_opening_an_item_runs_the_open_time_lookup(self):
        navigation = (SOURCES / 'Gate1AppModel+Navigation.swift').read_text(encoding='utf-8')
        self.assertIn('retryVoiceoverLookupIfNeeded', navigation,
                      'the open-time retry is what the open-time files in INVENTORY rely on')


if __name__ == '__main__':
    unittest.main()
