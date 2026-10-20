# Voice catalog on the site (#1818, slice 3 of #1391)

The site publishes the signed list of voices the app can download, plus a plain page a person can read. `scripts/voice-catalog` builds and checks it. The catalog format and the app's verifier are #1816.

**Since 2026-10-19 the app asks the owner's server for nothing (#2055).** The owner: "Supertonic downloading straight from Hugging Face at pinned revisions and no server." Every file in `sources.json` has a publisher source, none is mirrored, and the app fetches no signed catalog: it uses the snapshot bundled with it (`scripts/voice-catalog app-snapshot`). The signed catalog below needs a home off the server before the app fetches it again; until then, don't `publish --apply`.

## What lives where

| Piece | Where |
| --- | --- |
| The reviewed source list: per voice, each file's pinned upstream URL, size and SHA-256, whether we mirror it, and each licence | `Contracts/voice-models/sources.json` |
| A committed copy of each licence text as it was reviewed (what a change is diffed against) | `Contracts/voice-models/licenses/` |
| The tool | `scripts/voice_catalog.py`, run as `scripts/voice-catalog` |
| The signed catalog, its manifest and the page | `Site/voices/v1/catalog.json`, `Site/voices/v1/manifest.json`, `Site/voices/index.html` (written by the tool, committed after a publish) |
| Mirror files we may redistribute (Supertonic only) | `voices/files/` on the server. They sit outside `Site/`, and the site deploy leaves that folder alone |
| The voices' files on this Mac, for the mirror upload and the tests that need the real model | `artifacts/voice-catalog/files/<voice id>/`, written by `fetch`. Supertonic's model files are in neither the repository nor the app (#1820); only its licence copies and the modification notice are, in `App/SpokenMarginsApp/Resources/Supertonic/` |
| The private signing key | the Mac's login Keychain, service "SpokenMargins voice catalog signing key". Never in the repository, `artifacts/` or a log |
| Detail from each run | `artifacts/voice-catalog/` (`check.txt`, `check.json`, `licences/`, `changed/`) |

## Commands

Each prints one line per voice and writes the detail to `artifacts/voice-catalog/`.

1. `check` requests every source and licence text. It downloads a file only the first time, when its ETag or size changes, or when it was last verified over 30 days ago (`--full` forces every file), and compares the SHA-256 with `sources.json`. A voice's `upstreamArchives` entry (Supertonic's sherpa-onnx archive, with its size and hash, kept as a spare source of the INT8 graphs) is checked too, always counting against the voice. A file the catalog carries as text (`contentFile`) is checked against its hash when `sources.json` is validated. A voice whose file or licence text no longer matches is **held**. `--mirror require` also holds a voice whose mirror copy is missing or wrong; the default only notes it.
2. `build` writes the unsigned catalog. A held voice keeps the entry from the last published catalog, or is left out if it was never published. `catalogVersion` rises only when the voices changed; an unchanged catalog keeps its version and date, so the app treats a re-sign as a refresh.
3. `keygen` (once, on the Mac) makes the key and prints the line for `VoiceCatalogTrust.production`.
4. `sign` signs the built catalog and writes the envelope and manifest.
5. `page` renders the page from the signed catalog.
6. `fetch` downloads each downloadable voice's files into `artifacts/voice-catalog/files/<voice id>/` and checks each one's size and SHA-256 against `sources.json`. A file the publisher serves alone comes from its pinned URL. Supertonic's INT8 graphs come out of the pinned sherpa-onnx archive, matched by hash because the archive names them differently, and the archive is deleted afterwards. Files the repository holds are copied from it, and files already fetched with the right bytes are left alone. `fetch supertonic-3-int8` takes one voice.
7. `publish` is a dry run. `publish --apply` uploads the mirror files and then the site through `scripts/deploy-spoken-margins-site.sh`, and afterwards checks the live manifest and every mirror file's size.

`publish` refuses unless: the last `check` is under a day old, was made against this `sources.json`, and is the one `build` used; the signed catalog, manifest and page agree with each other and with `sources.json`; a key compiled into the app signed the catalog; compared with the catalog listeners have right now, the version is not lower, no live voice is missing (withdraw it with `status: withdrawn` instead), and every held voice goes out exactly as it is live (or stays out if it never was); and every mirror file's bytes match the reviewed hash. When a mirror file isn't in the repository, `publish` runs `fetch` first, so the first dry run downloads about 145 MB. Run `git pull` before `build`, so the last published `Site/voices/` is there to keep held voices from.

## First publish (the owner's Mac, once)

1. `scripts/voice-catalog keygen`, then put the line it prints into `VoiceCatalogTrust.production` in a PR.
2. Nothing to pull: `publish` fetches Supertonic's files from the publishers (`fetch`, step 6 above).
3. `scripts/voice-catalog check && build && sign && page`, then `publish` as a dry run.
4. Run `publish --apply` only after #1819 ships: the page describes the download flow in the app. Then commit `Site/voices/`.
5. Install the weekly check: `ops/voice-catalog/deploy.sh <ssh-host> --dry-run`, then `--enable`.

## The weekly check

A systemd timer on the VPS (the Mac does not have to be awake) runs `check --mirror require --file-issues` every Sunday. It needs only Python 3 and the committed source list. When a voice is held it opens one issue per kind of change and skips any title that is already open:

- **Voice licence changed: `<voice>` / `<licence>`**, with the old and new text as a diff. A thread reads it. It goes to the owner only if the new terms add use restrictions or forbid how we distribute the files.
- **Voice source problem: `<voice>`**, for a file that moved, vanished or changed in place.

The token that files them stays on the host in `/etc/sm-voice-catalog/github-token`; the deploy script never copies or prints it. The VPS keeps `seen.json` (each URL's ETag and verified hash) in `/var/lib/sm-voice-catalog`, so a normal week is a few dozen small requests.

## What it does not do

- It does not watch prose that is not a licence file. The Pocket TTS prohibited-use summary comes from Kyutai's model page; if that page changes, nobody is told. Re-read the page whenever `sources.json` moves to a new revision.
- It never deletes a mirror file from the server. Removing one (a withdrawn voice, or a licence that stops allowing redistribution) is a manual step on the host.
- A single failed request is retried once; two in a row hold the voice and open a "source problem" issue.

## Privacy

The app requests each file from its publisher (Hugging Face, GitHub, apache.org), and today no catalog. When it fetched `/voices/v1/catalog.json`, it was a plain GET: no identifier, cookie or query string, the same bytes for every listener. `docs/legal/privacy-policy-draft.md` row 18 describes it. The weekly check sends nothing about listeners; it is our server asking publishers for public files.

## Tests

```sh
python3 -m unittest scripts/tests/test_voice_catalog.py
```

The `check` tests run against a real HTTP server on the same machine whose files they change, so the hashing, the ETag shortcut and the hold-back are exercised end to end.
