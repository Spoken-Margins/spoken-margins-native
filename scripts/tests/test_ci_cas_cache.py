"""ci-cas-cache.sh: the compilation cache is archived sparse, and a bad restore costs a cold build (#2617).

The hosted `app` check restored a 481 MB archive of the store with plain tar, which wrote the store's holes out as
zeros until the runner's 36 GB disk was full, before anything was compiled.
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_workflow_files import parse

SCRIPT = Path(__file__).resolve().parents[1] / 'ci-cas-cache.sh'
WORKFLOWS = Path(__file__).resolve().parents[2] / '.github/workflows'
MIB = 1024 * 1024


def gnu_tar():
    for name in ('gtar', 'tar'):
        path = shutil.which(name)
        if path and 'GNU tar' in subprocess.run([path, '--version'], capture_output=True, text=True).stdout:
            return path
    return None


@unittest.skipUnless(gnu_tar() and shutil.which('zstd') and shutil.which('unzstd'), 'needs GNU tar and zstd')
class CasCacheTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='cas-cache-'))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.cas = self.root / 'work' / 'compilation-cache'
        self.pack = self.root / 'work' / 'cas-pack'
        self.summary = self.root / 'summary.md'
        self.outputs = self.root / 'outputs.txt'
        self.bin = self.root / 'bin'
        self.bin.mkdir()

    def run_script(self, mode, **extra):
        env = dict(os.environ, CAS=str(self.cas), PACK=str(self.pack), TAR=gnu_tar(),
                   GITHUB_STEP_SUMMARY=str(self.summary), GITHUB_OUTPUT=str(self.outputs),
                   CAS_POLL='0.05', **extra)
        env['PATH'] = f'{self.bin}{os.pathsep}{env["PATH"]}'
        result = subprocess.run(['bash', str(SCRIPT), mode], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def summary_text(self):
        return self.summary.read_text() if self.summary.exists() else ''

    def write_store(self, real_bytes, hole_bytes=0):
        """A store like Xcode's: a data file mapped far larger than what it holds, plus small leaf files."""
        self.cas.mkdir(parents=True)
        (self.cas / 'v9.leaf').write_bytes(b'leaf')
        with open(self.cas / 'v9.data', 'wb') as data:
            data.write(os.urandom(real_bytes))
            if hole_bytes:
                data.truncate(real_bytes + hole_bytes)

    def test_holes_survive_a_round_trip_so_a_restore_costs_what_the_store_uses(self):
        self.write_store(real_bytes=2 * MIB, hole_bytes=1024 * MIB)
        before = (self.cas / 'v9.data').read_bytes()[:2 * MIB]
        self.run_script('pack')
        self.assertIn('ok=true', self.outputs.read_text())
        shutil.rmtree(self.cas)

        self.run_script('unpack')

        restored = self.cas / 'v9.data'
        with open(restored, 'rb') as data:
            self.assertEqual(data.read(2 * MIB), before)
            data.seek(500 * MIB)
            self.assertEqual(data.read(16), bytes(16))
        self.assertEqual((self.cas / 'v9.leaf').read_bytes(), b'leaf')
        self.assertEqual(restored.stat().st_size, 2 * MIB + 1024 * MIB)
        # Written out as zeros, the file would hold 1 GiB more than it does.
        self.assertLess(restored.stat().st_blocks * 512, 64 * MIB)
        self.assertFalse(self.pack.exists(), 'the compressed copy is deleted once restored')
        self.assertIn('Compilation cache restored', self.summary_text())

    def test_a_store_over_the_limit_is_not_saved(self):
        self.write_store(real_bytes=6 * MIB)
        self.run_script('pack', CAS_MAX_KB='1000')
        self.assertIn('ok=false', self.outputs.read_text())
        self.assertFalse(self.pack.exists())
        self.assertIn('not saved', self.summary_text())

    def test_no_store_means_nothing_to_save(self):
        self.run_script('pack')
        self.assertIn('ok=false', self.outputs.read_text())

    def test_nothing_saved_means_a_cold_build_not_a_failure(self):
        out = self.run_script('unpack')
        self.assertFalse(self.cas.exists())
        self.assertIn('starts cold', out)

    def test_a_restore_that_would_fill_the_disk_is_stopped_and_deleted(self):
        # An archive written the way actions/cache wrote it: plain tar, every byte of the store present.
        self.write_store(real_bytes=60 * MIB)
        self.pack.mkdir()
        subprocess.run(f'tar -C "{self.cas.parent}" -cf - compilation-cache | zstd -q -o "{self.pack}/cas.tar.zst"',
                       shell=True, check=True)
        shutil.rmtree(self.cas)
        # Two stubs make the crossing certain instead of a race with a fast disk. unzstd hands tar the whole archive
        # and then lingers, so the extraction is still running when the script looks; df reports 10 MB free until
        # the store exists and none after, so the 5 MB floor is crossed the moment the first file lands.
        unzstd = self.bin / 'unzstd'
        unzstd.write_text('#!/bin/bash\n"%s" "$@" || exit\nexec sleep 5 >/dev/null 2>&1\n' % shutil.which('zstd'))
        df = self.bin / 'df'
        df.write_text('#!/bin/bash\n'
                      'echo "Filesystem 1024-blocks Used Available Capacity Mounted"\n'
                      'if [ -e "%s" ]; then free=0; else free=10240; fi\n'
                      'echo "stub 0 0 $free 0%% /"\n' % self.cas)
        for stub in (unzstd, df):
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

        out = self.run_script('unpack', CAS_MIN_FREE_KB='5120')

        self.assertFalse(self.cas.exists(), 'the half-written store is deleted')
        self.assertFalse(self.pack.exists())
        self.assertIn('Restore abandoned', out)

    def test_a_damaged_archive_means_a_cold_build_not_a_failure(self):
        self.pack.mkdir(parents=True)
        (self.pack / 'cas.tar.zst').write_bytes(b'not an archive')
        out = self.run_script('unpack')
        self.assertFalse(self.cas.exists())
        self.assertIn('Restore failed', out)


