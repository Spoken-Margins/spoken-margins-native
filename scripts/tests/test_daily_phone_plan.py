"""Daily phone-plan fixtures: no network, builds, audio, launchd or real phone."""
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch, Mock

SCRIPTS = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('daily_phone_plan', str(SCRIPTS / 'daily-phone-plan'))
spec = importlib.util.spec_from_loader('daily_phone_plan', loader)
daily = importlib.util.module_from_spec(spec)
loader.exec_module(daily)
SHA = 'a' * 40


def issue(number, pr=200, check='Tap Play. Hear the article once.'):
    return {'number': number, 'title': f'Fix {number}', 'body': f'Owner check: {check}',
            'state': 'OPEN', 'createdAt': '2026-10-01', 'comments': {'nodes': []},
            'labels': {'nodes': [{'name': daily.phone.MERGED_ON_NEXT}]},
            'timelineItems': {'nodes': [{'source': {'number': pr, 'merged': True,
                                                   'body': f'Fixes #{number}', 'title': f'Fix #{number}'}}]}}


class ScheduleTests(unittest.TestCase):
    def test_central_times_and_dst_independent_of_mac_timezone(self):
        for before, morning, evening in [('2026-10-14T12:59:00+00:00', '2026-10-14T13:00:00+00:00',
                                         '2026-10-14T22:00:00+00:00'),
                                        ('2026-11-02T13:59:00+00:00', '2026-11-02T14:00:00+00:00',
                                         '2026-11-02T23:00:00+00:00')]:
            self.assertIsNone(daily.slot(dt.datetime.fromisoformat(before), {}))
            am = daily.slot(dt.datetime.fromisoformat(morning), {})
            self.assertTrue(am.endswith('-am'))
            self.assertIsNone(daily.slot(dt.datetime.fromisoformat(morning), {'slots': [am]}))
            self.assertTrue(daily.slot(dt.datetime.fromisoformat(evening), {}).endswith('-pm'))

    def test_three_unanswered_plans_require_owner_request(self):
        now = dt.datetime.fromisoformat('2026-10-14T13:00:00+00:00')
        self.assertIsNone(daily.slot(now, {'unanswered': 3}))
        self.assertIn('request', daily.slot(now, {'unanswered': 3}, True))
        self.assertIsNone(daily.slot(now, {'unanswered': 0, 'on_request_only': True}))

    def test_launchd_runs_lightweight_tick_not_an_extra_build(self):
        data = plistlib.loads((SCRIPTS / 'com.spokenmargins.daily-phone-plan.plist').read_bytes())
        self.assertEqual(data['StartInterval'], 300)
        self.assertTrue(data['ProgramArguments'][1].endswith('/daily-phone-plan'))
        self.assertNotIn('--if-changed', data['ProgramArguments'])

    def test_backlog_query_does_not_silently_truncate(self):
        page = {'data': {'repository': {'issues': {'nodes': [issue(101)],
                'pageInfo': {'hasNextPage': True, 'endCursor': 'more'}}}}}
        with patch.object(daily.phone, 'gh', return_value=json.dumps(page)):
            self.assertIsNone(daily.phone.fetch_waiting())


