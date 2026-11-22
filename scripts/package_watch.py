#!/usr/bin/env python3
"""Weekly check of every Swift package the app builds from, against its upstream (#2048, after #4512).

On 2026-11-17 Microsoft's onnxruntime-swift-package-manager repository went 404 and every fresh Mac build failed
for a day. #4568 builds it from a copy in the Spoken-Margins organization; a copy is only safe if we notice when the
original changes. For every package pinned in a Package.resolved, this reports:

  gone       the source we build from does not answer `git ls-remote`
  upstream-gone  the upstream of a copy we build from does not answer (the copy is now the only source)
  moved      GitHub answers for the upstream under another owner/name (a rename or transfer)
  newer      the upstream has a release tag newer than the pinned version, or a branch pin's branch moved on
  advisory   GitHub's advisory database lists a Swift advisory whose affected range covers the pinned version
  advisory-other  an advisory exists for the package but not for the pinned version (listed, not flagged)
  binary-gone  a binaryTarget URL in the pinned revision's Package.swift does not download its first byte over
             verified TLS, so a resolve with a cold cache fails (#4913: download.onnxruntime.ai's certificate broke)

    scripts/package_watch.py                      print the report; exit 1 if anything is flagged
    scripts/package_watch.py --json FILE          also write the findings as JSON
    scripts/package_watch.py --issue              file the report on the one open "Package watch" issue
                                                  (needs GITHUB_TOKEN and GITHUB_REPOSITORY; comments only when the
                                                  findings changed since the last report on that issue)

Copies and their upstreams are listed in docs/legal/package-upstreams.json. A package not listed there is its own
upstream. The same file's "accepted" table records a known state with a reason, so the weekly report stops
re-opening it (#4579): `"upstream-gone": "<why>"` for a copy whose upstream is gone, and
`"newer": {"through": "<tag>", "why": "<why>"}` for a pin kept on purpose, which flags again when a tag newer than
`through` appears. A source that is gone, a moved repository and an advisory can never be accepted. An accepted
finding is still listed, as `accepted-<kind>`, with its reason. A binary target that does not download can't be
accepted either. Standard library only, plus `git` on PATH.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVED = (
    'Packages/SessionKit/Package.resolved',
    'Packages/SessionKitTools/Package.resolved',
    'SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
)
UPSTREAMS = 'docs/legal/package-upstreams.json'
API = 'https://api.github.com'
TITLE = 'Package watch: an upstream Swift package changed'
MARKER = re.compile(r'<!-- package-watch: (\S+) -->')
FLAGGED = ('gone', 'upstream-gone', 'moved', 'newer', 'advisory', 'binary-gone')
NEWER_TAG = re.compile(r'^upstream tag (\S+) is newer than the pinned ')  # the text findings_for writes for a tag pin
SEMVER = re.compile(r'^v?(\d+)\.(\d+)(?:\.(\d+))?$')
# The url: argument of one binaryTarget(...) call; the body may hold parenthesised text but never crosses the call's
# closing parenthesis, so a path-based binaryTarget doesn't borrow the next target's url.
BINARY_URL = re.compile(r'\bbinaryTarget\s*\((?:[^()]|\([^()]*\))*?\burl:\s*"([^"]+)"')


# ---------- pure helpers (tested) ----------

def version_key(text):
    match = SEMVER.match(text.strip())
    return tuple(int(part or 0) for part in match.groups()) if match else None


def github_slug(url):
    """'owner/repo' for a github.com URL, else None."""
    match = re.match(r'^https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$', url.strip())
    return f'{match.group(1)}/{match.group(2)}' if match else None


def in_range(version, spec):
    """True when `version` satisfies a GitHub advisory range such as '< 0.9.17' or '>= 1.0, < 1.2.3'.
    An unreadable range or version counts as covered, so a human looks at it."""
    key = version_key(version or '')
    if key is None:
        return True
    for clause in (part.strip() for part in spec.split(',') if part.strip()):
        match = re.match(r'^(<=|>=|<|>|=)?\s*(\S+)$', clause)
        bound = version_key(match.group(2)) if match else None
        if bound is None:
            return True
        op = match.group(1) or '='
        if not {'<': key < bound, '<=': key <= bound, '>': key > bound, '>=': key >= bound, '=': key == bound}[op]:
            return False
    return True


def collect_pins(root=ROOT, files=RESOLVED):
    """Every distinct pin across the Package.resolved files: identity -> {location, version, revision, branch, files}."""
    pins = {}
    for name in files:
        path = Path(root) / name
        if not path.exists():
            continue
        for pin in json.loads(path.read_text()).get('pins', []):
            state = pin.get('state', {})
            entry = pins.setdefault(pin['identity'], {
                'identity': pin['identity'], 'location': pin['location'], 'version': state.get('version'),
                'revision': state.get('revision'), 'branch': state.get('branch'), 'files': []})
            entry['files'].append(name)
    return pins


def binary_urls(manifest):
    """The url of every remote binaryTarget in a Package.swift's text, in order."""
    return BINARY_URL.findall(manifest)


