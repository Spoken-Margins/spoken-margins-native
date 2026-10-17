"""#712: a PR that brings in another PR's blocked commits inherits the block.

The ancestry here is real: temporary git repositories with real branches and merges. Only GitHub is faked
(the commit-to-PR lookup, the closed-PR search and the comments), because that is the boundary a test can't reach.
"""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lane_inherited_holds as holds  # noqa: E402

spec = importlib.util.spec_from_file_location('lane_runner_for_inherited', SCRIPTS / 'lane-runner.py')
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)

REPO = 'owner/repo'
GIT_ENV = {'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.test', 'GIT_COMMITTER_NAME': 't',
           'GIT_COMMITTER_EMAIL': 't@example.test', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null',
           'PATH': '/usr/bin:/bin:/usr/local/bin'}
BLOCKED = 'Findings\n\n[P1] The wrong item is played.'
CLEAN = 'No blocking findings.'


def audit(sha, verdict, comment_id, login='uncomposed'):
    return {'id': comment_id, 'user': {'login': login}, 'author_association': 'NONE' if login.endswith('[bot]') else 'OWNER',
            'html_url': f'https://github.test/{REPO}/pull/1#issuecomment-{comment_id}', 'body': f'**Claude audit on `{sha[:7]}`**\n\n{verdict}'}


def resolution(source, head, evidence='fixed in the merge, see the new test', comment_id=900):
    body = json.dumps({'source': source, 'head': head, 'evidence': evidence})
    return {'id': comment_id, 'user': {'login': 'uncomposed'}, 'author_association': 'OWNER', 'body': f'Resolved.\n<!-- audit-resolution: {body} -->'}


class Repo:
    """next, plus branches built with real commits and merges."""

    def __init__(self, folder: Path):
        self.path = folder
        self.git('init', '--quiet', '-b', 'next')
        self.commit('base')
        self.git('update-ref', 'refs/remotes/origin/next', 'HEAD')

    def git(self, *args):
        done = subprocess.run(['git', '-C', str(self.path), *args], capture_output=True, text=True, env=GIT_ENV)
        if done.returncode:
            raise AssertionError(f'git {args}: {done.stderr}')
        return done.stdout.strip()

    def commit(self, name):
        (self.path / f'{name}.txt').write_text(name)
        self.git('add', '-A')
        self.git('commit', '--quiet', '-m', name)
        return self.git('rev-parse', 'HEAD')

    def branch(self, name, start='next'):
        self.git('switch', '--quiet', '-c', name, start)

    def switch(self, name):
        self.git('switch', '--quiet', name)

    def merge(self, other):
        self.git('merge', '--quiet', '--no-ff', '-m', f'merge {other}', other)
        return self.git('rev-parse', 'HEAD')


class FakeGitHub:
    """The three GitHub reads the lookup makes, answered from dictionaries."""

    def __init__(self, comments, associated=None, closed=(), open_prs=()):
        self.comments, self.associated = comments, associated or {}
        self.closed, self.open_prs = list(closed), list(open_prs)
        self.paths = []

    def __call__(self, path, paginate=False):
        self.paths.append(path)
        if '/commits/' in path:
            sha = re.search(r'/commits/([0-9a-f]{40})/pulls', path).group(1)
            return [{'number': n} for n in self.associated.get(sha, [])]
        if path.startswith('search/issues'):
            numbers = self.open_prs if 'is%3Aopen' in path else self.closed
            return {'total_count': len(numbers), 'incomplete_results': False,
                    'items': [{'number': n, 'updated_at': f'2026-10-13T00:00:0{n % 10}Z'} for n in numbers]}
        number = int(re.search(r'issues/(\d+)/comments', path).group(1))
        return self.comments.get(number, [])


