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

SCRIPT = Path(__file__).resolve().parents[1] / 'ci-cas-cache.sh'
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
        # A df that reports 10 MB free minus what the store holds so far, so the 5 MB floor is crossed mid-restore.
        df = self.bin / 'df'
        df.write_text('#!/bin/bash\n'
                      'used=$(du -sk "%s" 2>/dev/null | awk \'{print $1}\')\n'
                      'echo "Filesystem 1024-blocks Used Available Capacity Mounted"\n'
                      'echo "stub 0 0 $(( 10240 - ${used:-0} )) 0%% /"\n' % self.cas)
        df.chmod(df.stat().st_mode | stat.S_IXUSR)

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


if __name__ == '__main__':
    unittest.main()
