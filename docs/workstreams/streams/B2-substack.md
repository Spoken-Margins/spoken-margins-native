# B2 · substack: follow any Substack, and hear what you pay for

**Outcome.** Any Substack link (a post, a publication home page, a custom domain) reliably offers Follow, and following it brings new posts into the app. People who pay for a Substack can listen to the paid posts they already have access to.

**Why now.** The owner doesn't reliably get a Follow button for Substack links, and people close to the owner pay for Substacks and want to hear them.

**Where.** M1 on the Mac. M2 research in the cloud.

**Seams.** Plugs into **I1** as a resolver. Private feed links follow I1's privacy rule.

## Starting points (why Follow is unreliable today)

- **Articles never get a manual Follow button.** `ManualSourceFollowButton` shows only when `canManuallyFollowSelectedSource` is true, which requires podcast or transcript-backed media.
- Articles get only a suggestion card (`offerFollowSuggestionIfEligible`). It needs at least 25% listened or a Margin, an HTTPS reference, successful discovery, and no prompt for that source in the last 30 days.
- Discovery (`FollowedSourceCoordinator.discover`) aborts before trying `/feed` if the HTML fetch fails or exceeds its 1 MB cap. Large Substack pages may exceed it.
- For browser-imported items, discovery also requires the feed to contain the item's exact URL. Links keep `?utm_…` or `?r=` query strings, and the feed holds only about the 20 newest posts, so older or tracked links never match.
- There is no Substack-specific code at all.

## Milestones

**M1: Follow works for every Substack link** (target: Build 30).
- Done when:
  - Every article item whose source has a discoverable feed shows a Follow action, not only a delayed suggestion.
  - For a committed test list of at least 30 Substack URLs (post links with tracking parameters, old posts, home pages, custom domains, `/feed` links), resolution finds the publication feed for all of them in host tests with recorded responses.
  - T2 green, and a lane T4 run shows Follow on a Substack post shared from Safari.

**M2: Paid posts (research first).**
- Done when a written finding (on the tracking issue, not a doc) answers three questions: what paid-subscriber access Substack actually offers (private feed links, email delivery, app sign-in), what each option would require of the app, and the terms-of-service and credential risks.
  - It ends with a recommendation and a prototype of the lowest-risk option that works on the owner's own paid subscription.
  - No in-app credential handling ships without the owner's OK.

## Must not break

The generic feed discovery other sources rely on. Existing follows.

## Out of scope

Substack Notes, chat and comments. Ranking (D3).

## Owner decisions

Before M2 ships anything: whether the app may hold a Substack sign-in.

## Related

#76, #144, #168 (private feed URLs leaking in packets).
