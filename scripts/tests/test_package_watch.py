import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import package_watch as pw  # noqa: E402

ONNX = 'https://github.com/Spoken-Margins/onnxruntime-swift-package-manager.git'
MS = 'https://github.com/microsoft/onnxruntime-swift-package-manager.git'


def pin(version='1.24.2', location=ONNX, branch=None, revision='b7fb7f7dea8a'):
    return {'identity': 'x', 'location': location, 'version': version, 'branch': branch, 'revision': revision, 'files': []}


def remote_of(table):
    return lambda url: table.get(url)


NONE = lambda slug: []  # noqa: E731
SAME = lambda slug: slug  # noqa: E731


class RangeTests(unittest.TestCase):
    def test_ranges(self):
        rows = [('0.9.16', '< 0.9.17', True), ('0.9.17', '< 0.9.17', False), ('0.9.20', '>= 0.9.0, < 0.9.20', False),
                ('0.9.19', '>= 0.9.0, < 0.9.20', True), ('1.0.0', '= 1.0', True), ('2.0.0', '<= 1.9.9', False),
                ('v1.2.3', '> 1.2', True), (None, '< 1.0', True), ('1.0.0', 'garbage', True)]
        for version, spec, want in rows:
            with self.subTest(version=version, spec=spec):
                self.assertEqual(pw.in_range(version, spec), want)

    def test_slug(self):
        self.assertEqual(pw.github_slug('https://github.com/weichsel/ZIPFoundation.git'), 'weichsel/ZIPFoundation')
        self.assertEqual(pw.github_slug('https://github.com/apple/swift-numerics'), 'apple/swift-numerics')
        self.assertIsNone(pw.github_slug('https://gitlab.com/a/b'))

    def test_newest_tag_ignores_non_versions(self):
        self.assertEqual(pw.newest_tag(['v1.15.0', '1.24.2', 'nightly', 'v1.19.2']), '1.24.2')


class FindingTests(unittest.TestCase):
    def kinds(self, found):
        return [kind for kind, _ in found]

    def test_upstream_gone_behind_a_copy_is_flagged_once(self):
        """#4512: Microsoft's repository answered 404 while our copy still worked."""
        found = pw.findings_for(pin(), MS, remote_of({ONNX: {'tags': ['1.24.2'], 'heads': {}}}), NONE, SAME)
        self.assertEqual(self.kinds(found), ['upstream-gone'])
        self.assertIn('only source', found[0][1])

    def test_source_we_build_from_gone(self):
        found = pw.findings_for(pin(location=MS), MS, remote_of({}), NONE, SAME)
        self.assertEqual(self.kinds(found), ['gone'])

    def test_newer_upstream_tag(self):
        table = {ONNX: {'tags': ['1.24.2'], 'heads': {}}, MS: {'tags': ['1.24.2', 'v1.30.0'], 'heads': {}}}
        found = pw.findings_for(pin(), MS, remote_of(table), NONE, SAME)
        self.assertEqual(self.kinds(found), ['newer'])

    def test_same_version_is_quiet(self):
        table = {ONNX: {'tags': ['1.24.2'], 'heads': {}}, MS: {'tags': ['1.24.2', 'v1.19.2'], 'heads': {}}}
        self.assertEqual(pw.findings_for(pin(), MS, remote_of(table), NONE, SAME), [])

    def test_branch_pin_moved(self):
        url = 'https://github.com/mattmireles/kokoro-coreml'
        table = {url: {'tags': [], 'heads': {'main': 'ffff0000'}}}
        found = pw.findings_for(pin(version=None, location=url, branch='main', revision='aaaa1111'), url,
                                remote_of(table), NONE, SAME)
        self.assertEqual(self.kinds(found), ['newer'])

    def test_renamed_upstream_is_moved(self):
        table = {ONNX: {'tags': ['1.24.2'], 'heads': {}}, MS: {'tags': ['1.24.2'], 'heads': {}}}
        found = pw.findings_for(pin(), MS, remote_of(table), NONE, lambda slug: 'microsoft/onnxruntime-spm')
        self.assertEqual(self.kinds(found), ['moved'])

    def test_advisory_covering_the_pin_is_flagged_and_an_old_one_is_not(self):
        url = 'https://github.com/weichsel/ZIPFoundation.git'
        table = {url: {'tags': ['0.9.20'], 'heads': {}}}

        def advisories(slug):
            return [{'ghsa_id': 'GHSA-old', 'severity': 'high', 'summary': 'path traversal',
                     'vulnerabilities': [{'package': {'name': 'github.com/weichsel/ZIPFoundation'},
                                          'vulnerable_version_range': '< 0.9.17'}]},
                    {'ghsa_id': 'GHSA-new', 'severity': 'high', 'summary': 'zip slip',
                     'vulnerabilities': [{'package': {'name': 'github.com/weichsel/ZIPFoundation'},
                                          'vulnerable_version_range': '<= 0.9.20'}]}]
        found = pw.findings_for(pin(version='0.9.20', location=url), url, remote_of(table), advisories, SAME)
        self.assertEqual(self.kinds(found), ['advisory-other', 'advisory'])


