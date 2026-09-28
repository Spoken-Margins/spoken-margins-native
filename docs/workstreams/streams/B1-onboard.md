# B1 · onboard: from a fresh install to following things you love

**Outcome.** A new listener opens the app and, without leaving it, follows five podcasts they care about within a minute: from a browsable drawer of top podcasts filtered by subject, from search by name, or by importing their old app's OPML.

**Why now.** Testers find the app hard to get into. Today, getting a podcast in means going to another app and sharing, and nothing helps a new user start following anything.

**Where.** Research and catalog work in the cloud. App work on the Mac.

**Seams.** Owns **I1** (link → source resolution) and **I2** (followed source and catalog entry). B2, B3 and B4 plug into I1, and D2 and D3 read I2. Publish both in M1, with a stub resolver and a fixture catalog. I2 includes the source *kind* (podcast, article, paper, news, and so on) that D3 filters by.

## Starting points

- No podcast search, no OPML import or export, and no background feed refresh exist today.
- iTunes Search is used only inside Spotify matching (`PublicPodcastLinkResolver.swift`).
- Following lives in `FollowedSourceCoordinator.swift` (discovery, 25 newest entries per feed, refresh on launch or foreground when older than 6 hours) and `SessionKit/SourceFollowingModels.swift`. Feeds are parsed by `SessionKitFeeds/FeedParser.swift`.
- **Conditional refresh is broken:** ETag and Last-Modified are sent when stored, but nothing ever stores them, so every refresh downloads the whole feed.
- A remote manifest pattern already exists: `GuidedOnboardingCoordinator` fetches a size-capped, checksum-verified manifest from the owner's static site (`Site/onboarding/v1/`). A catalog can reuse that pattern (#69).
- The Add Source flow is in `ExperienceAddSourceFlow.swift` (five routes). The Library has a "two-minute tour" card.
- Build 30 reach item that belongs here: #145 (Paste & go).

## Milestones

**M1: First-run drawer** (target: Build 30).
- Done when:
  - On a fresh install, a drawer offers at least 100 popular podcasts with artwork, filterable by at least 8 subjects. One tap follows and shows it's followed.
  - It works offline from a bundled snapshot and refreshes from a remote catalog when online.
  - A lane T4 run on a fresh simulator shows five follows in at most 7 taps from first launch (count taps: an agent's clock isn't a listener's), with new episodes appearing in Following afterwards.
  - I1 and I2 are published.

**M2: Search and OPML.**
- Done when:
  - Searching by podcast name puts the right show first for at least 45 of a 50-name test list (the list is committed as a fixture; mix popular and niche).
  - OPML exports from at least three other apps (for example Apple Podcasts, Overcast, Pocket Casts) import with a preview of what will be followed. Duplicates are skipped.
  - The app can export its own follows as OPML.
  - Tests use recorded responses, not live network.

**M3: Refresh that scales.**
- Done when conditional refresh works (a host test shows a 304 path), and following 60 feeds refreshes without main-thread hitches. Show the timing on the lane.
  - Background refresh (#170) is done here or explicitly handed to D3 with a note on its issue.

## Must not break

- The existing Spotify and Apple resolvers, and Link-field fallback to article extraction (#144).
- Following never downloads episodes by itself.
- No private feed URL leaves the device (#168).

## Out of scope

Ranking the inbox (D3). Substack specifics (B2). YouTube (B3). Sites without feeds (B4).

## Owner decisions

The catalog's source: Apple's public top charts, Podcast Index, or a hand-curated list. Recommendation: Apple's charts for breadth, plus a short hand-picked "starter" row per subject that the owner can edit in the remote manifest.

## Related

#69, #76, #145, #170, #179 (episodes with audio dropped by the feed parser).
