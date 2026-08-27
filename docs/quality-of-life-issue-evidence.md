# Non-Watch Quality-of-Life Issue Evidence

This matrix maps the authorized release scope to implementation and automated
evidence. `Verified` means repository checks support the claim; it does not mean
the product owner has `human_validated` the flow.

| Issue | Implemented surface | Primary evidence | State |
| --- | --- | --- | --- |
| #34 | Kokoro/MLX runtime removal, James migration, canonical Supertonic identity | Runtime/configuration reference scan; `QualityOfLifeModelsTests` | Verified |
| #64 | Durable manifests, committed chunks, resumable coordinator, complete M4A adoption | `PreparedAudioCoordinatorTests`; manifest fixtures and schema validation | Verified |
| #72 | Unified 5 GB ledger, reservations, protections, adoption, deterministic eviction | `OfflineStorageLedgerTests`; protected-overage fixture | Verified |
| #73 | Injected chapter-aware preparation horizon and safety gating | `QualityOfLifeModelsTests`; coordinator scheduling tests | Verified |
| #61 | Bounded EPUB ingestion with authored navigation and source locators | `EPUBSafetyTests`; nested EPUB contract fixture | Verified |
| #79 | App-owned local-audio import, AVFoundation validation, chapters, duplicate fingerprint | App build and focused app-model tests | Verified |
| #74 | Opt-in charging-only durable background preparation using the foreground coordinator | App configuration/build checks; coordinator tests | Verified |
| #69 | Trusted guided-onboarding manifest, compiled routes, fallback, LKG, tombstone behavior | Onboarding fixtures and app-model tests; local checksum audit | Implemented; production deployment blocked |
| #76 | Bounded feed discovery/parsing, subscriptions, refresh, inbox, mute/unfollow | Feed parser fixtures/tests and app-model tests | Verified |
| #77 | Evidence-based, capped follow suggestions without implicit import | App-model tests and source repository records | Verified |
| #86 | Metadata search, typed filters, deterministic persisted sorting | `QualityOfLifeModelsTests` and app-model tests | Verified |
| #87 | Timed/end-of-chapter sleep modes, countdown, extension, recording deferral | `QualityOfLifeModelsTests` and app-model tests | Verified |

## Cross-cutting falsification checks

- Contract and surface validators cover every new schema and fixture family.
- SQLite concurrency coverage forces simultaneous ledger and library reads/writes
  through one connection, guarding the mutex-misuse crash found during the final
  route run.
- Storage tests compare ledger inventory and reservation behavior around writers.
- Prepared-audio tests count render calls across reconstruction and reject stale
  identities.
- Source-locator tests require monotonic source/media round trips.
- Feed and onboarding tests reject unexpected routes, hosts, redirects, sizes,
  nesting, and invalid checksums.
- Repository scans classify residual Kokoro/MLX text and require no runtime or
  generated-project matches.
- The release diff contains no changed Watch app, connectivity, or render source.

## Omission and stopping checks

Issue #75 remains excluded. Dormant Watch artifacts may be counted or protected
by the storage ledger, but no Watch runtime behavior is enabled or changed. The
release remains stopped until the production onboarding manifest and audio are
deployed and the product owner completes the physical-device checklist.
