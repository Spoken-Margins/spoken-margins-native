"""#4575: the release gate on main's scheduled app tests (scripts/main_t3_gate.py).

It reads the `main-t3` status scripts/main_t3.py writes, so the context and the states are shared contract.
"""
from __future__ import annotations

import io
import json
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import main_t3 as T3  # noqa: E402
import main_t3_gate as G  # noqa: E402

SHA = 'a' * 40
OLD = 'b' * 40


def st(state, when='2026-11-23T10:00:00Z', context=G.CONTEXT, url=None):
    return {'context': context, 'state': state, 'created_at': when, 'target_url': url}


class FakeGh:
    """Answers the gate's gh calls: `statuses` is a list or None (GitHub down); `dispatch` says whether a run starts."""

    def __init__(self, statuses=None, nodes=None, dispatch=True, down=False):
        self.statuses, self.nodes, self.dispatch, self.down = statuses or [], nodes, dispatch, down
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ('workflow', 'run'):
            return '' if self.dispatch else None
        if self.down:
            return None
        if args[:2] == ('api', 'graphql'):
            return json.dumps({'data': {'repository': {'object': {'history': {'nodes': self.nodes or []}}}}})
        return json.dumps(self.statuses)

    def dispatched(self):
        return [c for c in self.calls if c[:2] == ('workflow', 'run')]


def run(argv, gh):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = G.main(argv, gh=gh)
    return code, out.getvalue(), err.getvalue()


class ContractTests(unittest.TestCase):
    def test_reads_the_context_main_t3_writes(self):
        self.assertEqual(G.CONTEXT, T3.CONTEXT)


class NewestStateTests(unittest.TestCase):
    def test_newest_main_t3_status_wins_and_other_contexts_are_ignored(self):
        statuses = [st('failure', '2026-11-23T09:00:00Z'), st('success', '2026-11-23T11:00:00Z', url='u'),
                    st('failure', '2026-11-23T12:00:00Z', context='lane')]
        self.assertEqual(G.newest_state(statuses), ('success', 'u'))

    def test_a_later_failure_overrides_an_earlier_success(self):
        statuses = [st('success', '2026-11-23T09:00:00Z'), st('failure', '2026-11-23T11:00:00Z')]
        self.assertEqual(G.newest_state(statuses)[0], 'failure')

    def test_none_and_junk(self):
        for statuses in (None, [], ['x', 3], [st('success', context='main-t3-old')]):
            self.assertEqual(G.newest_state(statuses), (None, None), statuses)


class NewestGreenTests(unittest.TestCase):
    def test_first_green_in_history_order(self):
        nodes = [{'oid': SHA, 'status': None}, {'oid': OLD, 'status': {'context': {'state': 'SUCCESS'}}},
                 {'oid': 'c' * 40, 'status': {'context': {'state': 'SUCCESS'}}}]
        self.assertEqual(G.newest_green(nodes), OLD)

    def test_failure_pending_error_and_missing_are_not_green(self):
        nodes = [{'oid': SHA, 'status': {'context': {'state': s}}} for s in ('FAILURE', 'PENDING', 'ERROR')]
        nodes += [{'oid': OLD, 'status': {'context': None}}, None, {'status': {'context': {'state': 'SUCCESS'}}}]
        self.assertIsNone(G.newest_green(nodes))
        self.assertIsNone(G.newest_green(None))


class GreenInHistoryTests(unittest.TestCase):
    def test_reads_the_history_and_reports_github_down(self):
        gh = FakeGh(nodes=[{'oid': OLD, 'status': {'context': {'state': 'SUCCESS'}}}])
        self.assertEqual(G.green_in_history(gh, 'o/r', SHA), (OLD, True))
        self.assertEqual(G.green_in_history(FakeGh(down=True), 'o/r', SHA), (None, False))

    def test_a_malformed_answer_counts_as_unread(self):
        self.assertEqual(G.green_in_history(lambda *a: '{"data": null}', 'o/r', SHA), (None, False))
        self.assertEqual(G.green_in_history(lambda *a: 'not json', 'o/r', SHA), (None, False))


class RefusalTests(unittest.TestCase):
    def test_every_refusal_names_the_sha(self):
        for state in (None, 'pending', 'failure', 'error', 'odd'):
            line = G.refusal(SHA, state)
            self.assertIn(SHA, line)
            self.assertIn('#4575', line)
        self.assertIn('could not be read', G.refusal(SHA, None, read=False))
        self.assertIn('runner fault', G.refusal(SHA, 'error'))


class CheckCommandTests(unittest.TestCase):
    def test_green_is_allowed(self):
        code, out, _ = run(['check', '--sha', SHA], FakeGh([st('success', url='https://x/run')]))
        self.assertEqual(code, 0)
        self.assertIn(f'allowed {SHA}', out)
        self.assertIn('https://x/run', out)

    def test_not_green_is_refused_with_the_sha(self):
        for statuses in ([], [st('failure')], [st('error')], [st('pending')]):
            gh = FakeGh(statuses)
            code, _, err = run(['check', '--sha', SHA], gh)
            self.assertEqual(code, 1, statuses)
            self.assertIn(f'refused {SHA}', err)
            self.assertEqual(gh.dispatched(), [], 'check without --request starts nothing')

    def test_request_starts_a_forced_run_unless_one_is_going(self):
        gh = FakeGh([st('error')])
        code, _, err = run(['check', '--sha', SHA, '--request'], gh)
        self.assertEqual(code, 1)
        self.assertEqual(gh.dispatched(), [('workflow', 'run', 'main-t3.yml', '--repo', G.DEFAULT_REPO, '-f', f'sha={SHA}',
                                             '-f', 'force=true')])
        self.assertIn('started a main-t3 run', err)
        gh = FakeGh([st('pending')])
        run(['check', '--sha', SHA, '--request'], gh)
        self.assertEqual(gh.dispatched(), [])

    def test_a_real_failure_starts_no_run_that_would_fail_again(self):
        gh = FakeGh([st('failure')])
        code, _, err = run(['check', '--sha', SHA, '--request'], gh)
        self.assertEqual(code, 1)
        self.assertEqual(gh.dispatched(), [])
        self.assertIn('started no run', err)

    def test_a_short_or_malformed_sha_is_refused_before_github_is_asked(self):
        for bad in ('abc1234', 'g' * 40, SHA + 'a', ''):
            gh = FakeGh([st('success')])
            with self.assertRaises(SystemExit) as stop, redirect_stderr(io.StringIO()):
                G.main(['check', '--sha', bad, '--request'], gh=gh)
            self.assertEqual(stop.exception.code, 2, bad)
            self.assertEqual(gh.calls, [], bad)
        self.assertFalse(G.request(FakeGh(), G.DEFAULT_REPO, 'abc1234'))

    def test_github_down_exits_2_and_starts_nothing(self):
        gh = FakeGh(down=True)
        code, _, err = run(['check', '--sha', SHA, '--request'], gh)
        self.assertEqual(code, 2)
        self.assertIn('could not be read', err)
        self.assertEqual(gh.dispatched(), [])

    def test_a_non_list_answer_is_unread(self):
        code, _, _ = run(['check', '--sha', SHA], lambda *a: '{"message": "Not Found"}')
        self.assertEqual(code, 2)


class RequestCommandTests(unittest.TestCase):
    def test_request(self):
        self.assertEqual(run(['request', '--sha', SHA], FakeGh())[0], 0)
        code, _, err = run(['request', '--sha', SHA], FakeGh(dispatch=False))
        self.assertEqual(code, 2)
        self.assertIn('could not start', err)


if __name__ == '__main__':
    unittest.main()
