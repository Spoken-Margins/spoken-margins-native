# Spoken Margins formats

`Contracts/` is the one home of the formats Spoken Margins writes for other people and other tools: packets of shared Margins, the Listening Maps inside them, session exports and Listening Editions. The app bundles `Contracts/fixtures` and `Contracts/traces` from this folder (see `project.yml`); there is no second copy. The schemas, examples and tools here are not bundled.

| Folder | What it holds |
| --- | --- |
| `schemas/` | JSON Schemas (draft 2020-12). The portable ones are listed below; the rest describe app-internal fixtures. |
| `examples/packets/` | Example `.spokenmargins` packets, valid and invalid, and `expectations.json`: what the shipped readers did with each. |
| `tools/spoken_margins_format.py` | The reference reader and validator. Python 3.10+, standard library only for packets. |
| `fixtures/`, `traces/` | Test fixtures and behaviour traces, bundled into the app. |
| `docs/` | Product and architecture notes. |

## Portable formats

| Format | Version string | Schema |
| --- | --- | --- |
| Packet manifest (`manifest.json` in a `.spokenmargins` zip) | `spoken-margins.package.v1` | `spoken-margins-package.schema.json` |
| Commentary layer (the Margins, inside a packet) | `spoken-margins.commentary-layer.v1` | `shared-commentary-layer.schema.json` |
| Listening Map proposal (inside a packet) | `spoken-margins.listening-map-proposal.v2` | `portable-listening-map-proposal.schema.json` |
| Margin conversation (reply links, inside a packet) | `spoken-margins.margin-conversation.v1` | `margin-conversation.schema.json` |
| Embedded text item (inside a packet) | `spoken-margins.embedded-text-item.v1` | none yet; rules in the reader |
| Episode fingerprint spine, transcript phrase sketch (inside a packet) | `spoken-margins.edition-fingerprint-spine.v1`, `spoken-margins.transcript-phrase-sketch.v1` | none yet; rules in the Swift reader |
| Session export (JSON, with a Markdown twin) | `spoken-margins.export.v1` | `session-export.schema.json` |
| Listening Edition | `spoken-margins.listening-edition.v1` | `listening-edition.schema.json` |

`scripts/validate-contracts.py`, which runs in every `--plan fast`, fails when any of these drift apart: the version each Swift type writes, the schema's `schemaVersion` constant, the reference reader's constants, and the manifest keys that the app's reader and Build 29's frozen reader (`Packages/SessionKit/Tests/ShippedReader`) accept.

## Checking a file

```zsh
python3 Contracts/tools/spoken_margins_format.py check shared.spokenmargins export.json
```

Each problem prints as `file: error [code] where: message`; a valid file prints `file: valid <format>`. `--json` prints the findings as JSON, `--strict` also fails on warnings, and `inspect <packet>` prints the item and each Margin's place and text. The exit code is 0 when every file is valid, 1 when one is not, and 2 for a bad command line. JSON documents are matched to their schema by `schemaVersion` (or `--schema <file name>`) and need the `jsonschema` package.

A packet is a zip holding `manifest.json`, `preview.md`, `artifacts/<name>.json` and, optionally, `assets/audio/<name>.m4a` and `assets/evidence/<name>.shazamsignature`. The reader checks it the way the app does, in the same order, and stops at the first refusal:

1. The archive: no other paths, no duplicates, size limits (100 MB in all, 1 MB manifest, 5 MB per artifact, 20 MB per voice), and no entry that unpacks to more than 100 times its packed size.
2. The manifest: the version, no unknown keys, the field types, unique ids and paths, and every declared file present with its `byteCount` and `sha256`.
3. The artifacts: each known kind at its one version. An unknown kind or version is skipped when `required` is false and refused when it is true.
4. The rules across fields: the item's links are https without a user name, the redactions, the item transport, the embedded text's edition hashes, the Margins' bounds, the limits inside fingerprint spines and phrase sketches (the first failed rule is named, as the app names a spine's; it names a phrase sketch's too, which the app does not), and reply links that name a Margin in the packet.
5. `contentDigest`: SHA-256 over the manifest without `contentDigest` (sorted keys, no spaces, slashes unescaped, absent optionals left out, `createdAt` with milliseconds), then, for `preview.md` and each declared file in path order, `path NUL sha256(bytes) NUL byte-count NUL`.
6. `preview.md` must be exactly the text the writer derives from the packet.

