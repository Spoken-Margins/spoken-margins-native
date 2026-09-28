# B2 research: Substack links → Follow, and paid access

Cloud groundwork for stream B2 (brief: `docs/workstreams/streams/B2-substack.md`, tracking issue #188). Nothing here ships in the app. The M2 finding itself is on #188; this folder holds the test set, the recorded responses, and a Python prototype of the resolver M1 should port to Swift.

| File | What it is |
| --- | --- |
| `urls.json` | The test list: 42 links (37 Substack, 2 traps, 3 controls). Each has the feed it must resolve to (`expect_feed`, `null` = not a Substack). |
| `fixtures/` | Recorded responses, one JSON per request hop (`sha256("<kind> <url>")[:16].json`, kind `feed` or `html`). |
| `fetcher.py` | Record/replay HTTP. It follows redirects hop by hop, at most 5, https only, like `BoundedRedirectDelegate`. |
| `current_app.py` | Line-by-line Python port of today's discovery and Follow gates. Each failure names the Swift line that throws. |
| `substack_resolver.py` | Prototype I1 resolver: Substack link → publication feed, plus private-feed and paywall detection (M2). |
| `run_cases.py` | Runs every case through both and writes `results.md` (table) and `results.json`. |
| `test_b2.py` | Offline host tests (15). |

```bash
cd research/B2
python3 -m unittest -v test_b2       # offline; replays fixtures/, never touches the network
python3 run_cases.py                 # print the today-vs-resolver table
python3 run_cases.py --record --write  # network: record any missing hop, rewrite results.*
```

The tests use only the standard library (Python 3.11). Replay never goes to the network: an unrecorded request raises `FixtureMiss`.

## Fixtures

- Recorded 2026-09-28 with the app's `Accept` headers and a CFNetwork-style User-Agent.
- Bodies are trimmed so the folder stays around 2.5 MB:
  - HTML keeps `<head>` plus short windows around the paywall element and a profile's `primaryPublication`.
  - Feeds drop `<description>` and `<content:encoded>`.
- `original_bytes` keeps the real size, which is what the 1 MB HTML and 16 MB feed caps are checked against. A Swift port of these tests has to pad bodies to `original_bytes` (or stub the size) to reproduce the 1 MB failures.
- **Feed-dependent results are snapshots.** "Recent post, found in the feed" is true only in the recording. Substack feeds hold the 20 newest posts, so a post imported today fails membership a week or two later. That is the old-post failure below.

## Why Follow fails today, check by check

From reading `FollowedSourceCoordinator.swift` (FSC) and `Gate1AppModel.swift` (GAM) on `next`, confirmed by the emulation in `results.md`. Articles are Library items with `mediaType "text"`. Every article import path leaves `sourceURL` nil and stores the page URL in `externalReference`.

What each import path stores in `externalReference`:

| Import path | Stored reference | Source |
| --- | --- | --- |
| Safari extension | `location.href`, with the query and fragment kept | `browserExtractionCore.mjs:87` |
| Link field | the WKWebView's final `location.href` | `AppOwnedReadablePageExtractor.swift` |
| Share sheet from Safari | `<link rel=canonical>` (clean on Substack) | `SourceLinkShareViewController.swift:492` |

| # | Check that fails | Where | Substack cases it breaks (ids in `urls.json`) |
| --- | --- | --- | --- |
| 1 | No manual Follow for articles: `canManuallyFollowSelectedSource` allows only `podcast` / `transcript_backed_media` | GAM:15667-15672 | Every article item (all 17 `item: true` cases). Articles get only the suggestion card. |
| 2 | Suggestion is gated on engagement: ≥ 25% listened, or a Margin on the item | GAM:15802 | Every article until then. The check runs on open (GAM:5543), when crossing 25% (GAM:1729), and after `refreshSelectedItem` (GAM:14803). |
| 3 | Membership: `requiringItemMembership: item.sourceURL == nil` is always true for articles. The feed must then contain the item's exact URL. `itemURLKey` keeps the query and drops only the fragment. | GAM:15872 → FSC:77-80, FSC:97-103 | **Tracked links (Safari/Link import):** `post-custom-email-utm`, `post-custom-web-share-r`, `post-noahpinion-recent-r`, `post-paid-truncated`, `post-podcast-lenny-utm`. **Old posts (any import path):** `post-custom-old-2022`, `post-custom-old-2026-01`, `post-subdomain-old-utm`, `post-paid-podcast`. Today 8 of 17 article cases find a feed, and it falls toward 0 as recent posts age out of the 20-item feed. |
| 4 | The discovery page fetch aborts when the HTML is over 1 MB, before the `/feed` heuristics run | FSC:261 (reached from FSC:61) | `home-thefp-over-1mb` (2.0 MB), `post-custom-comments` (1.7 MB). The Free Press post pages are about 0.95 MB (`post-thefp-large-page` passes by about 100 KB). |
| 5 | The alternate link and `/feed` heuristics resolve against the **original** URL and host, not the final (redirected) one | FSC:62 (`baseURL: url`), FSC:64-69 (`host`), then FSC:93 | Substack app share links: `share-open-substack-pub`, `share-home-post-id`, `share-handle-post-id`, `share-inbox-post`, `share-app-link-email`. The apex domain `home-custom-apex`: `astralcodexten.com` redirects to `www.`, but `astralcodexten.com/feed` is a 404. |
| 6 | A profile page has no feed link | FSC:93 | `profile-handle`, `profile-subdomain-redirect` |
| 7 | `http://` is rejected outright | FSC:56 | `feed-http` |
| 8 | Some post pages advertise a **section** feed (`/feed?sectionId=N`) as their alternate link | FSC:62 | `post-paid-truncated`, `post-podcast-lenny-utm`: generic discovery tries the section feed first. |

Notes for #8 and for the share sheet:

- **#8 side effect.** A parsed feed's `atom:link rel=self` points at `/feed`, so the candidate's canonical URL is the whole publication anyway (FSC:127). That is harmless, but it is luck.
- **Before Follow, URL-only shares.** This is from code reading only; verify it on the Mac. A URL-only share (for example from the Substack iOS app, which shares `open.substack.com/pub/...` links) goes to `importSourceLinkInBackground` (GAM:3404-3447, from GAM:7763). That path resolves podcasts only, and a non-audio page is quarantined (GAM:7771-7773). So a Substack post shared from the Substack app may never become an article item.

Not failures:

- A `#fragment` is fine, because `itemURLKey` drops it.
- The Following tab's "Paste an RSS feed link" field (GAM:15618 → FSC:54 without membership) handles clean post, home, archive and `/feed` links. It fails on #4 to #7.

## The resolver (prototype for M1)

`substack_resolver.py` resolves all 42 cases. Controls come back as "not Substack", so generic discovery keeps them.

- **Evidence is the origin, not feed membership.** A `/p/<slug>` page that Substack serves from origin X belongs to the publication whose feed is `X/feed`. That makes old and tracked links resolve like clean, recent ones.
- **Requests.** Custom domains and `<name>.substack.com` cost one request: `GET <origin>/feed`, which must show Substack evidence (`x-served-by: Substack` / `x-sub` headers or `<generator>Substack`). No page is downloaded, so the 1 MB cap never applies.
  - **Fallback.** If the origin has no feed (the apex redirector, or a subdomain that redirects to a profile), follow the link itself once.
  - **substack.com post links** (`home/post/p-ID`, `@handle/p-ID`, `inbox/post/ID`, `app-link`) cost one redirect-following GET, then `/feed`.
  - **`open.substack.com/pub/<name>/…`** names the publication directly.
- **Profiles are "is this it?", never certain.** A profile gives its *primary* publication at confidence 0.8. `lennysnewsletter.substack.com` is a real trap: it is not Lenny's Newsletter (`lenny.substack.com` is). It redirects to an unrelated person's profile. The candidate's reason says so.
- **Cost for non-Substack links.** They cost one extra `GET /feed`, plus one page GET in the fallback. The Swift port could skip the fallback when `/feed` returned a non-Substack 200.

### Suggested M1 shape (for the Mac session)

1. Port the resolver to Swift as its own type in SessionKit, with an injected fetch closure so it can be tested on the host. It plugs into I1 as a resolver.
2. Call the resolver in `discoverFollowCandidates` (GAM:15865) before generic discovery. Pass its candidate through without the membership check (relation e.g. `substack_publication`). Its evidence is stronger than membership.
3. Let `canManuallyFollowSelectedSource` accept `text` items with an https `externalReference`. Discovery can run on tap, as `followSelectedSource` (GAM:15736) already does.
4. Port `test_b2.py`'s cases with a `URLProtocol` stub that reads `fixtures/` by the same file name. Keep `results.md` as the before-picture.

Generic discovery also has fixes that help every site, not just Substack. They are out of B2's remit unless the owner wants them in M1:

- strip tracking parameters in `itemURLKey`;
- resolve alternates against `http.url` rather than the original URL;
- read only the first ~1 MB of HTML instead of aborting.

## Paid access prototype (M2)

The decision and reasoning are on #188. The code parts:

- `is_private_feed_url` / `redact`: recognise a subscriber's private Substack feed link (`api.substack.com/feed/podcast/<id>/private/<token>.rss`) and show it without its token. The resolver returns it as a `substack_private_feed` candidate with `private = True`. Per I1 and #168 it must never leave the device.
  - Tested against a recorded public podcast feed served under a fake private URL. This session has no paid subscription.
  - A link's shape does not prove access. A UUID-shaped token that isn't a subscriber's gets `200` with the public episodes (checked live 2026-09-28), so the app should compare the followed feed with the public one before calling it "paid".
- `page_is_paywalled`: detects Substack's paywall element (`data-component-name="Paywall"`) in a captured page. The app can then say "this is only the preview; open it in Safari where you're signed in and use the extension" instead of narrating a teaser as if it were the post.
  - Tested on a recorded paid post (`post-paid-truncated`) and a free one.
