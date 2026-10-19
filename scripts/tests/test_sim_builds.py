"""scripts/sim_builds.py and scripts/sim-build-latest: ready-made simulator builds for desks."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import sim_builds  # noqa: E402

GB = 1024 ** 3
A, B, C = 'a' * 40, 'b' * 40, 'c' * 40


def load_cli():
    loader = importlib.machinery.SourceFileLoader('sim_build_latest', str(SCRIPTS / 'sim-build-latest'))
    spec = importlib.util.spec_from_loader('sim_build_latest', loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def fake_app(folder: Path, marker: str) -> Path:
    """A real bundle layout: a plist, a binary and a framework symlink, as ditto must keep them."""
    app = folder / marker / sim_builds.APP_NAME
    (app / 'Frameworks' / 'X.framework' / 'Versions' / 'A').mkdir(parents=True)
    (app / 'Info.plist').write_text(f'<plist>{marker}</plist>')
    (app / 'SpokenMarginsApp').write_bytes(b'\0' * 1000)
    (app / 'Frameworks' / 'X.framework' / 'Versions' / 'A' / 'X').write_bytes(b'x' * 10)
    (app / 'Frameworks' / 'X.framework' / 'X').symlink_to('Versions/A/X')
    return app


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = Path(self.tmp.name) / 'dd'
        self.root = Path(self.tmp.name) / 'sim-builds'

    def store(self, sha, at, free=50 * GB, keep=2):
        return sim_builds.store(fake_app(self.src, sha[:7] + str(at)), sha, 'next', self.root,
                                free_bytes=free, keep=keep, now=at)

    def test_copies_only_the_app_and_points_latest_at_it(self):
        kept = self.store(A, 1)
        self.assertTrue(kept['stored'])
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['aaaaaaa', 'latest'])
        self.assertEqual(os.readlink(self.root / 'latest'), 'aaaaaaa')
        app = self.root / 'latest' / sim_builds.APP_NAME
        self.assertTrue((app / 'Frameworks' / 'X.framework' / 'X').is_symlink())
        self.assertEqual(kept['size_bytes'], 1010 + len('<plist>aaaaaaa1</plist>'))
        self.assertEqual(sim_builds.latest(self.root)['sha'], A)

    def test_keeps_the_newest_two_and_never_the_one_it_replaces(self):
        self.store(A, 1)
        self.store(B, 2)
        kept = self.store(C, 3)
        self.assertEqual(kept['removed'], ['aaaaaaa'])
        self.assertEqual([b['sha'] for b in sim_builds.builds(self.root)], [C, B])
        self.assertEqual(os.readlink(self.root / 'latest'), 'ccccccc')

    def test_the_same_tip_again_replaces_its_copy(self):
        self.store(A, 1)
        self.store(A, 2)
        self.assertEqual([b['built_at'] for b in sim_builds.builds(self.root)], [2])

    def test_no_copy_below_ten_gigabytes_free(self):
        self.store(A, 1)
        kept = self.store(B, 2, free=9 * GB)
        self.assertFalse(kept['stored'])
        self.assertIn('10 GB floor', kept['why'])
        self.assertEqual(sim_builds.latest(self.root)['sha'], A)

    def test_refuses_a_short_sha_or_a_missing_app(self):
        self.assertFalse(sim_builds.store(self.src / 'none.app', A, 'next', self.root, free_bytes=50 * GB)['stored'])
        self.assertFalse(sim_builds.store(fake_app(self.src, 'x'), 'abc1234', 'next', self.root,
                                          free_bytes=50 * GB)['stored'])
        self.assertFalse(self.root.exists())

    def test_a_half_copied_build_is_never_offered_and_is_swept(self):
        self.store(A, 1)
        partial = self.root / 'bbbbbbb.partial'
        (partial / sim_builds.APP_NAME).mkdir(parents=True)
        (partial / 'build.json').write_text(json.dumps({'sha': B, 'built_at': 9}))
        self.assertEqual(sim_builds.latest(self.root)['sha'], A)
        self.store(C, 2)
        self.assertFalse(partial.exists())

    def test_find_matches_exactly_this_commit_by_full_sha_or_prefix(self):
        self.store(A, 1)
        self.store(B, 2)
        rows = [(A, A), (A[:7], A), (B[:12].upper(), B), (C, None), (A[:6], None), ('', None),
                (' ' + A + '\n', A), ('main', None)]
        for query, want in rows:
            with self.subTest(query=query):
                found = sim_builds.find(self.root, query)
                self.assertEqual(found and found['sha'], want)


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'sim-builds'
        self.cli = load_cli()
        patcher = patch.dict(os.environ, {'SM_SIM_BUILDS': str(self.root)})
        patcher.start()
        self.addCleanup(patcher.stop)

        self.tip = None          # origin/next as last fetched
        self.hosted = {}         # sha -> app marker the hosted run has an artifact for
        self.fetched = []

    def fake_fetch(self, folder, sha=None, *, free_bytes):
        self.fetched.append(sha)
        pick = next((k for k in self.hosted if k.startswith(sha)), None) if sha else max(self.hosted, default=None)
        if not pick:
            return {'stored': False, 'why': 'no hosted build'}
        kept = sim_builds.store(fake_app(Path(self.tmp.name) / 'hosted', self.hosted[pick]), pick, 'next', folder,
                                free_bytes=free_bytes, now=9, built_by='hosted integration')
        return dict(kept, artifact=sim_builds.ARTIFACT_PREFIX + pick)

    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                patch.object(self.cli, 'behind', return_value=3), patch.object(self.cli, 'tip', lambda *a: self.tip), \
                patch.object(self.cli, 'free_bytes', return_value=50 * GB), \
                patch.object(self.cli.sim_builds, 'fetch', self.fake_fetch):
            code = self.cli.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_a_commit_with_no_local_build_is_downloaded_from_the_hosted_run(self):
        self.hosted = {B: 'hostedB'}
        code, out, err = self.run_cli('--for', B[:7])
        self.assertEqual((code, out.splitlines()[1]), (0, B))
        self.assertIn('Downloaded sim-app-' + B, err)
        self.assertEqual(sim_builds.find(self.root, B)['built_by'], 'hosted integration')
        code, _, _ = self.run_cli('--for', B[:7])  # now local: no second download
        self.assertEqual((code, self.fetched), (0, [B[:7]]))

    def test_no_download_only_reads_this_mac(self):
        self.hosted = {B: 'hostedB'}
        self.tip = B
        self.assertEqual(self.run_cli('--for', B, '--no-download')[0], 1)
        self.assertEqual(self.run_cli('--no-download')[0], 1)
        self.assertEqual(self.fetched, [])

    def test_the_tip_is_downloaded_only_when_the_local_build_is_not_it(self):
        sim_builds.store(fake_app(Path(self.tmp.name), 'one'), A, 'next', self.root, free_bytes=50 * GB, now=1)
        rows = [(A, {}, A, []),              # local is the tip: nothing fetched
                (B, {B: 'hostedB'}, B, [B]),  # local is behind and the tip was built hosted: fetch it
                (C, {}, B, [C])]             # the tip has no hosted build: the newest kept build stands
        for tip, hosted, want, fetched in rows:
            with self.subTest(tip=tip[:1]):
                self.tip, self.hosted, self.fetched = tip, hosted, []
                code, out, _ = self.run_cli()
                self.assertEqual((code, out.splitlines()[1], self.fetched), (0, want, fetched))

    def test_with_nothing_local_the_newest_hosted_build_is_used(self):
        self.hosted, self.tip = {A: 'hostedA'}, C
        code, out, _ = self.run_cli()
        self.assertEqual((code, out.splitlines()[1], self.fetched), (0, A, [C, None]))

    def test_prints_the_newest_app_then_its_sha(self):
        sim_builds.store(fake_app(Path(self.tmp.name), 'one'), A, 'next', self.root, free_bytes=50 * GB, now=1)
        sim_builds.store(fake_app(Path(self.tmp.name), 'two'), B, 'next', self.root, free_bytes=50 * GB, now=2)
        code, out, err = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), [str(self.root / 'bbbbbbb' / sim_builds.APP_NAME), B])
        self.assertIn('3 commit(s) behind origin/next', err)

    def test_for_a_kept_commit_prints_that_build_and_for_any_other_fails(self):
        sim_builds.store(fake_app(Path(self.tmp.name), 'one'), A, 'next', self.root, free_bytes=50 * GB, now=1)
        sim_builds.store(fake_app(Path(self.tmp.name), 'two'), B, 'next', self.root, free_bytes=50 * GB, now=2)
        code, out, _ = self.run_cli('--for', A[:7])
        self.assertEqual((code, out.splitlines()[1]), (0, A))
        code, out, err = self.run_cli('--for', C)
        self.assertEqual((code, out), (1, ''))
        self.assertIn('build it yourself', err)

    def test_nothing_kept_fails_and_json_carries_the_lag(self):
        self.assertEqual(self.run_cli()[0], 1)
        sim_builds.store(fake_app(Path(self.tmp.name), 'one'), A, 'next', self.root, free_bytes=50 * GB, now=1)
        code, out, _ = self.run_cli('--json')
        self.assertEqual(code, 0)
        self.assertEqual({k: v for k, v in json.loads(out).items() if k in ('sha', 'behind', 'branch')},
                         {'sha': A, 'behind': 3, 'branch': 'next'})

    def test_behind_counts_from_this_checkout_and_is_none_when_git_cannot_say(self):
        self.assertIsNone(self.cli.behind(C, 'no-such-branch-here', Path(self.tmp.name)))


def artifact(folder: Path, sha: str, marker: str = 'h') -> Path:
    """The zip GitHub serves for a sim-app artifact: pack()'s two files, as upload-artifact zips them."""
    out = folder / 'packed'
    packed = sim_builds.pack(fake_app(folder / 'src', marker), sha, 'next', out, built_by='hosted integration', now=5)
    assert packed['packed'], packed
    path = folder / f'{sha[:7]}-artifact.zip'
    with zipfile.ZipFile(path, 'w') as z:
        for name in ('build.json', sim_builds.PACKED_APP):
            z.write(out / name, name)
    return path


