# I4 engagement log — DRAFT (superseded)

> **Superseded by the published I4:** [`Contracts/schemas/i4-engagement.schema.json`](../../Contracts/schemas/i4-engagement.schema.json)
> with the fixture `Contracts/fixtures/listening-signals/i4-engagement-sample.jsonl`, which is exactly
> what the app's recorder writes (#483). `evaluate.py` reads both. What changed from this draft:
>
> - `schema_version` is `i4-engagement.1`.
> - `export` rows also carry `packet_id`, so a later `packet_import` of the same packet has `from_other: false`.
> - `listened.at` is when the interval started. Intervals close on pause, item switch, a gap over 5 s, or after 5 minutes.
> - Only items from a followed source are logged. An item imported from a feed entry keeps the entry's id; any other item of that source is `library-<Library item id>`.
> - `categories` is always present and empty until I2 assigns categories; `content_kind` is derived from the subscription kind until then.

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
