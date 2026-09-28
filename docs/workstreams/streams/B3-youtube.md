# B3 · youtube: YouTube links find the podcast

**Outcome.** A listener pastes or shares a YouTube link to a podcast episode, and Spoken Margins finds the same episode in the podcast's own feed and adds it. When it can't be sure, it says so and offers its best candidates. It never silently adds the wrong episode.

**Why now.** Many podcasts are now shared as YouTube links. Playing video inside the app isn't the goal, so the route is the same one Spotify links already take: identify the episode, then find its audio feed.

**Where.** Matching research and the test set in the cloud. App integration on the Mac.

**Seams.** A resolver under **I1**.

## Starting points

- The Spotify path in `PublicPodcastLinkResolver.swift` does the same job: oEmbed and the embed page for title, date and duration; iTunes Search (`entity=podcastEpisode`) for candidates; scoring; and ambiguous matches sent to review. Tests are in `SourceLinkImportTests.swift` (roughly lines 2023–2271).
- YouTube offers public oEmbed (title and channel, no key). Publish date and duration may need the watch page.
- The cloud environment currently blocks `itunes.apple.com` and `podcastindex.org`. The owner needs to allow them for the research milestone (README → Owner setup).

## Milestones

**M1: Matcher and test set.**
- Done when a committed test set of at least 50 real YouTube podcast-episode links (a spread of big and small shows, full episodes and clips, some with no podcast feed at all), each labeled with the correct podcast episode or "none", scores:
  - at least 80% correct confident matches;
  - **zero** confident wrong matches;
  - "none" correctly reported for at least 90% of the no-feed cases.
- Recorded responses let the matcher be re-run offline. Language is the agent's choice; the app port is M2.

**M2: In the app.**
- Done when:
  - Pasting or sharing a YouTube link runs the matcher inside I1. A confident match adds the episode; otherwise the app shows the candidates or "couldn't find a podcast version".
  - Host tests replay the M1 set.
  - Lane T4: a YouTube link shared from Safari lands on the right episode.

## Must not break

The Spotify and Apple resolvers. Their tests stay green.

## Out of scope

Playing YouTube video or audio directly. Downloading from YouTube (terms of service).

## Related

The owner's notes. No existing issue: open one when starting.
