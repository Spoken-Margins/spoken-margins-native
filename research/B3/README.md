# B3 research: YouTube link → podcast episode

Stream B3, milestone M1 ([brief](../../docs/workstreams/streams/B3-youtube.md), tracking issue #189).
A listener pastes a YouTube link to a podcast episode; the matcher finds the same episode in the podcast's own feed, offers candidates when unsure, or says there's no podcast version. It must never be confidently wrong.

## Run it

```bash
cd research/B3
python3 score.py                  # offline: replays fixtures/http, no network
python3 -m unittest discover tests
```

`score.py` prints one line per case and the brief's three numbers, and exits non-zero if any confident match is wrong or a threshold is missed. `B3_HTTP=record` fetches anything not yet recorded; `B3_HTTP=refresh` re-fetches everything (results will drift as feeds change). Python 3.11 standard library only.

## What's here

| Path | What |
| --- | --- |
| `testset.json` | The labeled set (built from `labels.tsv` by `tools/build_testset.py`). |
| `labels.tsv` | Hand-written labels: category, show, feed URL, the feed item's guid, and why. |
| `b3/youtube.py` | Video evidence: title, channel, date, length, description and its full link targets. |
| `b3/itunes.py`, `b3/spotify.py` | Candidate sources: Apple's Search/Lookup APIs (as the app's Spotify resolver uses), Spotify oEmbed for show names. |
| `b3/match.py` | The matcher. |
| `b3/http.py` | Recording HTTP client; every response lives in `fixtures/http/` (gzipped JSON keyed by request). |
| `tools/` | Labeling helpers: read a feed, list the items a labeler should consider. |

## The test set

71 real links, collected on 2026-09-28 from the channels' public upload feeds.

| Category | Count | Label |
| --- | --- | --- |
| `full_episode` | 38 | The episode's item in the show's own RSS feed (guid, title, date, length, enclosure) |
| `clip` | 15 | none. Clip channels (Lex Clips, JRE Clips), Shorts, previews, and cuts that are much shorter than any episode |
| `no_feed` | 12 | none. Shows with no podcast feed: Hot Ones, Jubilee, Good Mythical Morning, Veritasium, MrBeast, Channel 5 with Andrew Callaghan… |
| `not_in_feed` | 4 | none. The show has a feed, but this video isn't in it |
| `non_podcast` | 2 | none |

It spans big shows (Joe Rogan, Huberman, Diary of a CEO, SmartLess), mid-size and small ones (Oxide and Friends, Syntax, Mindscape, Machine Learning Street Talk), and includes deliberate traps: a re-release whose 2023 original has the same length (SmartLess), monthly AMAs that differ only by month (Mindscape), an "(update)" whose 2024 original has a similar title (Planet Money), a "Essentials" re-cut next to an older full episode with a near-identical title (Huberman), older episodes with the same guest (Theo Von, Oxide, Lenny), retitled uploads (Diary of a CEO, Hard Fork, MLST), audio published a week before or after the video (TED, Syntax, Freakonomics), and a 16-minute video titled "(Full Conversation)" (Big Technology).

**How labels were decided.** From each podcast's own RSS feed, not from Apple's search results, so the labels don't share the matcher's candidate source. Feeds were found through fyyd.de and Apple Podcasts show pages. `tools/label_helper.py` lists the feed items near each video's date and the closest titles; the label and the reason are in `labels.tsv`. Five labels that weren't obvious from the titles (Hard Fork, 20VC, Syntax, TED, Freakonomics) were confirmed by word-for-word identical descriptions. "No feed" was checked in fyyd and Apple.

## How the matcher works

1. **Evidence from YouTube.** oEmbed gives title and channel. The watch page has the rest, but from this cloud network the watch page and the player endpoint are bot-blocked, so the harness reads the same data from the `next` endpoint (date, description, link targets) and a search for the video id (length). On a phone the app can read the watch page directly.
2. **Which show?** Candidates come from Apple Podcasts links in the description, Spotify show links (named via Spotify oEmbed), and Apple searches for the channel name and show-like parts of the title (`… | Lex Fridman Podcast #502`, `Mindscape 369`). A show counts as *identified* only when its name, or its publisher's, is backed by the channel, the title or a linked show, or when its feed is hosted on a site the video links to (lexfridman.com, changelog.com). A search hit alone never identifies a show.
3. **Which episode?** The identified shows' latest 200 episodes (Apple Lookup) are scored on title, description overlap, episode number, date and length. An episode search by title runs only when that gives no confident match.
4. **Confident only when all of these hold:** the show is identified; the episode numbers don't conflict; the lengths agree (within 3 minutes or 20%; a 10-minute clip never matches a 3-hour episode); at least one strong episode signal holds (same episode number, same title within a week, or matching description within a few days); and the runner-up is clearly behind. Otherwise it's *review* with candidates when there's something plausible to show, or *none*.

## Results

Offline replay of the recorded responses (`python3 score.py`, 2026-09-28):

| Measure | Result | Brief |
| --- | --- | --- |
| Correct confident matches (38 videos with a feed episode) | 35/38 = 92% | ≥ 80% |
| Confident wrong matches (all 71) | 0 | 0 |
| "none" for shows with no feed | 12/12 = 100% | ≥ 90% |

- The three misses weren't confident, and each went to review with the right episode among the candidates: a Freakonomics video posted 8 days before its audio; a Standup video cut 21 minutes shorter than the audio; an Impaulsive upload retitled with a different description.
- The 21 clips, not-in-feed and non-podcast videos never got a confident match. One clip was offered its parent episode for review; the rest got "none".

Two confident-wrong results turned up during development. Each became a rule and a unit test in `tests/test_safety.py`:

1. A Lex Clips video matched its full episode because its description is mostly Lex's standard links. Description evidence now counts only when it singles out one episode of the show.
2. A Vergecast "wrong" match turned out to be a labeling error: the feed carries the episode under a different title with an identical description. The label was fixed, and every "none" label was re-audited against feed descriptions.

## Known limits

- **In-sample numbers.** The matcher was tuned on this set: two rules were added after test-set failures, and one label was corrected after the matcher found the episode. There is no held-out set, so expect somewhat worse results on new links. A fresh batch of 20–30 links, labeled before the matcher sees them, is the honest check (cheap to do in M2).
- **Clips count as "none".** A clip confidently matched to its parent episode counts as wrong. Clips aren't in the 80% denominator.

- **Apple rate limit.** From this shared cloud IP Apple's Search API allows roughly four or five requests a minute before answering 403; `b3/http.py` paces and backs off. Recording the full set takes about an hour. A phone has its own quota.
- **Latest 200 episodes.** Apple Lookup returns at most the 200 newest episodes. Older episodes are only reachable through the title search, which is weaker when the YouTube title was rewritten.
- **Feeds change.** Recorded fixtures pin the results; `refresh` runs will differ as shows publish.
