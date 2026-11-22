#!/usr/bin/env python3
"""Print a short-lived installation token for the agents' GitHub App `spoken-margins-agent` (#4915 step 2).

Local agent jobs act on GitHub through `sm-agent-env` (this folder). With `SM_AGENT_AS_APP=1` it calls this script,
so their `gh` and `git push` act as `spoken-margins-agent[bot]` instead of the owner's login. Without the flag nothing
changes, which is the rollback.

How the token is made:
  1. The App's private key is read from the macOS Keychain (generic password, service `sm-agent-app-key`). It is
     stored as one line of base64 of the PEM file, because `security -w` prints multi-line secrets as hex.
  2. A JWT (RS256, 9 minutes) is signed with `openssl dgst -sha256 -sign`. The key reaches openssl through a pipe
     (`/dev/fd/N`), so it is never written to disk.
  3. GitHub exchanges the JWT for an installation token limited to this repository (1 hour). The token is cached
     under ~/Library/Caches/spoken-margins (mode 0600) and reused while it has more than 10 minutes left, so most
     calls cost no request at all; the mint request counts against the App's own rate limit, not the owner's.

Exit 0 and the token on stdout, or exit 1 with the reason on stderr (and nothing on stdout).

    sm_app_token.py              print a token (cached or new)
    sm_app_token.py --check      mint and print who the token is and when it expires, never the token
"""
from __future__ import annotations

import base64
import contextlib
import datetime as dt
import fcntl
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

APP_ID = '5876250'
INSTALLATION_ID = '184718081'
REPOSITORY = 'spoken-margins-native'
KEYCHAIN_SERVICE = 'sm-agent-app-key'
API = 'https://api.github.com'
CACHE = Path.home() / 'Library' / 'Caches' / 'spoken-margins' / 'agent-app-token.json'
REUSE_MARGIN = dt.timedelta(minutes=10)
JWT_LIFETIME = 540   # seconds; GitHub allows at most 600
CLOCK_SKEW = 60      # iat is set this far in the past, as GitHub's docs advise


class TokenError(Exception):
    pass


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def keychain_pem(service: str = KEYCHAIN_SERVICE) -> bytes:
    found = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', service, '-w'],
                           capture_output=True, text=True)
    if found.returncode != 0 or not found.stdout.strip():
        raise TokenError(f'no Keychain item {service!r} (the App key is not stored yet)')
    try:
        pem = base64.b64decode(found.stdout.strip(), validate=True)
    except ValueError as error:
        raise TokenError(f'Keychain item {service!r} is not base64 of a PEM file') from error
    if b'PRIVATE KEY-----' not in pem:
        raise TokenError(f'Keychain item {service!r} does not hold a private key')
    return pem


def sign_rs256(message: bytes, pem: bytes, openssl: str = 'openssl') -> bytes:
    """RS256 signature of `message`. The key goes to openssl through a pipe, never a file."""
    read_end, write_end = os.pipe()
    try:
        with subprocess.Popen([openssl, 'dgst', '-sha256', '-sign', f'/dev/fd/{read_end}'], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(read_end,)) as proc:
            os.close(read_end)
            read_end = -1
            with os.fdopen(write_end, 'wb') as key_pipe:
                write_end = -1
                key_pipe.write(pem)
            signature, error = proc.communicate(message)
    finally:
        for fd in (read_end, write_end):
            if fd >= 0:
                os.close(fd)
    if proc.returncode != 0 or not signature:
        raise TokenError(f'openssl could not sign: {error.decode(errors="replace").strip()[:200]}')
    return signature


def app_jwt(pem: bytes, now: float, app_id: str = APP_ID, **sign_args) -> str:
    header = b64url(json.dumps({'alg': 'RS256', 'typ': 'JWT'}, separators=(',', ':')).encode())
    claims = {'iat': int(now) - CLOCK_SKEW, 'exp': int(now) + JWT_LIFETIME, 'iss': app_id}
    payload = b64url(json.dumps(claims, separators=(',', ':')).encode())
    signing_input = f'{header}.{payload}'.encode()
    return f'{header}.{payload}.{b64url(sign_rs256(signing_input, pem, **sign_args))}'


def request_token(jwt: str, opener=urllib.request.urlopen) -> dict:
    body = json.dumps({'repositories': [REPOSITORY]}).encode()
    request = urllib.request.Request(f'{API}/app/installations/{INSTALLATION_ID}/access_tokens', data=body,
                                     method='POST', headers={
                                         'Accept': 'application/vnd.github+json',
                                         'Authorization': f'Bearer {jwt}',
                                         'X-GitHub-Api-Version': '2022-11-28',
                                         'User-Agent': 'sm-app-token'})
    try:
        with opener(request, timeout=20) as response:
            answer = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise TokenError(f'GitHub refused the token request: HTTP {error.code}') from error
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        raise TokenError(f'token request failed: {error}') from error
    if not answer.get('token') or not answer.get('expires_at'):
        raise TokenError('GitHub answered without a token')
    return {'token': answer['token'], 'expires_at': answer['expires_at']}


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00'))


def usable(entry: dict | None, now: dt.datetime) -> bool:
    try:
        return bool(entry and entry.get('token')) and parse_time(entry['expires_at']) - now > REUSE_MARGIN
    except (KeyError, TypeError, ValueError):
        return False


def read_cache(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def write_cache(path: Path, entry: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_suffix('.tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump(entry, handle)
    os.replace(temp, path)


@contextlib.contextmanager
def locked(path: Path):
    """One minter at a time, so parallel agent jobs share one token instead of each minting their own."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(path.with_suffix('.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def token(cache: Path = CACHE, now: dt.datetime | None = None, pem_source=keychain_pem, mint=request_token) -> str:
    now = now or dt.datetime.now(dt.timezone.utc)
    with locked(cache):
        entry = read_cache(cache)
        if usable(entry, now):
            return entry['token']
        entry = mint(app_jwt(pem_source(), now.timestamp()))
        write_cache(cache, entry)
        return entry['token']


def check() -> int:
    """Mint (or reuse) a token and show what it can see, without printing the token."""
    value = token()
    entry = read_cache(CACHE) or {}
    request = urllib.request.Request(f'{API}/installation/repositories?per_page=5', headers={
        'Accept': 'application/vnd.github+json', 'Authorization': f'Bearer {value}', 'User-Agent': 'sm-app-token'})
    with urllib.request.urlopen(request, timeout=20) as response:
        repos = [r['full_name'] for r in json.loads(response.read()).get('repositories', [])]
    print(f'token for App {APP_ID}, installation {INSTALLATION_ID}, expires {entry.get("expires_at")}, '
          f'repositories: {", ".join(repos) or "none"}')
    return 0


def main(argv: list[str]) -> int:
    try:
        if argv[1:] == ['--check']:
            return check()
        if argv[1:]:
            print(__doc__, file=sys.stderr)
            return 2
        print(token())
        return 0
    except TokenError as error:
        print(f'sm-app-token: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
