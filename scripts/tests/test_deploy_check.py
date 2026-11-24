"""The gated web and site deploys (#4982): the notice before the owner's tap, the live check after, and the workflows.

The "what is shipping" list runs real git in a temporary repository, since history is the boundary that would break.
GitHub's API and the live pages are replaced at the World and `api` boundaries.
"""
import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy_check as dc  # noqa: E402
from test_workflow_files import parse  # noqa: E402

SHA = 'a' * 40


class Repo:
    """A throwaway git repository whose commits touch the given paths."""

    def __init__(self, folder):
        self.folder = folder
        self.run('init', '-q', '-b', 'main')
        self.run('config', 'user.email', 't@example.invalid')
        self.run('config', 'user.name', 'T')

    def run(self, *args):
        return subprocess.run(['git', '-C', str(self.folder), *args], check=True, capture_output=True, text=True).stdout

    def commit(self, path, subject):
        target = self.folder / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(target.read_text() + 'x' if target.exists() else 'x')
        self.run('add', '-A')
        self.run('commit', '-q', '-m', subject)
        return self.run('rev-parse', 'HEAD').strip()

    def git(self, *args):
        done = subprocess.run(['git', '-C', str(self.folder), *args], capture_output=True, text=True)
        if done.returncode:
            raise dc.Failure(done.stderr)
        return done.stdout


