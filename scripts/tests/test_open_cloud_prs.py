"""#4915 route 1: which pushed cloud branches get a PR opened by the App, and what the PR says."""
import datetime as dt
import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import open_cloud_prs as ocp  # noqa: E402

NOW = dt.datetime(2026, 11, 23, 18, 0, tzinfo=dt.timezone.utc)
FRESH = '2026-11-23T17:00:00Z'
STALE = '2026-11-10T17:00:00Z'
REQUEST = ('PR: Fix the stuck timeline\n\nThe timeline froze after a thermal pause.\n\nCloses #123\n\n'
           'PR-Labels: automerge\nSigned-off-by: Cole <c@example.com>\n')


def ref(name, when=FRESH, prs=0):
    return {'name': name, 'associatedPullRequests': {'totalCount': prs}, 'target': {'committedDate': when}}


class ParseRequestTests(unittest.TestCase):
    def test_title_body_and_labels(self):
        request = ocp.parse_request(REQUEST)
        self.assertEqual(request.title, 'Fix the stuck timeline')
        self.assertEqual(request.body, 'The timeline froze after a thermal pause.\n\nCloses #123')
        self.assertEqual(request.labels, ('automerge',))

    def test_closes_and_part_of_survive(self):
        for line in ('Closes #4915', 'Part of #4915'):
            with self.subTest(line):
                self.assertIn(line, ocp.parse_request(f'PR: t\n\n{line}\n').body)

    def test_markdown_headings_stay_in_the_body(self):
        body = ocp.parse_request('PR: t\n\n## What this changes\n\n- a\n\n## How you checked it\n\nPart of #1').body
        self.assertTrue(body.startswith('## What this changes'))
        self.assertIn('## How you checked it', body)

    def test_neighbouring_subjects(self):
        table = {
            'PR: x\n\nbody': 'x',
            'PR:x\n\nbody': 'x',
            'PR:   spaced title   \n\nbody': 'spaced title',
            'PR:\ttab\n\nbody': 'tab',
            'PR: x\r\n\r\nwindows body\r\n': 'x',
            'PR: Ünïcode – title\n\nbody': 'Ünïcode – title',
            'pr: lower case\n\nbody': None,
            'PR : space before colon\n\nbody': None,
            ' PR: leading space\n\nbody': None,
            'Fix: PR: not at start\n\nbody': None,
            'PR:\n\nbody': None,
            'PR:    \n\nbody': None,
            'PRs: plural\n\nbody': None,
            '': None,
            'PR: no body': None,
            'PR: only trailers\n\nSigned-off-by: a <a@b>': None,
        }
        for message, title in table.items():
            with self.subTest(message):
                request = ocp.parse_request(message)
                self.assertEqual(request.title if request else None, title)
        self.assertIsNone(ocp.parse_request(None))

    def test_long_title_and_body_are_cut_to_github_limits(self):
        request = ocp.parse_request('PR: ' + 'a' * 500 + '\n\n' + 'b' * 70_000)
        self.assertEqual(len(request.title), ocp.TITLE_MAX)
        self.assertEqual(len(request.body), ocp.BODY_MAX)

    def test_only_allowed_labels_are_taken(self):
        # owner-tap stands in for the owner's approval: a session must never be able to ask the bot to add it.
        request = ocp.parse_request('PR: t\n\nbody\n\nPR-Labels: owner-tap, automerge automerge, needs-owner-tap\n')
        self.assertEqual(request.labels, ('automerge',))

    def test_a_last_paragraph_that_is_not_all_trailers_stays_in_the_body(self):
        request = ocp.parse_request('PR: t\n\nbody\n\nNote: this is prose\nPR-Labels: automerge\n')
        self.assertIn('PR-Labels: automerge', request.body)
        self.assertEqual(request.labels, ())