class AcceptedTests(unittest.TestCase):
    """#4579: a known state is accepted with a reason, so the weekly report stops re-opening it; a change re-flags."""

    def kinds(self, found):
        return [kind for kind, _ in found]

    def test_upstream_gone_is_accepted_with_its_reason(self):
        found = [('upstream-gone', 'the upstream X does not answer; our copy is now the only source')]
        out = pw.apply_accepted(found, {'upstream-gone': 'the copy is unmodified (#4568)'})
        self.assertEqual(self.kinds(out), ['accepted-upstream-gone'])
        self.assertIn('the copy is unmodified', out[0][1])
        self.assertFalse(pw.report({'a': (pin(), MS, out)})[2])

    def test_a_missing_or_empty_reason_accepts_nothing(self):
        found = [('upstream-gone', 'x'), ('newer', 'upstream tag 2.0.0 is newer than the pinned 1.0.0')]
        for accepted in ({}, {'upstream-gone': ''}, {'upstream-gone': '  '}, {'upstream-gone': {'why': 'x'}},
                         {'newer': {'through': '2.0.0'}}, {'newer': {'through': '2.0.0', 'why': ' '}}, {'newer': 'yes'}):
            with self.subTest(accepted=accepted):
                self.assertEqual(self.kinds(pw.apply_accepted(found, accepted)), ['upstream-gone', 'newer'])

    def test_newer_is_accepted_only_through_the_named_tag(self):
        rows = [('0.33.0', '0.33.0', True), ('0.33.0', 'v0.33.0', True), ('0.33.0', '0.34.0', True),
                ('0.34.0', '0.33.0', False), ('v0.7.1', 'v0.7.1', True), ('v0.7.2', 'v0.7.1', False),
                ('0.33.0', 'garbage', False), ('0.33.0', '', False)]
        for latest, through, accepted in rows:
            with self.subTest(latest=latest, through=through):
                found = [('newer', f'upstream tag {latest} is newer than the pinned 0.31.4')]
                out = pw.apply_accepted(found, {'newer': {'through': through, 'why': 'pinned on purpose'}})
                self.assertEqual(self.kinds(out), ['accepted-newer' if accepted else 'newer'])

    def test_a_malformed_table_flags_instead_of_crashing(self):
        found = [('upstream-gone', 'x'), ('newer', 'upstream tag 2.0.0 is newer than the pinned 1.0.0')]
        for accepted in (None, [], 'x', {'newer': {'through': '2.0.0', 'why': 5}}, {'newer': {'through': 7, 'why': 'x'}}):
            with self.subTest(accepted=accepted):
                out = pw.apply_accepted(found, accepted)
                self.assertEqual(len(out), 2)

    def test_real_findings_for_output_is_accepted(self):
        """Pins the wording coupling between findings_for and NEWER_TAG."""
        table = {ONNX: {'tags': ['1.24.2', 'v1.30.0'], 'heads': {}}}
        found = pw.findings_for(pin(), ONNX, remote_of(table), NONE, SAME)
        self.assertEqual(self.kinds(found), ['newer'])
        out = pw.apply_accepted(found, {'newer': {'through': 'v1.30.0', 'why': 'on purpose'}})
        self.assertEqual(self.kinds(out), ['accepted-newer'])

    def test_a_moved_branch_pin_is_never_accepted_as_newer(self):
        found = [('newer', 'upstream main is at ffff000, pinned aaaa111')]
        out = pw.apply_accepted(found, {'newer': {'through': '9.9.9', 'why': 'x'}})
        self.assertEqual(self.kinds(out), ['newer'])

    def test_a_gone_source_a_move_and_an_advisory_cannot_be_accepted(self):
        found = [('gone', 'a'), ('moved', 'b'), ('advisory', 'c'), ('advisory-other', 'd')]
        everything = {k: 'because' for k in ('gone', 'moved', 'advisory', 'upstream-gone')}
        self.assertEqual(self.kinds(pw.apply_accepted(found, everything)), ['gone', 'moved', 'advisory', 'advisory-other'])

    def test_each_accepted_entry_names_a_pinned_package(self):
        table = json.loads((pw.ROOT / pw.UPSTREAMS).read_text())
        pins = pw.collect_pins()
        for identity, entry in table.get('accepted', {}).items():
            with self.subTest(identity=identity):
                self.assertIn(identity, pins)
                self.assertTrue(set(entry) <= {'upstream-gone', 'newer'})
                if 'upstream-gone' in entry:
                    self.assertIn(identity, table['copies'])


class ReportTests(unittest.TestCase):
    def test_signature_is_stable_and_clean_when_nothing_flagged(self):
        quiet = {'a': (pin(), ONNX, []), 'b': (pin(), ONNX, [('advisory-other', 'old')])}
        text, sig, flagged = pw.report(quiet)
        self.assertEqual((sig, flagged), ('clean', False))
        loud = {'a': (pin(), MS, [('gone', 'x')])}
        self.assertEqual(pw.report(loud)[1], pw.report(dict(loud))[1])
        self.assertTrue(pw.report(loud)[2])

    def test_collect_pins_merges_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ('a.resolved', 'b.resolved'):
                Path(tmp, name).write_text(json.dumps({'pins': [
                    {'identity': 'zip', 'location': 'https://github.com/w/Z.git', 'state': {'version': '0.9.20', 'revision': 'r'}}]}))
            pins = pw.collect_pins(tmp, ('a.resolved', 'b.resolved', 'missing.resolved'))
        self.assertEqual(list(pins), ['zip'])
        self.assertEqual(pins['zip']['files'], ['a.resolved', 'b.resolved'])

    def test_upstreams_file_names_every_copy_in_the_resolved_files(self):
        copies = json.loads((pw.ROOT / pw.UPSTREAMS).read_text())['copies']
        pins = pw.collect_pins()
        for identity, entry in copies.items():
            self.assertIn(identity, pins)
            self.assertEqual(pins[identity]['location'].rstrip('/'), entry['copy'].rstrip('/'))


if __name__ == '__main__':
    unittest.main()
