# B1 onboard research

`build_catalog.py` builds the first-run drawer's catalog (seam I2) from Apple's public per-genre top-podcast charts:

1. For each of 12 subjects, fetch the US top-40 chart for that Apple genre (`itunes.apple.com/us/rss/toppodcasts/...genre=<id>/json`).
2. Resolve each show's RSS feed and 600px artwork with iTunes Lookup (batches of 100).
3. Fetch every candidate feed once and keep only those that answer 200 with RSS/Atom. Plain-http feeds are tried over https, because App Transport Security blocks http.
4. Keep the top 16 unique shows per subject. A show charting in several subjects belongs to the first one in `SUBJECTS` order and lists the others as secondary subjects.
5. Write `Site/onboarding/catalog/v1/catalog.json` and its `manifest.json` (byte count and SHA-256), plus `last-build-report.json` (drops and shows with no public feed).

Every raw response is recorded under `recorded/<date>/`. `--replay recorded/<date>` rebuilds the same catalog byte for byte without network access.

```bash
.venv/bin/python research/B1/build_catalog.py                              # live
.venv/bin/python research/B1/build_catalog.py --replay recorded/2026-09-28 # offline
.venv/bin/python scripts/validate-contracts.py                             # schema + checksum checks
```

To publish a new catalog, bump `--content-version` so apps holding the old one take the new one.
