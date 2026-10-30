# Compatibility

Two kinds of file outlive any one build of the app: the **Library** (a SQLite database on the phone) and the **packets** people share (`.spokenmargins` files). The project's rule is that both stay readable across builds. This page states the rules, then says where the code and tests hold them today and where they are still a policy rather than something the code enforces. For how the pieces fit together, see the [architecture overview](architecture.md).

## The rules

1. **A packet written by a newer build opens in the last released build.** Someone on an older version can still import a Margin you share and hear it at the right place. A change that would break this needs an explicit decision by the maintainers, and a test that imports the new packet into the frozen reader (below). The frozen reader is the packet reader of Build 29 today; Builds 32 and 34 are checked from their release tags (below).
2. **The previous build can still open the database a newer build wrote.** A new build adds to the Library; it does not rewrite it in a way an older build cannot read. As a policy, a full database migration should happen only after the app tells the listener and they tap to migrate. No such prompt exists yet: the store upgrades older libraries when it opens them (see below), which is why a new schema version is a decision, not a routine change.
3. **A packet asks for a new capability only when it uses the feature.** The manifest lists `requiredCapabilities`. A packet with no embedded text, for example, does not require the embedded-text capability, so builds that predate it still read it.
4. **Nothing is "just additive" in a packet.** The released reader rejects keys it does not know in the manifest, items, sources, artifacts and assets, and the schemas set `additionalProperties: false`. Adding a field is a format change, not a free extension.
5. **A listener's Library and recordings are never reset, reseeded or deleted by an update.**

## Packets

- A packet is a zip file (extension `.spokenmargins`) with a manifest, the shared Margins and, when the sender includes it, the item's text or audio. It is written and read by `Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift`. The reader checks the manifest's schema version, its size and compression limits, a content digest, and each required capability against the list it supports.
- The schema is `Contracts/schemas/spoken-margins-package.schema.json`; example packets are in `Contracts/fixtures/interjection-packages/`.
- `Packages/SessionKit/Tests/ShippedReader/` is a frozen copy of the packet reader from a released build (`scripts/freeze-shipped-reader.sh` makes it). Tests import freshly written packets through it, so a change that the released reader would refuse fails a test before it ships. The Mac tool `coop-packet` (`Packages/SessionKitTools/Sources/CoopPacket/`) builds sample packets and runs the same check.
- `scripts/check-build29-database.sh` covers the later shipped builds. It keeps every packet the exporter tests wrote that Build 29's frozen reader accepted, then builds each of Build 29, 32 and 34's own SessionKit and SessionKitSharing from its `testflight/0.1-build-N` tag and imports them all, checking every Margin arrives. In the same run it opens a database written by the current code with each build's persistence code. The `shipped-build-compat` workflow runs it on pull requests that touch storage, sharing or a stored type; `--plan fast` does not.

## The Library

- The Library is one SQLite file written through `Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift`. Records are stored as JSON rows (`records`: kind, id, payload) beside a `metadata` table that holds the schema version (`currentSchemaVersion`, 5 at the time of writing). The store opens any version from 1 to the current one, upgrades a version 1 to 4 library in place when it opens it, and refuses an unknown version with an error rather than guessing. Rows it cannot decode are set aside in a `quarantined_records` table rather than deleted.
- Opening, reading and saving a version 5 library do not rewrite rows they did not change. A build that decoded and re-encoded every row on launch would drop fields an older or newer build wrote. (The in-place upgrade of version 1 to 4 libraries does rewrite some rows.)
- The tests that hold this: `PriorBuildPersistenceTests` (libraries written by earlier builds open and keep their sessions), `Build29PersistedShapeTests` (what the current build writes stays decodable by Build 29) and `SQLiteOpenLeavesRecordsAloneTests` (opening a version 5 library leaves every column of every row alone), all in `Packages/SessionKit/Tests/SessionKitCoreTests/`.
- The table layout and migration rules are in [`docs/storage-and-migrations.md`](../storage-and-migrations.md). That document sets the intended rules: migrations are numbered and append-only, each schema change carries a fixture migration test, and no migration may drop a listener's audio or Margin anchors. The code does not yet follow the numbered layout; upgrades are conditional steps in `SQLiteSessionStore.swift`. Import and export formats are versioned separately from database migrations.

## Formats in Contracts

`Contracts/` holds the JSON schemas and fixtures for these formats (see the [architecture overview](architecture.md#contracts)), and `scripts/validate-contracts.py` checks that each fixture matches its schema. `Contracts/docs/sessionkit-contract.md` describes the behaviour contract in more detail. Change a schema, its fixtures and the code that reads them together.
