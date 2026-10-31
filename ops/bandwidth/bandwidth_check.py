#!/usr/bin/env python3
"""Daily VPS transfer check: ping Healthchecks every day, and ping its /fail URL once
this month's transfer passes half the plan's allowance, so the owner gets an email.

A daily ping also proves the check itself still runs: if it stops, Healthchecks
emails after its 1-day period plus grace. The ping URL lives on the host in
/etc/sm-bandwidth/ping-url, never in this public repository.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import subprocess
import urllib.request

CONFIG = pathlib.Path('/etc/sm-bandwidth/ping-url')
INTERFACE = 'eth0'
ALLOWANCE_BYTES = 8 * 10**12        # Hostinger KVM plan: 8 TB a month
ALERT_FRACTION = 0.5                # research/B4/DESIGN.md: alert at 50%


def month_bytes(vnstat_json: dict, today: dt.date) -> int:
    """This calendar month's rx + tx for INTERFACE; 0 when vnstat has no row yet."""
    for iface in vnstat_json.get('interfaces', []):
        if iface.get('name') != INTERFACE:
            continue
        for row in iface.get('traffic', {}).get('month', []):
            d = row.get('date', {})
            if (d.get('year'), d.get('month')) == (today.year, today.month):
                return int(row.get('rx', 0)) + int(row.get('tx', 0))
    return 0


def verdict(used: int) -> tuple[bool, str]:
    over = used >= ALERT_FRACTION * ALLOWANCE_BYTES
    pct = 100 * used / ALLOWANCE_BYTES
    text = f'{INTERFACE} this month: {used / 10**12:.3f} TB of {ALLOWANCE_BYTES / 10**12:.0f} TB ({pct:.1f}%)'
    return over, text + (f'; past the {ALERT_FRACTION:.0%} alert line' if over else '')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true', help='print the verdict, ping nothing')
    args = ap.parse_args()
    raw = subprocess.run(['vnstat', '--json', 'm', '-i', INTERFACE],
                         check=True, capture_output=True, text=True).stdout
    over, text = verdict(month_bytes(json.loads(raw), dt.date.today()))
    print(text)
    if args.dry_run:
        return 0
    url = CONFIG.read_text().strip() + ('/fail' if over else '')
    req = urllib.request.Request(url, method='POST', data=text.encode(),
                                 headers={'User-Agent': 'sm-bandwidth'})
    urllib.request.urlopen(req, timeout=30).read()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