def newest_tag(tags):
    keyed = [(version_key(tag), tag) for tag in tags if version_key(tag)]
    return max(keyed)[1] if keyed else None


def findings_for(pin, upstream, remote, advisories, repo_info, binaries=lambda pin: []):
    """The findings for one pin. `remote(url)` returns {'tags': [...], 'heads': {name: sha}} or None when the
    repository doesn't answer; `advisories(slug)` returns GitHub advisory dicts; `repo_info(slug)` returns
    GitHub's full_name for that slug, or None; `binaries(pin)` returns [(url, problem)] for the pinned revision's
    binary targets, problem None when the URL downloads."""
    out = []
    source = remote(pin['location'])
    if source is None:
        out.append(('gone', f"we build from {pin['location']}, which does not answer"))
    else:
        for url, problem in binaries(pin):
            if problem:
                out.append(('binary-gone', f'binary target {url} does not download ({problem}); a cold resolve fails'))
    up = source if upstream == pin['location'] else remote(upstream)
    if up is None and upstream != pin['location']:
        out.append(('upstream-gone', f'the upstream {upstream} does not answer; our copy is now the only source'))
    slug = github_slug(upstream)
    if slug and up is not None:
        full = repo_info(slug)
        if full and full.lower() != slug.lower():
            out.append(('moved', f'GitHub answers {slug} as {full}'))
    if up is not None:
        if pin['version']:
            latest = newest_tag(up['tags'])
            if latest and version_key(latest) > version_key(pin['version']):
                out.append(('newer', f"upstream tag {latest} is newer than the pinned {pin['version']}"))
        elif pin['branch']:
            head = up['heads'].get(pin['branch'])
            if head and pin['revision'] and head != pin['revision']:
                out.append(('newer', f"upstream {pin['branch']} is at {head[:7]}, pinned {pin['revision'][:7]}"))
    if slug:
        for adv in advisories(slug):
            ranges = [v.get('vulnerable_version_range') or '' for v in adv.get('vulnerabilities', [])
                      if github_slug('https://' + (v.get('package') or {}).get('name', '')) in (slug, github_slug(pin['location']))]
            hit = any(in_range(pin['version'], spec) for spec in ranges) if ranges else True
            text = f"{adv.get('ghsa_id')} ({adv.get('severity')}): {adv.get('summary')}; affected {', '.join(ranges) or 'unknown'}"
            out.append(('advisory' if hit else 'advisory-other', text))
    return out


def apply_accepted(found, accepted):
    """Move findings the owner's team has accepted out of the flagged kinds. `accepted` is the package's entry in the
    "accepted" table. Only `upstream-gone` (a reason) and `newer` (`through` tag and a reason) can be accepted; a
    `newer` finding with a tag past `through`, or with an unreadable table entry, stays flagged."""
    out = []
    accepted = accepted if isinstance(accepted, dict) else {}
    for kind, text in found:
        entry = accepted.get(kind)
        if kind == 'upstream-gone' and isinstance(entry, str) and entry.strip():
            out.append((f'accepted-{kind}', f'{text} (accepted: {entry.strip()})'))
        elif kind == 'newer' and isinstance(entry, dict) and str(entry.get('why', '')).strip():
            tag = NEWER_TAG.match(text)
            latest = tag.group(1) if tag else None
            through = version_key(str(entry.get('through', '')))
            if latest and through and version_key(latest) <= through:
                out.append((f'accepted-{kind}', f"{text} (accepted through {entry['through']}: {str(entry['why']).strip()})"))
            else:
                out.append((kind, text))
        else:
            out.append((kind, text))
    return out


def report(results):
    """Markdown report and a signature of the flagged findings (stable across runs when nothing changed)."""
    lines, flagged = [], []
    for identity, (pin, upstream, found) in sorted(results.items()):
        rev = (pin['revision'] or '')[:7]
        pinned = pin['version'] or (f"branch {pin['branch']} @ {rev}" if pin['branch'] else f'revision {rev} (no version or branch to compare)')
        copy = f' (copy of {upstream})' if upstream != pin['location'] else ''
        lines.append(f"- **{identity}** {pinned}, from {pin['location']}{copy}")
        for kind, text in found:
            lines.append(f'  - {kind}: {text}')
            if kind in FLAGGED:
                flagged.append(f'{identity}|{kind}|{text}')
        if not found:
            lines.append('  - no change')
    sig = hashlib.sha256('\n'.join(sorted(flagged)).encode()).hexdigest()[:16] if flagged else 'clean'
    head = f'{len(flagged)} flagged finding(s) across {len(results)} package(s).'
    return head + '\n\n' + '\n'.join(lines), sig, bool(flagged)


# ---------- network ----------

