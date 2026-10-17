"""Tests for the runner-side fork guard (#1719): the hook script itself, run as the runner would."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = 'uncomposed/spoken-margins-native'


def pr_payload(head_repo):
    return {'pull_request': {'number': 1, 'head': {'repo': None if head_repo is None else {'full_name': head_repo}}}}


class RunnerGuardTests(unittest.TestCase):
    def run_hook(self, event, payload, repository=REPO, raw=None):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'event.json'
            path.write_text(raw if raw is not None else json.dumps(payload))
            env = {**os.environ, 'GITHUB_EVENT_NAME': event, 'GITHUB_REPOSITORY': repository,
                   'GITHUB_EVENT_PATH': str(path)}
            result = subprocess.run(['bash', str(HERE / 'refuse-fork-jobs.sh')], env=env,
                                    capture_output=True, text=True, timeout=30)
            return result.returncode, result.stdout

    def test_table(self):
        rows = [
            # (event, payload, allowed, why)
            ('pull_request', pr_payload(REPO), True, 'same-repo PR'),
            ('pull_request', pr_payload(REPO.upper()), True, 'GitHub names are case-insensitive'),
            ('pull_request', pr_payload('stranger/spoken-margins-native'), False, 'fork PR'),
            ('pull_request', pr_payload('uncomposed/spoken-margins-native-fork'), False, 'lookalike name'),
            ('pull_request', pr_payload('uncomposed/spoken-margins-native '), False, 'trailing space'),
            ('pull_request', pr_payload(None), False, 'deleted fork: head.repo is null'),
            ('pull_request', {}, False, 'no pull_request in a PR event'),
            ('pull_request_target', pr_payload('stranger/x'), False, 'fork PR, target event'),
            ('pull_request_review', pr_payload('stranger/x'), False, 'fork PR review'),
            ('pull_request_review_comment', pr_payload(REPO), True, 'same-repo review comment'),
            ('issue_comment', {'issue': {'number': 1}}, False, 'anyone can comment'),
            ('push', {'ref': 'refs/heads/next'}, True, 'push needs write access'),
            ('workflow_dispatch', {'inputs': {}}, True, 'dispatch needs write access'),
            ('schedule', {}, True, 'schedule runs the default branch'),
        ]
        for event, payload, allowed, why in rows:
            with self.subTest(why=why):
                code, out = self.run_hook(event, payload)
                self.assertEqual(code == 0, allowed, out)

    def test_an_unreadable_payload_refuses_a_pull_request_job(self):
        code, out = self.run_hook('pull_request', None, raw='{not json')
        self.assertNotEqual(code, 0, out)

    def test_an_empty_repository_refuses_a_pull_request_job(self):
        code, out = self.run_hook('pull_request', pr_payload(REPO), repository='')
        self.assertNotEqual(code, 0, out)

    def test_an_unreadable_payload_still_allows_a_push(self):
        code, out = self.run_hook('push', None, raw='')
        self.assertEqual(code, 0, out)


if __name__ == '__main__':
    unittest.main()