class CollectionTests(unittest.TestCase):
    def setUp(self):
        self.patches = [patch.object(daily.phone, 'fetch_waiting', return_value=[issue(101), issue(102)]),
                        patch.object(daily.phone, 'build_prs', return_value={200}),
                        patch.object(daily.phone, 'built_numbers', return_value={200, 101, 102}),
                        patch.object(daily.phone, 'reverted_prs', return_value=set()),
                        patch.object(daily.phone, 'fetch_items', return_value={}),
                        patch.object(daily.phone, 'repo_files', return_value=[])]
        self.mocks = [p.start() for p in self.patches]
        for p in self.patches:
            self.addCleanup(p.stop)

    def test_all_open_fixes_in_binary_including_previous_plan(self):
        items, prior = daily.collect(SHA, [101])
        self.assertEqual({item['number'] for item in items}, {101, 102})
        self.assertEqual(prior, [101])
        self.assertTrue(all(item['check'] and not item['blocked'] for item in items))

    def test_rejects_lost_previous_issue_build_evidence(self):
        self.mocks[0].return_value = [issue(101, pr=999), issue(102)]
        self.mocks[2].return_value = {200, 102}
        with self.assertRaisesRegex(RuntimeError, '#101'):
            daily.collect(SHA, [101])

    def test_reverted_previous_issue_stays_visible_as_blocked(self):
        self.mocks[3].return_value = {200}
        self.mocks[1].return_value = set()
        self.mocks[2].return_value = set()
        items, prior = daily.collect(SHA, [101])
        self.assertEqual(prior, [101])
        self.assertEqual(items[0]['number'], 101)
        self.assertIn('reverted', items[0]['blocked'])

    def test_closed_prior_issue_does_not_hold_new_plan_back(self):
        self.mocks[0].return_value = [issue(102)]
        self.mocks[4].return_value = {101: {'number': 101, 'state': 'CLOSED'}}
        items, prior = daily.collect(SHA, [101])
        self.assertEqual(prior, [])
        self.assertEqual([item['number'] for item in items], [102])

    def test_prior_issue_still_open_after_label_removed_is_explicitly_blocked(self):
        self.mocks[0].return_value = [issue(102)]
        self.mocks[4].return_value = {101: {'number': 101, 'state': 'OPEN', 'title': 'Still open'}}
        items, prior = daily.collect(SHA, [101])
        self.assertEqual(prior, [101])
        self.assertIn(101, [item['number'] for item in items])
        self.assertIn('label was removed', next(item['blocked'] for item in items if item['number'] == 101))

    def test_unknown_previous_issue_state_is_not_silently_dropped(self):
        self.mocks[0].return_value = [issue(102)]
        with self.assertRaisesRegex(RuntimeError, 'cannot verify'):
            daily.collect(SHA, [101])

    def test_future_fix_is_excluded_and_missing_pdf_stays_blocked(self):
        self.mocks[0].return_value = [issue(101, 999), issue(102, check='Import a PDF. Tap Play.')]
        self.mocks[2].return_value = {200, 102}
        items, _ = daily.collect(SHA, [])
        self.assertEqual([item['number'] for item in items], [102])
        self.assertIn('PDF', items[0]['blocked'])

    def test_offline_does_not_replace_plan(self):
        self.mocks[0].return_value = None
        with self.assertRaisesRegex(RuntimeError, 'GitHub unavailable'):
            daily.collect(SHA, [101])

    def test_controls_are_from_selected_binary_including_dynamic_play_label(self):
        source = 'Button("Write a Margin") {}\n.accessibilityLabel(playing ? "Pause" : "Play")'
        with patch.object(daily.phone, 'git', side_effect=['App/PlaybackScreen.swift\n', source]) as git:
            catalog = daily.control_catalog(SHA)
        self.assertEqual(catalog['Play'], 'App/PlaybackScreen.swift')
        self.assertEqual(catalog['Pause'], 'App/PlaybackScreen.swift')
        self.assertEqual(git.call_args_list[1].args, ('show', f'{SHA}:App/PlaybackScreen.swift'))
        self.assertNotIn('Invented control', catalog)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.folder = self.root / '20261014-080000-aaaaaaa'
        self.folder.mkdir()
        (self.folder / daily.phone.APP_NAME).mkdir()
        (self.folder / 'build.json').write_text(json.dumps({'sha': SHA, 'bundle_version': '33'}))
        (self.root / 'latest').symlink_to(self.folder.name)
        self.state_path = self.root / 'daily-plan-state.json'
        self.now = dt.datetime.fromisoformat('2026-10-14T13:00:00+00:00')
        self.items = [{'number': n, 'title': f'Fix {n}', 'check': 'Tap Play.', 'prs': [200], 'blocked': None,
                       'in_build': True}
                      for n in (101, 102)]
        self.proposal = {'checks': [{'issues': [101, 102], 'source': 'one article', 'setup': 'Open it.',
                                    'controls': ['Play'], 'action': 'Tap **Play**.', 'expected': 'One voice.',
                                    'minutes': 1}], 'blocked': []}
        patches = {'collect': Mock(return_value=(self.items, [])), 'control_catalog': Mock(return_value={'Play': 'app'}),
                   'propose': Mock(return_value=self.proposal),
                   'validate': Mock(return_value={'markdown': 'both checks', 'minutes': 3}), 'relay': Mock()}
        self.mocks = {}
        for name, mock in patches.items():
            p = patch.object(daily, name, mock)
            p.start()
            self.addCleanup(p.stop)
            self.mocks[name] = mock
        for name, value in [('phone_dir', self.root), ('guard_reason', None), ('attach_files', []),
                            ('share_files', None), ('notify', None)]:
            p = patch.object(daily.phone, name, return_value=value)
            self.mocks[name] = p.start()
            self.addCleanup(p.stop)
        p = patch.object(daily.subprocess, 'run', return_value=Mock(returncode=0))
        self.mocks['run'] = p.start()
        self.addCleanup(p.stop)

    def test_delivers_once_and_pins_plan_to_rolling_binary(self):
        state = {}
        self.assertIn('delivered', daily.deliver(self.now, state, self.state_path))
        self.assertEqual((self.root / 'daily-ready').resolve(), self.folder.resolve())
        self.assertEqual((self.folder / 'test-plan.md').read_text(), 'both checks')
        self.assertIn('not due', daily.deliver(self.now, state, self.state_path))
        self.mocks['relay'].assert_called_once()
        self.mocks['notify'].assert_called_once()
        self.mocks['propose'].assert_called_once()
        self.assertEqual(state['issues'], [101, 102])
        self.assertEqual(self.mocks['run'].call_args.args[0][:2], ['git', 'merge-base'])
        ledger = json.loads((self.root / 'daily-plan-ledger/step-ledger.json').read_text())
        self.assertEqual(ledger['steps']['daily-phone-plan']['runs'], 1)

    def test_on_request_writer_timeout_still_moves_the_pin_with_a_plain_plan(self):
        # Seen 2026-10-23 (#2529): the headless writer timed out after 180 s and the pin never moved.
        self.mocks['propose'].side_effect = daily.subprocess.TimeoutExpired('claude', 180)
        state = {}
        self.assertIn('delivered', daily.deliver(self.now, state, self.state_path, on_request=True))
        self.assertEqual((self.root / 'daily-ready').resolve(), self.folder.resolve())
        plan = (self.folder / 'test-plan.md').read_text()
        self.assertIn('plain plan', plan)
        self.assertIn('#101 Fix 101', plan)
        self.assertIn('Tap Play.', plan)
        self.mocks['validate'].assert_not_called()
        self.mocks['relay'].assert_called_once()
        self.assertIn('plain plan', self.mocks['relay'].call_args.args[0])
        record = json.loads(next((self.root / 'daily-plans').glob('*/plan.json')).read_text())
        self.assertTrue(record['plain'])
        self.assertEqual(record['proposal']['checks'], [])
        self.assertEqual({entry['issue'] for entry in record['proposal']['blocked']}, {101, 102})

    def test_automatic_writer_timeout_is_still_an_error_not_a_plain_plan(self):
        self.mocks['propose'].side_effect = daily.subprocess.TimeoutExpired('claude', 180)
        with self.assertRaises(daily.subprocess.TimeoutExpired):
            daily.deliver(self.now, {}, self.state_path)
        self.assertFalse((self.root / 'daily-ready').exists())
        self.mocks['relay'].assert_not_called()

    def test_plain_plan_cannot_close_issues(self):
        self.mocks['propose'].side_effect = RuntimeError('plan writer failed; previous plan kept')
        daily.deliver(self.now, {}, self.state_path, on_request=True)
        path = next((self.root / 'daily-plans').glob('*/plan.json'))
        reply = f'Phone pass {path.parent.name}; build {SHA}\n#101: PASS\n'
        with self.assertRaises(ValueError):
            daily.parse_results(reply, json.loads(path.read_text()))

    def test_5_pm_threshold_counts_new_fixes_not_total_backlog(self):
        evening = self.now.replace(hour=22)
        self.items[:] = [dict(self.items[0], number=n) for n in range(101, 108)]
        state = {'issues': [101, 102, 103]}
        self.assertIn('fewer than five', daily.deliver(evening, state, self.state_path))
        self.mocks['propose'].assert_not_called()
        self.assertIn('not due', daily.deliver(evening, state, self.state_path))
        self.items.append(dict(self.items[0], number=108))
        self.assertIn('delivered', daily.deliver(evening, {'issues': [101, 102, 103]}, self.state_path))

    def test_three_consecutive_unanswered_days_stop_automatic_delivery(self):
        state = {}
        for offset in range(3):
            self.assertIn('delivered', daily.deliver(self.now + dt.timedelta(days=offset), state, self.state_path))
        self.assertEqual(state['unanswered'], 3)
        self.assertTrue(state['on_request_only'])
        self.assertIn('not due', daily.deliver(self.now + dt.timedelta(days=3), state, self.state_path))
        self.assertEqual(self.mocks['propose'].call_count, 3)

    def test_resource_gate_prevents_writer_and_delivery(self):
        self.mocks['guard_reason'].return_value = 'low disk'
        self.assertIn('resource gate', daily.deliver(self.now, {}, self.state_path))
        self.mocks['propose'].assert_not_called()
        self.mocks['relay'].assert_not_called()

    def test_failed_relay_reuses_validated_plan_without_second_writer_call(self):
        self.mocks['relay'].side_effect = RuntimeError('relay down')
        state = {}
        with self.assertRaisesRegex(RuntimeError, 'relay down'):
            daily.deliver(self.now, state, self.state_path)
        self.assertNotIn('slots', state)
        self.mocks['relay'].side_effect = None
        daily.deliver(self.now, state, self.state_path)
        self.mocks['propose'].assert_called_once()
        self.mocks['validate'].assert_called_once()

    def test_pinned_binary_is_not_pruned_when_rolling_tip_advances(self):
        for day in range(15, 19):
            (self.root / f'202610{day}-080000-aaaaaaa').mkdir()
        (self.root / 'daily-ready').symlink_to(self.folder.name)
        daily.phone.prune()
        self.assertTrue(self.folder.exists())
        self.assertFalse((self.root / '20261015-080000-aaaaaaa').exists())

    def record(self):
        daily.deliver(self.now, {}, self.state_path)
        path = self.root / 'daily-plans/2026-10-14-am/plan.json'
        return path, json.loads(path.read_text())

    def test_reply_requires_exact_build_explicit_verdict_and_failure_details(self):
        _, record = self.record()
        header = f'Phone pass {record["id"]}; build {SHA}\n'
        self.assertEqual(daily.parse_results(header + '#101: PASS\n#102: FAIL heard two voices', record),
                         {101: ('PASS', ''), 102: ('FAIL', 'heard two voices')})
        for text in ['#101: PASS', header + '#101: TODO', header + '#101: FAIL',
                     header + '#101: PASS\n#101: FAIL again', header + '#999: PASS']:
            with self.assertRaises(ValueError):
                daily.parse_results(text, record)

    def test_result_batch_closes_pass_files_failure_and_leaves_skips_open(self):
        path, record = self.record()
        reply = f'Phone pass {record["id"]}; build {SHA}\n#101: PASS\n#102: FAIL heard two voices'
        with patch.object(daily.phone, 'gh', side_effect=['[]', 'https://github.com/test/issues/300\n']) as gh:
            daily.apply_results(reply, {}, self.state_path)
        commands = self.mocks['run'].call_args_list
        self.assertEqual(commands[-1].args[0][1:4], ['close-issue', '101', '--pr'])
        self.assertIn('bug,found-on-phone', gh.call_args.args)
        self.assertIn('Solid Ground', gh.call_args.args)
        self.assertFalse((self.root / 'daily-ready').exists())
        result = json.loads(path.read_text())
        self.assertEqual(result['results']['101']['verdict'], 'PASS')
        self.assertEqual(result['results']['102']['verdict'], 'FAIL')
        self.mocks['run'].reset_mock()
        with patch.object(daily.phone, 'gh') as gh:
            daily.apply_results(reply, {}, self.state_path)
            gh.assert_not_called()
        self.mocks['run'].assert_not_called()

    def test_skip_and_absent_results_cannot_close_issues(self):
        _, record = self.record()
        self.mocks['run'].reset_mock()
        with patch.object(daily.phone, 'gh') as gh:
            daily.apply_results(f'Phone pass {record["id"]}; build {SHA}\n#101: SKIP', {}, self.state_path)
            gh.assert_not_called()
        self.mocks['run'].assert_not_called()
        self.assertTrue((self.root / 'daily-ready').exists())

    def test_writer_cannot_upgrade_blocked_prerequisite_to_runnable_check(self):
        self.items[0]['blocked'] = 'Missing supplied PDF.'
        with self.assertRaisesRegex(RuntimeError, 'prerequisite block'):
            daily.deliver(self.now, {}, self.state_path)
        self.mocks['validate'].assert_not_called()
        self.mocks['relay'].assert_not_called()

    def test_writer_failure_is_not_blindly_retried(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / 'writer.json').write_text('failed attempt')
            with self.assertRaisesRegex(RuntimeError, 'already attempted'):
                # Invoke the real function rather than this class's mock.
                self.mocks['propose'].assert_not_called()
                loader2 = importlib.machinery.SourceFileLoader('daily_phone_again', str(SCRIPTS / 'daily-phone-plan'))
                spec2 = importlib.util.spec_from_loader('daily_phone_again', loader2)
                module = importlib.util.module_from_spec(spec2)
                loader2.exec_module(module)
                module.propose(self.items, {}, folder)


