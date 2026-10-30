"""scripts/pipeline_dashboard.py (#2379): the daily snapshot on the `metrics` branch and the issue body."""
import datetime as dt
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane_event  # noqa: E402
import pipeline_dashboard as dash  # noqa: E402
import pipeline_events as pe  # noqa: E402
import test_pipeline_events as fixtures  # noqa: E402

NOW = dt.datetime(2026, 10, 30, 12, 0, tzinfo=dt.timezone.utc)


def lane(**fields):
    base = {'kind': 'lane', 'id': 'lane:1', 'at': '2026-10-29T10:00:00Z', 'pr': 5, 'via': 'pr', 'run': 9,
            'verdict': 'PASS', 'tier': 'auto', 'head': 'a' * 12, 'trunk': 'b' * 12, 'trunk_name': 'main',
            'seconds': 300, 'queue_seconds': None, 'steps': [], 'tests': None, 'requested': [], 'source': 'line'}
    return dict(base, **fields)


def job(**fields):
    base = {'kind': 'job', 'id': 'job:1', 'at': '2026-10-29T10:00:00Z', 'run': 9, 'attempt': 1, 'workflow': 'hosted-portable',
            'branch': 'pr', 'job': 'portable', 'head': 'a' * 12, 'runner': 'hosted', 'conclusion': 'success',
            'seconds': 120, 'queue_seconds': 3, 'failed_step': None}
    return dict(base, **fields)


def failure(test, cls=None, n=1):
    event = {'kind': 'test-failure', 'id': f'fail:{n}:{test}', 'at': '2026-10-29T10:00:00Z', 'test': test, 'pr': 5,
             'lane': 'lane:1', 'tier': 'T3', 'head': 'a' * 12, 'trunk': 'b' * 12}
    if cls:
        event['label'] = {'class': cls, 'by': 'heuristic', 'signal': 'same-head'}
    return event


def slow(test, seconds, day='2026-10-28'):
    return {'kind': 'slow', 'id': f'slow:{day}:{test}', 'at': f'{day}T00:00:00Z', 'test': test, 'seconds': seconds, 'reports': 1}


