"""scripts/lane_sender.py: only writers and the bot start lane runs (#1822)."""
import importlib.util
import unittest
import unittest.mock as mock
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lane_sender', SCRIPTS / 'lane_sender.py')
sender = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sender)

WORKFLOW = (SCRIPTS.parent / '.github/workflows/lane.yml').read_text()


class Decision(unittest.TestCase):
    def test_who_may_start_a_run(self):
        rows = [
            ('owner (admin)', 'uncomposed', 'admin', True),
            ('maintainer', 'm', 'maintain', True),
            ('collaborator with write', 'friend', 'write', True),
            ('triage permission only', 'triager', 'triage', False),
            ('read permission', 'reader', 'read', False),
            ('no permission', 'stranger', 'none', False),
            ('permission unknown', 'stranger', '', False),
            ('the bot', 'github-actions[bot]', '', True),
            ('lookalike bot', 'github-actions', '', False),
            ('lookalike bot, capitals', 'GitHub-Actions[bot]', '', False),
            ('no sender', '', 'admin', False),
        ]
        for name, login, permission, expected in rows:
            with self.subTest(name):
                self.assertIs(sender.trusted(login, permission), expected)

    def run_main(self, login, permission_json, code=0):
        found = mock.Mock(returncode=code, stdout=permission_json)
        with mock.patch.dict('os.environ', {'GH_REPO': 'o/r'}), mock.patch('subprocess.run', return_value=found) as run, \
                mock.patch('builtins.print') as printed:
            sender.main(['lane_sender.py', login])
        return printed.call_args_list[0].args[0], run

    def test_a_stranger_with_a_lookalike_login_is_refused(self):
        out, _ = self.run_main('github-actions', '{"permission": "none"}')
        self.assertEqual(out, 'trusted=false')

    def test_a_writer_is_accepted(self):
        out, _ = self.run_main('friend', '{"permission": "write"}')
        self.assertEqual(out, 'trusted=true')

    def test_a_failed_lookup_fails_closed_after_one_retry(self):
        out, run = self.run_main('friend', '', code=1)
        self.assertEqual(out, 'trusted=false')
        self.assertEqual(run.call_count, 2)

    def test_the_bot_needs_no_lookup(self):
        out, run = self.run_main('github-actions[bot]', '')
        self.assertEqual(out, 'trusted=true')
        run.assert_not_called()


class Wiring(unittest.TestCase):
    def test_the_route_job_checks_the_sender_and_skips_both_queues_for_a_stranger(self):
        self.assertIn('scripts/lane_sender.py', WORKFLOW)
        self.assertIn("github.event.sender.login", WORKFLOW)
        self.assertIn("steps.sender.outputs.trusted == 'false'", WORKFLOW)
        self.assertIn("skip_lane: ${{ steps.sender.outputs.trusted == 'false' && 'true' || steps.dedupe.outputs.skip_lane }}", WORKFLOW)
        self.assertIn("skip_automerge: ${{ steps.sender.outputs.trusted == 'false' && 'true' || steps.dedupe.outputs.skip_automerge }}", WORKFLOW)


if __name__ == '__main__':
    unittest.main()
