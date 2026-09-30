# Questions for one attorney meeting (DRAFT)

> **DRAFT. Not legal advice.** Written by an agent from the code on `next` and public sources, for Cole to take to a small-business attorney before share links or the App Store go public (#173, #455). Nothing here has been reviewed by a lawyer.

Read with [privacy-policy-draft.md](privacy-policy-draft.md) and [terms-draft.md](terms-draft.md). Each question has one line of context.

## 1. Business structure

1. **Should I form an LLC before the public release, and in which state?** Share links will put other people's words on a server I run, so claims would reach me personally unless an entity sits in between; formation and annual fees depend on the state.
2. **Does an LLC actually protect a solo developer who writes the code and runs the server himself?** I'd be the only member, the only operator and the one who takes things down, so I want to know what would still reach me personally.
3. **What should the App Store show as the seller, and when do I switch?** An individual developer account lists my legal name; an organization account lists the LLC, needs a D-U-N-S number, and moving an existing app between accounts is a transfer I'd rather do before launch than after.

## 2. Copyright and the DMCA

4. **Do I need a DMCA designated agent, and who should it be?** The U.S. Copyright Office charges $6 per designation, amendment or resubmission, and a designation lasts three years unless renewed by amending or resubmitting it, at the same $6 ([DMCA Directory FAQ](https://www.copyright.gov/dmca-directory/faq.html), checked 2026-09-30; rule at 37 C.F.R. § 201.38).
5. **Whose address goes in the public directory?** The Copyright Office generally requires a street address for the service provider (a P.O. box only with its approval), while the agent's own address may be a P.O. box, so a registered-agent service or the LLC's address may be the only way to keep my home address out of a public listing (same FAQ).
6. **Does a server that holds a shared packet for 30 days qualify for the § 512(c) safe harbor?** The server stores what a listener chose to upload, shows its Margin text on a public page, and deletes it after 30 days or on a takedown (#486); I want to know it counts as storage "at the direction of a user".
7. **What repeat-infringer policy is reasonable with no accounts?** § 512(i) requires one, but the app has no sign-in; the only handle the server has is a random per-install key that a reinstall replaces (`research/B4/DESIGN.md` §2 on `ws/b4-bridge`).
8. **Is showing a Margin's text, the source title and the show name on the link page a copyright risk?** A Margin can quote the source it's anchored to; no source audio or source text beyond what the listener typed or said is served (#486).

## 3. Other liability for hosted content

9. **What else, beyond copyright, am I exposed to for text people share through my server?** A shared Margin could be defamatory or harassing; I'd like to know what Section 230 covers, what it doesn't, and whether a "Report this link" button plus prompt takedown is enough.
10. **Is 30-day retention with deletion on report the right default?** Shorter lowers risk, longer is more useful to recipients, and I want to know whether any law requires me to keep a copy after a takedown.

## 4. Terms and consent

11. **Can new sharing terms be accepted at the first share, rather than by everyone at once?** Bumping the Terms version (`SpokenMarginsTerms.currentVersion`, `App/SpokenMarginsApp/Sources/SpokenMarginsApp/SpokenMarginsTerms.swift:4`) makes every listener accept again before the on-device voice works (`docs/legal/spoken-margins-terms.md`), so a separate sharing agreement shown at first share would disturb fewer people.
12. **Is the tap-to-accept flow enforceable for the voice model's use restrictions?** The Open RAIL-M licence requires its restrictions to appear in an enforceable agreement, and the app records only a version and date on the device.
13. **Do shared packets need a "machine-generated" disclosure?** The Open RAIL-M licence asks for one when distributing machine-generated content, and a packet can carry a cleaned or synthesized voice as well as the listener's own recording.

## 5. Privacy

14. **Do privacy laws such as the CCPA or GDPR apply to a free, invite-only beta with no accounts?** The server keeps no IP addresses and the app collects nothing linked to a person, but testers may be outside the U.S.
15. **Is the per-install App Attest key "Device ID" data for the App Store label?** The server keeps its public half, a counter and day-precision dates for up to 90 days, only to stop abuse (`research/B4/DESIGN.md` §2 and §7).
16. **Is a user-supplied OpenAI key enough to keep me out of the data path?** When enabled, the app sends source text and Margin transcripts to OpenAI with the listener's own key, and none of it touches my server (`App/SpokenMarginsApp/Sources/SpokenMarginsApp/OpenAIResponsesClient.swift`).
17. **What age rating and children's-privacy position should I take?** The app has no age gate, and share links are public pages anyone can open.