class CleanTests(unittest.TestCase):
    def test_a_field_a_kind_does_not_have_is_dropped(self):
        found = dash.clean(dict(lane(), message='cannot find type SQLiteSessionStore', log_path='/Users/x/log'))
        self.assertNotIn('message', found)
        self.assertNotIn('log_path', found)
        self.assertNotIn('Users', json.dumps(found))

    def test_a_known_field_holding_text_is_refused_not_stored(self):
        for bad in ('line one\nline two', 'x' * 201, '/x/\x1b[31mred', {'text': 'a log'}, ['a', {'b': 1}]):
            self.assertIsNone(dash.clean(lane(source=bad)), repr(bad)[:40])
            self.assertIsNone(dash.clean(job(job=bad)), repr(bad)[:40])

    def test_a_short_sentence_or_path_is_refused_in_every_text_looking_field(self):
        sentence = 'cannot find type SQLiteSessionStore in scope near /Users/x'
        for event in (failure(sentence), failure('A/B/testX | boom'), failure('A/B/test\nX'), lane(head='not hex'),
                      lane(verdict='FAIL: it broke'), lane(source=sentence), lane(requested=[sentence]),
                      job(workflow=sentence), job(conclusion='failed because ' + sentence[:20]), job(job=sentence + ' | `x`'),
                      job(failed_step='/Users/x/log'), slow('A/B/' + sentence, 3),
                      lane(label={'class': 'code', 'by': 'heuristic', 'signal': sentence})):
            self.assertIsNone(dash.clean(event), event)

    def test_real_names_with_spaces_and_parentheses_fit(self):
        for event in (job(job='Build and test (iOS)'), lane(steps=[{'step': 'app tests (T3)', 'seconds': 1, 'result': 'pass'}]),
                      failure('SessionKitCoreTests/VoiceModelInstallerTests/testResumesATransfer'),
                      failure('test_x.FooTests.test_it'),
                      {'kind': 'catch', 'id': 'catch:0123456789abcdef', 'at': '2026-10-28T00:00:00Z', 'step': 'host tests', 'test': 'step:app builds',
                       'pr': 5, 'from': 'a' * 12, 'to': 'b' * 12, 'class': 'catch', 'seconds': 3}):
            self.assertEqual(dash.clean(event), event, event)

    def test_a_nested_object_keeps_only_its_known_keys_and_refuses_text(self):
        found = dash.clean(lane(steps=[{'step': 'host tests', 'seconds': 4, 'result': 'pass', 'output': 'boom'}]))
        self.assertEqual(found['steps'], [{'step': 'host tests', 'seconds': 4, 'result': 'pass'}])
        self.assertIsNone(dash.clean(lane(steps=[{'step': 'a\nb', 'seconds': 4, 'result': 'pass'}])))
        self.assertIsNone(dash.clean(lane(label='free text')))

    def test_an_unknown_kind_and_an_event_with_no_id_are_refused(self):
        self.assertIsNone(dash.clean({'kind': 'note', 'id': 'x'}))
        self.assertIsNone(dash.clean({'kind': 'lane'}))
        self.assertIsNone(dash.clean('lane'))

    def test_a_human_label_with_a_step_survives(self):
        label = {'by': 'human', 'step': 'host tests'}
        self.assertEqual(dash.clean({'kind': 'escape', 'id': 'escape:issue:1', 'at': '2026-10-29T10:00:00Z', 'source': 'regression',
                                     'sha': '', 'reverts': '', 'pr': None, 'issue': 1, 'label': label})['label'], label)

    def test_nan_is_not_stored(self):
        self.assertIsNone(dash.clean(lane(seconds=float('nan'))))

    def test_skipped_runs_and_jobs_and_runs_their_jobs_already_tell_are_not_stored(self):
        run = {'kind': 'run', 'id': 'run:1:1', 'at': '2026-10-29T10:00:00Z', 'run': 1, 'attempt': 1, 'workflow': 'lane',
               'event': 'push', 'branch': 'trunk', 'head': 'a' * 12, 'seconds': 5}
        self.assertIsNone(dash.storable(job(conclusion='skipped')))
        self.assertIsNotNone(dash.storable(job()))
        self.assertIsNone(dash.storable(dict(run, conclusion='success')))
        self.assertIsNone(dash.storable(dict(run, conclusion='cancelled')))
        self.assertIsNotNone(dash.storable(dict(run, conclusion='startup_failure')))

    def test_everything_the_collector_makes_passes_unchanged(self):
        """The allow-list is only useful if it does not eat real events: lane, failure, job, run, catch and escape."""
        comments = [fixtures.comment(body) for body in (fixtures.EXIT_15, fixtures.COMPILE_ERROR, fixtures.NAMED_FAILURE,
                                                       fixtures.APP_FAIL, fixtures.MAIN_PASS)]
        made = pe.lane_events(comments)
        run = {'id': 7, 'run_attempt': 1, 'path': '.github/workflows/hosted-portable.yml@refs/heads/main', 'event': 'push',
               'head_branch': 'main', 'head_sha': 'a' * 40, 'conclusion': 'success', 'created_at': '2026-10-29T10:00:00Z',
               'run_started_at': '2026-10-29T10:00:00Z', 'updated_at': '2026-10-29T10:05:00Z'}
        summary = pe.run_event(run, 'main')
        made += [summary, pe.job_event({'id': 8, 'run_id': 7, 'name': 'portable', 'labels': ['ubuntu-latest'],
                                        'conclusion': 'success', 'created_at': '2026-10-29T10:00:00Z',
                                        'started_at': '2026-10-29T10:00:03Z', 'completed_at': '2026-10-29T10:02:00Z',
                                        'steps': []}, summary)]
        made += pe.catch_events([json.dumps({'test': 'A/B/testC', 'step': 'host tests', 'key': 'pr:5', 'class': 'catch', 'at': 1790000000})])
        made += pe.escape_events([{'sha': 'c' * 40, 'parents': [{}], 'commit': {'message': 'Revert "A (#5)"', 'committer': {'date': '2026-10-29T10:00:00Z'}}}], [])
        made = pe.label(made)
        self.assertGreater(len(made), 8)
        for event in made:
            self.assertEqual(dash.clean(event), event, event['kind'])


