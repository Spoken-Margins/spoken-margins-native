# Voice catalog sources (#1818)

`sources.json` is the hand-kept list behind the signed voice catalog the app downloads from `https://spokenmargins.proximitytoprogress.com/voices/v1/catalog.json`. A person edits it, in a PR, after looking at what changed. No script edits it.

Per voice it holds the pinned upstream URLs, each file's reviewed size and SHA-256, whether our mirror also serves the file, and each licence with the reviewed text in `licenses/` beside it (`textSHA256` is that file's hash). `notes` says why each choice was made; it never reaches the catalog. The format of the catalog itself is in `Contracts/schemas/voice-model-catalog.schema.json` (#1816).

## The commands

Run them as `scripts/voice-catalog <command>`. Each prints one line per voice and writes detail to `artifacts/voice-catalog/`.

| Command | What it does |
| --- | --- |
| `check` | Asks every file source and licence text what it serves now. A file whose ETag and size match the last run is trusted; anything else is downloaded into `artifacts/`, hashed and compared with the reviewed values. A moved or deleted upstream file, changed bytes, or a changed or unreachable licence text goes to `held.json`. An unpublished mirror is only a warning. Exit 1 if anything is held. `--file-issues` opens one GitHub issue per changed licence, with the old and new text diff (needs `gh`). |
| `build` | Writes `artifacts/voice-catalog/payload.json` from `sources.json`. `catalogVersion` goes up only when the voices differ from the published catalog, so rebuilding an unchanged list gives the same bytes. |
| `sign` | Signs the payload with the Ed25519 key in the Mac's login Keychain and writes `Site/voices/v1/catalog.json` (the envelope) and `manifest.json`. Refuses a lower `catalogVersion`. Checks its own signature before writing. |
| `page` | Writes `Site/voices/index.html`, the plain page, from the same payload. |
| `publish` | Dry run. It stops while `check` holds anything, while the catalog, manifest or page disagree with `sources.json`, or while a mirror file is missing or has the wrong hash. `--apply` stages the mirror files and runs `scripts/deploy-spoken-margins-site.sh`, which uploads them to `voices/files/` (never deleting there) and then the rest of `Site/`. |
| `keygen` | Once, on the Mac: makes the signing key in the login Keychain and prints its public half. |

Order for a change: edit `sources.json`, then `check`, `build`, `sign`, `page`, `publish`, and commit the `Site/voices/` files.

## What "held back" means

`check` never changes a hash. When upstream bytes or a licence text differ from what a person reviewed, `check` records it in `held.json` and `publish` refuses to run until someone has looked and updated `sources.json` (or withdrawn the voice) and `check` is clean again. A changed licence goes to the owner only if the new terms add use restrictions or forbid how we distribute the files.

## The signing key

The private key is made by `keygen`, lives only in the login Keychain (service `com.spokenmargins.voice-catalog-signing`), and is never written to the repository, `artifacts/`, a log or a command line. Its public half goes into `VoiceCatalogTrust.production` in `Packages/SessionKit/Sources/SessionKit/VoiceModelCatalogVerifier.swift`. Until it is there, every catalog fails with `unknownKey` and the app offers no downloads. Signing needs the `cryptography` package (`requirements-dev.txt`).

## Mirror

A file lists our mirror as a second source only where the licence allows redistributing it (`mirror.basis` says why). Files go to `voices/files/<mirror.directory><path>` on the VPS. The deploy script protects that folder from `rsync --delete`, because it is not part of `Site/`. A file that upstream serves exactly (Pocket TTS) is not mirrored.

## Running `check` weekly

Weekly, on a machine that doesn't need the Mac awake: a checkout of this repository, Python 3 with `jsonschema` installed, and `gh` signed in if `--file-issues` is wanted. For example, in cron on the VPS:

    17 6 * * 1  cd /srv/spoken-margins-native && git pull -q && python3 scripts/voice-catalog check --file-issues >> /var/log/voice-catalog-check.log 2>&1

`state.json` (ETags) lives in `artifacts/voice-catalog/` on that machine, so only the first run downloads everything.