class HostedArtifactTests(unittest.TestCase):
    """The hosted integration run's `sim-app-<sha>` artifact: packed on the hosted Mac, fetched by desks (#1389)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.root = self.dir / 'sim-builds'

    def test_a_packed_app_unpacks_as_built_with_its_symlinks(self):
        kept = sim_builds.unpack(artifact(self.dir, A), self.root, free_bytes=50 * GB)
        self.assertTrue(kept['stored'], kept)
        build = sim_builds.find(self.root, A)
        self.assertEqual((build['built_at'], build['built_by']), (5, 'hosted integration'))
        app = Path(build['app'])
        self.assertTrue((app / 'Frameworks' / 'X.framework' / 'X').is_symlink())
        self.assertEqual((app / 'Info.plist').read_text(), '<plist>h</plist>')

    def test_pack_refuses_a_short_sha_or_a_missing_app(self):
        out = self.dir / 'out'
        self.assertFalse(sim_builds.pack(self.dir / 'none.app', A, 'next', out, built_by='x')['packed'])
        self.assertFalse(sim_builds.pack(fake_app(self.dir, 'x'), A[:7], 'next', out, built_by='x')['packed'])
        self.assertFalse(out.exists())

    def test_an_artifact_without_the_packed_app_stores_nothing(self):
        bad = self.dir / 'bad.zip'
        with zipfile.ZipFile(bad, 'w') as z:
            z.writestr('build.json', json.dumps({'sha': A}))
            z.writestr('../evil', 'x')
        kept = sim_builds.unpack(bad, self.root, free_bytes=50 * GB)
        self.assertFalse(kept['stored'])
        self.assertIsNone(sim_builds.latest(self.root))

    def test_pick_takes_the_newest_unexpired_build_of_the_commit_asked_for(self):
        listed = [{'id': 1, 'name': 'sim-app-' + A, 'created_at': '2026-10-18T01:00:00Z', 'expired': False},
                  {'id': 2, 'name': 'sim-app-' + B, 'created_at': '2026-10-18T03:00:00Z', 'expired': True},
                  {'id': 3, 'name': 'sim-app-' + C, 'created_at': '2026-10-18T02:00:00Z', 'expired': False},
                  {'id': 4, 'name': 'hosted-integration-' + B, 'created_at': '2026-10-18T04:00:00Z'},
                  {'id': 5, 'name': 'sim-app-abc1234', 'created_at': '2026-10-18T05:00:00Z'}]
        rows = [(None, 3), (A, 1), (A[:7].upper(), 1), (B, None), ('abc1234', None), ('main', None), ('', None)]
        for sha, want in rows:
            with self.subTest(sha=sha):
                found = sim_builds.pick_artifact(listed, sha)
                self.assertEqual(found and found['id'], want)

    def fake_gh(self, listed, zips, calls, list_code=0):
        def run(cmd, **kw):
            calls.append(cmd[2])
            if cmd[2].endswith('/zip'):
                kw['stdout'].write(zips[int(cmd[2].split('/')[-2])].read_bytes())
                return subprocess.CompletedProcess(cmd, 0)
            return subprocess.CompletedProcess(cmd, list_code, stdout=json.dumps({'artifacts': listed}), stderr='HTTP 401')
        return run

    def test_fetch_downloads_stores_and_leaves_no_download_behind(self):
        listed = [{'id': 7, 'name': 'sim-app-' + A, 'created_at': '2026-10-18T01:00:00Z'}]
        calls = []
        got = sim_builds.fetch(self.root, A, free_bytes=50 * GB, repo='o/r',
                               run=self.fake_gh(listed, {7: artifact(self.dir, A)}, calls))
        self.assertTrue(got['stored'], got)
        self.assertEqual(calls, [f'repos/o/r/actions/artifacts?per_page=100&name=sim-app-{A}',
                                 'repos/o/r/actions/artifacts/7/zip'])
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['aaaaaaa', 'latest'])
        calls.clear()  # the same build again: listed, not downloaded
        again = sim_builds.fetch(self.root, None, free_bytes=50 * GB, repo='o/r', run=self.fake_gh(listed, {}, calls))
        self.assertTrue(again['already'])
        self.assertEqual(calls, ['repos/o/r/actions/artifacts?per_page=100'])

    def test_fetch_says_why_when_it_stores_nothing(self):
        rows = [('gh could not list', dict(list_code=1), 50 * GB),
                ('no hosted build of commit ' + B, {}, 50 * GB),
                ('under the 10 GB floor', {}, 9 * GB)]
        for why, kw, free in rows:
            with self.subTest(why=why):
                got = sim_builds.fetch(self.root, B, free_bytes=free, repo='o/r', run=self.fake_gh([], {}, [], **kw))
                self.assertFalse(got['stored'])
                self.assertIn(why, got['why'])


if __name__ == '__main__':
    unittest.main()