class FilesTests(unittest.TestCase):
    def test_events_go_to_a_file_for_their_month_and_come_back(self):
        events = [lane(id='lane:1', at='2026-09-30T23:00:00Z'), lane(id='lane:2', at='2026-10-01T00:00:00Z'),
                  slow('A/B/testC', 12)]
        files = dash.plan_files(events)
        self.assertEqual(sorted(files), ['events-2026-09.jsonl', 'events-2026-10.jsonl'])
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(sorted(dash.write_files(Path(folder), files)), sorted(files))
            self.assertEqual({e['id'] for e in dash.load(Path(folder))}, {e['id'] for e in events})

    def test_only_files_that_changed_are_written(self):
        with tempfile.TemporaryDirectory() as folder:
            first = dash.plan_files([lane(id='lane:1', at='2026-09-30T23:00:00Z'), lane(id='lane:2')])
            dash.write_files(Path(folder), first)
            second = dash.plan_files([lane(id='lane:1', at='2026-09-30T23:00:00Z'), lane(id='lane:2'), lane(id='lane:3')])
            self.assertEqual(dash.write_files(Path(folder), second), ['events-2026-10.jsonl'])
            self.assertEqual(dash.write_files(Path(folder), second), [])

    def test_a_year_over_the_limit_is_named_and_a_smaller_one_is_not(self):
        files = {'events-2026-01.jsonl': 'x' * 600, 'events-2026-02.jsonl': 'x' * 600, 'events-2027-01.jsonl': 'x' * 100}
        sizes = dash.year_bytes(files)
        self.assertEqual(sizes, {'2026': 1200, '2027': 100})
        self.assertEqual(dash.over_budget(sizes, limit=1000), ['2026'])
        self.assertEqual(dash.over_budget(sizes, limit=1200), [])

    def test_the_default_limit_is_20_mb_a_year(self):
        self.assertEqual(dash.YEAR_BYTES, 20 * 1024 * 1024)

    def test_an_undated_event_is_kept_in_its_own_file(self):
        self.assertEqual(list(dash.plan_files([lane(at='')])), ['events-undated.jsonl'])

    def test_collect_starts_at_a_day_boundary_a_few_days_back(self):
        self.assertEqual(dash.collect_since([lane(at='2026-10-29T10:00:00Z')], NOW), '2026-10-26T00:00:00Z')
        self.assertEqual(dash.collect_since([], NOW), '2026-10-16T00:00:00Z')


class SlowEventTests(unittest.TestCase):
    def report(self, slowest, request='pr1-r2'):
        body = fixtures.report_body(request, 'PASS', tier='T3')
        record = {'v': 1, 'verdict': 'PASS', 'fault': False, 'tier': 'T3', 'head': 'a' * 7, 'trunk': 'b' * 7, 'seconds': 10,
                  'queue_seconds': 3, 'steps': [], 'tests': {'ran': 3, 'failed': 0}, 'classes': {}, 'slowest': slowest}
        return fixtures.comment(body + lane_event.note(record) + '\n')

    def test_a_day_keeps_each_tests_longest_time_and_how_many_reports_named_it(self):
        found = pe.slow_events([self.report([['A/B/testX', 40], ['A/B/testY', 5]]), self.report([['A/B/testX', 90]], 'pr2-r3')])
        by_test = {e['test']: e for e in found}
        self.assertEqual((by_test['A/B/testX']['seconds'], by_test['A/B/testX']['reports']), (90, 2))
        self.assertEqual(by_test['A/B/testY']['at'], '2026-10-20T00:00:00Z')
        self.assertTrue(all(dash.clean(e) == e for e in found))

    def test_a_strangers_report_and_a_prose_only_report_add_nothing(self):
        stranger = self.report([['A/B/testX', 40]])
        stranger.update(user={'login': 'someone'}, author_association='NONE')
        prose = fixtures.comment(fixtures.report_body('pr3-r4', 'PASS'))
        self.assertEqual(pe.slow_events([stranger, prose]), [])

    def test_only_the_slowest_of_a_day_are_kept(self):
        many = [[f'A/B/test{n:03d}', n] for n in range(20)]
        found = pe.slow_events([self.report(many, f'pr{k}-r1') for k in range(3)])
        self.assertLessEqual(len(found), pe.SLOW_PER_DAY)

    def test_collect_events_includes_them_and_a_second_collect_does_not_double_them(self):
        comments = [self.report([['A/B/testX', 40]])]
        once = pe.collect_events(comments, [], [], '2026-10-01T00:00:00Z', [], 'main')
        twice = pe.collect_events(comments, [], [], '2026-10-01T00:00:00Z', once, 'main')
        self.assertEqual(sum(e['kind'] == 'slow' for e in twice), 1)


