"""Recover local attachments by failed individual test, independent of media flags."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


def test_selectors(payload):
    selectors = {}

    def visit(nodes, bundle=None):
        for node in nodes:
            if node['nodeType'] in ('Unit test bundle', 'UI test bundle'):
                bundle = node['name']
            if node['nodeType'] == 'Test Case' and bundle:
                name = node['nodeIdentifier'].removesuffix('()')
                selectors[f'{bundle}/{name}'] = node.get('nodeIdentifierURL') or node['nodeIdentifier']
            visit(node.get('children', []), bundle)

    visit((payload or {}).get('testNodes', []))
    return selectors


def export_failed_attachments(bundle, records, payload, output):
    """Exports have a 60-second per-test and 180-second total budget, with distinct directories.

    Do not use --only-failures or hasMediaAttachments: a failed XCTest can have a
    recording and hierarchy with every isAssociatedWithFailure flag false (#706).
    Export errors are evidence warnings; they cannot change an assertion's verdict.
    """
    selectors = test_selectors(payload)
    recovered = []
    deadline = time.monotonic() + 180
    for test, record in sorted(records.items()):
        if record['status'] != 'failed':
            continue
        selector = selectors.get(test, test.split('/', 1)[-1] + '()')
        slug = re.sub(r'[^A-Za-z0-9_-]', '-', test)[:64]
        directory = Path(output).resolve() / (slug + '-' + hashlib.sha256(test.encode()).hexdigest()[:12])
        entry = {'test': test, 'selector': selector, 'files': []}
        recovered.append(entry)
        try:
            directory.mkdir(parents=True, exist_ok=False)
            with (directory / 'export.log').open('w') as log:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    log.write('Attachment export total budget exhausted; test evidence not exported.\n')
                    raise TimeoutError('Attachment export total budget exhausted')
                subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(bundle),
                                '--test-id', selector, '--output-path', str(directory)],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=min(60, remaining))
            manifest = directory / 'manifest.json'
            entries = json.loads(manifest.read_text())
            entry['manifest'] = str(manifest)
            if not isinstance(entries, list):
                raise ValueError('Attachment manifest is not a list of tests')
            for group in entries:
                if not isinstance(group, dict) or not isinstance(group.get('attachments'), list):
                    raise ValueError('Attachment manifest has no attachment list')
                if (group.get('testIdentifierURL') != selector
                        and group.get('testIdentifier') != selector):
                    raise ValueError('Attachment manifest names a different test')
                for attachment in group['attachments']:
                    if not isinstance(attachment, dict) or not isinstance(attachment.get('exportedFileName'), str):
                        raise ValueError('Attachment manifest has no exported filename')
                    file = directory / attachment['exportedFileName']
                    if file.resolve().parent != directory or not file.is_file():
                        raise ValueError('Attachment file is missing or outside its test directory')
                    entry['files'].append(str(file))
            if not entry['files']:
                raise ValueError('Export returned no attachments; absence of retained media is not established')
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
            entry['error'] = f'{type(error).__name__}: {error}'
            entry['export_log'] = str(directory / 'export.log')
    return recovered


REPORT_CHARACTER_BUDGET = 8192
REPORT_FILES_PER_TEST = 10


def report_lines(attachments):
    """Bound the comment contribution; full files/warnings remain in verification manifests."""
    lines = []
    used = shown_tests = 0
    # Reserve room for omission counts even when a test's name/path or warning is very long.
    limit = REPORT_CHARACTER_BUDGET - 1024

    def append(block):
        nonlocal used
        size = sum(len(line) + 1 for line in block)
        if used + size > limit:
            return False
        lines.extend(block)
        used += size
        return True

    def priority(path):
        suffix = Path(path).suffix.lower()
        return (0 if suffix in ('.mp4', '.mov') else
                1 if suffix in ('.png', '.jpg', '.jpeg') else
                2 if suffix == '.txt' else 3)

    for entry in attachments:
        if entry.get('audio'):  # an audio window's verdict (#1790, lane_audio_window.py)
            audio = entry['audio']
            block = [f"Audio check for `{entry['test']}`: {audio.get('summary') or audio.get('verdict')}"[:1200], '']
        else:
            block = [f"Attachments for `{entry['test']}`: {len(entry['files'])} files.", '']
        if entry.get('manifest'):
            block.append(f"- [Attachment manifest](<{entry['manifest']}>)")
        if entry.get('error'):
            warning = entry['error'][:300]
            if len(entry['error']) > 300:
                warning += '… (full warning in the verification manifest)'
            block.append(f"- Export warning: {warning} (log: `{entry['export_log']}`)")
        # Keep a manifest and any warning together; do not emit a partial Markdown link.
        if used + sum(len(line) + 1 for line in block) + 200 > limit:
            break
        append(block)
        shown_tests += 1
        shown_files = 0
        for path in sorted(entry['files'], key=priority)[:REPORT_FILES_PER_TEST]:
            line = f'- [{Path(path).name}](<{path}>)'
            # Leave room for the per-test omission notice and the next blank line.
            if used + len(line) + 201 > limit:
                continue
            append([line])
            shown_files += 1
        omitted = len(entry['files']) - shown_files
        if omitted:
            append([f'- {omitted} more file links omitted; see the attachment manifest for all files.'])
        append([''])
    omitted_tests = len(attachments) - shown_tests
    if omitted_tests:
        warnings = sum(bool(entry.get('error')) for entry in attachments)
        lines.extend([f'Attachment summaries omitted for {omitted_tests} of {len(attachments)} tests '
                      f'to keep the report bounded; {warnings} export warning records in total.',
                      'Full attachment manifests, files and warnings remain in the verification '
                      'manifest.json files under the evidence directory on the Mac.', ''])
    return lines
