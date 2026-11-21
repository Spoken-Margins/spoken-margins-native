import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lane_package_seed as seed  # noqa: E402

OLD = time.time() - 3600
APFS = unittest.skipUnless(sys.platform == 'darwin', 'cp -c (APFS clone) is macOS only')
GIT_ENV = {**os.environ, 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.invalid',
           'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.invalid'}
UPSTREAMS = tempfile.TemporaryDirectory()


def git(*args, cwd=None):
    return subprocess.run(['git', '-c', 'protocol.file.allow=always', *args], cwd=cwd, env=GIT_ENV, check=True,
                          capture_output=True, text=True).stdout.strip()


def make_upstream(identity, submodule=None):
    """A real upstream repository with two commits; (path, [first, second] revisions). With
    `submodule`, the second commit adds it at `Source/Cmlx/mlx`, as mlx-swift has."""
    repo = Path(UPSTREAMS.name) / identity
    git('init', '-q', str(repo))
    revisions = []
    for n in (1, 2):
        (repo / 'Package.swift').write_text(f'// {identity} {n}\n')
        if submodule and n == 2:
            git('submodule', 'add', '-q', str(submodule), 'Source/Cmlx/mlx', cwd=repo)
        git('add', '.', cwd=repo)
        git('commit', '-q', '-m', str(n), cwd=repo)
        revisions.append(git('rev-parse', 'HEAD', cwd=repo))
    return repo, revisions


_MLX_CORE = make_upstream('mlx')
_UP = {'mlx-swift': make_upstream('mlx-swift', submodule=_MLX_CORE[0]), 'zipfoundation': make_upstream('zipfoundation')}
PINS = {identity: revs[1] for identity, (_, revs) in _UP.items()}
EARLIER = {identity: revs[0] for identity, (_, revs) in _UP.items()}


def make_checkout(folder, identity, subpath, revision):
    """What SwiftPM leaves: a bare `repositories/<pkg>` and a `git clone --shared` checkout of it, read-only."""
    repository = Path(folder) / 'repositories' / f'{identity}-1234'
    checkout = Path(folder) / 'checkouts' / subpath
    git('clone', '-q', '--bare', str(_UP[identity][0]), str(repository))
    git('clone', '-q', '--shared', '--no-checkout', str(repository), str(checkout))
    git('-C', str(checkout), 'checkout', '-q', '--detach', revision)
    if (checkout / '.gitmodules').is_file():
        git('-C', str(checkout), 'submodule', 'update', '-q', '--init', '--recursive')
    for name in ('config', 'objects/info/alternates', '../Package.swift'):
        (checkout / '.git' / name).chmod(0o444)


def write_resolved(root, pins, version=3):
    path = Path(root) / seed.RESOLVED
    path.parent.mkdir(parents=True, exist_ok=True)
    entries = [{'identity': k, 'kind': 'remoteSourceControl',
                'location': f'https://example.invalid/{k}', 'state': {'revision': v, 'version': '1.0.0'}}
               for k, v in pins.items()]
    path.write_text(json.dumps({'originHash': 'x', 'pins': entries, 'version': version}))
    return path


def write_packages(folder, pins, stamp=OLD, build_path=None, missing=(), edited=(), checked_out=None):
    """A SourcePackages folder as Xcode leaves it: state file, real git checkouts, and an artifact path naming its build.

    `checked_out` overrides the revision actually checked out (a checkout being updated in place). A pin
    that is not a real upstream revision gets a plain folder, enough for the pin-matching tests."""
    folder = Path(folder)
    deps = []
    for identity, revision in pins.items():
        subpath = identity.upper()
        if identity not in missing:
            head = (checked_out or {}).get(identity, revision)
            if identity in _UP and head in _UP[identity][1]:
                make_checkout(folder, identity, subpath, head)
            else:
                (folder / 'checkouts' / subpath).mkdir(parents=True, exist_ok=True)
        deps.append({'basedOn': None, 'packageRef': {'identity': identity, 'kind': 'remoteSourceControl'},
                     'state': {'checkoutState': {'revision': revision},
                               'name': 'edited' if identity in edited else 'sourceControlCheckout'},
                     'subpath': subpath})
    where = build_path or str(folder)
    state = {'object': {'artifacts': [{'path': f'{where}/artifacts/x/X.xcframework'}],
                        'dependencies': deps, 'prebuilts': []}, 'version': 7}
    folder.mkdir(parents=True, exist_ok=True)
    (folder / seed.STATE).write_text(json.dumps(state))
    os.utime(folder / seed.STATE, (stamp, stamp))
    return folder