class WriterOutputTests(unittest.TestCase):
    def test_plan_json_is_read_with_or_without_a_markdown_fence(self):
        plan = {'checks': [{'issues': [1]}], 'blocked': []}
        body = json.dumps(plan)
        for text in (body, '```json\n' + body + '\n```', '```\n' + body + '\n```',
                     '  ```json\n' + body + '\n```  \n', '\n' + body + '\n'):
            with self.subTest(text=text[:12]):
                self.assertEqual(daily.writer_plan(text), plan)

    def test_text_that_is_not_json_still_fails(self):
        for text in ('', 'Here is the plan:', '```json\nnot json\n```'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                daily.writer_plan(text)

    def test_writer_uses_the_keychain_token_and_never_an_api_key(self):
        found = subprocess.CompletedProcess([], 0, stdout='token-from-keychain\n', stderr='')
        with patch.dict(os.environ, {'ANTHROPIC_API_KEY': 'sk-x'}, clear=False), \
                patch.object(daily.subprocess, 'run', return_value=found) as run:
            os.environ.pop('CLAUDE_CODE_OAUTH_TOKEN', None)
            env = daily.writer_env()
        self.assertEqual(env['CLAUDE_CODE_OAUTH_TOKEN'], 'token-from-keychain')
        self.assertNotIn('ANTHROPIC_API_KEY', env)
        self.assertIn('claude-code-oauth', run.call_args.args[0])

    def test_an_existing_token_is_kept_without_reading_the_keychain(self):
        with patch.dict(os.environ, {'CLAUDE_CODE_OAUTH_TOKEN': 'already'}, clear=False), \
                patch.object(daily.subprocess, 'run') as run:
            env = daily.writer_env()
        self.assertEqual(env['CLAUDE_CODE_OAUTH_TOKEN'], 'already')
        run.assert_not_called()


class OmittedIssueTests(unittest.TestCase):
    def test_an_issue_the_writer_left_out_is_blocked_not_checked(self):
        items = [{'number': 1, 'blocked': ''}, {'number': 2, 'blocked': ''},
                 {'number': 3, 'blocked': ''}, {'number': 4, 'blocked': 'Fix was reverted.'}]
        proposal = {'checks': [{'issues': [1]}], 'blocked': [{'issue': 2, 'reason': 'No check.'}]}
        daily.add_omitted(proposal, items)
        self.assertEqual(proposal['checks'], [{'issues': [1]}])
        self.assertEqual(proposal['blocked'], [{'issue': 2, 'reason': 'No check.'},
                                               {'issue': 3, 'reason': daily.OMITTED},
                                               {'issue': 4, 'reason': 'Fix was reverted.'}])

    def test_a_complete_plan_is_unchanged(self):
        items = [{'number': 1, 'blocked': ''}, {'number': 2, 'blocked': ''}]
        proposal = {'checks': [{'issues': [1, 2]}], 'blocked': []}
        daily.add_omitted(proposal, items)
        self.assertEqual(proposal, {'checks': [{'issues': [1, 2]}], 'blocked': []})


if __name__ == '__main__':
    unittest.main()
