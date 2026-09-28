# B4 · bridge: follow sites that don't publish feeds

**Outcome.** A listener shares an article from a site with no RSS feed, taps Follow once, and from then on new articles from that site show up in Following like any other feed, with no more trips through Safari. A small Spoken Margins server does the watching. It never learns who follows what and never serves the articles themselves.

**Why now.** The owner's aim: "only have to do it once per source". Today a site without a feed means Safari → share sheet → several taps, for every article.

**Where.** Server and research in the cloud. The app milestone on the Mac.

**Seams.** Owns **I3** (bridge manifest and fetch recipes) and **I11** (server client and device attestation), which E3 and later F1 reuse. Plugs a resolver into **I1** ("this site can be bridged").

## Starting points

- No server exists. The owner runs a VPS that serves the static site at `spokenmargins.proximitytoprogress.com` through Caddy (`scripts/deploy-spoken-margins-site.sh`). The app already fetches a size-capped, checksum-verified manifest from it (`GuidedOnboardingCoordinator`).
- Existing web-page-to-feed tools (for example RSSHub, RSS-Bridge, or plain CSS-selector scrapers) are candidates for the server side. Check licenses before copying code, following the rule in the owner's `Digest` repo (`docs/inspiration-and-licenses.md`).
- On the phone, `AppOwnedReadablePageExtractor` already fetches and extracts a page in a locked-down WKWebView with the bundled Defuddle script.

## Milestones

**M1: Server foundation** (gate for B4's app side, E3 and F1's server phase). **Effort: xhigh.**
- Done when a short design note on the tracking issue, plus a deployed skeleton, shows each of these:
  - Hosting, with a monthly cost estimate and a hard budget alert.
  - A kill switch the app respects.
  - Per-install anonymous attestation (App Attest or equivalent), with the ability to block one install.
  - No accounts and no personal data stored.
  - Logs that can't reconstruct a user's follows or reading.
  - What goes on the privacy page (`Site/privacy`).
- The skeleton answers a health check and one attested request from a test client.
- Needs owner decisions first (below).

**M2: The bridge works for real sites.**
- Done when, for a committed list of at least 20 owner-chosen sites without usable feeds, the server publishes a manifest (I3) that picks up new articles within 6 hours of publication, measured over at least 3 days.
  - Each site has a declarative recipe, and the app-side extractor turns at least 18 of the 20 into clean readable text.
  - Recipe changes are data-only deploys.

**M3: In the app.**
- Done when:
  - Following a bridged site from an article is one action.
  - New items appear in Following through the manifest, and the phone fetches each article itself using the recipe.
  - Turning the server off (kill switch or outage) leaves the app working, with bridged sources marked "not updating".
  - Host tests cover manifest parsing and recipe application from fixtures. Lane T4 shows a follow and a new item arriving.

## Must not break

- **App Store Guideline 2.5.2:** recipes are data, never code.
- The server never serves article bodies.
- The phone must be able to filter the manifest locally, so the server can't learn follow lists.

## Out of scope

Hosting content. Paywalled sites (see B2 for Substack). Fediverse/ActivityPub: note it as an input source option in M2 if useful (#25).

## Owner decisions (before M1)

1. **Where it runs.** Recommendation: the existing VPS, since static manifests plus one small service fit there, with an off-box budget alert. Serverless is the alternative if the owner would rather not operate a box.
2. **Monthly cost ceiling.**
3. **How a new site gets bridged at first.** Recommendation: the owner approves each new site. Later, a request from the app can queue it for review, without identifying the requester.
