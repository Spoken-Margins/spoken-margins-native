# Questions for one attorney meeting (DRAFT)

> **DRAFT. Not legal advice.** Written by an agent from the code on `next` and public sources, for Cole to take to a small-business attorney before share links, Listening Maps or a public App Store release go public (#173). Nothing here has been reviewed by a lawyer.

Read with [privacy-policy-draft.md](privacy-policy-draft.md) and [terms-draft.md](terms-draft.md).

The list was cut from 20 questions to 6 on 2026-10-16; question 7 was added on 2026-10-20 (#2035). A question stays only if the answer turns on legal judgment we can't get from the statute, Apple's rules or a fee table. The rest are decisions, recorded below as defaults the owner can veto by number, or engineering work, filed as issues.

## Questions for counsel

In priority order. The first two are where the real exposure is.

1. **Listening maps.** A phone transcribes a public podcast episode on the device and uploads the transcript. Our server passes it to an AI service and publishes a map: chapter titles, one-sentence descriptions and timestamps, like a table of contents with redundant anchors in place of page numbers. Is that transient copy, and publishing the map, likely fair use? What would make a summary a derivative work instead of an index?
   - Planned changes (#1730): the transcript is never written to disk; anchors become hashes and timestamps, not quoted sentences; descriptions are capped at about 25 words and rejected if they copy 8 or more words in a row.
   - Full transcripts are never shared (default D14).
2. **Share links: the source excerpt next to a comment.** A shared Margin is the listener's own commentary on a moment in a source. The share page shows that comment with up to 500 characters of the source before and after it, as a marked quotation, with the title, the show and a link to the source. The source's audio is never included. Is a short excerpt that only gives a comment its context fair use, and is 500 characters a side a reasonable cap?
3. **The § 512(c) safe harbor when we can't read what we host.** Share-link content is encrypted on the phone, and the key travels only in the link, so the server stores data it cannot read. It deletes each item after 30 days, or when a notice names the link. Does this count as storage "at the direction of a user"? Does not being able to read the content change our knowledge or "red flag" position, for copyright and for the duty to report child sexual abuse material once someone sends us a link?
4. **Repeat infringers with no accounts.** § 512(i) expects a repeat-infringer policy. Our plan (#1728): two takedowns in 90 days against the same install set an Apple DeviceCheck flag on that device, which blocks it from sharing links even after a reinstall. We never store a device identifier. Is that a reasonable policy?
5. **Defamation and harassment in shared comments.** Calling something commentary protects it from a copyright claim, not a defamation claim. With Section 230, a "Report this link" button and deletion on report, is there anything else we owe the person a comment is about?
6. **Does a single-member LLC protect me if I personally handle takedowns?** I'll be the only member, the only operator and the person who acts on notices. What would still reach me personally, and what habits keep the LLC's protection intact?
7. **Is direct-to-Readwise sync "collection" under Apple's privacy definitions?** A listener who turns on "Send Margins to Readwise" has their Margin text, the source passage around it, and the item's title and author sent from the phone to readwise.io with their own Readwise token. No Spoken Margins server sees it, and it is off by default. Apple counts data as collected when it leaves the device and the developer or a partner can keep it. Does a transfer the listener chooses, to an account they own, count? Until counsel answers, the draft label is the conservative one: "Other User Content", linked to the user, not tracking ([app-store-submission.md](../launch/app-store-submission.md), row 12; #2035).

## Decided without counsel

Defaults taken on 2026-10-16. Veto any by number.

- **D1. LLC in the state Cole lives in.** Forming in Delaware or Wyoming adds a second registered agent and a foreign-registration fee, and gives a one-person business run from home nothing it needs. (Inference from general guidance; question 6 can confirm.)
- **D2. Organization developer account under the LLC before the public release.** The D-U-N-S number is free. Moving the app between accounts is easier before launch than after.
- **D3. Register a DMCA designated agent before share links go public.** $6, renewed every three years ([DMCA Directory FAQ](https://www.copyright.gov/dmca-directory/faq.html); 37 C.F.R. § 201.38). The agent is the LLC, at a registered-agent or virtual-mailbox address, so Cole's home address stays out of the public directory.
- **D4. 30-day retention, deleted on a valid report.** After a takedown we keep only the report record (link id, reason, date), unless law enforcement asks us to preserve something or question 3's answer says the law requires it.
- **D5. Sharing terms are accepted at the first share**, as a separate agreement, so the main Terms version doesn't change and nobody else is interrupted. Accepting at the point of use is the usual pattern.
- **D6. The Open RAIL-M voice keeps its tap-to-accept at download**, recording the terms version and date. No custom App Store EULA. Only listeners who download that voice use it, so only they need to agree.
- **D7. Nothing shared today is machine-generated audio.** Shared Margins carry only the listener's own recording or text. If a later feature shares synthesized voice, such as a paid server voice, it is labeled as synthetic; the packet format and the recipient's label for that already exist (`tts_audio_and_text`).
- **D8. Privacy laws.** The CCPA's revenue and volume thresholds are far above ours. For the GDPR, we store nothing linked to a person. The first public App Store release starts on the U.S. storefront and widens after a privacy check; TestFlight testers abroad are fine because nothing about them is stored.
- **D9. App Store privacy label:** declare the App Attest key as Device ID, not linked to the user, used for fraud prevention. That is the conservative reading of Apple's definitions.
- **D10. The listener's own OpenAI key is not a shipped feature.** The code exists but is switched off in every build (`SMRemoteProviderExperienceEnabled: false` in `project.yml`). The privacy policy covers it only if it is ever turned on.
- **D11. Age rating:** answer Apple's questionnaire as written for an app whose shared links anyone can open, and take at least 13+. The app isn't directed at children and has no age gate.
- **D12. A protection service such as Cloudflare is named in the published privacy policy in advance**, so it can be switched on during an attack without a policy change first.
- **D13. The starter podcast list is rebuilt from each show's own feed**, with no Apple chart data or Apple-hosted artwork (#1732). This was Cole's pick on #632.
- **D14. Full transcripts are never shared.** Not with other listeners and not in maps.

## Engineering mitigations filed

- #1728: block repeat abusers by device with DeviceCheck, storing no device ID.
- #1729: Report and Hide this sender in the app, for App Store guideline 1.2.
- #1730: listening maps with anchors that quote nothing, transcripts that never touch disk, and summaries checked for copying.
- #1732: rebuild the starter podcast list from publisher feeds.

The open-source licence is settled (owner, 2026-10-16) and isn't on this list.
