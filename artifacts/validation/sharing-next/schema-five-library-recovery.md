# Schema-5 library recovery and ingestion regression

Status: `implemented` and `verified` on 2026-08-29; not `human_validated`.

Fix commit: `4d3d311` (`Restore schema five library compatibility`)

## Reported failure

When the sharing build was installed over an app library last written by a schema-5 development lane:

- the home screen incorrectly said the library was empty;
- podcast links failed from paste and the share sheet;
- browser-plugin text failed;
- manually pasted text failed; and
- each operation surfaced `persistence_failed:unsupported_schema_version:5`.

## Root cause and data assessment

The sharing lane still declared SQLite schema 4 while another active development lane had advanced the same generic records database to schema 5. `requireStore()` therefore failed before the app could load the library, and every ingestion route failed when it requested that same store.

The empty screen was a presentation error, not a successful empty-database load. Code-path inspection gives strong evidence that the on-device library was not deleted:

- the store rejects an unsupported version before record writes;
- the only automatic legacy archive/move path is restricted to schema 1;
- no reset path is called after bootstrap failure; and
- the app retained `store == nil` and rendered its ordinary empty-library panel.

Physical-device recovery is still a product-owner check; automated evidence cannot prove the contents of that specific phone without inspecting its app container.

## Fix

- The sharing lane now recognizes generic-store schema 5 and migrates schemas 1–4 forward to 5.
- Existing schema-5 records load without downgrading the metadata version.
- Unknown schema-5 record kinds remain untouched while sharing-lane records are added.
- A future unsupported schema now produces a blocking **Your library could not be opened** panel that says the attempt did not reset the library and warns against Reset Library or app deletion. It no longer claims the library is empty.

## Automated verification

- A hand-built schema-5 database containing an existing item, schema-5-only optional JSON fields, and an unknown `canonical_source` record opens successfully. Adding a new item preserves the original payload and unknown record.
- One app-model regression begins with an existing schema-5 library and then completes all reported persistence routes in the same database: pasted text, browser-plugin text URL, and share-sheet podcast URL. The original item remains visible, all four items survive reopening, and the schema remains 5.
- A schema-6 counterexample remains unchanged after rejection and produces the data-preservation message instead of the empty-library state.
- `SourceLinkImportTests`: 44 passed, 0 failed.
- `Gate5BrowserTextImportTests`: 13 passed, 0 failed.
- Focused schema-5 app-model tests: 2 passed, 0 failed.
- Focused app UI tests for the podcast Add Source form and plain-text Add and Listen path: 2 passed, 0 failed.
- SessionKit package suite: 188 passed, 1 held-out benchmark test skipped by design, 0 failed.
- Contract and surface-contract validation: passed.
- SessionKit build with tests: passed.
- Generic physical-iOS target build: passed.

The broader selected app run passed 121 of 122 tests. The remaining failure is an unrelated, repeatable PDF expectation: the runtime includes `Front Matter` as a chapter while that app test expects it to be omitted. Package-level canonical-map tests explicitly expect front matter to be preserved. No PDF code changed in this fix; this mismatch is recorded rather than silently counted as a clean full-app suite.

## Safe on-device recovery

1. Do not delete the app and do not use **Reset Library**.
2. Open the sharing worktree at `/Users/colemiller/Documents/GitHub/spoken-margins-native-sharing-next` and confirm `git rev-parse --short HEAD` is `4d3d311` or later.
3. In Xcode, select `SpokenMarginsApp`, select the same physical iPhone, and press Run. Installing the fixed executable over the same bundle identifier should retain the app container.
4. Confirm the prior library appears before attempting any new import.
5. Test one pasted text item, one browser-plugin text item, and one podcast link. Then test the podcast share sheet.
6. If the prior library does not return, stop. Before reinstalling or resetting, use Xcode Devices and Simulators to download the app container so the SQLite database and WAL can be examined and recovered.

The recovery is `human_validated` only after the product owner sees the prior library on the phone and confirms at least one of each reported import type.
