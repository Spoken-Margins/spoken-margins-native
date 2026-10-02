import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane_xcresult_attachments as attachments

TEST = 'App/JourneyTests/testImport'
URL = 'test://com.apple.xcode/Project/App/JourneyTests/testImport'
PAYLOAD = {'testNodes': [{'nodeType': 'UI test bundle', 'name': 'App', 'children': [
    {'nodeType': 'Test Case', 'nodeIdentifier': 'JourneyTests/testImport()',
     'nodeIdentifierURL': URL, 'hasMediaAttachments': False}]}]}


class AttachmentTests(unittest.TestCase):
    def export(self, groups, files=()):
        def run(args, **kwargs):
            directory = Path(args[args.index('--output-path') + 1])
            for file in files:
                (directory / file).write_bytes(b'evidence')
            (directory / 'manifest.json').write_text(json.dumps(groups))
            return subprocess.CompletedProcess(args, 0)
        return run

    def recover(self, groups, files=()):
        with tempfile.TemporaryDirectory() as tmp, patch.object(
                attachments.subprocess, 'run', side_effect=self.export(groups, files)):
            return attachments.export_failed_attachments('retained.xcresult',
                       {TEST: {'status': 'failed'}}, PAYLOAD, Path(tmp))

    def test_no_export_for_passing_or_skipped_tests(self):
        with patch.object(attachments.subprocess, 'run') as run:
            self.assertEqual(attachments.export_failed_attachments('bundle', {
                TEST: {'status': 'passed'}, 'App/JourneyTests/testSkip': {'status': 'skipped'}},
                PAYLOAD, Path('/unused')), [])
            run.assert_not_called()

    def test_unfiltered_files_and_manifest_are_retained(self):
        result = self.recover([{'testIdentifierURL': URL, 'attachments': [
            {'exportedFileName': 'recording.mp4', 'isAssociatedWithFailure': False}]}], ['recording.mp4'])[0]
        self.assertNotIn('error', result)
        self.assertEqual(len(result['files']), 1)
        self.assertTrue(result['manifest'].endswith('/manifest.json'))

    def test_empty_export_warns_instead_of_claiming_no_retained_media(self):
        result = self.recover([])[0]
        self.assertIn('absence of retained media is not established', result['error'])
        self.assertIn('Export warning:', '\n'.join(attachments.report_lines([result])))

    def test_different_test_manifest_is_rejected(self):
        result = self.recover([{'testIdentifierURL': URL + 'Other', 'attachments': []}])[0]
        self.assertIn('different test', result['error'])

    def test_export_cannot_link_an_unrelated_file_outside_test_directory(self):
        for name in ('../manifest.json', '/etc/hosts', 'missing.mp4'):
            with self.subTest(name=name):
                result = self.recover([{'testIdentifierURL': URL,
                                       'attachments': [{'exportedFileName': name}]}])[0]
                self.assertEqual(result['files'], [])
                self.assertIn('missing or outside', result['error'])

    def test_bad_manifest_is_a_warning(self):
        for groups in ({'attachments': []}, [None], [{'testIdentifierURL': URL, 'attachments': [None]}]):
            with self.subTest(groups=groups):
                self.assertIn('error', self.recover(groups)[0])

    def test_export_failure_is_reported_per_test(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(
                attachments.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['xcrun'], 60)):
            result = attachments.export_failed_attachments('retained.xcresult',
                {TEST: {'status': 'failed'}}, PAYLOAD, Path(tmp))[0]
            self.assertIn('TimeoutExpired', result['error'])
            self.assertTrue(Path(result['export_log']).is_file())

    def test_total_budget_exhaustion_reports_every_unexported_failed_test(self):
        records = {TEST: {'status': 'failed'}, TEST + 'Again': {'status': 'failed'}}
        with tempfile.TemporaryDirectory() as tmp, patch.object(
                attachments.time, 'monotonic', side_effect=[0, 181, 182]), \
                patch.object(attachments.subprocess, 'run') as run:
            results = attachments.export_failed_attachments('bundle', records, PAYLOAD, Path(tmp))
            self.assertEqual({r['test'] for r in results}, set(records))
            self.assertTrue(all('total budget exhausted' in r['error'] for r in results))
            run.assert_not_called()

    def test_log_only_failure_uses_test_id_and_a_bounded_unique_directory(self):
        records = {'App/JourneyTests/test' + 'Long' * 100: {'status': 'failed'},
                   'OtherApp/JourneyTests/test' + 'Long' * 100: {'status': 'failed'}}
        with tempfile.TemporaryDirectory() as tmp, patch.object(
                attachments.subprocess, 'run', side_effect=self.export([])) as run:
            results = attachments.export_failed_attachments('bundle', records, None, Path(tmp))
            directories = [Path(r['manifest']).parent for r in results]
            self.assertEqual(len(set(directories)), 2)
            self.assertTrue(all(len(d.name) <= 77 for d in directories))
            self.assertTrue(all(r['selector'].startswith('JourneyTests/test') for r in results))
            self.assertTrue(all(call.kwargs['timeout'] <= 60 for call in run.call_args_list))