class Shipping(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def test_lists_only_commits_that_touch_what_the_deploy_copies_newest_first(self):
        live = self.repo.commit('Web/a.ts', 'live web')
        self.repo.commit('App/x.swift', 'app only')
        self.repo.commit('Web/b.ts', 'web fix one')
        self.repo.commit('research/B4/server/internal/links/open.mjs', 'link opener')
        head = self.repo.commit('Site/index.html', 'site words')
        lines, note = dc.shipping('web', live[:9], head, run=self.repo.git)
        self.assertIsNone(note)
        self.assertEqual([line.split(' ', 1)[1] for line in lines], ['link opener', 'web fix one'])
        lines, _ = dc.shipping('site', live[:9], head, run=self.repo.git)
        self.assertEqual([line.split(' ', 1)[1] for line in lines], ['site words'])

    def test_a_long_list_is_capped_and_says_how_many_more(self):
        live = self.repo.commit('Web/a.ts', 'live')
        for n in range(dc.SHOWN + 3):
            head = self.repo.commit('Web/a.ts', f'change {n}')
        lines, _ = dc.shipping('web', live, head, run=self.repo.git)
        self.assertEqual(len(lines), dc.SHOWN + 1)
        self.assertEqual(lines[-1], 'and 3 more')

    def test_an_unknown_or_foreign_live_commit_falls_back_to_the_new_commit_and_says_so(self):
        head = self.repo.commit('Web/a.ts', 'newest')
        for live in (None, 'deadbeefdead'):
            with self.subTest(live=live):
                lines, note = dc.shipping('web', live, head, run=self.repo.git)
                self.assertEqual(len(lines), 1)
                self.assertIn('newest', lines[0])
                self.assertIn('only the newest change', note)

    def test_nothing_new_says_it_copies_the_same_files(self):
        live = self.repo.commit('Web/a.ts', 'live')
        head = self.repo.commit('App/x.swift', 'app only')
        lines, note = dc.shipping('web', live, head, run=self.repo.git)
        self.assertEqual(lines, [])
        self.assertIn('same files', note)


class Body(unittest.TestCase):
    def test_mentions_the_owner_once_links_the_run_and_breaks_other_mentions(self):
        body = dc.notice_body('web', SHA, 'bbbbbbbbb', ['abc Thanks @someone for #12'], None, 'https://run/1')
        self.assertTrue(body.startswith('@uncomposed '))
        self.assertEqual(body.count('@uncomposed'), 1)
        self.assertNotIn('@someone', body)
        self.assertIn('https://run/1', body)
        self.assertIn('Review deployments', body)
        self.assertIn(dc.marker('web', SHA), body)

    def test_a_dirty_mac_stamp_still_names_its_commit(self):
        self.assertEqual(dc.live_commit({'commit': 'd904a2e06-dirty'}), 'd904a2e06')
        self.assertIsNone(dc.live_commit({'unknown': 'no stamp'}))
        self.assertIsNone(dc.live_commit({'commit': 'not-a-sha'}))


class FakeApi:
    def __init__(self, pulls, comments=()):
        self.pulls, self.comments, self.posted = pulls, list(comments), []

    def __call__(self, *args, payload=None):
        path = args[-1]
        if path.endswith('/pulls'):
            return self.pulls
        if '-X' in args:
            self.posted.append((path, payload['body']))
            return {}
        return self.comments


class Posting(unittest.TestCase):
    def test_posts_on_the_merged_pr(self):
        api = FakeApi([{'number': 7, 'merge_commit_sha': 'other'}, {'number': 9, 'merge_commit_sha': SHA}])
        self.assertEqual(dc.post_notice('o/r', SHA, 'hi', 'web', api=api), 'PR #9')
        self.assertEqual(api.posted, [('repos/o/r/issues/9/comments', 'hi')])

    def test_falls_back_to_a_commit_comment_when_no_pr_is_behind_it(self):
        api = FakeApi([])
        self.assertEqual(dc.post_notice('o/r', SHA, 'hi', 'web', api=api), f'commit {SHA[:9]}')
        self.assertEqual(api.posted, [(f'repos/o/r/commits/{SHA}/comments', 'hi')])

    def test_a_rerun_does_not_post_twice_but_a_lookalike_from_someone_else_does_not_count(self):
        tag = dc.marker('web', SHA)
        api = FakeApi([{'number': 9, 'merge_commit_sha': SHA}], [{'user': {'login': dc.BOT_LOGIN}, 'body': tag}])
        self.assertIn('already posted', dc.post_notice('o/r', SHA, 'hi', 'web', api=api))
        self.assertEqual(api.posted, [])
        api = FakeApi([{'number': 9, 'merge_commit_sha': SHA}], [{'user': {'login': 'stranger'}, 'body': tag}])
        dc.post_notice('o/r', SHA, 'hi', 'web', api=api)
        self.assertEqual(len(api.posted), 1)

    def test_notice_reads_the_live_stamp_and_posts_one_comment(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Repo(Path(tmp.name))
        live = repo.commit('Site/index.html', 'live')
        head = repo.commit('Site/index.html', 'new words')
        world = SimpleNamespace(fetch=lambda url: (200, {}, f'{{"commit":"{live[:9]}-dirty"}}'.encode()))
        api = FakeApi([{'number': 3, 'merge_commit_sha': head}])
        args = SimpleNamespace(target='site', sha=head, run_url='https://run/2', dry_run=False)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dc.notice(args, world=world, run=repo.git, api=api), 0)
        (path, body), = api.posted
        self.assertEqual(path, 'repos/Spoken-Margins/spoken-margins-native/issues/3/comments'
                         if not os.environ.get('GITHUB_REPOSITORY') else path)
        self.assertIn('new words', body)
        self.assertIn('website (https://spokenmargins.com)', body)


def stamp(commit):
    return {'commit': commit, 'deployed': '2026-11-22T00:00:00Z', 'source': 'x'}


class Judge(unittest.TestCase):
    def test_web_passes_only_when_the_stamp_is_this_commit(self):
        self.assertEqual(dc.judge('web', SHA, dict(stamp(SHA[:9]), behind=0)), ([], []))
        problems, _ = dc.judge('web', SHA, dict(stamp('bbbbbbbbb'), behind=0))
        self.assertTrue(problems)
        problems, _ = dc.judge('web', SHA, {'unknown': 'could not reach'})
        self.assertTrue(problems)

    def test_web_newer_changes_on_main_warn_but_do_not_fail(self):
        problems, warnings = dc.judge('web', SHA, dict(stamp(SHA[:9]), behind=2))
        self.assertEqual(problems, [])
        self.assertIn('2 newer', warnings[0])

    def test_site_needs_every_page_live_and_matching(self):
        good = {'page': '/', 'http': 200, 'matches_trunk': True}
        facts = {'rows': [good], 'deploy': stamp(SHA[:9])}
        self.assertEqual(dc.judge('site', SHA, facts), ([], []))
        for row in ({'page': '/x/', 'http': 404}, {'page': '/x/', 'unknown': 'down'},
                    {'page': '/x/', 'http': 200, 'matches_trunk': False}):
            with self.subTest(row=row):
                problems, _ = dc.judge('site', SHA, dict(facts, rows=[good, row]))
                self.assertEqual(len(problems), 1)
        problems, _ = dc.judge('site', SHA, dict(facts, deploy=stamp(SHA[:9] + '-dirty')))
        self.assertTrue(problems)

    def test_a_site_page_that_differs_only_because_main_moved_on_warns(self):
        facts = {'rows': [{'page': '/', 'http': 200, 'matches_trunk': False}], 'deploy': stamp(SHA[:9])}
        problems, warnings = dc.judge('site', SHA, facts, site_tree_moved=True)
        self.assertEqual(problems, [])
        self.assertEqual(len(warnings), 1)


class Newest(unittest.TestCase):
    """#4985 audit: a re-run keeps its old commit, so the deploy job stops when main has a newer change it copies."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Repo(Path(self.tmp.name))
        self.fetched = []

    def run_git(self, *args):
        if args[0] == 'fetch':
            self.fetched.append(args)
            return ''
        return self.repo.git(*[a.replace('origin/main', 'main') for a in args])

    def verdict(self, target, sha):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = dc.newest(SimpleNamespace(target=target, sha=sha), run=self.run_git)
        return code, out.getvalue()

    def test_the_newest_change_deploys(self):
        sha = self.repo.commit('Web/app.js', 'web change')
        self.repo.commit('Site/index.html', 'site change after it')
        self.assertEqual(self.verdict('web', sha)[0], 0)
        self.assertTrue(self.fetched, 'main must be fetched fresh before the comparison')

    def test_an_older_commit_stops_before_the_copy_and_names_the_newer_one(self):
        old = self.repo.commit('Web/app.js', 'old web change')
        newer = self.repo.commit('Web/app.js', 'newer web change')
        code, out = self.verdict('web', old)
        self.assertEqual(code, 1)
        self.assertIn(newer[:7], out)
        self.assertIn('::error::', out)

    def test_each_target_only_counts_what_it_copies(self):
        site = self.repo.commit('Site/index.html', 'site change')
        self.repo.commit('research/B4/deploy/deploy-web.sh', 'web script change')
        self.assertEqual(self.verdict('site', site)[0], 0)
        web = self.repo.commit('Web/app.js', 'web change')
        self.repo.commit('scripts/deploy-spoken-margins-site.sh', 'site script change')
        self.assertEqual(self.verdict('web', web)[0], 0)
        self.assertEqual(self.verdict('site', site)[0], 1)


class WebSources(unittest.TestCase):
    """The web deploy builds from a git archive, so a file the build reads outside Web/ must be in that archive.

    Run 45133642168 (2026-11-23) failed because vite.config.ts began reading Contracts/fixtures/margins-control-center
    and deploy-web.sh archived only Web/ and the share-link folder.
    """

    def archived(self):
        script = (ROOT / 'research/B4/deploy/deploy-web.sh').read_text()
        match = re.search(r'^sources=\(([^)]*)\)', script, re.M)
        self.assertIsNotNone(match, 'deploy-web.sh no longer lists its sources=(...)')
        return match.group(1).split()

    def test_every_file_the_build_config_reads_is_archived(self):
        sources = self.archived()
        config = (ROOT / 'Web/vite.config.ts').read_text()
        for relative in re.findall(r"new URL\('(\.\./[^']+)'", config):
            path = (ROOT / 'Web' / relative).resolve().relative_to(ROOT).as_posix()
            with self.subTest(path=path):
                self.assertTrue(any(path == s or path.startswith(s + '/') for s in sources),
                                f'vite.config.ts reads {path}, which deploy-web.sh does not archive')

    def test_the_change_list_names_every_archived_folder(self):
        paths = dc.TARGETS['web']['paths']
        for source in self.archived():
            self.assertIn(source, paths)


class Workflows(unittest.TestCase):
    """The deploy key only ever reaches main, behind the owner's tap, with strict host checking."""

    FILES = {'deploy-web.yml': ('web-deploy', 'web', ['Web/**', 'research/B4/deploy/deploy-web.sh',
                                                       'Contracts/fixtures/margins-control-center/**']),
             'deploy-site.yml': ('site-deploy', 'site', ['Site/**', 'scripts/deploy-spoken-margins-site.sh'])}

    def test_each_deploy_is_main_only_gated_and_announced(self):
        for name, (environment, target, paths) in self.FILES.items():
            with self.subTest(name=name):
                document = parse(ROOT / '.github/workflows' / name)
                triggers = next(document[key] for key in ('on', True, 'true') if key in document)
                self.assertEqual(set(triggers), {'push', 'workflow_dispatch'})
                self.assertEqual(triggers['push']['branches'], ['main'])
                for path in paths:
                    self.assertIn(path, triggers['push']['paths'])
                self.assertEqual(document['permissions'], {'contents': 'read'})
                notice, deploy = document['jobs']['notice'], document['jobs']['deploy']
                self.assertNotIn('environment', notice)
                self.assertNotIn('secrets.', str(notice))
                self.assertEqual(deploy['environment'], environment)
                self.assertEqual(deploy['needs'], 'notice')
                self.assertNotIn('permissions', deploy)
                self.assertEqual(deploy['concurrency'], {'group': environment, 'cancel-in-progress': False})
                for job in (notice, deploy):
                    self.assertIn("github.ref == 'refs/heads/main'", job['if'])
                    self.assertIn('refs/heads/main', job['steps'][0]['run'])
                    for step in job['steps']:
                        uses = step.get('uses', '')
                        if uses:
                            self.assertRegex(uses, r'@[0-9a-f]{40}$', f'{uses} is not pinned to a commit')
                        if 'checkout' in uses:
                            self.assertFalse(step['with']['persist-credentials'])
                runs = ' '.join(step.get('run', '') for step in deploy['steps'])
                self.assertIn('scripts/deploy-ssh-setup.sh', runs)
                self.assertIn(f'deploy_check.py verify --target {target}', runs)
                names = [step.get('name', '') for step in deploy['steps']]
                stop = next(i for i, step in enumerate(deploy['steps'])
                            if f'deploy_check.py newest --target {target}' in step.get('run', ''))
                copy = next(i for i, n in enumerate(names) if 'copy the' in n.lower())
                self.assertLess(stop, names.index('Set up the deploy key'))
                self.assertLess(stop, copy)
                self.assertIn(f'deploy_check.py notice --target {target}', notice['steps'][-1]['run'])
                self.assertNotIn('cache', ' '.join(step.get('uses', '') for step in deploy['steps']))

    def test_the_ssh_setup_checks_host_keys_strictly_and_keeps_the_key_private(self):
        text = (SCRIPTS / 'deploy-ssh-setup.sh').read_text()
        self.assertIn('StrictHostKeyChecking yes', text)
        self.assertIn('BatchMode yes', text)
        self.assertIn('chmod 600 "${HOME}/.ssh/sm_deploy"', text)
        self.assertNotIn('StrictHostKeyChecking no', text)
        self.assertNotRegex(text, r'echo[^\n]*\$\{?(SSH_KEY|HOST)\}?(?!#)')

    def test_the_ssh_setup_writes_a_private_key_file_and_refuses_a_bad_host(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home, SSH_KEY='KEY', KNOWN_HOSTS='host ssh-ed25519 AAAA', HOST='deploy@192.0.2.1')
            out = subprocess.run(['bash', str(SCRIPTS / 'deploy-ssh-setup.sh')], env=env, capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            key = Path(home, '.ssh/sm_deploy')
            self.assertEqual(oct(key.stat().st_mode & 0o777), '0o600')
            self.assertEqual(key.read_text(), 'KEY\n')
            self.assertIn('::add-mask::192.0.2.1', out.stdout)
            self.assertNotIn('KEY', out.stdout.replace('KNOWN', ''))
            env['HOST'] = 'no user here'
            out = subprocess.run(['bash', str(SCRIPTS / 'deploy-ssh-setup.sh')], env=env, capture_output=True, text=True)
            self.assertNotEqual(out.returncode, 0)


if __name__ == '__main__':
    unittest.main()
