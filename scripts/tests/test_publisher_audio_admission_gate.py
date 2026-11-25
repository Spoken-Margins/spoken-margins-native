"""#4640: every new publisher-audio record passes PublisherAudioAdmission.

`savePublisherAudioIfItemExists` runs the admission gate before it saves. Outside tests, a record may be written
directly only by the store and repository that implement the protocol, the gated helper itself, and the text mapper,
which re-saves a record that was already admitted with its new map. A new direct caller fails here until it goes
through the helper.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

SAVES_DIRECTLY = {
    'PublisherAudio.swift': 'the protocol',
    'SQLiteSessionStore.swift': 'the store',
    'InMemoryRepository.swift': 'the in-memory repository',
    'PublisherAudioSaving.swift': 'the gated helper',
    'PublisherAudioTextMapper.swift': 're-saves an admitted record with its map',
}


def swift_sources():
    for folder in ('App', 'Packages'):
        for path in sorted((ROOT / folder).rglob('*.swift')):
            parts = path.relative_to(ROOT).parts
            if '.build' in parts or 'Tests' in parts or 'TestFixtures' in parts or any(part.endswith('Tests') for part in parts):
                continue
            yield path


class PublisherAudioAdmissionGateTests(unittest.TestCase):
    def test_only_the_gated_helper_and_the_store_save_a_record(self):
        found = {path.name for path in swift_sources() if 'savePublisherAudio(' in path.read_text(errors='replace')}
        self.assertEqual(found, set(SAVES_DIRECTLY), 'a file saves publisher audio without PublisherAudioAdmission')

    def test_the_helper_admits_before_it_saves(self):
        source = (ROOT / 'Packages/SessionKit/Sources/SessionKitPersistence/PublisherAudioSaving.swift').read_text()
        self.assertLess(source.index('PublisherAudioAdmission.admit('), source.index('try savePublisherAudio('))


if __name__ == '__main__':
    unittest.main()
