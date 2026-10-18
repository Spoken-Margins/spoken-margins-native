"""scripts/sim_builds.py and scripts/sim-build-latest: ready-made simulator builds for desks."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

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

    def run_cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                patch.object(self.cli, 'behind', return_value=3):
            code = self.cli.main(list(args))
        return code, out.getvalue(), err.getvalue()

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


if __name__ == '__main__':
    unittest.main()
