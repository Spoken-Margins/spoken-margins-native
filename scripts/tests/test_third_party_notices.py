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
        'Packages/SessionKitTools/Package.swift', 'Packages/SessionKitTools/Package.resolved',
        'App/SharedResources/BundledJavaScript-NOTICES.txt', 'App/SharedResources/Defuddle-LICENSE.txt',
        'App/SpokenMarginsShareExtension/Resources/BundledJavaScript-NOTICES.txt',
        'App/SpokenMarginsShareExtension/Resources/Defuddle-LICENSE.txt',
        'SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
        'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift']
# The run-time fixture folders the app bundles (#3075), as project.yml lists them.
APP_FIXTURES = ''.join(f'      - path: Contracts/fixtures/{name}\n        type: folder\n'
                       for name in ('items', 'maps', 'capabilities'))


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

    def test_a_dependency_added_to_the_tools_package_needs_an_entry(self):
        # coop-packet and phone-plan have their own package (#1873); a dependency there is a dependency too.
        root = self.tree()
        swift = root / 'Packages/SessionKitTools/Package.swift'
        swift.write_text(swift.read_text() + '\nlet extra = [.package(url: "https://github.com/x/ToolDep.git", exact: "1.0.0")]\n')
        self.assertProblem(root, 'Swift package tooldep')
        self.edit_json(root / 'Packages/SessionKitTools/Package.resolved',
                       lambda d: d['pins'].append({'identity': 'pinned-tool-dep', 'state': {}}))
        self.assertProblem(root, 'Swift package pinned-tool-dep')

    def test_a_package_declared_with_a_name_still_needs_an_entry(self):
        root = self.tree()
        swift = root / 'Packages/SessionKit/Package.swift'
        swift.write_text(swift.read_text() + '\nlet named = [.package(name: "Named", url: "https://github.com/x/Named.git", exact: "2.0.0")]\n')
        self.assertProblem(root, 'Swift package named')

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

    def test_the_app_bundles_only_the_contract_fixtures_it_reads(self):
        # main before #3075: the whole of Contracts/fixtures and Contracts/traces shipped to every listener.
        root = self.tree()
        project = root / 'project.yml'
        original = project.read_text()
        self.assertIn(APP_FIXTURES, original)
        project.write_text(original.replace(APP_FIXTURES, '      - path: Contracts/fixtures\n        type: folder\n'
                                            '      - path: Contracts/traces\n        type: folder\n'))
        self.assertProblem(root, 'project.yml bundles Contracts/fixtures in SpokenMarginsApp')
        self.assertProblem(root, 'project.yml bundles Contracts/traces in SpokenMarginsApp')
        project.write_text(original.replace(APP_FIXTURES, APP_FIXTURES + '      - path: Contracts/fixtures/feeds\n'
                                            '        type: folder\n'))
        self.assertProblem(root, 'project.yml bundles Contracts/fixtures/feeds in SpokenMarginsApp')
        project.write_text(original.replace(APP_FIXTURES, APP_FIXTURES + '      - path: Contracts/fixtures/feeds/x.rss\n'
                                            '        buildPhase: resources\n'))
        self.assertProblem(root, 'project.yml bundles Contracts/fixtures/feeds/x.rss in SpokenMarginsApp')

    def test_a_bundled_fixture_folder_fails_once_its_reader_is_gone(self):
        root = self.tree()
        model = root / 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift'
        text = model.read_text()
        self.assertIn('subdirectory: "maps"', text)
        model.write_text(text.replace('subdirectory: "maps"', 'subdirectory: "fixtures/maps"'))
        self.assertProblem(root, 'project.yml bundles Contracts/fixtures/maps in SpokenMarginsApp')
        # A test's read does not count: it runs in the test bundle, not on a listener's phone.
        test = root / 'App/SpokenMarginsAppTests/MapsReaderTests.swift'
        test.parent.mkdir(parents=True)
        test.write_text('let url = Bundle.main.url(forResource: "m", withExtension: "json", subdirectory: "maps")\n')
        self.assertProblem(root, 'project.yml bundles Contracts/fixtures/maps in SpokenMarginsApp')

    def test_a_test_bundle_may_carry_any_fixture(self):
        root = self.tree()
        project = root / 'project.yml'
        original = project.read_text()
        marker = '      - path: App/TestFixtures\n        buildPhase: resources\n'
        self.assertEqual(original.count(marker), 2, 'the unit and UI test targets both bundle App/TestFixtures')
        project.write_text(original.replace(marker, marker + '      - path: Contracts/traces\n        type: folder\n'))
        self.assertEqual(notices.problems(root), [])

    def test_a_dependency_manifest_nobody_claims_fails(self):
        root = self.tree()
        # A name no real folder shares, even on a case-insensitive disk (the Mac has Tools/ and the copy makes it).
        (root / 'extra-vendored').mkdir()
        (root / 'extra-vendored/package.json').write_text('{}')
        self.assertProblem(root, 'extra-vendored/package.json')

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

    def test_a_changed_version_fails_in_each_manifest(self):
        root = self.tree()
        swift = root / 'Packages/SessionKit/Package.swift'
        text = swift.read_text()
        swift.write_text(text.replace('exact: "1.24.2"', 'exact: "1.99.0"'))
        self.assertProblem(root, 'Swift package onnxruntime-swift-package-manager: Package.swift')
        swift.write_text(text)
        self.edit_json(root / 'package.json', lambda d: d['devDependencies'].update({'esbuild': '0.99.0'}))
        self.assertProblem(root, 'npm package esbuild: package.json says 0.99.0')
        requirements = root / 'requirements-dev.txt'
        requirements.write_text(requirements.read_text().replace('4.26.0', '4.99.0'))
        self.assertProblem(root, 'Python requirement jsonschema: requirements-dev.txt says 4.99.0')

    def test_a_package_declared_in_project_yml_or_the_app_resolved_file_needs_an_entry(self):
        root = self.tree()
        project = root / 'project.yml'
        original = project.read_text()
        project.write_text(original.replace('packages:\n', 'packages:\n  Lottie:\n    url: https://github.com/airbnb/lottie-spm.git\n    from: 4.0.0\n', 1))
        self.assertProblem(root, 'Swift package lottie-spm')
        project.write_text(original)
        resolved = root / 'SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        self.edit_json(resolved, lambda d: d['pins'].append({'identity': 'app-only-pin', 'state': {}}))
        self.assertProblem(root, 'Swift package app-only-pin')

    def test_the_extension_copies_of_the_notices_must_match(self):
        root = self.tree()
        copy = root / 'App/SpokenMarginsShareExtension/Resources/Defuddle-LICENSE.txt'
        copy.write_text(copy.read_text() + 'changed\n')
        self.assertProblem(root, 'Defuddle-LICENSE.txt differs from')

    def test_a_tool_entry_s_folder_does_not_cover_a_model_file(self):
        root = self.tree()
        (root / 'scripts/stray.onnx').touch()
        (root / 'App/SharedResources/Serif.ttf').touch()
        self.assertProblem(root, 'scripts/stray.onnx')
        self.assertProblem(root, 'App/SharedResources/Serif.ttf')

    def test_a_content_folder_does_not_cover_a_model_file(self):
        root = self.tree()
        (root / 'fixtures/voice.onnx').touch()
        (root / 'Contracts/fixtures/Serif.ttf').touch()
        self.assertProblem(root, 'fixtures/voice.onnx')
        self.assertProblem(root, 'Contracts/fixtures/Serif.ttf')

    def test_other_model_file_types_are_caught(self):
        root = self.tree()
        (root / 'Stray').mkdir()
        for name in ('m.ort', 'tok.model', 'w.pkl', 'x.data', 'f.ttc'):
            (root / 'Stray' / name).touch()
        for name in ('m.ort', 'tok.model', 'w.pkl', 'x.data', 'f.ttc'):
            self.assertProblem(root, f'Stray/{name}')

    def test_worktrees_and_build_folders_are_not_the_repository(self):
        root = self.tree()
        (root / '.claude/worktrees/ws-1').mkdir(parents=True)
        (root / '.claude/worktrees/ws-1/package.json').write_text('{}')
        (root / '.claude/worktrees/ws-1/voice.onnx').touch()
        self.assertEqual(notices.problems(root), [])

    def test_a_source_folder_before_a_resource_folder_is_not_read_as_a_resource(self):
        root = self.tree()
        project = root / 'project.yml'
        original = project.read_text()
        marker = '      - path: App/SpokenMarginsApp/Resources/Supertonic\n'
        self.assertIn(marker, original)
        project.write_text(original.replace(marker, '      - path: App/NewSources\n' + marker, 1))
        self.assertEqual(notices.problems(root), [])

    def test_pip_option_lines_and_extras_are_read(self):
        root = self.tree()
        requirements = root / 'requirements-dev.txt'
        requirements.write_text('-r other.txt\n' + requirements.read_text())
        self.assertEqual(notices.problems(root), [])
        self.assertEqual(set(notices.pip_requirements(root)), {'jsonschema', 'lxml', 'pyyaml'})

    def test_a_stale_generated_file_fails(self):
        root = self.tree()
        with (root / 'THIRD_PARTY_NOTICES.md').open('a') as handle:
            handle.write('hand edit\n')
        self.assertProblem(root, 'THIRD_PARTY_NOTICES.md is out of date')


if __name__ == '__main__':
    unittest.main()
