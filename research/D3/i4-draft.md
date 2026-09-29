# I4 engagement log — DRAFT

> **DRAFT only. D3 M1 finalizes and publishes I4.** This research format is an
> input contract for the offline M2 experiment, not an app/database contract.
> Field names and event boundaries may change when the recorder is built.

The owner's export is UTF-8 JSON Lines: one complete JSON object per line,
ordered by `at` (readers must not depend on that order). All timestamps are UTC
RFC 3339 strings. The append-only export contains no transcript, Margin text,
audio, private feed URL, or packet payload. Stable opaque IDs permit grouping.

Every row has:

| field | type | meaning |
|---|---|---|
| `schema_version` | string | `i4-engagement.draft-1` |
| `event` | string | event name below |
| `at` | string | when the action occurred |
| `source` | object | `id`, display `title`, I2 `subscription_kind` (`podcast_feed`, `article_feed`, `website`, or `bridged_site`), I2 `content_kind` (`podcast`, `article`, `newsletter`, `paper`, `news`, `video`, or an opaque future value), and `categories` (strings) |
| `item` | object or null | opaque `id`, display `title`, `published_at`, and `duration_seconds` (null when not meaningful/known) |

Event-specific fields are:

| event | additional fields | meaning |
|---|---|---|
| `item_published` | none | makes an item eligible for the inbox replay |
| `listened` | `seconds` (positive number) | one coalesced listening interval; totals give listened time per item, while grouping through `source.id` gives time per source |
| `margin` | `margin_kind` (`spoken` or `written`), `length` (nonnegative integer), `length_unit` (`seconds` for spoken, `characters` for written) | a Margin recorded on the item |
| `share` | none | item shared through the system share flow |
| `export` | `margin_count` (nonnegative integer) | `.spokenmargins` packet exported for the item |
| `packet_import` | `packet_id`, `from_other` (boolean), `margin_count` | packet imported; source/item describe the receiving copy when matched, otherwise item may be null |
| `dismiss` | none | item dismissed from Following |
| `finish` | none | item marked/observed finished |

Example lines (wrapped here only; an actual export uses one line each):

```json
{"schema_version":"i4-engagement.draft-1","event":"item_published","at":"2026-09-01T08:00:00Z","source":{"id":"src-07","title":"Systems Weekly","subscription_kind":"article_feed","content_kind":"newsletter","categories":["technology"]},"item":{"id":"src-07-item-12","title":"Queues and clocks","published_at":"2026-09-01T08:00:00Z","duration_seconds":900}}
{"schema_version":"i4-engagement.draft-1","event":"margin","at":"2026-09-04T19:12:00Z","source":{"id":"src-07","title":"Systems Weekly","subscription_kind":"article_feed","content_kind":"newsletter","categories":["technology"]},"item":{"id":"src-07-item-12","title":"Queues and clocks","published_at":"2026-09-01T08:00:00Z","duration_seconds":900},"margin_kind":"written","length":184,"length_unit":"characters"}
```

Export validation should reject missing common/event fields, invalid timestamps,
negative counts, and item events without an item. Unknown fields and future event
names should be preserved or skipped by a tolerant production importer; this
research evaluator deliberately rejects them so experiment mistakes are visible.