class SelectionTests(unittest.TestCase):
    def test_recent_branches_with_no_pr_ever(self):
        refs = [ref('fresh'), ref('old', when=STALE), ref('merged', prs=1), ref('closed-or-open', prs=2),
                ref('bad name;rm'), {'name': 'no-commit', 'associatedPullRequests': {'totalCount': 0}, 'target': {}},
                {'name': 'missing-count', 'target': {'committedDate': FRESH}}]
        self.assertEqual(ocp.recent_without_pr(refs, NOW), ['claude/fresh'])

    def test_age_limit_is_inclusive_of_the_edge(self):
        edge = (NOW - dt.timedelta(days=ocp.MAX_AGE_DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ')
        just_over = (NOW - dt.timedelta(days=ocp.MAX_AGE_DAYS, seconds=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.assertEqual(ocp.recent_without_pr([ref('edge', when=edge), ref('over', when=just_over)], NOW),
                         ['claude/edge'])

    def test_only_branches_with_a_request_commit_are_picked(self):
        refs = [ref('asks'), ref('asks-older'), ref('silent'), ref('has-pr', prs=1)]
        histories = {
            'claude/asks': [{'oid': 'a1', 'message': REQUEST}],
            'claude/asks-older': [{'oid': 'b2', 'message': 'Fix typo'}, {'oid': 'b1', 'message': REQUEST}],
            'claude/silent': [{'oid': 'c1', 'message': 'Work in progress\n\nCloses #9'}],
            'claude/has-pr': [{'oid': 'd1', 'message': REQUEST}],
        }
        self.assertEqual(ocp.pick(refs, histories, NOW), ['claude/asks', 'claude/asks-older'])

    def test_newest_request_wins(self):
        oid, request = ocp.find_request([{'oid': 'n', 'message': 'PR: new\n\nbody'},
                                         {'oid': 'o', 'message': 'PR: old\n\nbody'}])
        self.assertEqual((oid, request.title), ('n', 'new'))

    def test_branch_names_held_to_the_claude_prefix(self):
        for name, ok in {'claude/x': True, 'claude/a/b-c_d.e': True, 'claude/': False, 'main': False,
                         'claudex/y': False, 'claude/x y': False, 'claude/$(id)': False, 'claude/x;rm': False}.items():
            with self.subTest(name):
                self.assertEqual(bool(ocp.BRANCH_RE.match(name)), ok)


def fake_github(branches, ahead=None, fail_open=False, fail_label=False):
    """A GitHub whose `gh api` answers from `branches` ({name: (ref node, history newest first)}); `ahead` names, per
    branch, the oids not on main (default: all of them). Returns (gh, calls)."""
    calls = []

    def run(cmd, input=None, **kwargs):
        args = cmd[2:]
        payload = json.loads(input) if input else None
        calls.append((args, payload))
        if args[0] == 'graphql':
            query = payload['query']
            if 'refs(refPrefix' in query:
                nodes = [node for node, _ in branches.values()]
                answer = {'data': {'repository': {'refs': {'pageInfo': {'hasNextPage': False}, 'nodes': nodes}}}}
            else:
                repo, base, errors, i = {}, {}, [], 0
                full = 'oid message ' in query
                while f'r{i}: ref(qualifiedName: ' in query:
                    name = query.split(f'r{i}: ref(qualifiedName: "refs/heads/')[1].split('"')[0]
                    if name in branches:
                        node, history = branches[name]
                        keep = set((ahead or {}).get(name, [c['oid'] for c in history]))
                        commits = [{'oid': c['oid'], 'message' if full else 'messageHeadline':
                                    c['message'] if full else c['message'].split('\n')[0]}
                                   for c in history if c['oid'] in keep]
                        repo[f'r{i}'] = node
                        base[f'c{i}'] = {'aheadBy': len(commits), 'commits': {'nodes': list(reversed(commits))[-20:]}}
                    else:
                        repo[f'r{i}'], base[f'c{i}'] = None, None
                        errors.append({'type': 'NOT_FOUND', 'message': f'Could not resolve head ref {name}'})
                    i += 1
                repo['base'] = base
                answer = {'data': {'repository': repo}, **({'errors': errors} if errors else {})}
                if errors:
                    return subprocess.CompletedProcess(cmd, 1, json.dumps(answer), 'gh: Could not resolve head ref')
        elif args[0].endswith('/pulls'):
            if fail_open:
                return subprocess.CompletedProcess(cmd, 1, '', 'HTTP 422: A pull request already exists')
            answer = {'number': 900}
        elif args[0].endswith('/labels'):
            if fail_label:
                return subprocess.CompletedProcess(cmd, 1, '', 'HTTP 403: Resource not accessible by integration')
            answer = []
        else:
            answer = []
        return subprocess.CompletedProcess(cmd, 0, json.dumps(answer), '')
    return ocp.GitHub('o/r', run=run), calls


class EndToEndTests(unittest.TestCase):
    BRANCHES = {
        'claude/asks': (ref('asks'), [{'oid': 'a1', 'message': REQUEST}]),
        'claude/silent': (ref('silent'), [{'oid': 's1', 'message': 'wip'}]),
    }

    def test_find_reads_full_messages_only_for_branches_that_ask(self):
        gh, calls = fake_github(self.BRANCHES)
        self.assertEqual(ocp.find(gh, NOW), ['claude/asks'])
        full_queries = [p['query'] for a, p in calls if a[0] == 'graphql' and 'oid message ' in p['query']]
        self.assertEqual(len(full_queries), 1)
        self.assertNotIn('claude/silent', full_queries[0])
        self.assertFalse([a for a, _ in calls if a[0] != 'graphql'], 'find must only read')

    def test_a_request_commit_already_on_main_does_not_count(self):
        # Merged PRs leave their request commits on main; a branch cut from main must not look like it asks.
        branches = {'claude/new-work': (ref('new-work'), [{'oid': 'n1', 'message': 'Start the work'},
                                                          {'oid': 'm1', 'message': REQUEST}])}
        gh, _ = fake_github(branches, ahead={'claude/new-work': ['n1']})
        self.assertEqual(ocp.find(gh, NOW), [])
        self.assertEqual(ocp.open_prs(gh, ['claude/new-work'], NOW, log=lambda _: None), ([], 0))

    def test_the_branch_own_request_wins_over_an_older_one_merged_in_from_main(self):
        branches = {'claude/b': (ref('b'), [{'oid': 'merge', 'message': 'Merge main'},
                                            {'oid': 'old', 'message': 'PR: someone else\n\nPart of #1'},
                                            {'oid': 'mine', 'message': REQUEST}])}
        gh, calls = fake_github(branches, ahead={'claude/b': ['merge', 'mine']})
        self.assertEqual(ocp.open_prs(gh, ['claude/b'], NOW, log=lambda _: None), ([('claude/b', 900)], 0))
        post = [p for a, p in calls if a[0].endswith('/pulls')][0]
        self.assertEqual(post['title'], 'Fix the stuck timeline')

    def test_open_creates_the_pr_with_body_footer_and_allowed_labels(self):
        gh, calls = fake_github(self.BRANCHES)
        self.assertEqual(ocp.open_prs(gh, ['claude/asks', 'claude/silent'], NOW, log=lambda _: None),
                         ([('claude/asks', 900)], 0))
        posts = [(a[0], p) for a, p in calls if '-X' in a]
        self.assertEqual(posts[0][0], 'repos/o/r/pulls')
        self.assertEqual(posts[0][1]['head'], 'claude/asks')
        self.assertEqual(posts[0][1]['base'], 'main')
        self.assertEqual(posts[0][1]['title'], 'Fix the stuck timeline')
        self.assertIn('Closes #123', posts[0][1]['body'])
        self.assertIn('open-cloud-prs', posts[0][1]['body'])
        self.assertEqual(posts[1], ('repos/o/r/issues/900/labels', {'labels': ['automerge']}))

    def test_open_rechecks_and_ignores_names_it_was_handed_that_do_not_qualify(self):
        branches = {**self.BRANCHES, 'claude/has-pr': (ref('has-pr', prs=1), [{'oid': 'h', 'message': REQUEST}])}
        gh, calls = fake_github(branches)
        self.assertEqual(ocp.open_prs(gh, ['claude/has-pr', 'main', 'claude/gone', 'claude/silent'], NOW,
                                      log=lambda _: None), ([], 0))
        self.assertFalse([a for a, _ in calls if '-X' in a])

    def test_a_branch_deleted_since_it_was_listed_is_skipped_not_fatal(self):
        gh, _ = fake_github(self.BRANCHES)
        self.assertEqual(ocp.open_prs(gh, ['claude/gone', 'claude/asks'], NOW, log=lambda _: None),
                         ([('claude/asks', 900)], 0))

    def test_a_race_that_already_opened_the_pr_is_logged_not_counted(self):
        gh, _ = fake_github(self.BRANCHES, fail_open=True)
        lines = []
        self.assertEqual(ocp.open_prs(gh, ['claude/asks'], NOW, log=lines.append), ([], 0))
        self.assertIn('already has a PR', lines[0])

    def test_a_refused_label_is_a_failure_and_the_pr_still_counts_as_opened(self):
        gh, _ = fake_github(self.BRANCHES, fail_label=True)
        lines = []
        self.assertEqual(ocp.open_prs(gh, ['claude/asks'], NOW, log=lines.append), ([('claude/asks', 900)], 1))
        self.assertIn('NOT added', lines[0])

    def test_other_graphql_errors_still_fail(self):
        def run(cmd, input=None, **kwargs):
            return subprocess.CompletedProcess(cmd, 0, json.dumps({'data': None, 'errors': [{'type': 'FORBIDDEN'}]}), '')
        with self.assertRaises(RuntimeError):
            ocp.GitHub('o/r', run=run).branches(['claude/x'])

    def test_main_rejects_a_dispatch_input_outside_the_prefix(self):
        self.assertEqual(ocp.main(['find', '--branch', 'main']), 2)


class WorkflowTests(unittest.TestCase):
    """The token never meets branch code: schedule and dispatch only, the App token only in the job that opens."""

    def setUp(self):
        import yaml
        self.text = (ocp_root() / '.github/workflows/open-cloud-prs.yml').read_text()
        self.workflow = yaml.safe_load(self.text)

    def test_triggers_are_schedule_and_dispatch_only(self):
        on = self.workflow.get('on', self.workflow.get(True))
        self.assertEqual(set(on), {'schedule', 'workflow_dispatch'})

    def test_only_the_open_job_has_the_environment_and_neither_checks_out_a_branch(self):
        jobs = self.workflow['jobs']
        self.assertNotIn('environment', jobs['find'])
        self.assertEqual(jobs['open']['environment'], 'agent-identity')
        for job in jobs.values():
            for step in job['steps']:
                if 'actions/checkout' in step.get('uses', ''):
                    self.assertNotIn('ref', step.get('with') or {})
                    self.assertFalse((step.get('with') or {}).get('persist-credentials', True))

    def test_dispatch_input_reaches_the_shell_through_env_only(self):
        self.assertNotIn('${{ inputs.branch }}', '\n'.join(
            step.get('run', '') for job in self.workflow['jobs'].values() for step in job['steps']))


def ocp_root():
    return Path(__file__).resolve().parents[2]


if __name__ == '__main__':
    unittest.main()
