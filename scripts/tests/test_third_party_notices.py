"""The third-party notices list stays complete (#1823).

THIRD_PARTY_NOTICES.md is generated from docs/legal/third-party-components.json, and scripts/third_party_notices.py
fails when a dependency, a bundled model or a bundled folder has no entry. These tests run it on the real
repository, then on a small copy with one gap opened at a time, so each gap is shown to fail the check.
"""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import third_party_notices as notices  # noqa: E402

REAL = notices.ROOT
READ = ['docs/legal/third-party-components.json', 'THIRD_PARTY_NOTICES.md', 'project.yml', 'package.json',
        'requirements-dev.txt', 'Packages/SessionKit/Package.swift', 'Packages/SessionKit/Package.resolved',
        'App/SharedResources/BundledJavaScript-NOTICES.txt']


class ThirdPartyNoticesTests(unittest.TestCase):
    def tree(self):
        """The files the check reads, plus an empty stand-in for every path the manifest names."""
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        for name in READ:
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REAL / name, root / name)
        data = notices.load(root)
        named = [path for component in data['components']
                 for path in [*component.get('paths', []), *component.get('licenseFiles', []),
                              *component.get('tracks', {}).get('manifests', [])]]
        for path in [*named, *data['projectAuthored']]:
            target = root / path
            if (REAL / path).is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.touch()
        self.assertEqual(notices.problems(root), [], 'the copy must start clean')
        return root

    def assertProblem(self, root, text):
        found = notices.problems(root)
        self.assertTrue(any(text in line for line in found), f'{text!r} not reported in {found}')

    def edit_json(self, path, change):
        data = json.loads(path.read_text())
        change(data)
        path.write_text(json.dumps(data, indent=2) + '\n')

    def test_the_repository_is_covered_and_the_file_is_current(self):
        self.assertEqual(notices.problems(REAL), [])

    def test_a_new_swift_package_needs_an_entry(self):
        root = self.tree()
        manifest = root / 'Packages/SessionKit/Package.resolved'
        self.edit_json(manifest, lambda d: d['pins'].append({'identity': 'new-package', 'state': {}}))
        self.assertProblem(root, 'Swift package new-package')

    def test_a_new_dependency_in_package_swift_needs_an_entry_before_it_is_pinned(self):
        root = self.tree()
        swift = root / 'Packages/SessionKit/Package.swift'
        swift.write_text(swift.read_text() + '\nlet extra = [.package(url: "https://github.com/x/Extra.git", exact: "1.0.0")]\n')
        self.assertProblem(root, 'Swift package extra')

    def test_a_new_npm_dependency_needs_an_entry(self):
        root = self.tree()
        self.edit_json(root / 'package.json', lambda d: d['devDependencies'].update({'left-pad': '1.0.0'}))
        self.assertProblem(root, 'npm package left-pad')

    def test_a_new_python_requirement_needs_an_entry(self):
        root = self.tree()
        requirements = root / 'requirements-dev.txt'
        requirements.write_text(requirements.read_text() + 'requests==2.0.0\n')
        self.assertProblem(root, 'Python requirement requests')

    def test_a_package_compiled_into_the_scripts_needs_an_entry_at_its_version(self):
        root = self.tree()
        notes = root / 'App/SharedResources/BundledJavaScript-NOTICES.txt'
        text = notes.read_text()
        notes.write_text(text.replace('turndown 7.2.4 (MIT)', 'turndown 7.3.0 (MIT)'))
        self.assertProblem(root, 'turndown: App/SharedResources/BundledJavaScript-NOTICES.txt says 7.3.0')
        notes.write_text(text + '\n' + '=' * 72 + '\nnew-lib 1.0.0 (MIT)\n' + '=' * 72 + '\n')
        self.assertProblem(root, 'new-lib 1.0.0 is compiled into the page-reading scripts')

    def test_a_model_or_font_file_must_sit_under_an_entry(self):
        root = self.tree()
        (root / 'App/SpokenMarginsApp/Resources/Fonts').mkdir(parents=True)
        (root / 'App/SpokenMarginsApp/Resources/Fonts/Serif.ttf').touch()
        (root / 'App/SpokenMarginsApp/Resources/NewVoice').mkdir()
        (root / 'App/SpokenMarginsApp/Resources/NewVoice/model.onnx').touch()
        self.assertProblem(root, 'Fonts/Serif.ttf')
        self.assertProblem(root, 'NewVoice/model.onnx')

    def test_a_bundled_folder_must_have_an_entry_or_be_claimed_as_ours(self):
        root = self.tree()
        project = root / 'project.yml'
        project.write_text(project.read_text() + '\n      - path: App/SpokenMarginsApp/Resources/Mystery\n        type: folder\n')
        self.assertProblem(root, 'project.yml bundles App/SpokenMarginsApp/Resources/Mystery')

    def test_a_dependency_manifest_nobody_claims_fails(self):
        root = self.tree()
        (root / 'tools').mkdir()
        (root / 'tools/package.json').write_text('{}')
        self.assertProblem(root, 'tools/package.json')

    def test_the_go_server_may_not_pick_up_an_outside_module_unnoticed(self):
        root = self.tree()
        (root / 'research/B4/server/go.mod').write_text('module x\n\ngo 1.24\n\nrequire github.com/a/b v1.2.3\n')
        self.assertProblem(root, 'research/B4/server/go.mod requires an outside module')

    def test_a_missing_licence_file_fails(self):
        root = self.tree()
        (root / 'App/SpokenMarginsApp/Resources/Legal/ZIPFoundation-LICENSE.txt').unlink()
        self.assertProblem(root, 'ZIPFoundation-LICENSE.txt does not exist')

    def test_an_entry_without_licence_evidence_fails(self):
        root = self.tree()
        self.edit_json(root / 'docs/legal/third-party-components.json',
                       lambda d: d['components'][1].pop('licenseFiles'))
        self.assertProblem(root, 'zipfoundation: needs licenseFiles or licenseUrl')

    def test_a_stale_generated_file_fails(self):
        root = self.tree()
        with (root / 'THIRD_PARTY_NOTICES.md').open('a') as handle:
            handle.write('hand edit\n')
        self.assertProblem(root, 'THIRD_PARTY_NOTICES.md is out of date')


if __name__ == '__main__':
    unittest.main()
