# Keeping the comparison current

`comparison.json` is the one place Spoken Margins states facts about other products. Anything we publish that compares apps, such as an inbound page, reads from it, and every value in it carries a source, a check date and a quote. This page says what goes stale, where to look, and how often.

## Files

| Path | What it is |
| --- | --- |
| `comparison/apps/<id>.json` | One record per app. Edit these by hand. |
| `comparison/FIELDS.md` | What each field means and the allowed values. |
| `comparison.json` | Built from the app files by `build.py`. Never edit it by hand. |
| `comparison/scripts/validate.py` | Fails any claim with no URL, no check date, no quote, or an unknown value with no note. For our own row it also checks that each quote is really in the repo file at the pinned commit. |
| `comparison/scripts/recheck.py` | Fetches every cited page and lists sources whose quote no longer appears. It only tells a person where to look. |
| `comparison/scripts/build.py` | Validates, then writes `comparison.json`. |

## What changes, and how fast

| Field | Changes | Where to check first |
| --- | --- | --- |
| `price_free_tier`, `price_paid` | Often: several times a year, sometimes by region or with trials | Vendor pricing page, then the US App Store listing's in-app purchases |
| `platforms` | Rarely, but a new platform is news | App Store and Google Play listings, vendor download page |
| `ai_summaries`, `transcripts` | Often: AI features ship and get withdrawn (Pocket Casts' AI chapters were "temporarily unavailable" a few weeks after launch) | Vendor changelog or blog, help centre, App Store "What's New" |
| `export_markdown_pkm`, `hands_free_capture`, `text_notes_anchored`, `voice_notes_anchored` | Occasionally, and these are the fields our positioning rests on | Help centre, changelog, integrations page, the vendor's forum announcements |
| `share_note_at_moment`, `group_listening` | Occasionally | Changelog, press |
| `account_required`, `on_device_privacy` | Rarely | Privacy policy, sign-up flow, App Store privacy label |
| `plays_podcasts`, `reads_*_aloud` | Rarely | Feature page |

Products also appear, get acquired or shut down (Pocket closed 2025-07-08, Geneva in September 2025, Fable was bought by Everand in June 2025). Each refresh starts with a web search for "<name> shut down OR acquired OR discontinued".

## How often

- **Monthly, the five closest rivals** (the ones an inbound page is most likely to name): Snipd, Speechify, ElevenReader, Readwise Reader, margin.fm. Also our own row, whenever a build ships.
- **Quarterly, everything else.** `python3 research/G2/comparison/scripts/validate.py --max-age-days 90` fails any claim whose newest check is older than 90 days. Treat that failure as the reminder.
- **Before any page that uses the data is published or updated**, re-check every row that page names, whatever its age, and rebuild.
- **Our own row**: re-point its sources to the release commit whenever a build ships, then run the validator, which confirms each quote still exists at that commit.

## Refresh procedure

1. `python3 research/G2/comparison/scripts/recheck.py [ids…] > artifacts/recheck.txt` (`artifacts/` is git-ignored). A `QUOTE-GONE` line means the product changed, the page moved, or the page renders with JavaScript. A `FETCH-FAILED` line means the page blocks scripts; open it in a browser.
2. For each flagged source, and for every field in the "Often" rows above, a person reads the page and then:
   - if nothing changed, sets `checked` to today;
   - if something changed, updates `value`, `detail` and the verbatim `quote`, and sets `checked` to today;
   - if the page is gone, finds the new page or marks the value `unknown` with a note saying what was checked.
3. Web-search for news on each product (new features, pricing changes, shutdowns) and add sources where they change a value.
4. `python3 research/G2/comparison/scripts/build.py` must print no problems.
5. Commit with a message listing each value that changed ("Snipd price_paid: USD 6.99/mo → 7.99/mo, pricing page 2026-10-28"). The git history is the change log. Don't write a separate one.

## Rules that keep it honest

- **A quote must be verbatim.** Copy it from the page, not from an AI summary of the page. `recheck.py` finds quotes that aren't on the page.
- **"No" needs evidence.** Use it only when the vendor says so, or when a feature list that looks complete leaves the feature out; say which in `note`. Otherwise use `unknown`.
- **Third-party pages** (reviews, price trackers) are allowed only where the vendor has no page. Name them as third-party in `note`.
- **Our own row follows the shipped app**, not plans or docs. Where the docs and the app's own words disagree, the app wins, and the note says so. A planned feature is never `yes`.
- **Scope.** The file compares documented capabilities. It doesn't rate quality ("better voices") unless a named, dated measurement backs the rating.
