import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import usage

# Usage event recorded from a read-only Codex CLI probe on the Mac, 2026-10-06.
# The full transcript stays in artifacts/879/; no prompt or thread identity here.
RECORDED = '''{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK"}}
{"type":"turn.completed","usage":{"input_tokens":20154,"cached_input_tokens":13184,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
'''


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.transcript = self.root / 'transcript.jsonl'
        self.transcript.write_text(RECORDED)

    def test_recorded_usage_is_exact_and_cache_is_part_of_input(self):
        result = usage.read_usage(self.transcript)
        self.assertEqual([result[k] for k in usage.TOKEN_FIELDS], [20154, 13184, 5])
        self.assertIsNone(result['usage_missing_reason'])

    def test_multiple_turns_sum_usage_but_items_are_not_counted(self):
        self.transcript.write_text(RECORDED * 2 + 'warning: ignored stderr\n')
        result = usage.read_usage(self.transcript)
        self.assertEqual(result['input_tokens'], 40308)
        self.assertEqual(result['output_tokens'], 10)

    def test_missing_malformed_and_partial_usage_are_explicit(self):
        for raw in ('', '{"type":"turn.failed"}\n',
                    '{"type":"turn.completed","usage":{"input_tokens":true}}\n'):
            with self.subTest(raw=raw):
                self.transcript.write_text(raw)
                result = usage.read_usage(self.transcript)
                self.assertIsNone(result['output_tokens'])
                self.assertTrue(result['usage_missing_reason'])
        self.transcript.write_text(RECORDED + '{"type":"turn.started"}\n')
        result = usage.read_usage(self.transcript)
        self.assertEqual(result['input_tokens'], 20154)
        self.assertFalse(result['usage_complete'])

    def test_failed_run_keeps_usage_outcome_and_comment(self):
        record = usage.Run(self.root / 'ledger', 'issue', 'model', 'high', self.transcript,
                           targets=[{'pr': None, 'issues': [879], 'head_sha': 'a' * 40,
                                     'base_sha': 'b' * 40, 'trigger': 'new ready issue'}])
        record.finish({'kind': 'failed', 'reason': 'Codex killed: exit -9'},
                      comment_url='https://github.com/comment')
        rows = [json.loads(line) for line in (self.root / 'ledger/usage.jsonl').read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['input_tokens'], 20154)
        self.assertEqual(rows[0]['outcome']['reason'], 'Codex killed: exit -9')
        self.assertEqual(rows[0]['comment_url'], 'https://github.com/comment')
        self.assertGreaterEqual(rows[0]['wall_time_seconds'], 0)
        self.assertFalse(list((self.root / 'ledger/pending').glob('*.json')))

    def test_interrupted_wrapper_is_recovered_once_and_live_run_is_left_alone(self):
        record = usage.Run(self.root / 'ledger', 'audit', 'model', 'high', self.transcript,
                           targets=[{'pr': 1}, {'pr': 2}])
        usage.recover(self.root / 'ledger')
        self.assertFalse((self.root / 'ledger/usage.jsonl').exists())
        record.close()  # Equivalent to the OS releasing the wrapper's lock on SIGKILL.
        usage.recover(self.root / 'ledger')
        usage.recover(self.root / 'ledger')
        rows = (self.root / 'ledger/usage.jsonl').read_text().splitlines()
        self.assertEqual(len(rows), 1)
        row = json.loads(rows[0])
        self.assertEqual(row['outcome']['kind'], 'failed')
        self.assertEqual(len(row['targets']), 2)  # One batch, no double counting.

    def test_ledger_write_error_is_logged_and_does_not_raise(self):
        blocked = self.root / 'blocked'
        blocked.write_text('not a directory')
        logs = []
        record = usage.Run(blocked, 'issue', 'model', 'high', self.transcript, log=logs.append)
        record.finish({'kind': 'stop note'})
        self.assertTrue(any('usage ledger' in line for line in logs))

    def test_torn_append_is_preserved_and_recovered_without_corrupting_jsonl(self):
        record = usage.Run(self.root / 'ledger', 'audit', 'model', 'high', self.transcript)
        (self.root / 'ledger/usage.jsonl').write_text('{"run_id":')
        record.close()
        usage.recover(self.root / 'ledger')
        row = json.loads((self.root / 'ledger/usage.jsonl').read_text())
        self.assertEqual(row['output_tokens'], 5)
        self.assertEqual(len(list((self.root / 'ledger').glob('torn-*.txt'))), 1)

    def test_real_killed_wrapper_is_recovered_from_its_retained_transcript(self):
        code = ('import sys, time; from pathlib import Path; import usage; '
                'r=usage.Run(Path(sys.argv[1]), "audit", "model", "high", Path(sys.argv[2])); '
                'print("ready", flush=True); time.sleep(30)')
        proc = subprocess.Popen([sys.executable, '-c', code, str(self.root / 'ledger'), str(self.transcript)],
                                cwd=Path(__file__).resolve().parent, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(proc.stdout.readline().strip(), 'ready')
            proc.kill()
            proc.wait(timeout=5)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            proc.stdout.close()
        usage.recover(self.root / 'ledger')
        row = json.loads((self.root / 'ledger/usage.jsonl').read_text())
        self.assertEqual(row['output_tokens'], 5)
        self.assertEqual(row['outcome']['kind'], 'failed')


if __name__ == '__main__':
    unittest.main()
