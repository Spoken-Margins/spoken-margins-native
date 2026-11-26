# Publisher audio

How Spoken Margins plays a publisher's own recording of an article instead of reading it with the app's voice, and why
each source may play (#239, #545, #810, #3438, #4640).

## One path for every source

Every source saves the same `publisher_audio` record beside the article (the recording's address, its length, where it
came from, and later a text-to-time map). Playback is one path (`PublisherAudioPlayback`, `SessionEngine`): the
recording streams only once its map places at least 80% of the article's sentences (`PublisherAudioAligner`), and the
article plays in the app's voice until then. Nothing in playback names a site.

Every new record passes one gate, `PublisherAudioAdmission.admit` (`SessionKit/PublisherAudioSourcePolicy.swift`), which
checks the record's source against its rule: https only, no user name or password, no port, Type III only from
`type3.audio`, and, on the article feed route, no signed or expiring address. A refused record is not saved, and
Diagnostics says `refused:<token>`. `scripts/tests/test_publisher_audio_admission_gate.py` fails if a new file saves a
record without the gate.

## The sources and their basis

| Source (`detectedFrom`) | Found by | Basis |
| --- | --- | --- |
| `substack_post_voiceover`, `substack_post_generated_voice`, `feed_enclosure` (early builds) | The Substack post page or a followed Substack feed | Cole, 2026-10-14: play the publisher's voiceover "if it is avalible and allowed" |
| `type3_audio_narration` | Type III Audio's find call for LessWrong and EA Forum posts | Permission by email from Type III Audio, 2026-11-05 |
| `article_feed_enclosure` | The article's own public feed lists the page with an audio enclosure | The publisher published that audio in its feed for podcast apps, the basis on which every podcast already plays (#4640, Default taken; on the lawyer's list) |

### Why audio a page plays only in its own player is not used

An `<audio>` element, an `og:audio` tag, a JSON-LD `AudioObject` or an embedded player shows that a page can play
audio in that page. It grants nothing to another player, and the issue that asked for this said not to assume that
publicly playable audio may be extracted, streamed elsewhere or cached. Pages of those shapes are test fixtures that
must fall back to the app's voice (`ArticleFeedAudioTests`).

### The OpenAI article, checked 2026-11-22

`https://openai.com/index/managing-frontier-ai-risk/`: the server-rendered page names no audio file and links no feed,
and `openai.com/news/rss.xml` lists the article with no enclosure. Not checked: media a script fetches after the page
draws. OpenAI's Terms of Use (effective 2026-01-01) bar programmatically extracting data from its websites, so using
its reader would need its written permission. No route plays it; it plays in the app's voice.

## The article feed route

On the listener's open or play of an https article with no Substack or Type III address, from a site they don't
already follow, the app reads what the Follow check's discovery saw for that page (`FollowedSourceCoordinator.
articleFeedAudio`): the feed item whose link is this page. It sends nothing beyond the Follow check's own requests (the
page, at most 8 feeds and 4 same-site probes), and the two share one discovery. Never at import, never in the
background. The enclosure must be https audio (not HLS), unsigned, not the page itself, on an article of at least 600
words, and its duration within 0.4× to 2× of the article's reading time at 150 words a minute, or with no duration at
most 150 MB.

## Streaming, and the one temporary download

Recordings stream; no copy is kept. To make the map, the app downloads the recording once into a temporary file,
transcribes it on the device and deletes it (`PublisherAudioTextMapper`). That download runs only on Wi-Fi (never
cellular or Low Data Mode), stops past 150 MB, and is skipped for a file whose length doesn't fit a narration of the
article (`not_narration`). The map needs Speech Recognition, which the app asks for only when a spoken Margin is first
transcribed: a listener who never allowed it keeps the app's voice for every publisher.

Limits: redirects are followed by the player and the mapper and are not checked again against the host rule.

## Margins

Margins anchor to the article's words, never to the recording's clock. Where the map left a sentence unplaced, the app's
voice reads it. Packets carry Margins on the text, so a friend's copy works with or without the publisher's audio.

## What the listener sees

- Under the title on Now, while the recording reads: **Publisher's audio · <site>**, or **Narration by Type III Audio**.
- In Listening options, a **Reading voice** row: **Use the App's Voice** keeps the app's voice for that article (a
  `publisher_audio_choice` record; not a failure, so nothing holds the recording back); **Play Publisher's Audio**
  removes the choice and tries the recording again at once.
- With VoiceOver on, the automatic switch and the fallback are announced.

Publisher audio plays by default (#239, 2026-09-30); there is no Settings switch.

## Adding a source

1. Record the permission in `docs/decisions.md`.
2. Add one case to `PublisherAudioSource` with its rights basis and host rule.
3. Find the recording in a listener-gated lookup and save it through `savePublisherAudioIfItemExists`.
