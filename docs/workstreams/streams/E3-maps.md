# E3 · maps: listening maps for everyone, shared by the community

**Outcome.** Listeners get a listening map (scenes, short summaries, Skim) for the podcasts they play, even when their phone can't make one:
- Phones that can make maps on device do it quietly, and may contribute them.
- Phones that can't get one from the community.

Everything is anonymous. There are no accounts; installs that submit junk can be blocked. A map always says where it came from, so a listener can tell a community map from their own.

**Why.** Listening maps make Skim and navigation work, and they're only as common as the devices that can make them. A community multiplies them. Eventually this could be a revenue stream; for now it raises everyone's listening quality.

**Where.**
- M1 on the Mac.
- M2 (server design) in the cloud. **Effort: xhigh.**
- M3 on both.

**Waits for.** B4 M1 (server foundation and I11), I9 (episode identity; #177: the app doesn't store episode GUIDs yet), and the owner's rights decision for transcripts.

**Seams.** Owns **I8** (listening map extensions), with E1 for entity fields. Uses I9 and I11.

## Starting points

- A full on-device pipeline exists but is **off by default**: `Gate1AppModel.prepareEpisodeMap` → `runEpisodeMapPreparation`, which runs these stages:
  1. hash the episode;
  2. ShazamKit landmarks;
  3. on-device transcription;
  4. a phrase sketch;
  5. deterministic scenes, of 4 minutes, 90 s minimum and 8 minutes maximum (`EpisodeSceneSegmenter`);
  6. a Foundation Models title and description per scene;
  7. summary audio;
  8. delete the transcript.
- Users reach it through Item → Advanced, or Settings → Automatic Episode Map Preparation, where the options are Off and While Charging.
- Portable maps already exist for sharing (`PortableListeningMapProposalArtifact`, schema `listening-map-proposal.v2`). Their start and end anchors are designed to land on a different edition of the same episode, and the same acoustic-matching benchmark gates apply: zero false-confident placements, p95 ≤ 1.5 s.
- Current policy: the full transcript of native audio stays internal and is never exported. Uploading transcripts changes that policy, and is the owner's call (#14, #173).
- #51 is an earlier spike for server-hosted AI maps; #88 and #89 cover portable scenes and Skim summaries.

## Milestones

**M1: More maps without a server.**
- Done when:
  - Episodes of followed podcasts get maps automatically where the device can make them, within an owner-accepted battery and heat budget. Recommendation: while charging by default, with a visible toggle.
  - Publisher chapters are used when present.
  - Measured on the owner's phone: the share of new episodes of followed shows that have a map within 24 hours, before and after. The owner sees Skim available more often.
  - Episode GUIDs are stored (#177), in coordination with C4.

**M2: Community server design.**
- Done when a design on the tracking issue, with a skeleton on B4's foundation, covers:
  - submitting a map from an attested install;
  - looking up maps by episode identity without revealing the listener's library in the clear (I9);
  - how bad maps are detected, reported and blocked, and how a blocked install is refused;
  - storage and cost;
  - the transcript question: the maps-only route (devices with AI contribute maps; devices without AI consume them), and what a transcript-upload route with server-side generation would add, cost and risk;
  - privacy page text.
- The owner decides the route.

**M3: In the app.**
- Done when:
  - A device with no on-device AI opens a popular episode and gets a community map within 2 s when one exists. It's labeled as a community map and can be reported.
  - For a test set of 20 episodes with differing editions, community scenes land on the recipient's edition within the benchmark gate.
  - Contributing is opt-in.
  - Submissions from a blocked install are refused.
  - With the server off, nothing breaks.

## Must not break

The on-device pipeline's validation rules. The anchor benchmark gate, which never loosens. The rule that nothing leaves the device unless the listener opted in.

## Out of scope

Paying for maps. Creator-curated editions (#24).

## Owner decisions

The battery and heat budget for automatic maps (M1). The maps-only or transcript-upload route (after M2).