def git_remote(url):
    try:
        out = subprocess.run(['git', 'ls-remote', '--tags', '--heads', url], capture_output=True, text=True,
                             timeout=60, env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'})
    except subprocess.TimeoutExpired:
        return None
    if out.returncode != 0:
        return None
    tags, heads = [], {}
    for line in out.stdout.splitlines():
        sha, ref = line.split('\t', 1)
        if ref.startswith('refs/tags/') and not ref.endswith('^{}'):
            tags.append(ref[len('refs/tags/'):])
        elif ref.startswith('refs/heads/'):
            heads[ref[len('refs/heads/'):]] = sha
    return {'tags': tags, 'heads': heads}


def api(method, path, body=None):
    token = os.environ.get('GITHUB_TOKEN', '')
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'spoken-margins-package-watch',
        **({'Authorization': f'Bearer {token}'} if token else {}),
        **({'Content-Type': 'application/json'} if data is not None else {})})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read() or b'null')


def gh_advisories(slug):
    query = urllib.parse.urlencode({'ecosystem': 'swift', 'affects': f'github.com/{slug}', 'per_page': 100})
    try:
        return api('GET', f'/advisories?{query}') or []
    except urllib.error.URLError:
        return []


def gh_repo_name(slug):
    try:
        return (api('GET', f'/repos/{slug}') or {}).get('full_name')
    except urllib.error.URLError:
        return None


def url_problem(url, tries=2, pause=10):
    """None when the first byte of `url` downloads over verified TLS, else what went wrong. A failure is retried
    once after `pause` seconds, so one dropped connection doesn't flag the week."""
    problem = None
    for attempt in range(tries):
        if attempt:
            time.sleep(pause)
        try:
            req = urllib.request.Request(url, headers={'Range': 'bytes=0-0', 'User-Agent': 'spoken-margins-package-watch'})
            with urllib.request.urlopen(req, timeout=30) as response:
                problem = None if response.status in (200, 206) else f'HTTP {response.status}'
        except urllib.error.HTTPError as err:
            problem = f'HTTP {err.code}'
        except Exception as err:  # URLError (TLS, DNS, refused), timeouts, a malformed url: report, never crash
            problem = str(getattr(err, 'reason', err)) or type(err).__name__
        if problem is None:
            return None
    return problem


def pinned_binaries(pin):
    """[(url, problem)] for the binary targets in the pinned revision's Package.swift; [] when it isn't on GitHub
    or can't be read (a source that doesn't answer is already `gone`)."""
    slug = github_slug(pin['location'])
    if not slug or not pin['revision']:
        return []
    try:
        with urllib.request.urlopen(f"https://raw.githubusercontent.com/{slug}/{pin['revision']}/Package.swift",
                                    timeout=30) as response:
            manifest = response.read().decode('utf-8', 'replace')
    except Exception:  # unreadable manifest: the `gone` check covers a source that doesn't answer
        return []
    return [(url, url_problem(url)) for url in binary_urls(manifest)]


def file_issue(text, sig, flagged, run_url):
    repo = os.environ['GITHUB_REPOSITORY']
    query = urllib.parse.urlencode({'state': 'open', 'per_page': 100, 'creator': 'github-actions[bot]'})
    issues = [i for i in api('GET', f'/repos/{repo}/issues?{query}') if i.get('title') == TITLE]
    body = f'{text}\n\nRun: {run_url}\n\n<!-- package-watch: {sig} -->'
    if not issues:
        if flagged:
            api('POST', f'/repos/{repo}/issues', {'title': TITLE, 'body': body, 'labels': ['ready', 'area: groundwork']})
            return 'opened'
        return 'nothing'
    number = issues[0]['number']
    comments = api('GET', f'/repos/{repo}/issues/{number}/comments?per_page=100')
    marks = [m.group(1) for c in [issues[0]] + comments for m in MARKER.finditer(c.get('body') or '')]
    if marks and marks[-1] == sig:
        return 'unchanged'
    api('POST', f'/repos/{repo}/issues/{number}/comments', {'body': body})
    return 'commented'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--json', metavar='FILE')
    parser.add_argument('--issue', action='store_true')
    parser.add_argument('--run-url', default='')
    args = parser.parse_args(argv)
    table = json.loads((ROOT / UPSTREAMS).read_text())
    upstreams, accepted = table.get('copies', {}), table.get('accepted', {})
    results = {}
    for identity, pin in collect_pins().items():
        upstream = upstreams.get(identity, {}).get('upstream', pin['location'])
        found = findings_for(pin, upstream, git_remote, gh_advisories, gh_repo_name, pinned_binaries)
        results[identity] = (pin, upstream, apply_accepted(found, (accepted or {}).get(identity, {})))
    text, sig, flagged = report(results)
    print(text)
    if args.json:
        Path(args.json).write_text(json.dumps({k: {'pin': v[0], 'upstream': v[1], 'findings': v[2]}
                                               for k, v in results.items()}, indent=1) + '\n')
    if args.issue:
        print('issue:', file_issue(text, sig, flagged, args.run_url))
    return 1 if flagged else 0


if __name__ == '__main__':
    sys.exit(main())