class Incident(unittest.TestCase):
    """The 2026-10-02 shape: A is blocked, B includes A's commit and gets a clean audit of its own."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.repo = Repo(Path(folder.name))
        self.repo.branch('a')
        self.x = self.repo.commit('x')
        self.repo.branch('b')
        self.repo.merge('a')
        self.head = self.repo.commit('y')
        self.blocked = audit(self.x, BLOCKED, 111)

    def find(self, comments, associated=None, closed=(), pr=2, head=None, open_prs=(), cache=None):
        github = FakeGitHub(comments, {self.x: [1]} if associated is None else associated, closed, open_prs)
        return holds.find_holds(self.repo.path, REPO, 'origin/next', head or self.head, pr, api=github, cache=cache), github

    def test_blocked_a_inside_clean_b_is_held(self):
        found, _ = self.find({1: [self.blocked]})
        self.assertEqual([(h['pr'], h['sha'], h['id']) for h in found], [(1, self.x, 111)])
        clean_b = [audit(self.head, CLEAN, 222)]
        standing = holds.unresolved(found, clean_b, self.head)
        self.assertEqual(standing, found)
        reason = holds.reasons(standing, self.head)[0]
        self.assertTrue(reason.startswith(holds.INHERITED))
        self.assertIn('"source": 111', reason)
        self.assertIn(self.head, reason)

    def test_an_explicit_resolution_followed_by_a_clean_audit_admits(self):
        found, _ = self.find({1: [self.blocked]})
        comments = [resolution(111, self.head), audit(self.head, CLEAN, 222)]
        self.assertEqual(holds.unresolved(found, comments, self.head), [])
        url = found[0]['url']  # the audit comment's URL names it as well as its id does
        self.assertEqual(holds.unresolved(found, [resolution(url, self.head), audit(self.head, CLEAN, 222)], self.head), [])

    def test_a_resolution_clears_nothing_without_a_clean_audit_after_it(self):
        found, _ = self.find({1: [self.blocked]})
        for name, comments in {
            'no audit at all': [resolution(111, self.head)],
            'the clean audit came first': [audit(self.head, CLEAN, 222), resolution(111, self.head)],
            'the audit after it is blocking': [resolution(111, self.head), audit(self.head, BLOCKED, 222)],
        }.items():
            with self.subTest(name):
                self.assertEqual(holds.unresolved(found, comments, self.head), found)

    def test_a_resolution_must_name_this_head_this_audit_and_give_evidence(self):
        found, _ = self.find({1: [self.blocked]})
        clean = audit(self.head, CLEAN, 222)
        older = 'f' * 40
        for name, note in {
            'stale: an earlier head': resolution(111, older),
            'a short sha for the head': resolution(111, self.head[:7]),
            'another audit comment': resolution(112, self.head),
            'no evidence': resolution(111, self.head, evidence=''),
            'blank evidence': resolution(111, self.head, evidence='   '),
            'no source': {'body': f'<!-- audit-resolution: {json.dumps({"head": self.head, "evidence": "x"})} -->'},
            'broken json': {'body': '<!-- audit-resolution: {"source": 111, "head": -->'},
            'prose only': {'body': f'Resolved {self.x} in {self.head}: fine.'},
        }.items():
            with self.subTest(name):
                self.assertEqual(holds.unresolved(found, [note, clean], self.head), found)

    def test_a_new_head_makes_the_old_resolution_stale(self):
        found, _ = self.find({1: [self.blocked]})
        comments = [resolution(111, self.head), audit(self.head, CLEAN, 222)]
        self.repo.commit('z')
        new_head = self.repo.git('rev-parse', 'HEAD')
        again, _ = self.find({1: [self.blocked]}, head=new_head)
        self.assertEqual(holds.unresolved(again, comments + [audit(new_head, CLEAN, 333)], new_head), again)

    def test_an_unresolved_sibling_still_holds(self):
        self.repo.switch('next')
        self.repo.branch('c')
        w = self.repo.commit('w')
        self.repo.switch('b')
        self.head = self.repo.merge('c')
        sibling = audit(w, BLOCKED, 333)
        found, _ = self.find({1: [self.blocked], 3: [sibling]}, associated={self.x: [1], w: [3]})
        self.assertEqual(sorted(h['id'] for h in found), [111, 333])
        comments = [resolution(111, self.head), audit(self.head, CLEAN, 444)]
        standing = holds.unresolved(found, comments, self.head)
        self.assertEqual([h['id'] for h in standing], [333])
        both = [resolution(111, self.head), resolution(333, self.head, comment_id=901), audit(self.head, CLEAN, 444)]
        self.assertEqual(holds.unresolved(found, both, self.head), [])

    def test_an_unrelated_pr_keeps_its_eligibility(self):
        self.repo.switch('next')
        self.repo.branch('d')
        d = self.repo.commit('d')
        elsewhere = audit(d, BLOCKED, 555)  # blocked, but nothing here brings in d
        found, _ = self.find({1: [self.blocked], 4: [elsewhere]}, associated={self.x: [1]})
        self.assertEqual([h['pr'] for h in found], [1])
        self.repo.switch('d')
        self.assertEqual(holds.find_holds(self.repo.path, REPO, 'origin/next', d, 4,
                                          api=FakeGitHub({4: [elsewhere]})), [])
        plain = holds.find_holds(self.repo.path, REPO, 'origin/next', d, 4, api=FakeGitHub({}))
        self.assertEqual(plain, [])

    def test_a_blocked_commit_already_on_next_is_not_inherited(self):
        self.repo.switch('next')
        self.repo.merge('a')  # A merged: its defect is a remediation issue, not a hold on whoever comes next
        self.repo.git('update-ref', 'refs/remotes/origin/next', 'HEAD')
        self.repo.switch('b')
        self.repo.merge('next')
        found, _ = self.find({1: [self.blocked]})
        self.assertEqual(found, [])

    def test_a_later_clean_audited_head_of_the_same_pr_supersedes_the_older_block(self):
        self.repo.switch('a')
        z = self.repo.commit('z')  # A's fix, audited clean
        self.repo.switch('b')
        self.head = self.repo.merge('a')
        fixed = [self.blocked, audit(z, CLEAN, 113)]
        found, _ = self.find({1: fixed}, associated={self.x: [1], z: [1]})
        self.assertEqual(found, [])
        still_blocked = [self.blocked, audit(z, BLOCKED, 114)]
        found, _ = self.find({1: still_blocked}, associated={self.x: [1], z: [1]})
        self.assertEqual([h['id'] for h in found], [114])  # the newest audited head decides

    def test_an_older_source_head_holds_even_when_the_pr_moved_on(self):
        # A got a clean audit of a newer head, but B includes only the older, blocked one.
        newer = audit('e' * 40, CLEAN, 113)
        found, _ = self.find({1: [self.blocked, newer]})
        self.assertEqual([h['id'] for h in found], [111])

    def test_a_closed_unmerged_source_is_found_by_search(self):
        found, github = self.find({1: [self.blocked]}, associated={}, closed=[1])
        self.assertEqual([h['pr'] for h in found], [1])
        self.assertTrue(any(p.startswith('search/issues') for p in github.paths))
        self.assertIn('is%3Aunmerged', next(p for p in github.paths if p.startswith('search/issues')))

    def test_a_source_whose_branch_was_rewritten_is_found_through_the_open_search(self):
        # A was audited blocked at x, then force-pushed: GitHub no longer lists x under A, and A is open.
        found, github = self.find({1: [self.blocked]}, associated={}, open_prs=[1])
        self.assertEqual([h['id'] for h in found], [111])
        self.assertEqual(self.find({1: [self.blocked]}, associated={})[0], [])  # no search hit, no association: unknown

    def test_a_copy_of_the_hold_line_is_never_a_resolution(self):
        # The runner's report quotes the template; neither it nor a placeholder may clear the finding.
        found, _ = self.find({1: [self.blocked]})
        template = holds.reasons(found, self.head)[0]
        clean = audit(self.head, CLEAN, 222)
        bot = {'id': 5, 'user': {'login': 'github-actions[bot]'}, 'body': f'Lane report pr2-r1 — PASS\nnot merged by the runner: {template}.'}
        person = {'id': 6, 'user': {'login': 'uncomposed'}, 'author_association': 'OWNER', 'body': template}
        filled = resolution(111, self.head)
        filled['user'] = {'login': 'github-actions[bot]'}
        for name, note in {'the lane report': bot, 'a pasted template': person, 'a bot-posted resolution': filled,
                           'placeholder evidence': resolution(111, self.head, evidence='...'),
                           'short evidence': resolution(111, self.head, evidence='done')}.items():
            with self.subTest(name):
                self.assertEqual(holds.resolutions([note], self.head), [])
                self.assertEqual(holds.unresolved(found, [clean, note, clean], self.head), found)
                self.assertFalse(holds.needs_reaudit([clean, note], self.head))

    def test_a_source_that_is_not_plain_digits_is_ignored_not_a_crash(self):
        for source in ('\u00b2', '\u0661\u0662', '1.5', '', None, True, [1], {'a': 1}):
            note = {'body': '<!-- audit-resolution: ' + json.dumps({'source': source, 'head': self.head,
                                                                      'evidence': 'a real explanation'}) + ' -->'}
            with self.subTest(source=source):
                self.assertEqual(holds.resolutions([note], self.head), [])

    def test_unchanged_prs_are_read_from_the_cache_and_changed_ones_again(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder) / 'holds.json'
            found, github = self.find({1: [self.blocked]}, associated={}, closed=[1], cache=cache)
            self.assertEqual([h['id'] for h in found], [111])
            self.assertEqual(sum('issues/1/comments' in p for p in github.paths), 1)
            again, github = self.find({1: []}, associated={}, closed=[1], cache=cache)  # same updated_at: not fetched
            self.assertEqual([h['id'] for h in again], [111])
            self.assertEqual(sum('issues/1/comments' in p for p in github.paths), 0)
            cache.write_text('not json')  # a broken cache costs a call, not a verdict
            broken, github = self.find({1: [self.blocked]}, associated={}, closed=[1], cache=cache)
            self.assertEqual([h['id'] for h in broken], [111])
            self.assertEqual(sum('issues/1/comments' in p for p in github.paths), 1)

    # #1822: only the owner's, a member's, a collaborator's and the bot's comments are read.
    @staticmethod
    def by_stranger(comment):
        return dict(comment, user={'login': 'mallory'}, author_association='NONE')

    def test_a_strangers_resolution_clears_nothing(self):
        found, _ = self.find({1: [self.blocked]})
        forged = self.by_stranger(resolution(111, self.head))
        self.assertEqual(holds.resolutions([forged], self.head), [])
        self.assertEqual(holds.unresolved(found, [forged, audit(self.head, CLEAN, 222)], self.head), found)
        genuine = [resolution(111, self.head), audit(self.head, CLEAN, 222)]
        self.assertEqual(holds.unresolved(found, genuine, self.head), [])

    def test_a_strangers_clean_audit_clears_nothing(self):
        found, _ = self.find({1: [self.blocked]})
        forged_clean = self.by_stranger(audit(self.head, CLEAN, 223))
        self.assertEqual(holds.unresolved(found, [resolution(111, self.head), forged_clean], self.head), found)

    def test_a_strangers_clean_audit_does_not_supersede_the_sources_blocking_one(self):
        forged_clean = self.by_stranger(audit(self.x, CLEAN, 999))
        found, _ = self.find({1: [self.blocked, forged_clean]})
        self.assertEqual([(h['pr'], h['id']) for h in found], [(1, 111)])

    def test_a_strangers_blocking_audit_holds_nothing(self):
        found, _ = self.find({1: [self.by_stranger(audit(self.x, BLOCKED, 998))]})
        self.assertEqual(found, [])

    def test_a_cache_entry_from_before_the_author_check_is_fetched_again(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder) / 'holds.json'
            self.find({1: [self.blocked]}, associated={}, closed=[1], cache=cache)
            _, github = self.find({1: []}, associated={}, closed=[1], cache=cache)
            self.assertEqual(sum('issues/1/comments' in p for p in github.paths), 0)  # a current entry is used
            saved = json.loads(cache.read_text())
            for entry in saved[REPO].values():
                for comment in entry['comments']:
                    del comment['author_association']  # what an older runner wrote
            cache.write_text(json.dumps(saved))
            found, github = self.find({1: [self.blocked]}, associated={}, closed=[1], cache=cache)
            self.assertEqual([h['id'] for h in found], [111])
            self.assertEqual(sum('issues/1/comments' in p for p in github.paths), 1)

    def test_the_candidate_s_own_audits_are_not_inherited(self):
        found, _ = self.find({2: [audit(self.head, BLOCKED, 7), audit(self.x, BLOCKED, 8)]},
                             associated={self.x: [2]})
        self.assertEqual(found, [])

    def test_a_lookup_that_fails_raises_so_the_caller_can_hold(self):
        def broken(path, paginate=False):
            raise holds.LookupFailed('rate limited')

        with self.assertRaises(holds.LookupFailed):
            holds.find_holds(self.repo.path, REPO, 'origin/next', self.head, 2, api=broken)
        with self.assertRaises(holds.LookupFailed):
            holds.find_holds(self.repo.path, REPO, 'origin/missing', self.head, 2, api=FakeGitHub({}))

    def test_a_seven_character_prefix_names_the_commit(self):
        found, _ = self.find({1: [audit(self.x[:7], BLOCKED, 111)]})
        self.assertEqual([h['sha'] for h in found], [self.x])

    def test_the_reaudit_signal(self):
        clean = audit(self.head, CLEAN, 222)
        self.assertFalse(holds.needs_reaudit([clean], self.head))
        self.assertTrue(holds.needs_reaudit([clean, resolution(111, self.head)], self.head))
        self.assertFalse(holds.needs_reaudit([resolution(111, self.head), clean], self.head))
        self.assertFalse(holds.needs_reaudit([clean, resolution(111, 'f' * 40)], self.head))

    def test_the_audit_that_follows_a_resolution_sees_it_and_its_evidence(self):
        # The real order: the resolution lands after the head's blocking audit; the re-audit's prompt is built before
        # the audit that would clear it exists (#1531 audit).
        found, _ = self.find({1: [self.blocked]})
        first = audit(self.head, BLOCKED, 222)
        note = resolution(111, self.head, evidence='the merge now plays only the playing item; see test_x')
        note['html_url'] = 'https://github.test/owner/repo/pull/2#issuecomment-900'
        text = holds.context(found, [first, note], self.head)
        self.assertNotIn('UNRESOLVED', text)
        self.assertIn('the merge now plays only the playing item', text)
        self.assertIn('issuecomment-900', text)
        self.assertEqual(holds.unresolved(found, [first, note], self.head), found)  # still held until the audit passes
        other = holds.context(found, [first, resolution(112, self.head)], self.head)
        self.assertIn('UNRESOLVED', other)  # a resolution of another finding doesn't count
        stale = holds.context(found, [first, resolution(111, 'f' * 40)], self.head)
        self.assertIn('UNRESOLVED', stale)

    def test_the_auditor_is_told_what_is_unresolved(self):
        found, _ = self.find({1: [self.blocked]})
        text = holds.context(found, [], self.head)
        self.assertIn('UNRESOLVED', text)
        self.assertIn(self.x[:7], text)
        resolved = holds.context(found, [resolution(111, self.head), audit(self.head, CLEAN, 222)], self.head)
        self.assertNotIn('UNRESOLVED', resolved)
        self.assertEqual(holds.context([], [], self.head), '')


class RunnerWiring(unittest.TestCase):
    def test_audit_formats_match_the_runner(self):
        self.assertEqual(holds.AUDIT_HEADINGS, lane.AUDITS[:2])
        self.assertEqual(holds.CLEAN_AUDIT.pattern, lane.CLEAN_AUDIT.pattern)
        self.assertEqual(holds.AUDIT_SHA.pattern, lane.AUDIT_SHA.pattern)
        self.assertEqual(holds.INHERITED, lane.INHERITED_HOLD)
        head = 'abcdef0' + '0' * 33
        for text in ('**Claude audit on `abcdef0`**', '**Codex audit (Astra) on `abcdef0`**',
                     '## Codex audit (gpt-6-astra, high) of `abcdef0`',
                     '**Codex audit on `a919a79` (P2): fixed in `abcdef0`**',  # a finisher's reply: not an audit
                     '**Claude audit on `abcdef0` (P2)**', 'Waiting on the Codex audit (Astra) for `abcdef0`.'):
            body = {'body': text + '\n\nNo blocking findings.', 'author_association': 'OWNER'}
            with self.subTest(text):
                self.assertEqual(bool(holds.audit_records([body])), lane.audit_blocker([body], head) is None)

    def test_merge_blockers_adds_the_inherited_reasons(self):
        scope = {'files': [], 'lane_paths': []}
        self.assertEqual(lane.merge_blockers(scope, [], 'a' * 40), [])
        self.assertEqual(lane.merge_blockers(scope, [], 'a' * 40, lambda comments: ['x']), ['x'])

    def test_inherited_check_holds_when_the_lookup_cannot_finish(self):
        github = mock.Mock(repo=REPO, pr=2)
        with mock.patch.object(lane, 'base_policy', return_value=None):
            check = lane.inherited_check(github, Path('.'), 'next', 'a' * 40)
        self.assertTrue(check([])[0].startswith(lane.INHERITED_FAILED))
        broken = mock.Mock(find_holds=mock.Mock(side_effect=holds.LookupFailed('rate limited')))
        with mock.patch.object(lane, 'base_policy', return_value=broken):
            check = lane.inherited_check(github, Path('.'), 'next', 'a' * 40)
        self.assertIn('rate limited', check([])[0])
        self.assertIn('Remove and re-add automerge', check([])[0])

    def test_inherited_check_reads_next_s_copy_of_the_policy(self):
        github = mock.Mock(repo=REPO, pr=2)
        with mock.patch.object(lane, 'base_policy', return_value=holds) as policy, \
                mock.patch.object(holds, 'find_holds', return_value=[]) as find:
            check = lane.inherited_check(github, Path('/tree'), 'next', 'a' * 40)
        policy.assert_called_once_with(Path('/tree'), 'next', 'scripts/lane_inherited_holds.py')
        find.assert_called_once_with(Path('/tree'), REPO, 'origin/next', 'a' * 40, 2, cache=lane.INHERITED_CACHE)
        self.assertEqual(check([]), [])

    def test_the_new_policy_file_is_a_lane_path_and_loads_as_a_next_copy(self):
        policy = importlib.util.spec_from_file_location('scope_for_inherited', SCRIPTS / 'test-scope.py')
        scope = importlib.util.module_from_spec(policy)
        policy.loader.exec_module(scope)
        self.assertTrue(scope.is_lane_path('scripts/lane_inherited_holds.py'))
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(Path(folder))
            (repo.path / 'scripts').mkdir()
            (repo.path / 'scripts' / 'lane_inherited_holds.py').write_text((SCRIPTS / 'lane_inherited_holds.py').read_text())
            repo.git('add', '-A')
            repo.git('commit', '--quiet', '-m', 'policy')
            repo.git('update-ref', 'refs/remotes/origin/next', 'HEAD')
            loaded = lane.base_policy(repo.path, 'next', 'scripts/lane_inherited_holds.py')
        self.assertTrue(callable(loaded.find_holds))
        self.assertEqual(loaded.INHERITED, holds.INHERITED)


if __name__ == '__main__':
    unittest.main()
