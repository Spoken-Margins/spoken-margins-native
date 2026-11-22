"""Tests for the agents' App token minter and the sm-agent-env wrapper (#4915 step 2).

The signature is made and checked with a real throwaway RSA key and the real openssl, so a JWT GitHub would refuse
fails here. GitHub itself is faked: the token request returns a canned answer and records what it was sent.
"""
import base64
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import sm_app_token as mint  # noqa: E402

NOW = dt.datetime(2026, 11, 22, 20, 0, tzinfo=dt.timezone.utc)


def b64url_decode(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + '=' * (-len(part) % 4))


class Keys(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        root = Path(cls.dir.name)
        cls.key = root / 'key.pem'
        cls.pub = root / 'pub.pem'
        subprocess.run(['openssl', 'genrsa', '-out', str(cls.key), '2048'], check=True, capture_output=True)
        subprocess.run(['openssl', 'rsa', '-in', str(cls.key), '-pubout', '-out', str(cls.pub)],
                       check=True, capture_output=True)
        cls.pem = cls.key.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()


class Jwt(Keys):

    def test_signature_verifies_with_the_public_key(self):
        jwt = mint.app_jwt(self.pem, NOW.timestamp())
        header, payload, signature = jwt.split('.')
        with tempfile.TemporaryDirectory() as tmp:
            data, sig = Path(tmp) / 'data', Path(tmp) / 'sig'
            data.write_bytes(f'{header}.{payload}'.encode())
            sig.write_bytes(b64url_decode(signature))
            checked = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(self.pub), '-signature', str(sig),
                                      str(data)], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_claims_are_what_github_asks_for(self):
        header, payload, _ = mint.app_jwt(self.pem, NOW.timestamp()).split('.')
        self.assertEqual(json.loads(b64url_decode(header)), {'alg': 'RS256', 'typ': 'JWT'})
        claims = json.loads(b64url_decode(payload))
        self.assertEqual(claims['iss'], '5876250')
        self.assertEqual(claims['iat'], int(NOW.timestamp()) - 60)
        self.assertLessEqual(claims['exp'] - int(NOW.timestamp()), 600)  # GitHub's ceiling

    def test_a_bad_key_is_a_token_error_not_a_crash(self):
        with self.assertRaises(mint.TokenError):
            mint.sign_rs256(b'x', b'not a key')  # no PEM markers: scripts/check-public-tree.py flags them


class Cache(Keys):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name) / 'sub' / 'token.json'
        self.sent = []

    def tearDown(self):
        self.tmp.cleanup()

    def fake_mint(self, expires):
        def mint_once(jwt):
            self.sent.append(jwt)
            return {'token': f'ghs_{len(self.sent)}', 'expires_at': expires}
        return mint_once

    def get(self, now, expires='2026-11-22T21:00:00Z'):
        return mint.token(self.cache, now=now, pem_source=lambda: self.pem, mint=self.fake_mint(expires))

    def test_a_fresh_token_is_reused_and_the_cache_is_private(self):
        self.assertEqual(self.get(NOW), 'ghs_1')
        self.assertEqual(self.get(NOW + dt.timedelta(minutes=30)), 'ghs_1')
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)

    def test_a_token_near_expiry_is_replaced(self):
        self.get(NOW)
        self.assertEqual(self.get(NOW + dt.timedelta(minutes=51)), 'ghs_2')  # 9 minutes left: under the margin

    def test_a_corrupt_cache_mints_again(self):
        self.cache.parent.mkdir(parents=True)
        self.cache.write_text('{not json')
        self.assertEqual(self.get(NOW), 'ghs_1')


class TokenRequest(unittest.TestCase):

    def test_request_is_scoped_to_this_repository(self):
        seen = {}

        class Answer:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return json.dumps({'token': 'ghs_x', 'expires_at': '2026-11-22T21:00:00Z'}).encode()

        def opener(request, timeout):
            seen['url'], seen['body'] = request.full_url, json.loads(request.data)
            seen['auth'] = request.get_header('Authorization')
            return Answer()

        self.assertEqual(mint.request_token('j.w.t', opener)['token'], 'ghs_x')
        self.assertEqual(seen['url'], 'https://api.github.com/app/installations/184718081/access_tokens')
        self.assertEqual(seen['body'], {'repositories': ['spoken-margins-native']})
        self.assertEqual(seen['auth'], 'Bearer j.w.t')

    def test_an_answer_without_a_token_is_refused(self):
        class Empty:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b'{}'

        with self.assertRaises(mint.TokenError):
            mint.request_token('j', lambda request, timeout: Empty())


class Wrapper(unittest.TestCase):
    """sm-agent-env, run for real with a stand-in minter next to it."""

    def run_env(self, minter_body, flag):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'sm-agent-env').write_bytes((HERE / 'sm-agent-env').read_bytes())
            (root / 'sm-agent-env').chmod(0o755)
            (root / 'sm-app-token').write_text(minter_body)
            env = {'PATH': '/usr/bin:/bin', 'HOME': tmp}
            if flag:
                env['SM_AGENT_AS_APP'] = '1'
            return subprocess.run([str(root / 'sm-agent-env'), '/bin/sh', '-c', 'printf "%s" "$GH_TOKEN"'],
                                  capture_output=True, text=True, env=env)

    def test_the_flag_uses_the_app_token(self):
        done = self.run_env('print("ghs_app")\n', flag=True)
        self.assertEqual((done.returncode, done.stdout), (0, 'ghs_app'))

    def test_the_flag_fails_closed_when_minting_fails(self):
        done = self.run_env('import sys; sys.exit(1)\n', flag=True)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stdout, '')  # the command never ran
        self.assertIn('no App token', done.stderr)

    def test_without_the_flag_the_minter_is_not_called(self):
        done = self.run_env('print("ghs_app")\n', flag=False)
        self.assertEqual(done.returncode, 0)
        self.assertNotEqual(done.stdout, 'ghs_app')


if __name__ == '__main__':
    unittest.main()