class RenderTests(unittest.TestCase):
    def test_an_empty_branch_still_renders_with_the_date(self):
        body = dash.render([], NOW)
        self.assertIn('Updated 2026-10-30', body)
        self.assertIn('Not enough data', body)
        self.assertIn('```mermaid', body)

    def test_a_step_gets_one_line_with_its_counts_and_what_its_failures_were(self):
        lanes = [lane(id='lane:1', verdict='FAIL', steps=[{'step': 'host tests', 'seconds': 300, 'result': 'fail'}],
                      label={'class': 'code', 'by': 'heuristic', 'signal': 'later-head'}),
                 lane(id='lane:2', steps=[{'step': 'host tests', 'seconds': 100, 'result': 'pass'}]),
                 lane(id='lane:3', steps=[{'step': 'host tests', 'seconds': 200, 'result': 'pass'}, {'step': 'ops tests', 'seconds': 5, 'result': 'pass'}])]
        body = dash.render(lanes, NOW)
        self.assertIn('- **host tests**: 3 runs, 2 pass, 1 fail, 0 fault (1 code), median 3m20s', body)
        self.assertIn('- **ops tests**: 1 runs, 1 pass, 0 fail, 0 fault, median 5s', body)

    def test_a_job_line_names_workflow_job_and_runner(self):
        body = dash.render([job(), job(id='job:2', conclusion='failure'), job(id='job:3', conclusion='cancelled')], NOW)
        self.assertIn('- **hosted-portable / portable** (hosted): 3 runs, 1 failed, 1 cancelled', body)

    def test_events_outside_the_window_are_left_out(self):
        old = lane(at='2026-08-01T00:00:00Z', steps=[{'step': 'old step', 'seconds': 1, 'result': 'pass'}])
        self.assertNotIn('old step', dash.render([old], NOW))

    def test_the_noisiest_tests_are_the_ones_that_failed_then_passed(self):
        failures = ([failure('A/B/testFlaky', 'flake', n) for n in range(3)] + [failure('A/B/testMoved', 'trunk-moved', 9)]
                    + [failure('A/B/testReal', 'code', 20), failure('A/B/testReal', 'code', 21)])
        lines = dash.noisy_tests(failures)
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith('1. `A/B/testFlaky`: 3 flaky failures of 3'))
        self.assertNotIn('testReal', ' '.join(lines))

    def test_the_slow_list_leaves_out_every_test_that_ever_failed_and_takes_five(self):
        slows = [slow(f'A/B/test{n}', 10 * n) for n in range(1, 9)]
        lines = dash.slow_never_failed(slows, failed_ever={'A/B/test8'})
        self.assertEqual(len(lines), 5)
        self.assertTrue(lines[0].startswith('1. `A/B/test7`: typically 1m10s'))
        self.assertNotIn('test8', ' '.join(lines))

    def test_a_slow_test_not_seen_in_the_window_is_forgotten(self):
        self.assertNotIn('A/B/testGone', dash.render([slow('A/B/testGone', 500, day='2026-06-01')], NOW))

    def test_a_neutral_or_unknown_job_is_not_a_failure(self):
        body = dash.render([job(id='j1', conclusion='neutral'), job(id='j2', conclusion='unknown'),
                            job(id='j3', conclusion='timed_out'), job(id='j4')], NOW)
        self.assertIn('4 runs, 1 failed', body)
        self.assertEqual(dict((d, f) for d, _, f in dash.daily_series([], [job(conclusion='neutral'), job(id='j2')], NOW))['10-29'], 0)

    def test_a_test_that_failed_before_the_window_is_not_never_failed(self):
        old_failure = dict(failure('A/B/test1', 'code'), at='2026-06-01T00:00:00Z')
        body = dash.render([old_failure, slow('A/B/test1', 500)], NOW)
        self.assertNotIn('typically 8m20s', body)

    def test_the_batching_verdict_needs_data_then_waits_and_volume(self):
        def t3(n, wait):
            return [lane(id=f'lane:{i}', tier='T3', queue_seconds=wait) for i in range(n)]
        self.assertIn('Not enough data', dash.batching_verdict(t3(3, 2000), 30))
        self.assertIn('Not enough data', dash.batching_verdict(t3(12, None), 30))
        self.assertIn('Batch T3 requests', dash.batching_verdict(t3(200, 1800), 30))
        self.assertIn('Leave T3 requests unbatched', dash.batching_verdict(t3(200, 60), 30))
        self.assertIn('Leave T3 requests unbatched', dash.batching_verdict(t3(20, 1800), 30))  # waits, but under 5 a day
        self.assertIn('median queue wait 30m00s', dash.batching_verdict(t3(200, 1800), 30))

    def test_desk_and_integration_reports_do_not_count_as_pr_requests(self):
        lanes = [lane(id=f'lane:{i}', tier='T3', via='desk', queue_seconds=5000) for i in range(30)]
        self.assertIn('Not enough data', dash.batching_verdict(lanes, 30))

    def test_the_trend_is_a_mermaid_chart_with_okabe_ito_colours_and_named_series(self):
        body = dash.render([lane(verdict='FAIL', at='2026-10-29T10:00:00Z'), job()], NOW)
        self.assertIn('xychart-beta', body)
        self.assertIn('#0072B2, #E69F00', body)
        self.assertIn('Blue bars: lane first-try FAIL %. Orange line: hosted job failed %.', body)
        chart = body.split('xychart-beta')[1]
        self.assertEqual(chart.count('"'), chart.count('"') // 2 * 2)
        self.assertEqual(len(dash.daily_series([], [], NOW)), dash.TREND_DAYS)

    def test_the_series_count_first_tries_and_hosted_failures_by_day(self):
        lanes = [lane(id='lane:1', verdict='FAIL', pr=1, head='a' * 12), lane(id='lane:2', verdict='PASS', pr=2, head='c' * 12)]
        jobs = [job(id='job:1', conclusion='failure'), job(id='job:2'), job(id='job:3', conclusion='cancelled'),
                job(id='job:4', runner='self-hosted', conclusion='failure')]
        row = dict((day, (first, failed)) for day, first, failed in dash.daily_series(lanes, jobs, NOW))['10-29']
        self.assertEqual(row, (50, 50))

    def test_the_size_line_and_notes_are_shown(self):
        body = dash.render([], NOW, {'2026': 3 * 1048576}, ['3 events were not stored.'])
        self.assertIn('Branch size this year: 3.0 MB of 20 MB.', body)
        self.assertIn('> 3 events were not stored.', body)

    def test_the_body_stays_under_githubs_limit(self):
        steps = [lane(id=f'lane:{n}', steps=[{'step': f'step {n}', 'seconds': 1, 'result': 'pass'}]) for n in range(3000)]
        self.assertLessEqual(len(dash.render(steps, NOW)), 65000)


class FakeGitHub:
    def __init__(self, existing=None):
        self.repo, self.calls, self.existing = 'Spoken-Margins/spoken-margins-native', [], existing

    def get(self, path):
        self.calls.append(('GET', path))
        return {'items': self.existing or []}

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        return {'number': 77, 'node_id': 'I_x'}, {}


class PublishTests(unittest.TestCase):
    def issue(self, title=dash.TITLE, login='github-actions[bot]', association='NONE', number=40):
        return {'number': number, 'title': title, 'user': {'login': login}, 'author_association': association}

    def test_the_first_run_creates_and_pins_the_issue(self):
        github = FakeGitHub()
        self.assertEqual(dash.publish_issue(github, 'body'), 77)
        self.assertEqual(github.calls[1][:2], ('POST', 'issues'))
        self.assertEqual(github.calls[1][2], {'title': dash.TITLE, 'body': 'body'})
        self.assertIn('pinIssue', github.calls[2][2]['query'])

    def test_a_later_run_rewrites_the_body_in_place_and_never_comments(self):
        github = FakeGitHub([self.issue()])
        self.assertEqual(dash.publish_issue(github, 'new body'), 40)
        writes = [call for call in github.calls if call[0] != 'GET']
        self.assertEqual(writes, [('PATCH', 'issues/40', {'body': 'new body'})])

    def test_a_strangers_issue_with_our_title_is_not_ours(self):
        github = FakeGitHub([self.issue(login='someone', association='NONE', number=13)])
        self.assertEqual(dash.publish_issue(github, 'body'), 77)
        self.assertEqual(github.calls[1][:2], ('POST', 'issues'))

    def test_a_refused_pin_does_not_fail_the_run(self):
        class Refusing(FakeGitHub):
            def request(self, method, path, body=None):
                if path == '/graphql':
                    raise RuntimeError('HTTP 403')
                return super().request(method, path, body)
        self.assertEqual(dash.publish_issue(Refusing(), 'body'), 77)

    def run_publish(self, folder, comments, events=None, limit=None):
        fake = mock.MagicMock()
        fake.GitHub.return_value = FakeGitHub()
        out = Path(folder) / 'body.md'
        patches = [mock.patch.dict(sys.modules, {'sm_status': fake}),
                   mock.patch.object(pe, 'fetch_comments', return_value=comments),
                   mock.patch.object(pe, 'fetch_runs', return_value=[]),
                   mock.patch.object(pe, 'fetch_escapes', return_value=([], [])),
                   mock.patch.object(pe, 'default_catches', return_value=Path(folder) / 'none.jsonl')]
        if limit:
            patches.append(mock.patch.object(dash, 'YEAR_BYTES', limit))
        for patch in patches:
            patch.start()
        try:
            code = dash.main(['publish', '--metrics', str(Path(folder) / 'metrics'), '--body-out', str(out)])
        finally:
            mock.patch.stopall()
        return code, out.read_text(), fake.GitHub.return_value

    def test_publish_writes_the_month_files_and_updates_the_issue(self):
        comments = [fixtures.comment(fixtures.MAIN_PASS, at=NOW.strftime('%Y-%m-%dT%H:%M:%SZ'))]
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(dash.dt, 'datetime', wraps=dt.datetime) as clock:
            clock.now.return_value = NOW
            clock.strptime = dt.datetime.strptime
            code, body, github = self.run_publish(folder, comments)
            files = sorted(p.name for p in (Path(folder) / 'metrics').glob('events-*.jsonl'))
        self.assertEqual(code, 0)
        self.assertEqual(files, ['events-2026-10.jsonl'])
        self.assertIn('Updated 2026-10-30', body)
        self.assertEqual([c[0] for c in github.calls if c[0] != 'GET'][:1], ['POST'])

    def test_a_full_year_writes_nothing_says_so_in_the_issue_and_fails_the_run(self):
        comments = [fixtures.comment(fixtures.MAIN_PASS, at=NOW.strftime('%Y-%m-%dT%H:%M:%SZ'))]
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(dash.dt, 'datetime', wraps=dt.datetime) as clock:
            clock.now.return_value = NOW
            clock.strptime = dt.datetime.strptime
            code, body, github = self.run_publish(folder, comments, limit=10)
            self.assertEqual(list((Path(folder) / 'metrics').glob('events-*.jsonl')), [])
        self.assertEqual(code, 1)
        self.assertIn('is full for 2026', body)
        self.assertTrue(any(c[0] == 'POST' for c in github.calls))


class WorkflowTests(unittest.TestCase):
    """The workflow is the single daily writer of the metrics branch and the pinned issue."""
    PATH = Path(__file__).resolve().parents[2] / '.github/workflows/pipeline-dashboard.yml'

    def setUp(self):
        self.text = self.PATH.read_text()
        self.document = fixtures_workflow_parse(self.PATH)

    def test_it_runs_once_a_day_and_by_hand_and_on_no_pull_request(self):
        triggers = next(self.document[key] for key in ('on', True, 'true') if key in self.document)
        self.assertEqual(len(triggers['schedule']), 1)
        self.assertEqual(len(triggers['schedule'][0]['cron'].split()), 5)
        self.assertRegex(triggers['schedule'][0]['cron'], r'^\d+ \d+ \* \* \*$')
        self.assertIn('workflow_dispatch', triggers)
        for other in ('pull_request', 'pull_request_target', 'push'):
            self.assertNotIn(other, triggers)

    def test_it_is_the_single_writer_and_a_second_run_waits(self):
        self.assertEqual(self.document['concurrency'], {'group': 'pipeline-dashboard', 'cancel-in-progress': False})
        self.assertEqual(list(self.document['jobs']), ['snapshot'])

    def test_it_asks_for_no_more_than_it_uses(self):
        self.assertEqual(self.document['permissions'], {'actions': 'read', 'contents': 'write', 'issues': 'write'})

    def test_it_pushes_only_the_metrics_branch(self):
        pushes = [line.strip() for line in self.text.splitlines() if ' push ' in line and 'git' in line]
        self.assertEqual(len(pushes), 1)
        self.assertTrue(pushes[0].endswith('origin HEAD:metrics'))
        self.assertNotIn('--force', self.text)

    def test_it_says_what_it_costs_and_when_it_is_waste(self):
        for phrase in ('Cost and catch', 'Waste signal', 'Actions minutes'):
            self.assertIn(phrase, self.text)

    def test_it_runs_the_script_this_file_tests(self):
        self.assertIn('python3 scripts/pipeline_dashboard.py publish --metrics metrics', self.text)


def fixtures_workflow_parse(path):
    import test_workflow_files
    return test_workflow_files.parse(path)


if __name__ == '__main__':
    unittest.main()
