"""The shadow conflict resolver (#5320): who it may touch, what Claude may change, and that it pushes nowhere else."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import conflict_resolver as cr  # noqa: E402

REPO = 'owner/app'
NOW = datetime(2026, 11, 25, 12, 0, tzinfo=timezone.utc)
HEAD = 'a' * 40


def iso(dt):
    return dt.strftime('%Y-%m-%dT%H:%M:%SZ')


def pull(number=7, head=HEAD, fork=False, association='OWNER', labels=('needs-mac',), login='uncomposed'):
    return {'number': number, 'state': 'open', 'title': 'Add a thing', 'body': 'Closes #1',
            'head': {'sha': head, 'ref': 'claude/x', 'repo': {'full_name': 'stranger/app' if fork else REPO}},
            'base': {'ref': 'main', 'repo': {'full_name': REPO}},
            'user': {'login': login}, 'author_association': association,
            'labels': [{'name': name} for name in labels]}


def marker_comment(head=HEAD, minutes_ago=45, login=cr.BOT, association='NONE'):
    return {'user': {'login': login}, 'author_association': association,
            'created_at': iso(NOW - timedelta(minutes=minutes_ago)),
            'body': f'Handing to the Mac finisher: ...\n<!-- lane-conflict head={head[:7]} base=bbbbbbb -->'}


class Handoff(unittest.TestCase):
    def test_a_quiet_handed_off_same_repo_pr_is_taken(self):
        ok, why, _ = cr.handoff(pull(), [marker_comment()], NOW)
        self.assertTrue(ok, why)

    def test_a_fork_is_never_taken(self):
        self.assertFalse(cr.handoff(pull(fork=True), [marker_comment()], NOW)[0])

    def test_a_strangers_pr_is_ignored(self):
        for association in ('CONTRIBUTOR', 'NONE', 'FIRST_TIME_CONTRIBUTOR', None):
            self.assertFalse(cr.handoff(pull(association=association, login='someone'), [marker_comment()], NOW)[0])

    def test_a_recent_push_is_left_to_its_thread(self):
        ok, why, _ = cr.handoff(pull(), [marker_comment(minutes_ago=10)], NOW)
        self.assertFalse(ok)
        self.assertIn('30 minutes', why)

    def test_a_marker_for_an_older_head_means_a_push_came_after(self):
        self.assertFalse(cr.handoff(pull(), [marker_comment(head='c' * 40)], NOW)[0])

    def test_a_lookalike_marker_from_a_stranger_does_not_count(self):
        fake = marker_comment(login='github-actions', association='NONE')
        self.assertFalse(cr.handoff(pull(), [fake], NOW)[0])

    def test_an_explicit_hand_off_by_a_collaborator_skips_the_wait(self):
        hand = {'user': {'login': 'uncomposed'}, 'author_association': 'OWNER',
                'created_at': iso(NOW - timedelta(minutes=2)), 'body': 'Handing to the conflict resolver: thread ended.'}
        ok, why, _ = cr.handoff(pull(), [marker_comment(minutes_ago=5), hand], NOW)
        self.assertTrue(ok)
        self.assertEqual(why, 'handed off')

    def test_a_strangers_hand_off_does_not_skip_the_wait(self):
        hand = {'user': {'login': 'x'}, 'author_association': 'NONE',
                'created_at': iso(NOW - timedelta(minutes=2)), 'body': 'Handing to the conflict resolver: go.'}
        self.assertFalse(cr.handoff(pull(), [marker_comment(minutes_ago=5), hand], NOW)[0])

    def test_a_re_armed_pr_is_left_alone(self):
        self.assertFalse(cr.handoff(pull(labels=('automerge',)), [marker_comment()], NOW)[0])


class Protected(unittest.TestCase):
    def test_owner_tap_and_compatibility_paths_are_protected(self):
        paths = ['.github/workflows/x.yml', 'scripts/lane-runner.py',
                 'Packages/SessionKit/Sources/SessionKitPersistence/Store.swift',
                 'Packages/SessionKit/Sources/SessionKitSharing/Packet.swift',
                 'Packages/SessionKit/Tests/SessionKitPersistenceTests/StoreTests.swift', 'App/X.swift',
                 'docs/SessionKitSharing.md']
        self.assertEqual(cr.protected(paths), sorted(paths[:5]))


class Hunks(unittest.TestCase):
    def test_split_reads_diff3_hunks_and_keeps_plain_text(self):
        text = 'a\n<<<<<<< HEAD\nmain\n||||||| base\nold\n=======\npr\n>>>>>>> pr\nz\n'
        segs = cr.split_conflicts(text)
        self.assertEqual(segs, ['a\n', {'ours': 'main\n', 'base': 'old\n', 'theirs': 'pr\n'}, 'z\n'])

    def test_a_markdown_rule_inside_plain_text_is_not_a_marker(self):
        self.assertEqual(cr.split_conflicts('Title\n=======\n'), ['Title\n=======\n'])

    def test_broken_markers_raise(self):
        for text in ('<<<<<<< HEAD\nx\n', '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> pr\n'):
            with self.assertRaises(ValueError):
                cr.split_conflicts(text)

    def test_whitespace_only_takes_main(self):
        self.assertEqual(cr.mechanical('a.py', {'ours': 'x = 1\n', 'base': 'x=1\n', 'theirs': 'x =  1\n'}), 'x = 1\n')

    def test_both_appending_to_a_doc_keeps_main_then_pr(self):
        hunk = {'ours': '- main entry\n', 'base': '', 'theirs': '- pr entry\n'}
        self.assertEqual(cr.mechanical('docs/decisions.md', hunk), '- main entry\n- pr entry\n')

    def test_both_appending_in_code_needs_judgment(self):
        self.assertIsNone(cr.mechanical('a.py', {'ours': 'x()\n', 'base': '', 'theirs': 'y()\n'}))

    def test_a_baseline_keeps_every_added_line_and_drops_removed_ones(self):
        hunk = {'base': '    {"a": 1},\n    {"b": 2},\n', 'ours': '    {"a": 1},\n    {"c": 3},\n',
                'theirs': '    {"b": 2},\n    {"d": 4},\n'}
        self.assertEqual(cr.mechanical('scripts/x_baseline.json', hunk), '    {"c": 3},\n    {"d": 4},\n')

    def test_a_baseline_where_main_deleted_the_rows_keeps_its_commas(self):
        hunk = {'base': '    {"x": 1},\n', 'ours': '', 'theirs': '    {"x": 1},\n    {"y": 2},\n'}
        self.assertEqual(cr.mechanical('scripts/x_baseline.json', hunk), '    {"y": 2},\n')

    def test_a_baseline_row_both_sides_changed_needs_judgment(self):
        row = '    {{"api": "a", "class": "c", "count": {n}, "function": "f"}},\n'
        hunk = {'base': row.format(n=2), 'ours': row.format(n=1), 'theirs': row.format(n=3)}
        self.assertIsNone(cr.mechanical('scripts/x_baseline.json', hunk))

    def test_both_appending_to_data_under_docs_needs_judgment(self):
        self.assertIsNone(cr.mechanical('docs/task-cost-map.json', {'ours': '1,\n', 'base': '', 'theirs': '2,\n'}))

    def test_sort(self):
        h = {'ours': 'a\n', 'base': 'b\n', 'theirs': 'c\n'}
        big = {'ours': 'a\n' * 11, 'base': 'b\n', 'theirs': 'c\n'}
        self.assertEqual(cr.sort_case([('a.py', 'UU', [h])]), 'small')
        self.assertEqual(cr.sort_case([('a.py', 'UU', [h] * 4)]), 'medium')
        self.assertEqual(cr.sort_case([('a.py', 'UU', [big])]), 'hard')
        self.assertEqual(cr.sort_case([('a.py', 'UD', None)]), 'hard')
        self.assertEqual(cr.sort_case([('docs/a.md', 'UU', [{'ours': 'x\n', 'base': '', 'theirs': 'y\n'}])]),
                         'mechanical')


class Reply(unittest.TestCase):
    def test_a_good_reply_fills_only_its_hunks(self):
        res, whys, back = cr.parse_reply('{"hunks":[{"id":"h1","text":"x","why":"both"}],"handback":null}', {'h1'})
        self.assertEqual(res, {'h1': 'x\n'})
        self.assertIsNone(back)

    def test_a_fenced_reply_is_read(self):
        self.assertEqual(cr.parse_reply('```json\n{"hunks":[{"id":"h1","text":"x\\n"}]}\n```', {'h1'})[0],
                         {'h1': 'x\n'})

    def test_a_reply_that_reaches_outside_the_hunks_is_refused(self):
        bad = [
            '{"hunks":[{"id":"h2","text":"x"}]}',  # an id it was not given
            '{"hunks":[{"id":"h1","text":"x","path":".github/workflows/x.yml"}]}',  # a path
            '{"hunks":[{"id":"h1","text":"x"}],"files":{"a":"b"}}',  # extra top-level field
            '{"hunks":[{"id":"h1","text":"x"},{"id":"h1","text":"y"}]}',  # twice
            '{"hunks":[]}',  # leaves one out
            '{"hunks":[{"id":"h1","text":"<<<<<<< HEAD\\nx\\n"}]}',  # markers
            'Sure! Here is the merge.',
        ]
        for text in bad:
            with self.subTest(text=text), self.assertRaises(ValueError):
                cr.parse_reply(text, {'h1'})

    def test_a_handback_is_returned(self):
        self.assertEqual(cr.parse_reply('{"hunks":[],"handback":"two rewrites"}', {'h1'})[2], 'two rewrites')

    def test_the_prompt_marks_the_data_untrusted(self):
        prompt = cr.build_prompt(pull(), [], [('h1', 'a.py', {'ours': 'a\n', 'base': 'b\n', 'theirs': 'c\n'}, '', '')])
        self.assertIn('untrusted', prompt)
        self.assertLess(prompt.index('BEGIN DATA'), prompt.index('Hunk h1'))

    def test_safe_line_strips_mentions_and_fences(self):
        self.assertNotIn('@o', cr.safe_line('ping @owner ```x```'))
        self.assertNotIn('`', cr.safe_line('```'))

    def test_kept(self):
        h = {'ours': 'if a and b:\n', 'base': 'if a:\n', 'theirs': 'if a or c:\n'}
        self.assertEqual(cr.kept_case([(h, 'if (a and b) or c:\n')]), (1.0, 1.0))
        self.assertEqual(cr.kept_case([(h, 'if a and b:\n')]), (1.0, 0.0))


def git(cwd, *args):
    return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *args], cwd=cwd, text=True,
                          capture_output=True, check=True).stdout.strip()


class FakeApi:
    def __init__(self, pulls, comments):
        self.pulls, self.comments, self.posts = pulls, comments, []

    def get(self, path):
        if path.startswith('commits/'):
            return []
        raise AssertionError(path)

    def get_all(self, path):
        if path.startswith('pulls?'):
            return self.pulls
        number = int(path.split('/')[1])
        return self.comments.get(number, [])

    def post(self, path, fields):
        self.posts.append((path, fields))
        if path.startswith(f'issues/{cr.LOG_ISSUE}/comments'):
            self.comments.setdefault(cr.LOG_ISSUE, []).append(
                {'user': {'login': cr.BOT}, 'created_at': iso(NOW), 'body': fields['body']})


class EndToEnd(unittest.TestCase):
    """A real origin: main and a PR edit the same line. The resolver must push only resolver-shadow/*."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.bare, work = root / 'origin.git', root / 'work'
        git(root, 'init', '-q', '--bare', '-b', 'main', str(self.bare))
        git(root, 'clone', '-q', str(self.bare), str(work))
        git(work, 'checkout', '-q', '-b', 'main')
        (work / 'a.py').write_text('one\nif a:\ntwo\n')
        (work / 'docs').mkdir()
        (work / 'docs/log.md').write_text('# Log\n')
        git(work, 'add', '.')
        git(work, 'commit', '-qm', 'start')
        git(work, 'push', '-q', 'origin', 'main')
        git(work, 'checkout', '-q', '-b', 'pr')
        (work / 'a.py').write_text('one\nif a or c:\ntwo\n')
        (work / 'docs/log.md').write_text('# Log\n- pr entry\n')
        git(work, 'commit', '-qam', 'pr')
        self.head = git(work, 'rev-parse', 'HEAD')
        git(work, 'push', '-q', 'origin', f'HEAD:refs/pull/7/head', 'HEAD:refs/heads/claude/x')
        git(work, 'checkout', '-q', 'main')
        (work / 'a.py').write_text('one\nif a and b:\ntwo\n')
        (work / 'docs/log.md').write_text('# Log\n- main entry\n')
        git(work, 'commit', '-qam', 'main moves')
        git(work, 'push', '-q', 'origin', 'main')
        self.work = work
        self.workdir = root / 'cache'

    def tearDown(self):
        self.tmp.cleanup()

    def resolver_run(self, reply, pulls=None):
        p = pull(head=self.head)
        api = FakeApi(pulls if pulls is not None else [p], {7: [marker_comment(head=self.head)]})
        calls = []

        def claude(prompt, cli):
            calls.append(prompt)
            return reply, '$0.01'
        posted = cr.run(api, REPO, 'main', self.workdir, now=NOW, claude=claude, remote=str(self.bare))
        return api, posted, calls

    def heads(self):
        out = git(self.bare, 'for-each-ref', '--format=%(refname) %(objectname)')
        return dict(line.split(' ') for line in out.splitlines())

    def test_a_small_conflict_is_proposed_on_a_shadow_branch_only(self):
        before = self.heads()
        reply = json.dumps({'hunks': [{'id': 'h1', 'text': 'if (a and b) or c:\n', 'why': 'both conditions'}],
                            'handback': None})
        api, posted, calls = self.resolver_run(reply)
        self.assertEqual(len(calls), 1)
        self.assertIn('if a or c:', calls[0])
        self.assertNotIn('pr entry', calls[0], 'the doc append is mechanical and never reaches the model')
        self.assertEqual(len(posted), 1)
        record = posted[0]
        self.assertEqual((record['sort'], record['outcome']), ('small', 'proposed'), record)
        after = self.heads()
        changed = {ref for ref in after if after.get(ref) != before.get(ref)}
        self.assertEqual(changed, {f'refs/heads/resolver-shadow/7-{self.head[:7]}'})
        shadow = record['shadow']
        self.assertEqual(git(self.bare, 'show', f'{shadow}:a.py'), 'one\nif (a and b) or c:\ntwo')
        self.assertEqual(git(self.bare, 'show', f'{shadow}:docs/log.md'), '# Log\n- main entry\n- pr entry')
        self.assertEqual(git(self.bare, 'rev-parse', f'{shadow}^1'), before['refs/heads/main'])
        self.assertEqual(git(self.bare, 'rev-parse', f'{shadow}^2'), self.head)
        paths = [p for p, _ in api.posts]
        self.assertIn('actions/workflows/hosted-portable.yml/dispatches', paths)
        self.assertFalse([p for p in paths if '/labels' in p], 'no label moves')
        log = [f['body'] for p, f in api.posts if p == f'issues/{cr.LOG_ISSUE}/comments']
        self.assertEqual(len(log), 2)  # trial start, then the case
        self.assertEqual(cr.records([{'user': {'login': cr.BOT}, 'created_at': iso(NOW), 'body': log[1]}])[0]['pr'], 7)

    def test_the_same_head_is_proposed_once(self):
        reply = json.dumps({'hunks': [{'id': 'h1', 'text': 'if a:\n'}]})
        api, _, _ = self.resolver_run(reply)
        posted = cr.run(api, REPO, 'main', self.workdir, now=NOW, claude=lambda *a: (reply, ''), remote=str(self.bare))
        self.assertEqual(posted, [])

    def test_a_refused_reply_pushes_nothing(self):
        before = self.heads()
        reply = json.dumps({'hunks': [{'id': 'h1', 'text': 'x\n', 'path': '.github/workflows/evil.yml'}]})
        _, posted, _ = self.resolver_run(reply)
        self.assertEqual(posted[0]['outcome'], 'refused')
        self.assertEqual(self.heads(), before)

    def test_a_protected_path_is_only_reported(self):
        git(self.work, 'checkout', '-q', 'pr')
        (self.work / '.github').mkdir()
        (self.work / '.github/x.yml').write_text('x\n')
        git(self.work, 'add', '.')
        git(self.work, 'commit', '-qm', 'touch github')
        self.head = git(self.work, 'rev-parse', 'HEAD')
        git(self.work, 'push', '-q', '-f', 'origin', 'HEAD:refs/pull/7/head')
        before = self.heads()
        _, posted, calls = self.resolver_run('{}')
        self.assertEqual(calls, [])
        self.assertEqual((posted[0]['sort'], posted[0]['outcome']), ('hard', 'handback'))
        self.assertEqual(self.heads(), before)

    def test_crlf_lines_outside_the_hunk_are_kept(self):
        git(self.work, 'checkout', '-q', 'main')
        (self.work / 'a.py').write_bytes(b'one\r\nif a:\r\ntwo\r\n')
        git(self.work, 'commit', '-qam', 'crlf base')
        git(self.work, 'checkout', '-q', '-b', 'pr2')
        (self.work / 'a.py').write_bytes(b'one\r\nif a or c:\r\ntwo\r\n')
        git(self.work, 'commit', '-qam', 'pr')
        self.head = git(self.work, 'rev-parse', 'HEAD')
        git(self.work, 'push', '-q', '-f', 'origin', 'HEAD:refs/pull/7/head')
        git(self.work, 'checkout', '-q', 'main')
        (self.work / 'a.py').write_bytes(b'one\r\nif a and b:\r\ntwo\r\n')
        git(self.work, 'commit', '-qam', 'main')
        git(self.work, 'push', '-q', 'origin', 'main')
        reply = json.dumps({'hunks': [{'id': 'h1', 'text': 'if (a and b) or c:\r\n'}]})
        _, posted, _ = self.resolver_run(reply)
        self.assertEqual(posted[0]['outcome'], 'proposed', posted[0])
        blob = subprocess.run(['git', 'show', f'{posted[0]["shadow"]}:a.py'], cwd=self.bare, capture_output=True,
                              check=True).stdout
        self.assertEqual(blob, b'one\r\nif (a and b) or c:\r\ntwo\r\n')

    def test_moving_a_file_out_of_a_protected_folder_is_protected(self):
        git(self.work, 'checkout', '-q', 'main')
        (self.work / '.github').mkdir()
        (self.work / '.github/w.yml').write_text('a\nb\nc\nd\n')
        git(self.work, 'add', '.')
        git(self.work, 'commit', '-qm', 'workflow')
        git(self.work, 'push', '-q', 'origin', 'main')
        git(self.work, 'checkout', '-q', 'pr')
        git(self.work, 'merge', '-q', 'main', '-X', 'theirs', '-m', 'm')
        git(self.work, 'mv', '.github/w.yml', 'w.yml')
        (self.work / 'a.py').write_text('one\nif a or z:\ntwo\n')
        git(self.work, 'commit', '-qam', 'move it out')
        self.head = git(self.work, 'rev-parse', 'HEAD')
        git(self.work, 'push', '-q', '-f', 'origin', 'HEAD:refs/pull/7/head')
        git(self.work, 'checkout', '-q', 'main')
        (self.work / 'a.py').write_text('one\nif a and q:\ntwo\n')
        git(self.work, 'commit', '-qam', 'main again')
        git(self.work, 'push', '-q', 'origin', 'main')
        _, posted, calls = self.resolver_run('{}')
        self.assertEqual(calls, [])
        self.assertEqual(posted[0]['outcome'], 'handback', posted[0])
        self.assertIn('.github/w.yml', posted[0]['reason'])

    def test_after_the_trial_window_nothing_runs(self):
        start = {'user': {'login': cr.BOT}, 'created_at': iso(NOW - timedelta(hours=13)),
                 'body': cr.record_comment({'kind': 'trial-start'}, 'started')}
        api = FakeApi([pull(head=self.head)], {7: [marker_comment(head=self.head)], cr.LOG_ISSUE: [start]})
        posted = cr.run(api, REPO, 'main', self.workdir, now=NOW, claude=lambda *a: self.fail('called'), remote=str(self.bare))
        self.assertEqual(posted, [])
        self.assertIn('ended', api.posts[-1][1]['body'])


class Grading(unittest.TestCase):
    class Api:
        def __init__(self, head_checks=None, playwright='success', portable='success', web_status='completed'):
            self.head_checks = head_checks if head_checks is not None else [
                {'name': 'hosted fast: portable', 'conclusion': 'success'},
                {'name': 'hosted web: build and Playwright', 'conclusion': 'success'},
                {'name': 'hosted fast: Mac rest', 'conclusion': 'success'},
                {'name': 'owner-tap-alert', 'conclusion': 'success'},
                {'name': 'hosted app: build (no tests)', 'conclusion': 'skipped'}]
            self.playwright, self.portable, self.web_status = playwright, portable, web_status

        def get(self, path):
            if path.startswith('commits/'):
                return {'check_runs': self.head_checks}
            if path.startswith('actions/runs?'):
                return {'workflow_runs': [
                    {'id': 1, 'status': 'completed', 'path': '.github/workflows/hosted-portable.yml'},
                    {'id': 2, 'status': self.web_status, 'path': '.github/workflows/hosted-web.yml'}]}
            if path.startswith('actions/runs/2/'):
                if self.web_status != 'completed':
                    return {'jobs': []}
                return {'jobs': [{'name': 'hosted web: build and Playwright', 'status': 'completed',
                                  'conclusion': self.playwright, 'labels': ['xcode-27']}]}
            return {'jobs': [
                {'name': 'hosted fast: portable', 'status': 'completed', 'conclusion': self.portable,
                 'labels': ['ubuntu-latest']},
                {'name': 'owner-tap-alert', 'status': 'completed', 'conclusion': 'skipped',
                 'labels': ['ubuntu-latest']},
                {'name': 'hosted fast: Mac rest', 'status': 'completed', 'conclusion': 'failure', 'labels': ['xcode-27']},
                {'name': 'hosted app: build (no tests)', 'status': 'completed', 'conclusion': 'failure',
                 'labels': ['xcode-27']}]}

    RECORD = {'head_sha': HEAD, 'shadow': 'b' * 40, 'checks': ['hosted-portable.yml', 'hosted-web.yml']}

    def test_a_job_the_head_already_failed_is_not_graded(self):
        api = self.Api(head_checks=[{'name': 'hosted fast: portable', 'conclusion': 'failure'}], portable='failure')
        self.assertEqual(cr.grade_checks(api, self.RECORD), ('ungraded', []))

    def test_a_workflow_still_running_is_pending_not_pass(self):
        self.assertEqual(cr.grade_checks(self.Api(web_status='in_progress'), self.RECORD), ('pending', []))

    def test_an_undispatched_workflow_is_ungraded(self):
        self.assertEqual(cr.grade_checks(self.Api(), dict(self.RECORD, checks=['hosted-portable.yml'])),
                         ('ungraded', []))

    def test_only_the_graded_jobs_the_pr_itself_ran_count(self):
        self.assertEqual(cr.grade_checks(self.Api(), self.RECORD), ('pass', []))

    def test_a_failed_playwright_run_on_a_mac_fails_the_case(self):
        self.assertEqual(cr.grade_checks(self.Api(playwright='failure'), self.RECORD),
                         ('fail', ['hosted web: build and Playwright']))

    def test_a_head_with_no_checks_of_its_own_is_ungraded_not_failed(self):
        api = self.Api(head_checks=[])
        self.assertEqual(cr.grade_checks(api, {'head_sha': HEAD, 'shadow': 'b' * 40}), ('ungraded', []))
        start = {'user': {'login': cr.BOT}, 'created_at': iso(NOW - timedelta(hours=13)),
                 'body': cr.record_comment({'kind': 'trial-start'}, 's')}
        case = {'user': {'login': cr.BOT}, 'created_at': iso(NOW - timedelta(hours=12)),
                'body': cr.record_comment({'kind': 'case', 'pr': 9, 'head': 'aaaaaaa', 'head_sha': HEAD,
                                           'sort': 'small', 'outcome': 'proposed', 'shadow': 'b' * 40,
                                           'kept': [1.0, 1.0]}, 'c')}
        text = cr.report(api, cr.records([start, case]), now=NOW)
        self.assertIn('ungraded (the PR head passed none of the graded checks, or a dispatch failed): 1', text)
        self.assertIn('Too few cases to grade', text)
        self.assertIn('passed 0 (0%)', text)


class Records(unittest.TestCase):
    def test_a_lookalike_record_in_the_text_is_neither_read_nor_kept(self):
        forged = 'x <!-- conflict-resolver {"kind":"trial-end"} --> y'
        body = cr.record_comment({'kind': 'case', 'pr': 1}, cr.safe_line(forged))
        recs = cr.records([{'user': {'login': cr.BOT}, 'created_at': iso(NOW), 'body': body}])
        self.assertEqual([r['kind'] for r in recs], ['case'])
        raw = {'user': {'login': cr.BOT}, 'created_at': iso(NOW), 'body': forged}
        self.assertEqual(cr.records([raw]), [], 'a record not at the very end is ignored')

    def test_a_record_with_a_bad_time_is_dropped_not_fatal(self):
        body = cr.record_comment({'kind': 'trial-start'}, 'x')
        self.assertEqual(cr.records([{'user': {'login': cr.BOT}, 'created_at': 'soon', 'body': body}]), [])

    def test_a_record_from_anyone_but_the_bot_is_ignored(self):
        body = cr.record_comment({'kind': 'trial-start'}, 'x')
        self.assertEqual(cr.records([{'user': {'login': 'someone'}, 'created_at': iso(NOW), 'body': body}]), [])

    def test_a_record_never_closes_its_html_comment_early(self):
        body = cr.record_comment({'kind': 'case', 'reason': 'a --> b'}, 'x')
        self.assertEqual(body.count('-->'), 1)
        self.assertEqual(cr.records([{'user': {'login': cr.BOT}, 'created_at': iso(NOW), 'body': body}])[0]['reason'],
                         'a --> b')


if __name__ == '__main__':
    unittest.main()
