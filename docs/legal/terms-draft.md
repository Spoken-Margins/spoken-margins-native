# Terms of Use redline (DRAFT)

> **DRAFT. Not legal advice.** A redline of `App/SpokenMarginsApp/Resources/Legal/SPOKEN_MARGINS_TERMS_OF_USE.txt` (version 1.0, effective July 23, 2026) for Cole and an attorney to review (#455, part of #173). Nothing here is published, and the bundled Terms and `Site/terms/` are unchanged.

## Read this first

- **Changing the Terms needs a version bump.** The app enables the on-device voice (James, Lily) only when the accepted version equals `SpokenMarginsTerms.currentVersion` (`App/SpokenMarginsApp/Sources/SpokenMarginsApp/SpokenMarginsTerms.swift:4`, `:20-22`). Publishing a new text means bumping that constant and updating both the bundled file and the public page together (`docs/legal/spoken-margins-terms.md`, "A future material revision increments…"). Every listener then has to accept again before the voice works; until then the app falls back to the iOS system voice.
- **An option to raise with the attorney** ([attorney-questions.md](attorney-questions.md), question 11): put the share-link terms in a separate agreement shown the first time someone creates a share link, and leave the voice Terms at 1.0. This draft is written as one document so the full text is in one place; splitting it is mechanical.
- **Share links don't exist in the app yet.** The server side is #486; `next` has no client code that uploads a packet. Sections 5A and 5B describe the design in #486 (30 days, report button, takedown) and should be checked against the shipped feature before publishing.
- **Blanks** are marked `[[like this]]`.

Markup: ~~struck~~ text is removed; **bold** text is added; unmarked text is unchanged.

---

SPOKEN MARGINS TERMS OF USE

Version ~~1.0~~ **[[2.0]]**
Effective ~~July 23, 2026~~ **[[date]]**

These Terms of Use ("Terms") are between you and ~~the developer of Spoken Margins~~ **[[the developer's legal name, or the LLC]]** ("Developer"). They supplement, and do not replace, Apple's Standard Licensed Application End User License Agreement ("Apple Standard EULA"). If these Terms conflict with the Apple Standard EULA, the Apple Media Services Terms and Conditions, applicable App Store Usage Rules, or law that cannot be waived, those controlling terms or laws apply.

1. Acceptance and scope

By tapping "Agree and Enable On-Device Voice," you accept this version of the Terms. **If you create a share link before you have accepted this version, Spoken Margins will ask you to accept it first.** Spoken Margins records the accepted version and acceptance date locally on your device. You may continue using the iOS system voice without accepting these Terms. If a future material change affects your obligations, Spoken Margins will require acceptance of the new version before enabling the affected feature.

2. User-selected content

Spoken Margins is a private reading and listening tool. You are responsible for ensuring that you have the rights and permissions necessary to access, copy, download, process, synthesize, annotate, or export the source material you select. You may not use Spoken Margins to bypass authentication, paywalls, digital rights management, or other technical access controls, or to infringe another person's intellectual-property, privacy, publicity, or other rights.

3. On-device synthesized voice

Spoken Margins includes the Supertonic 3 machine-learning model under the BigScience Open RAIL-M License. The complete license is included in Spoken Margins at Settings > Support & Privacy > Legal > On-Device Voice and is incorporated into these Terms by reference.

You agree to comply with paragraph 5 and Attachment A of the Open RAIL-M License. You must not use the model, a derivative of the model, or its output for an unlawful purpose; to exploit or harm minors; intentionally to create or spread harmful falsehoods or harmful personally identifiable information; to defame, harass, discriminate against, or impersonate another person without consent; to make fully automated decisions that adversely affect legal rights; to provide medical advice or interpret medical results; or for the prohibited justice, law-enforcement, immigration, or asylum uses described in Attachment A. You must provide an intelligible disclosure when distributing machine-generated content.

Voice synthesis runs locally. Spoken Margins reads text selected by you and does not author, endorse, interpret, or verify that text. You remain responsible for the selected text and for any use or distribution of synthesized output.

4. External services

Spoken Margins may retrieve user-selected material from third-party services and websites, including public source websites, podcast feeds and media hosts, Spotify's public metadata service, and Apple's public podcast search and lookup services. **If you connect a Readwise Reader or Raindrop.io account, or enter your own OpenAI API key, Spoken Margins sends requests to that service with the credential you provide, and your use of it is governed by that service's terms.** Those services may be governed by separate terms, and you must comply with applicable third-party terms.

**Spoken Margins also fetches app content, such as the introductory tour and the starter podcast list, from a server the Developer operates. The Privacy Policy describes what that server receives and keeps.**

5. Privacy

Spoken Margins' data practices are described in the Privacy Policy at https://spokenmargins.proximitytoprogress.com/privacy/. Local library data, recordings, transcripts, and settings remain on your device **unless you share or export them**. ~~Outside services receive information only when needed to retrieve a source you select or when you deliberately share or export content to a destination you choose.~~ **Outside services receive information when Spoken Margins retrieves a source you select or follow (including automatic refreshes of sources you follow), when it fetches app content from the Developer's server, and when you deliberately share or export content to a destination you choose.**

**5A. Sharing Margins by link**

**When you create a share link, Spoken Margins uploads the packet you chose (your Margins, their audio and text, the source's title and address, and any sender name you typed) to the Developer's server. Anyone who has the link can open a web page that shows your Margin text, the source title and the show, and can download the packet. The server never serves the source's audio.**

**You keep ownership of what you share. You give the Developer a worldwide, non-exclusive, royalty-free permission to store, copy, display, and transmit the shared packet and its preview only to operate the link for as long as it is kept. You confirm that you have the right to share what you upload, including anything you quote, and that it does not violate these Terms or anyone's rights.**

**You must not use share links to share content you do not have the right to share, to harass, defame, or threaten anyone, to share another person's private information, or to spread malware or spam. The Developer may refuse, remove, or disable any share link, and may block an installation of the app from creating share links, at its discretion and without notice.**

**5B. Retention and removal**

**A share link and its stored packet are deleted [[30 days]] after the link is created. The Developer may delete them sooner in response to a report, a legal request, or abuse. Deleting the app or the Margin on your device does not delete a link you already created; [[to remove it sooner, contact the Developer at the address in section 8 / use Delete link in the app]].**

**5C. Copyright complaints**

**If you believe a share link infringes your copyright, send a notice to the Developer's designated agent: [[agent name, address, email]]. The notice must include the information required by 17 U.S.C. § 512(c)(3), including the link, the work you believe is infringed, and a statement under penalty of perjury that you are the owner or authorized to act for the owner. The Developer will remove or disable access to the material it identifies. If your link was removed and you believe that was a mistake, you may send a counter-notice as described in 17 U.S.C. § 512(g). The Developer will [[block installations that repeatedly share infringing material from creating share links]]. Anyone can also report a link with "Report this link" on its page.**

6. Third-party software and model licenses

Open-source software and model components remain subject to their applicable licenses and notices, which are included in Spoken Margins. If these Terms conflict with an applicable open-source or model license regarding that component, the component's license controls for that component.

7. Changes

The Developer may revise these Terms prospectively as Spoken Margins evolves. The version and effective date will identify each revision. A material revision that changes your obligations will not enable an affected feature until Spoken Margins presents the new version and you affirmatively accept it.

8. Support

Questions about these Terms or Spoken Margins may be sent to resists.fabric-0o@icloud.com. **[[Keep, or replace with the support address Cole chooses for the App Store listing (#173).]]**

---

## Notes on each change

| Change | Why | Evidence |
|---|---|---|
| Version and effective date | Share links add obligations (5A), so this is a material revision under section 7 | `SpokenMarginsTerms.swift:4-5` |
| Developer's legal name | "the developer of Spoken Margins" names no one; the seller name depends on the LLC question | attorney questions 1-3 |
| Section 1, acceptance before a share link | Otherwise someone who never enabled the voice could share without having accepted any terms | today acceptance is tied to the voice only (`docs/legal/spoken-margins-terms.md`, "Supertonic gate") |
| Section 4, Readwise, Raindrop, OpenAI | The app connects to them with the listener's own credential | `Packages/SessionKit/Sources/SessionKit/ReadLaterClient.swift:29-36`; `App/SpokenMarginsApp/Sources/SpokenMarginsApp/OpenAIResponsesClient.swift:30` |
| Section 4, the Developer's server | The app fetches onboarding content from it at launch | `App/SpokenMarginsApp/Sources/SpokenMarginsApp/GuidedOnboardingCoordinator.swift:30`; `Packages/SessionKit/Sources/SessionKit/SourceCatalogStore.swift:32` |
| Section 5, struck sentence | Followed feeds refresh without a tap, and launch fetches the tour | see the privacy draft's table |
| 5A, 5B | Share links host user content on the Developer's server for 30 days | #486 |
| 5C | The § 512 safe harbor needs a designated agent, a notice process and a repeat-infringer policy | attorney questions 4-5 |
| Section 8, contact (unchanged unless Cole picks another) | The support address for the listing is still an open owner choice | #173 |
