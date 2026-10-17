#!/usr/bin/env python3
"""Render, install, replace or remove the Mac launchd jobs of this repository (#1843).

Every live job's plist in the repository holds `@HOME@` where the owner's home folder used to be, so the same file
works on any Mac and moving a job to another repository is a file move. This script fills the placeholders in and
hands the result to launchd. It changes nothing unless you pass --install or --remove.

    ops/install-launchd.py --list
    ops/install-launchd.py --print disk-relief          # the rendered plist, to stdout (all jobs with "all")
    ops/install-launchd.py --install disk-relief        # write ~/Library/LaunchAgents/<label>.plist, bootout, bootstrap
    ops/install-launchd.py --remove disk-relief         # bootout and delete that file

Placeholders: `@HOME@` is `$HOME` (or --home). `@SM_REPO@` is $SM_REPO (or --repo) and is an error when it is used
without a value; no job uses it yet. Any other `@NAME@` left in a template is an error, so a typo fails here rather than
inside launchd. The rendered text is the template with only those substitutions (XML-escaped), so comments and layout
stay as written. A job is named by its label without the `com.spokenmargins.` prefix.

The retired Codex worker and release-cut plists are not templates and are not handled here.
"""
import argparse
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'com.spokenmargins.'
PLACEHOLDER = re.compile(r'@([A-Z][A-Z0-9_]*)@')
# Live jobs whose plist stays under scripts/ because scripts/lane-runner.py and a test read that path; the file is
# still a template (it holds @HOME@). Every other job is ops/**/<label>.plist.template.
SCRIPTS_JOBS = ('scripts/com.spokenmargins.daily-phone-plan.plist', 'scripts/com.spokenmargins.phone-build.plist')


class TemplateError(Exception):
    pass


def jobs(root=ROOT):
    """{job name: template path} for every live job."""
    found = {}
    for path in sorted((root / 'ops').rglob('*.plist.template')):
        found[path.name.removesuffix('.plist.template').removeprefix(PREFIX)] = path
    for relative in SCRIPTS_JOBS:
        path = root / relative
        if path.is_file():
            found[path.name.removesuffix('.plist').removeprefix(PREFIX)] = path
    return found


def label_of(path):
    return path.name.removesuffix('.template').removesuffix('.plist')


def render(text, values):
    """The template with each @NAME@ replaced by values[NAME] (XML-escaped); unknown or empty ones are errors."""
    def fill(match):
        name = match.group(1)
        if not values.get(name):
            raise TemplateError(f'the template uses @{name}@ and no value was given for it')
        return escape(values[name])
    out = PLACEHOLDER.sub(fill, text)
    try:
        plistlib.loads(out.encode())  # it must still be a plist
    except (ExpatError, plistlib.InvalidFileException, ValueError) as error:
        raise TemplateError(f'the rendered text is not a valid plist: {error}') from error
    return out


def values_from(args, env):
    home = args.home or env.get('HOME', '')
    if not home or not os.path.isabs(home):
        raise TemplateError('HOME is unset or not an absolute path; pass --home /path/to/home')
    return {'HOME': home.rstrip('/') or '/', 'SM_REPO': args.repo or env.get('SM_REPO', '')}


def launchctl(*arguments, run=subprocess.run):
    return run(['launchctl', *arguments], capture_output=True, text=True)


def install(name, path, values, agents, uid, run=subprocess.run):
    text = render(path.read_text(), values)
    label = label_of(path)
    target = agents / f'{label}.plist'
    agents.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    launchctl('bootout', f'gui/{uid}/{label}', run=run)  # not loaded yet is fine
    done = launchctl('bootstrap', f'gui/{uid}', str(target), run=run)
    if done.returncode:
        raise TemplateError(f'launchctl bootstrap {label} failed: {(done.stderr or done.stdout).strip()}')
    return target


def remove(name, path, agents, uid, run=subprocess.run):
    label = label_of(path)
    launchctl('bootout', f'gui/{uid}/{label}', run=run)
    target = agents / f'{label}.plist'
    target.unlink(missing_ok=True)
    return target


def main(argv=None, env=None, root=ROOT, run=subprocess.run):
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--list', action='store_true')
    action.add_argument('--print', dest='print_job', metavar='JOB')
    action.add_argument('--install', metavar='JOB')
    action.add_argument('--remove', metavar='JOB')
    parser.add_argument('--home')
    parser.add_argument('--repo')
    parser.add_argument('--agents-dir', help='where plists are installed (default ~/Library/LaunchAgents)')
    args = parser.parse_args(argv)
    available = jobs(root)
    try:
        if args.list:
            for name, path in available.items():
                print(f'{name}\t{path.relative_to(root)}')
            return 0
        chosen = args.print_job or args.install or args.remove
        if chosen != 'all' and chosen not in available:
            raise TemplateError(f'no job named {chosen!r}; --list shows them')
        if chosen == 'all' and not args.print_job:
            raise TemplateError('"all" works with --print only; install or remove one job at a time')
        values = values_from(args, env)
        agents = Path(args.agents_dir) if args.agents_dir else Path(values['HOME']) / 'Library/LaunchAgents'
        if args.print_job:
            for name in (available if chosen == 'all' else [chosen]):
                print(render(available[name].read_text(), values), end='')
        elif args.install:
            print(f'installed {install(chosen, available[chosen], values, agents, os.getuid(), run)}')
        else:
            print(f'removed {remove(chosen, available[chosen], agents, os.getuid(), run)}')
    except TemplateError as error:
        print(f'install-launchd: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