class Base(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.dir = Path(self.temporary.name)
        self.cache = self.dir / 'cache'
        self.root = self.dir / 'worktree'
        write_resolved(self.root, PINS)
        patch = unittest.mock.patch.dict(os.environ, {'SM_LANE_PACKAGE_SEED': '', 'SM_BUILD_CACHE': ''})
        patch.start()
        self.addCleanup(patch.stop)
        os.environ.pop('GITHUB_ACTIONS', None)

    def tearDown(self):
        self.temporary.cleanup()

    def slot(self, name):
        return self.cache / name / 'root' / 'dd' / 'SourcePackages'


class PinsTests(Base):
    def test_resolved_pins_read_identity_and_revision(self):
        self.assertEqual(seed.resolved_pins(self.root / seed.RESOLVED), PINS)

    def test_resolved_pins_of_a_missing_or_broken_file_are_empty(self):
        self.assertEqual(seed.resolved_pins(self.dir / 'nope'), {})
        (self.dir / 'bad').write_text('{')
        self.assertEqual(seed.resolved_pins(self.dir / 'bad'), {})

    def test_state_pins_need_every_checkout_present(self):
        self.assertEqual(seed.state_pins(write_packages(self.dir / 'a', PINS)), PINS)
        self.assertIsNone(seed.state_pins(write_packages(self.dir / 'b', PINS, missing=('mlx-swift',))))

    def test_an_edited_dependency_is_not_a_donor(self):
        self.assertIsNone(seed.state_pins(write_packages(self.dir / 'c', PINS, edited=('zipfoundation',))))

    def test_pins_hash_ignores_order(self):
        self.assertEqual(seed.pins_hash(PINS), seed.pins_hash(dict(reversed(list(PINS.items())))))


class ChooseDonorTests(Base):
    def test_only_an_exact_match_is_chosen(self):
        other = {**PINS, 'mlx-swift': 'c' * 40}
        extra = {**PINS, 'swift-numerics': 'd' * 40}
        fewer = {'mlx-swift': PINS['mlx-swift']}
        options = [write_packages(self.slot(n), p) for n, p in
                   (('other', other), ('extra', extra), ('fewer', fewer), ('match', PINS))]
        self.assertEqual(seed.choose_donor(PINS, options), self.slot('match'))
        self.assertIsNone(seed.choose_donor(PINS, options[:3]))

    def test_a_donor_still_being_resolved_is_skipped(self):
        busy = write_packages(self.slot('busy'), PINS, stamp=time.time())
        self.assertIsNone(seed.choose_donor(PINS, [busy]))
        self.assertEqual(seed.choose_donor(PINS, [busy], now=time.time() + seed.SETTLE_SECONDS + 1), busy)

    def test_no_pins_choose_nothing(self):
        self.assertIsNone(seed.choose_donor({}, [write_packages(self.slot('a'), {})]))

    def test_shared_copies_come_before_slots_and_newer_first(self):
        old_slot = write_packages(self.slot('old'), PINS, stamp=OLD - 100)
        new_slot = write_packages(self.slot('new'), PINS, stamp=OLD)
        shared = write_packages(self.cache / seed.SHARED / 'h' / 'SourcePackages', PINS, stamp=OLD - 500)
        self.assertEqual(seed.candidates(self.cache), [shared, new_slot, old_slot])
        self.assertEqual(seed.candidates(self.cache, exclude=[shared]), [new_slot, old_slot])


class RewriteTests(Base):
    def test_donor_paths_point_at_the_new_build(self):
        folder = write_packages(self.dir / 'copy', PINS, build_path='/old/wt/.build/dd/SourcePackages')
        self.assertEqual(seed.rewrite_paths(folder, '/new/wt/.build/dd/SourcePackages'), 1)
        state = json.loads((folder / seed.STATE).read_text())
        self.assertEqual(state['object']['artifacts'][0]['path'],
                         '/new/wt/.build/dd/SourcePackages/artifacts/x/X.xcframework')
        self.assertEqual(seed.rewrite_paths(folder, '/new/wt/.build/dd/SourcePackages'), 0)


@APFS
class SeedTests(Base):
    def test_a_fresh_build_folder_is_cloned_from_the_matching_donor_and_the_donor_is_untouched(self):
        write_packages(self.slot('wrong'), {**PINS, 'mlx-swift': EARLIER['mlx-swift']})
        donor = write_packages(self.slot('donor'), PINS, build_path='/donor/.build/dd/SourcePackages')
        before = (donor / seed.STATE).read_text()
        package = (donor / 'checkouts' / 'MLX-SWIFT' / 'Package.swift').read_text()
        derived = self.dir / 'new' / 'dd'
        self.assertEqual(seed.seed(self.root, derived, self.cache), donor)
        target = derived / 'SourcePackages'
        self.assertEqual(seed.state_pins(target), PINS)
        self.assertIn(str(target), (target / seed.STATE).read_text())
        cloned = target / 'checkouts' / 'MLX-SWIFT' / 'Package.swift'
        cloned.chmod(0o644)
        cloned.write_text('changed in the clone')
        self.assertEqual((donor / seed.STATE).read_text(), before)
        self.assertEqual((donor / 'checkouts' / 'MLX-SWIFT' / 'Package.swift').read_text(), package)
        self.assertEqual([p.name for p in derived.iterdir()], ['SourcePackages'])  # no temporary left

    def test_an_existing_source_packages_is_left_alone(self):
        write_packages(self.slot('donor'), PINS)
        derived = self.dir / 'new' / 'dd'
        (derived / 'SourcePackages').mkdir(parents=True)
        self.assertIsNone(seed.seed(self.root, derived, self.cache))
        self.assertEqual(list((derived / 'SourcePackages').iterdir()), [])

    def test_no_donor_or_off_changes_nothing(self):
        derived = self.dir / 'new' / 'dd'
        self.assertIsNone(seed.seed(self.root, derived, self.cache))
        write_packages(self.slot('donor'), PINS)
        with unittest.mock.patch.dict(os.environ, {'SM_LANE_PACKAGE_SEED': 'off'}):
            self.assertIsNone(seed.seed(self.root, derived, self.cache))
        self.assertFalse(derived.exists())

    def test_a_failed_clone_leaves_nothing_behind(self):
        write_packages(self.slot('donor'), PINS)
        derived = self.dir / 'new' / 'dd'
        failure = subprocess.CalledProcessError(1, 'cp')
        with unittest.mock.patch.object(seed.subprocess, 'run', side_effect=failure):
            self.assertIsNone(seed.seed(self.root, derived, self.cache))
        self.assertEqual(list(derived.iterdir()), [])

    def test_a_seeded_checkout_still_works_after_the_donor_is_deleted(self):
        donor = write_packages(self.slot('donor'), PINS)
        derived = self.dir / 'new' / 'dd'
        self.assertEqual(seed.seed(self.root, derived, self.cache), donor)
        shutil.rmtree(self.cache / 'donor')
        target = derived / 'SourcePackages'
        for identity, subpath in (('mlx-swift', 'MLX-SWIFT'), ('zipfoundation', 'ZIPFOUNDATION')):
            checkout = str(target / 'checkouts' / subpath)
            self.assertEqual(git('-C', checkout, 'rev-parse', 'HEAD^{commit}'), PINS[identity])
            git('-C', checkout, 'cat-file', '-e', EARLIER[identity])  # history, read through alternates
            git('-C', checkout, 'status', '--porcelain')
            url = git('-C', checkout, 'config', 'remote.origin.url')
            self.assertTrue(url.startswith(str(target / 'repositories') + '/'), url)
            git('-C', checkout, 'fetch', '-q', 'origin')
        status = git('-C', str(target / 'checkouts' / 'MLX-SWIFT'), 'submodule', 'status', '--recursive')
        self.assertTrue(status.startswith(_MLX_CORE[1][1]), status)  # checked out at its recorded commit

    def test_a_shared_copy_outlives_the_build_it_was_kept_from(self):
        built = self.dir / 'built' / 'dd'
        write_packages(built / 'SourcePackages', PINS)
        shared = seed.keep_shared(self.root, built, self.cache)
        self.assertIsNotNone(shared)
        os.utime(shared / seed.STATE, (OLD, OLD))  # settled
        shutil.rmtree(built)  # phone-build deletes dd-sim after a passing build
        derived = self.dir / 'new' / 'dd'
        self.assertIsNotNone(seed.seed(self.root, derived, self.cache))
        checkout = str(derived / 'SourcePackages' / 'checkouts' / 'MLX-SWIFT')
        git('-C', checkout, 'cat-file', '-e', EARLIER['mlx-swift'])

    def test_a_donor_checkout_updated_in_place_is_not_used(self):
        write_packages(self.slot('donor'), PINS, checked_out={'mlx-swift': EARLIER['mlx-swift']})
        derived = self.dir / 'new' / 'dd'
        self.assertIsNone(seed.seed(self.root, derived, self.cache))
        self.assertEqual(list(derived.iterdir()), [])

    def test_a_donor_whose_submodule_is_mid_update_is_not_used(self):
        donor = write_packages(self.slot('donor'), PINS)
        submodule = donor / 'checkouts' / 'MLX-SWIFT' / 'Source' / 'Cmlx' / 'mlx'
        git('-C', str(submodule), 'checkout', '-q', '--detach', _MLX_CORE[1][0])
        derived = self.dir / 'new' / 'dd'
        self.assertIsNone(seed.seed(self.root, derived, self.cache))
        self.assertEqual(list(derived.iterdir()), [])

    def test_a_donor_checkout_holding_a_git_lock_is_not_used(self):
        """git checkout writes the working files under the old HEAD and index, behind `.git/index.lock`: the
        pins, HEAD and submodule status all still match, so only the lock shows it is mid-update."""
        for name in ('index.lock', 'HEAD.lock', 'config.lock'):
            with self.subTest(lock=name):
                donor = write_packages(self.slot('donor-' + name), PINS)
                (donor / 'checkouts' / 'MLX-SWIFT' / '.git' / name).write_text('')
                derived = self.dir / name / 'dd'
                self.assertIsNone(seed.seed(self.root, derived, self.cache))
                self.assertEqual(list(derived.iterdir()), [])

    def test_a_donor_submodule_holding_a_git_lock_is_not_used(self):
        donor = write_packages(self.slot('donor'), PINS)
        modules = donor / 'checkouts' / 'MLX-SWIFT' / '.git' / 'modules'
        lock = next(modules.rglob('HEAD')).parent / 'index.lock'
        lock.write_text('')
        derived = self.dir / 'new' / 'dd'
        self.assertIsNone(seed.seed(self.root, derived, self.cache))
        self.assertEqual(list(derived.iterdir()), [])

    def test_a_donor_checkout_without_git_is_not_used(self):
        donor = write_packages(self.slot('donor'), PINS)
        shutil.rmtree(donor / 'checkouts' / 'ZIPFOUNDATION' / '.git')
        derived = self.dir / 'new' / 'dd'
        self.assertIsNone(seed.seed(self.root, derived, self.cache))
        self.assertEqual(list(derived.iterdir()), [])

    def test_a_relative_derived_data_path_writes_absolute_paths(self):
        write_packages(self.slot('donor'), PINS, build_path='/donor/.build/dd/SourcePackages')
        cwd = os.getcwd()
        os.chdir(self.dir)
        try:
            self.assertIsNotNone(seed.seed(self.root, Path('rel/dd'), self.cache))
        finally:
            os.chdir(cwd)
        target = self.dir / 'rel' / 'dd' / 'SourcePackages'
        path = json.loads((target / seed.STATE).read_text())['object']['artifacts'][0]['path']
        self.assertTrue(os.path.isabs(path), path)
        self.assertEqual(os.path.realpath(path.split('/artifacts/')[0]), os.path.realpath(target))

    def test_keep_shared_copies_once_per_pins(self):
        derived = self.dir / 'built' / 'dd'
        write_packages(derived / 'SourcePackages', PINS)
        shared = seed.keep_shared(self.root, derived, self.cache)
        self.assertEqual(shared, self.cache / seed.SHARED / seed.pins_hash(PINS) / 'SourcePackages')
        self.assertEqual(seed.state_pins(shared), PINS)
        self.assertIsNone(seed.keep_shared(self.root, derived, self.cache))

    def test_keep_shared_skips_packages_that_do_not_match_the_pins(self):
        derived = self.dir / 'built' / 'dd'
        write_packages(derived / 'SourcePackages', {**PINS, 'mlx-swift': EARLIER['mlx-swift']})
        self.assertIsNone(seed.keep_shared(self.root, derived, self.cache))
        self.assertFalse((self.cache / seed.SHARED).exists())


FAKE_XCODEBUILD = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_RECORD"], "a") as handle:
    handle.write(json.dumps(sys.argv[1:]) + "\\n")
'''


@APFS
class WrapperTests(Base):
    """The real wrapper, a fake xcodebuild, a throwaway git checkout and cache."""

    def run_wrapper(self, derived):
        fake = self.dir / 'xcodebuild'
        fake.write_text(FAKE_XCODEBUILD)
        fake.chmod(0o755)
        env = {**os.environ, 'SM_LANE_STATE_DIR': str(self.dir / 'state'), 'SM_LANE_XCODEBUILD': str(fake),
               'FAKE_RECORD': str(self.dir / 'record.jsonl'), 'SM_BUILD_CACHE_ROOT': str(self.cache)}
        result = subprocess.run([sys.executable, str(SCRIPTS / 'xcodebuild-lane'), '-scheme', 'S',
                                 '-derivedDataPath', str(derived), 'build'], cwd=self.root, env=env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.dir / 'record.jsonl').read_text().splitlines()[-1]), result.stderr

    def setUp(self):
        super().setUp()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)

    def test_a_seeded_build_skips_package_updates(self):
        write_packages(self.slot('donor'), PINS)
        derived = self.dir / 'dd'
        argv, err = self.run_wrapper(derived)
        self.assertIn('-skipPackageUpdates', argv)
        self.assertIn('SourcePackages: cloned from', err)
        self.assertEqual(seed.state_pins(derived / 'SourcePackages'), PINS)

    def test_without_a_donor_the_build_runs_as_before(self):
        argv, err = self.run_wrapper(self.dir / 'dd')
        self.assertNotIn('-skipPackageUpdates', argv)
        self.assertIn('resolving from GitHub', err)


if __name__ == '__main__':
    unittest.main()