class WorkflowsUseTheScriptTests(unittest.TestCase):
    """Every workflow that caches the compilation cache goes through the script, and saves only after a good build (#2619).

    lane.yml and phone-build.yml kept actions/cache on the store itself after #2618 fixed the hosted app check, so the
    same disk-filling restore could still happen there, and the lane saved the store of a failed build too.
    """
    FILES = ('hosted-app-macos.yml', 'lane.yml', 'phone-build.yml')

    def cache_steps(self, name):
        steps = [step for job in parse(WORKFLOWS / name)['jobs'].values() for step in job.get('steps', [])]
        return [step for step in steps if str(step.get('uses', '')).startswith('actions/cache')
                and '-cas-' in str(step.get('with', {}).get('key', ''))]

    def test_no_workflow_caches_the_store_directly_or_restores_a_plain_tar_entry(self):
        for name in self.FILES:
            steps = self.cache_steps(name)
            self.assertTrue(steps, f'{name} has no compilation cache step')
            for step in steps:
                action = step['uses'].split('@')[0]
                self.assertIn(action, ('actions/cache/restore', 'actions/cache/save'), f'{name}: plain actions/cache')
                key = step['with']['key']
                self.assertIn('-cas-sparse-27.0-', key, f'{name}: the old plain-tar prefix could be restored')
                self.assertIn('pack', step['with']['path'].lower(), f'{name}: caches the store, not its sparse archive')
                if 'restore-keys' in step['with']:
                    self.assertIn('-cas-sparse-27.0-', step['with']['restore-keys'])

    def test_each_workflow_unpacks_what_it_restores_and_packs_before_it_saves(self):
        for name in self.FILES:
            text = (WORKFLOWS / name).read_text()
            self.assertIn('ci-cas-cache.sh unpack', text, name)
            self.assertIn('ci-cas-cache.sh pack', text, name)

    def test_a_save_needs_a_successful_pack_and_the_pack_needs_a_good_build(self):
        wanted = {'lane.yml': "steps.run.outputs.verdict == 'PASS'",
                  'phone-build.yml': "steps.archive.outcome == 'success'",
                  'hosted-app-macos.yml': "steps.t2-sim.outcome == 'success'"}
        for name, condition in wanted.items():
            steps = [step for job in parse(WORKFLOWS / name)['jobs'].values() for step in job.get('steps', [])]
            packs = [step for step in steps if 'ci-cas-cache.sh pack' in step.get('run', '')]
            saves = [step for step in steps if str(step.get('uses', '')).startswith('actions/cache/save')
                     and 'cas-' in step['with']['key']]
            self.assertEqual((len(packs), len(saves)), (1, 1), name)
            self.assertIn(condition, packs[0]['if'], f'{name}: a failed build\'s store could be saved')
            self.assertIn(f"steps.{packs[0]['id']}.outputs.ok == 'true'", saves[0]['if'], name)


if __name__ == '__main__':
    unittest.main()
