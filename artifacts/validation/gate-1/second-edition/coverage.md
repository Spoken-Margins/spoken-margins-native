# State coverage and limits

All 20 reference states have native paths and were compared with the approved behavior requirements. The final run index in `handoff.md` identifies execution evidence; this table does not claim a screenshot or physical audio check for every state.

| State | Native outcome and evidence path |
| --- | --- |
| Library | Actual rows and local search/filter/sort first. Dense Library and persistent-player UI routes; long titles at maximum native text size. |
| Listen | Scrollable item content with fixed transport/capture controls. Simulator touch drags and long-title control reachability UI routes. |
| Record | Exclusive recording screen with real lifecycle, saved anchor, Save/Cancel and source restoration. Recording UI route and engine/app tests; a synthetic recording fixture is not microphone audibility evidence. |
| Saved | Persisted note returns to the collection and detail/Timeline. Voice capture route plus written capture route and reconstruction tests. |
| Margins | Local private-note/title search, Starred/attention filters, separated Shared rows. Fifty-note app case and native written search/star route. |
| Note | Complete words, explicit provenance, bounded context and Play this moment. Cross-session identity/rollback tests and native detail/play route. |
| Timeline | Source, private and generated labels remain distinct; Shared details are expandable. Rail, generated-row, keyboard and mini-player clearance UI routes. |
| Add | Typed intake choices; a dedicated pasted-text editor with a persistent Add action. All intake-route, ambiguous import and keyboard UI routes; app import-without-autoplay tests. |
| Ready | Real readiness and retry state govern listening. Item action-before-map UI route and preparation model cases. |
| Item | Full title, primary listening action, compact session actions, immediate Shared provenance. Item/recipient native captures and per-item/session app tests. |
| Sources / Following | Existing source identity, distinct new entries and recovery. Following root UI plus duplicate/stale-discovery app tests. |
| Share | Explicit selection, representation/cleanup review, verified preview, then system share. Sender stage UI route and sharing/export isolation suites. |
| Received | Source absence/mismatch remains unresolved; provenance and import are explicit, without autoplay. Recipient UI and source-resolution/package tests. |
| Offline | Real queue/storage state, retries and protected originals. Storage UI route, preparation app cases and ledger tests. |
| Settings | Playback/voice choices precede optional model detail; consent and diagnostics remain available. Seeded settings, diagnostics and storage UI routes; consent app tests. |
| First | Useful Add/sample paths with current instructions. Bootstrap/onboarding sample and all-intake tests. Synthetic data does not establish first-use comprehension. |
| Finished | Completion retains review access; deliberate replay creates a new session and preserves old notes. Completion-while-browsing and replay app tests. |
| Skim | Existing eligibility and audible-target logic; a fixed Return to Source control calls the existing restoration action. Source/code review, rate/readiness/state tests; physical source restoration and audibility remain owner checks. |
| Shared playing | Existing preview/cue/consent behavior with fixed Return to Source. Eligibility, package/compact-control tests and source review; manual voice preview is distinct from anchor navigation. Physical listening remains an owner check. |
| Permission | Real denial supports Settings and independent writing. Late-grant/cancel/written-switch and denied-microphone app tests. The owner checks the real OS permission prompt on a device. |

No flow is `human_validated` by this table. The owner checklist separately covers listening quality, VoiceOver traversal, Bluetooth/Lock Screen behavior, real collections and comfort. Native screenshots establish composition at their recorded device/text settings; they do not establish those physical or experiential outcomes.
