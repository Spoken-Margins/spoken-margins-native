"""scripts/seed_tools_artifacts.py: the tools build reuses SessionKit's downloaded binary targets (#4664)."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('seed', Path(__file__).resolve().parents[1] / 'seed_tools_artifacts.py')
S = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(S)


def entry(target, path, identity='onnxruntime-swift-package-manager', checksum='abc'):
    return {'packageRef': {'identity': identity, 'kind': 'remoteSourceControl', 'location': 'https://example.com/x.git', 'name': identity},
            'targetName': target, 'source': {'type': 'remote', 'url': f'https://host.example/{target}.zip', 'checksum': checksum},
            'path': str(path)}


class SeedTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.source = self.root / 'SessionKit' / '.build' / 'workspace-state.json'
        self.target = self.root / 'SessionKit' / '.build' / 'tools' / 'workspace-state.json'
        self.source.parent.mkdir(parents=True)
        self.core = self.root / 'artifacts' / 'onnxruntime.xcframework'
        self.extensions = self.root / 'artifacts' / 'onnxruntime_extensions.xcframework'
        self.core.mkdir(parents=True)
        self.extensions.mkdir(parents=True)
        (self.core / 'Info.plist').write_text('core')
        (self.extensions / 'Info.plist').write_text('extensions')
        self.scratch = self.target.parent

    def write_source(self, artifacts, version=7):
        self.source.write_text(json.dumps({'version': version, 'object': {
            'artifacts': artifacts, 'dependencies': [{'packageRef': {'identity': 'swift-crypto'}}], 'prebuilts': []}}))

    def target_state(self):
        return json.loads(self.target.read_text())

    def test_a_fresh_tools_scratch_gets_the_entries_and_none_of_the_dependencies(self):
        self.write_source([entry('onnxruntime', self.core), entry('onnxruntime_extensions', self.extensions)], version=7)
        line = S.seed(self.source, self.target)
        state = self.target_state()
        self.assertEqual(state['version'], 7)
        self.assertEqual(sorted(e['targetName'] for e in state['object']['artifacts']), ['onnxruntime', 'onnxruntime_extensions'])
        self.assertEqual(state['object']['dependencies'], [], 'SwiftPM resolves its own dependencies')
        self.assertIn('onnxruntime-swift-package-manager/onnxruntime_extensions', line)
        copies = {e['targetName']: Path(e['path']) for e in state['object']['artifacts']}
        self.assertEqual(copies['onnxruntime'], self.scratch / 'artifacts' / 'onnxruntime-swift-package-manager' / 'onnxruntime' / 'onnxruntime.xcframework')
        self.assertEqual((copies['onnxruntime'] / 'Info.plist').read_text(), 'core')
        self.assertEqual((copies['onnxruntime_extensions'] / 'Info.plist').read_text(), 'extensions')
        self.assertTrue(self.core.exists(), 'SessionKit\'s own folder stays where it was')
        # A SwiftPM that later deletes a stale entry's folder takes the tools copy, never SessionKit's (review of #4892).
        import shutil
        shutil.rmtree(copies['onnxruntime'])
        self.assertTrue((self.core / 'Info.plist').exists())

    def test_an_entry_whose_folder_is_gone_is_left_out(self):
        self.write_source([entry('onnxruntime', self.core), entry('onnxruntime_extensions', self.root / 'missing')])
        S.seed(self.source, self.target)
        self.assertEqual([e['targetName'] for e in self.target_state()['object']['artifacts']], ['onnxruntime'])

    def seed_with_own_entry(self, own):
        self.write_source([entry('onnxruntime', self.core), entry('onnxruntime_extensions', self.extensions)])
        self.target.parent.mkdir(parents=True)
        self.target.write_text(json.dumps({'version': 7, 'object': {'artifacts': [own], 'dependencies': [{'x': 1}], 'prebuilts': []}}))
        S.seed(self.source, self.target)
        state = self.target_state()
        self.assertEqual(state['object']['dependencies'], [{'x': 1}], 'the rest of its state is untouched')
        return {e['targetName']: e for e in state['object']['artifacts']}, state['object']['artifacts']

    def test_an_entry_the_tools_state_has_from_the_same_source_with_its_folder_is_kept(self):
        own_folder = self.root / 'tools-own'
        own_folder.mkdir()
        by_target, listed = self.seed_with_own_entry(entry('onnxruntime', own_folder))
        self.assertEqual(by_target['onnxruntime']['path'], str(own_folder))
        self.assertIn('onnxruntime_extensions', by_target)
        self.assertEqual(len(listed), 2)

    def test_an_entry_whose_folder_is_gone_or_whose_source_differs_is_replaced(self):
        # A restored tools state can hold an entry from another runner's checkout path, or an older checksum.
        own_folder = self.root / 'tools-own'
        own_folder.mkdir()
        for name, own in (('folder gone', entry('onnxruntime', self.root / 'not-there')),
                          ('older checksum', entry('onnxruntime', own_folder, checksum='older'))):
            with self.subTest(name):
                if self.target.parent.exists():
                    import shutil
                    shutil.rmtree(self.target.parent)
                by_target, listed = self.seed_with_own_entry(own)
                self.assertEqual(by_target['onnxruntime']['source']['checksum'], 'abc')
                self.assertTrue(by_target['onnxruntime']['path'].startswith(str(self.scratch / 'artifacts')))
                self.assertEqual(len(listed), 2, 'replaced, not duplicated')

    def test_running_twice_changes_nothing_the_second_time(self):
        self.write_source([entry('onnxruntime', self.core)])
        S.seed(self.source, self.target)
        first = self.target.read_text()
        self.assertIn('already holds', S.seed(self.source, self.target))
        self.assertEqual(self.target.read_text(), first)

    def test_nothing_to_reuse_writes_nothing(self):
        self.assertIn('no usable', S.seed(self.source, self.target), 'no source state at all')
        self.write_source([])
        self.assertIn('holds no downloaded', S.seed(self.source, self.target))
        self.write_source([entry('onnxruntime', self.root / 'gone')])
        self.assertIn('holds no downloaded', S.seed(self.source, self.target))
        self.source.write_text('{not json')
        self.assertIn('no usable', S.seed(self.source, self.target))
        self.source.write_text(json.dumps({'object': 'wrong shape'}))
        self.assertIn('no usable', S.seed(self.source, self.target))
        self.assertFalse(self.target.exists())

    def test_an_unreadable_tools_state_is_left_alone(self):
        self.write_source([entry('onnxruntime', self.core)])
        self.target.parent.mkdir(parents=True)
        self.target.write_text('{broken')
        self.assertIn('left alone', S.seed(self.source, self.target))
        self.assertEqual(self.target.read_text(), '{broken')

    def test_entries_of_another_package_with_the_same_target_name_are_separate(self):
        self.write_source([entry('onnxruntime', self.core), entry('onnxruntime', self.core, identity='other-package')])
        S.seed(self.source, self.target)
        self.assertEqual(len(self.target_state()['object']['artifacts']), 2)

    def test_main_never_fails_the_build(self):
        self.assertEqual(S.main(['seed', str(self.source), str(self.target)]), 0)
        self.assertEqual(S.main(['seed']), 2)
        self.source.mkdir()  # a folder where a file should be
        self.assertEqual(S.main(['seed', str(self.source), str(self.target)]), 0)


if __name__ == '__main__':
    unittest.main()