`write_packet` in the same file writes a packet the shipped readers accept. `article-embedded-text.spokenmargins` was written that way, and both Swift readers imported it.

### What the reference reader does not check

The Swift reader in `Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift` stays the authority. This reader leaves to it:

- decoding voice audio (it only looks for an MPEG-4 `ftyp` box) and parsing acoustic signatures;
- the Listening Map quotation rule (`PortableListeningMapContract`) when it turns on non-ASCII text, where Python splits words differently (it warns `not-checked` instead; a text under ten words, or a scene with no source of ten words, needs no guess);
- URL syntax beyond the scheme, host and user name (Foundation's `URLComponents`), and whether `ISO8601DateFormatter` takes a zone written without a colon (this reader does; digits and field ranges are checked);
- hexadecimal digits written in fullwidth forms (Swift's `isHexDigit` takes them in a digest or a phrase-sketch hash; this reader takes ASCII only, and no writer emits them);
- the normalized-content hash of non-ASCII text, which depends on Foundation's case and diacritic folding (it warns instead).

It counts characters as extended grapheme clusters (UAX #29, with the Indic conjunct rule of Unicode 15.1) from its own property ranges, since Python has no segmenter; the emoji ranges are the common ones, so a rare symbol may count differently. That matters only for the limits and the character count in the preview.

How it decides that a field decodes: `SWIFT_TYPES` in the reader lists the stored properties of every Swift type a shipped reader decodes, with the Swift type of each, and one function (`decode_problem`) reads that table for the manifest and every artifact. `scripts/validate-contracts.py` compares the table with the Swift structs and enums in the app and in Build 29's frozen reader, so a field with a type the table gets wrong, or lacks, fails the fast plan. Asset ids and file names use Swift's `CharacterSet.alphanumerics` (letters, marks and numbers of any script), and an archive entry must be a regular file, as ZIPFoundation reports it: a symlink at an allowed path is refused. Ids compare by canonical equivalence, as Swift Strings do, so `café` composed and decomposed is one id; `NaN` and `Infinity` in JSON are refused, as Swift's parser does.

Listening Map proposals pass through `PortableListeningMapContract.forSharing` first, as in the Swift reader: summaries on excluded and unknown scenes are stripped, and a proposal that still breaks a scene rule is left out while its Margins import (warning `proposal-dropped`). Only a proposal that survives meets the order, bounds and summary-asset checks that refuse a packet. Build 29 has no `forSharing` step and refuses some packets that Build 30 and later import; the reader reports those as `older-reader-refuses`, so `--strict` fails them.

Build 29 stops with a fatal error importing a packet in which two fingerprint landmarks name one acoustic signature (Build 30 keeps the first, #536, and the app's writer keeps one landmark per signature); that warns `older-reader-refuses` too. Every rule of a spine and a sketch was checked against both Swift readers with `coop-packet check` on 2026-10-28 (#1856); the verdicts agreed for each rule (a spine that reads as valid was tried with a real ShazamKit signature, since this reader does not parse one).

## Compatibility policy

- **A version string names one shape.** Readers read the versions they know and refuse others; they don't guess. A change that an older reader would misread gets a new version, and the reader keeps reading the old one.
- **The manifest is closed.** Every shipped reader refuses a manifest key it doesn't list, so new manifest keys mean a new package version. New data goes in a new artifact instead.
- **New artifacts are optional unless they must not be ignored.** `required: false` artifacts are skipped by older readers; that's how packets with reply links still open in Build 29. Use `required: true`, and list the version in `requiredCapabilities`, only when a reader that skips it would show the listener something wrong.
- **Inside the commentary layer, the Listening Map proposal and the embedded text item, readers ignore fields they don't know**, so those may gain optional fields within a version. The fingerprint spine, the phrase sketch and the margin conversation are closed like the manifest. Removing or renaming a field, or changing its meaning, always needs a new version.
- **Packets a new build writes must open in the last shipped build** unless the owner accepts a break (AGENTS.md, "Keep packets compatible"). `coop-packet check` imports a packet with both the current reader and Build 29's.
- **Releases.** Until the formats are published on their own, a format release is the app build that first shipped it. Build 29 (`testflight/0.1-build-29`) and every build since read `spoken-margins.package.v1` and every artifact version above except the margin conversation, which Build 29 skips (its replies arrive as ordinary Margins). A change to these formats lands with a new row in the table above, a new example packet, and a new line in `expectations.json`.

## Source identity

A packet never carries the item itself unless the transport says so. `item` names it:

- `canonicalURL` is its public https address; `originalURL` is the address the sender opened, when different.
- A podcast episode is also named by `episodeGUID` (from the feed), `enclosureURL` (the audio file), `showTitle`, `publishedAt` and `durationMs`; `source` names the feed or site.
- `exactEditionSHA256` is the SHA-256 of the exact UTF-8 text the sender's character offsets were taken from. `normalizedContentSHA256` hashes a folded copy (lowercase, no diacritics, punctuation and space runs collapsed). It recognises a similar edition, but it is never grounds for reusing raw offsets.
- `itemTransport.kind` says how the recipient gets the item:
  - `reference`: they open `canonicalURL`;
  - `recipient_supplied`: there is no public address, and they bring their own copy;
  - `embedded_text`: the full text travels as an `embedded_text_item`, only with a `rightsBasis` (`app_authored`, or `sender_confirmed_private_rights`).

The exporter drops links that carry an access token or name a paid feed (SessionKit's `ShareableLinkPolicy`). The reader warns about such a link but doesn't refuse it, because the shipped readers don't.

Every redaction flag but `fullItemOmitted` must be true: a packet never carries the raw recording, a raw transcript, the item's audio, diagnostics, file paths, unrelated turns or private representations.

## Positions and times

- **Times** are integer milliseconds. `mediaTimeMs` counts from the start of the sender's copy of the media. Two copies of one episode can differ (dynamic ads, a re-cut), which is why time-placed Margins can carry acoustic evidence.
- **Evidence clips.** `anchorOffsetMs` on an evidence asset is the Margin's moment measured from the start of that clip; it is negative when the clip starts after the moment.
- **`roughPercent`** is a whole-number percentage (0–100) of the item's duration, a fallback when nothing finer resolves.
- **Text positions.** `startChar` and `endChar` are offsets in Swift `Character`s (grapheme clusters) into the exact edition: `startChar` is the first character and `endChar` the one after the last. They are used only when the recipient's text has the same `exactEditionSHA256`. Otherwise the reader matches `exactText` (at most 1,000 characters) with up to 500 characters of `prefix` and `suffix`.
- **Dates** are ISO-8601 with a zone, in every field the readers decode as a date (the manifest, Margins, Listening Map proposals, fingerprint spines and phrase sketches); anything else refuses the packet. The manifest's `createdAt` is written in UTC with milliseconds.

**Listening Map provenance.** Each proposal names its `generator`, and each scene its `summaryProvenance`: `publisher_supplied`, `sender_authored`, `deterministic` or `model_generated`. A recipient's app never turns a proposal on by itself.

## Content and rights

These formats describe Margins about other people's work. Redistributing a schema, the validator or a packet doesn't license the article, episode or book it points at. That stays with its publisher. Packets reference items by default and embed text only on a stated rights basis.

The examples here hold no user data, no real voices or media, no tokens and no private feeds:

- every link is on `example.com`;
- every sender is labelled "synthetic";
- the one embedded text was written for the examples;
- the one "voice" is a few bytes of text with an `.m4a` name, there to be refused.

## Updating the examples

The two `*-reference` packets were written by the app's Swift writer: `coop-packet build` (Packages/SessionKitTools/Sources/CoopPacket) with text-only Margins. The rest are derived from them:

```zsh
.venv/bin/python Contracts/tools/spoken_margins_format.py corpus Contracts/examples/packets
```

```zsh
swift build --package-path Packages/SessionKitTools --scratch-path Packages/SessionKit/.build/tools --product coop-packet
```

```zsh
Packages/SessionKit/.build/tools/debug/coop-packet check Contracts/examples/packets/<name>.spokenmargins
```

Record each `check` result in `expectations.json`; `validate-contracts.py` fails if a committed packet, a regenerated one and the recorded verdict disagree.
