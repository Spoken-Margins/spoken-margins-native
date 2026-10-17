# B1 onboard research

`build_catalog.py` builds the first-run drawer's starter list (seam I2) from each show's own feed. Nothing comes from Apple's charts or lookup API, and no artwork URL may point at Apple's image servers (#1732).

1. `shows.json` is the list: one row per show with its feed URL, its subjects (the first is the primary one), and `"starter": true` for the shows that lead their subject's row. It is hand-picked, so edit it freely. Optional per-show fields: `id`, `kind`, `contentKind`, `author`, `summary` and `explicit` override what the feed says.
2. For each show the script reads its feed up to the first episode and takes the title, author (`itunes:author`), description, website, explicit flag (`itunes:explicit`) and artwork (`itunes:image`, else the channel `<image>`). An http feed or image is used over https, because App Transport Security blocks http.
3. Each candidate artwork URL is fetched once and kept only if it answers 200 with an image. A show with no feed answer, no title or no usable artwork is dropped and listed in `last-build-report.json`.
4. Write `Site/onboarding/catalog/v1/catalog.json` and its `manifest.json` (byte count and SHA-256), in the order of `shows.json`.

The head of every feed and every artwork check are recorded under `recorded/<date>/`. `--replay recorded/<date>` rebuilds the same catalog byte for byte without network access, and `scripts/tests/test_starter_catalog.py` checks that it does.

```bash
.venv/bin/python research/B1/build_catalog.py --content-version 4                    # live
.venv/bin/python research/B1/build_catalog.py --content-version 3 --replay recorded/2026-10-17   # offline
.venv/bin/python scripts/validate-contracts.py                                       # schema, checksum and no-Apple checks
```

To publish a new catalog, edit `shows.json`, bump `--content-version` so apps holding the old one take the new one, delete the old `recorded/` folder (the test replays the newest) and commit the new one.
