# App Store Connect submission package — Spoken Margins 0.1 (8)

Status: prepared for product-owner entry and confirmation on July 23, 2026.

Source baseline: `1f8f6ef0ef937df6aa2933969af6dad7bc9d9840` plus the
versioned-terms working-tree changes described in this package. Replace this
line with the final submission commit before attaching the processed build.

This package is grounded in the shipping `SpokenMarginsApp` target and its three
embedded extensions. It does not record an App Store Connect submission or an
Apple approval. Text marked `OWNER CONFIRM` must be resolved before submission.

## Release boundary

- Platform: iOS and iPadOS only.
- Minimum OS: iOS/iPadOS 18.0.
- Marketing version: 0.1.
- Build: 8.
- Primary category: Productivity.
- Main bundle: `com.spokenmargins.native`.
- Widget/Live Activity extension: `com.spokenmargins.native.gate2widget`.
- Share extension: `com.spokenmargins.native.share`.
- Safari Web Extension: `com.spokenmargins.native.browsertext`.
- No watchOS app is included in this build. Do not claim Apple Watch support in
  App Store Connect metadata or review notes.
- No app account, subscription, in-app purchase, advertising, analytics, or
  developer-operated backend is included.
- Live AI is optional. Requests go directly from the device to OpenAI using a
  key entered by the user. Non-AI import, listening, interjection, and export
  paths remain available without a key.

## Owner-only stop conditions

- [ ] `OWNER CONFIRM`: the exact processed build is 0.1 (8) from the source
  commit above, or this file is updated to the actual submitted build and SHA.
- [ ] `OWNER CONFIRM`: review contact first name, last name, phone, and email are
  current and monitored. These are provided privately to Apple for review and
  are not the public custom-EULA contact fields being avoided.
- [ ] `OWNER CONFIRM`: the dedicated reviewer OpenAI key works from a clean
  installation, is monitored/revocable, and is entered only in App Store
  Connect review notes.
- [ ] `OWNER CONFIRM — LEGAL`: Spoken Margins is permitted to access the
  user-selected third-party sources described under Content Rights in every
  distribution territory selected in App Store Connect.
- [ ] `OWNER CONFIRM — LEGAL`: Spoken Margins Terms of Use version 1.0 and the
  affirmative in-app acceptance flow satisfy the Supertonic/OpenRAIL-M
  downstream agreement requirement. Use Apple's Standard EULA; do not enter a
  custom EULA in App Store Connect.
- [ ] `OWNER CONFIRM`: App Store Connect generates the expected rating after
  the age-rating answers below are entered; record the generated global and
  regional ratings here.
- [ ] Publish the App Privacy responses after checking the Product Page Preview.

## Public URLs

- Privacy Policy URL:
  `https://spokenmargins.proximitytoprogress.com/privacy/`
- Support URL:
  `https://spokenmargins.proximitytoprogress.com/support/`
- Terms of Use URL:
  `https://spokenmargins.proximitytoprogress.com/terms/`
- Marketing URL, if desired:
  `https://spokenmargins.proximitytoprogress.com/`
- User Privacy Choices URL: leave blank. The app exposes consent revocation,
  API-key deletion, and local-data deletion in Settings; there is no separate
  web privacy-request workflow.

The Privacy and Support URLs returned HTTP 200 during preparation on July 23,
2026. Publish the new Terms page before submission and verify all three URLs.

## TestFlight test information

### Beta App Description

Spoken Margins is a local-first reading and listening workspace for iPhone and
iPad. Import text, PDFs, web articles, and public podcast links; listen with
native media playback or bundled on-device speech; capture spoken
interjections; optionally generate Listening Maps, summaries, and follow-ups;
and export the resulting session. The Share extension and Safari extension
provide user-invoked ways to add source material.

### Feedback Email

`resists.fabric-0o@icloud.com`

`OWNER CONFIRM`: confirm this mailbox is monitored for the entire test period.

### What to Test

Please test text/PDF and public-podcast intake, continuous and offline playback,
chapter navigation, spoken interjections, optional AI Listening Maps and
follow-ups, session export, the system Share extension, and user-invoked Safari
page capture. Podcast episodes stream immediately and download automatically
on Wi-Fi for offline listening. Settings offers a 1/2/5/10/20 GB podcast cache
with a 5 GB default. Spoken Margins has no watchOS app in this build.

### Sign-in Required

No. Spoken Margins has no app account or sign-in requirement.

### Beta App Review Notes

Spoken Margins has no app account or sign-in requirement. A fresh installation
includes “Welcome to Spoken Margins,” which demonstrates local listening,
navigation, spoken interjection, and export without network access or an API
key.

Optional AI features call the OpenAI Responses API directly from the device.
For review, enter the dedicated reviewer key below in Settings, then save it:

`[PASTE DEDICATED REVIEWER KEY IN APP STORE CONNECT ONLY — NEVER COMMIT IT]`

At the first live AI action, the app discloses the source and conversation text
that may be sent to OpenAI and requires explicit permission. The app does not
send recorded audio, local file paths, or internal database identifiers.
Requests set OpenAI response storage to false. To exercise AI, import a text or
PDF item, generate a Listening Map, record an interjection and generate its
summary, then submit a follow-up. Settings provides both Revoke Permission and
Delete API Key actions.

The Share extension accepts a web page or URL, selected text, a public
podcast/audio URL, PDF, Markdown, or plain-text file when the reviewer
explicitly invokes the system share sheet.

The Safari Web Extension has only `activeTab`, `scripting`, and
`nativeMessaging` permissions. It reads the active page only after the reviewer
opens the extension and selects either Selected Text or Readable Page. It does
not run continuously, retain browsing history, or request blanket website
access. The captured payload is written to the app's local shared container.

The bundled James and Lily voices use the Supertonic 3 model locally through
ONNX Runtime. Spoken text is not sent to Supertone. A fresh installation uses
the iOS system voice. To enable James or Lily, open Settings, select that voice,
review Spoken Margins Terms of Use version 1.0, and tap Agree and Enable
On-Device Voice. Declining keeps the iOS system voice enabled. The accepted
terms version and date are stored locally. Complete model and software license
notices are available in Settings → Support & Privacy → Legal · On-Device
Voice.

The app also includes a Widget/Live Activity compact-control extension. It
reads only playback state from the local app-group container and provides
playback/interjection commands to the main app.

### Review Contact

- First name: `[OWNER ENTER]`
- Last name: `[OWNER ENTER]`
- Phone: `[OWNER ENTER PRIVATE APPLE REVIEW CONTACT — INCLUDE COUNTRY CODE]`
- Email: `resists.fabric-0o@icloud.com` (`OWNER CONFIRM`)

## App Privacy

### Collection declaration

Select **Yes, we collect data from this app**.

Apple defines collection as off-device transmission that allows the developer
or a third-party partner to retain readable data longer than the time needed to
service the request. OpenAI may retain standard abuse-monitoring logs even
though Spoken Margins sends `store: false`, so the conservative declaration is
to disclose the optional live-AI text flow.

### Declare this data type

| App Store Connect field | Answer | Evidence and rationale |
| --- | --- | --- |
| User Content → Other User Content | Collected | Optional AI requests can include source excerpts, interjection transcripts, follow-up text, nearby anchors, and recent conversation text. |
| Used for tracking | No | No advertising, data-broker sharing, cross-app tracking, or tracking SDK is present. |
| Linked to the user | Yes | Conservative answer: OpenAI processes the request under the API project represented by the key supplied for the request. |
| Purpose | App Functionality | The text is used only to produce the user-requested Listening Map, summary, or response. |

### Do not declare these data types for build 8

- Contact information, health/fitness, financial information, location,
  contacts, photos/videos, purchases, identifiers, usage data, diagnostics,
  surroundings, or body data: the app does not transmit these categories to
  the developer or an integrated service.
- Audio Data: recordings remain local. Speech transcription requires
  on-device recognition; recorded audio is not included in OpenAI requests.
- Browsing History: the Safari extension reads only the active page after a
  user invokes a capture action. It does not collect or transmit browsing
  history. A selected page excerpt may later be included as Other User Content
  only if the user separately initiates and consents to an AI request.
- Customer Support: diagnostics are copied locally for the user to review and
  send through their chosen email client. There is no in-app support upload.

### Tracking and domains

- Tracking: No.
- App Tracking Transparency prompt: Not applicable.
- Tracking domains: None.

### Binary/privacy-manifest consistency

- Main app manifest: Other User Content; linked; App Functionality; no
  tracking; UserDefaults and file-timestamp required-reason APIs.
- Widget manifest: no collected data; UserDefaults required-reason API.
- Share extension manifest: no collected data; file-timestamp required-reason
  API.
- Safari extension manifest: no collected data and no tracking.

## Content Rights

### App Store Connect selection

For **Does your app contain, show, or access third-party content?**, select
**Yes**.

For the follow-up attestation that the app has the necessary rights or is
otherwise permitted to use that content, select **Yes only after the product
owner/legal confirmation below is complete**. This is an owner attestation,
not a conclusion established by automated tests.

### Rights boundary to confirm

- Users deliberately provide or select web pages, documents, text, and source
  links for private local listening and annotation.
- Podcast discovery resolves user-supplied links to public publisher feeds and
  publisher-provided RSS enclosure URLs. Streaming/offline caching uses those
  public enclosure URLs.
- The app does not bypass paywalls, authentication, DRM, or technical access
  controls.
- The app does not download protected Apple Music or Spotify media. Apple
  Podcasts and Spotify pages may be used as discovery references only; playable
  audio must resolve to a permitted public source.
- The app preserves source titles and URLs where available.
- The app does not publish or redistribute downloaded source audio.
- Exports are user-directed and should contain the user's notes plus bounded
  source context, not full third-party source material by default.

### Optional review-note explanation

Spoken Margins is a private, user-directed reader and podcast client. Users
choose the pages, documents, and source links they import. Podcast playback and
offline caching use public enclosure URLs published in podcast RSS feeds. The
app does not bypass access controls, download protected Apple Music or Spotify
media, or redistribute downloaded source audio. Source attribution is retained
where available.

`OWNER CONFIRM — LEGAL`: confirm that this boundary and the selected
distribution territories are supportable before making the App Store Connect
rights attestation.

## Export Compliance

### Binary declaration

The main app contains `ITSAppUsesNonExemptEncryption = false`.

### App Store Connect answers

- The app uses standard HTTPS/TLS through Apple's `URLSession` and Apple
  Keychain services.
- It does not implement proprietary or non-standard cryptography, provide VPN
  or secure-messaging functionality, or expose encryption as a primary feature.
- Expected classification: only exempt encryption; no export documentation or
  `ITSEncryptionExportComplianceCode` expected.

App Store Connect's wording can vary. If it asks whether the app uses *any*
encryption, answer that it uses standard OS-provided HTTPS/Keychain encryption,
then select the exemption path. Do not claim that the app performs no
encryption at all. If App Store Connect produces a documentation request from
those facts, stop and resolve the generated questionnaire rather than changing
the binary declaration to bypass it.

`OWNER CONFIRM`: verify the processed build shows export compliance complete
before submission.

## Age Rating

### Recommended posture

Use a conservative editorial-content rating rather than claiming that all
user-selected articles and podcasts are child-directed. The answers below are
expected to produce a global **13+** rating on current Apple OS versions and a
roughly corresponding **12+** rating on earlier systems. App Store Connect is
the authority; record its generated result after entry.

### In-App Controls

- Parental Controls: No.
- Age Assurance: No.

### Capabilities

- Unrestricted Web Access: No. The app has no embedded browser or free web
  navigation. Users explicitly import a URL or invoke Safari capture.
- User-Generated Content: No. User notes remain private/local and are not
  broadly distributed inside the app.
- Social Media: No.
- Social Media Disabled for Users Under 13: No.
- Messaging and Chat: No. AI follow-ups are not communication with another
  user.
- Advertising: No.

### Mature Themes

- Profanity or Crude Humor: Infrequent.
- Horror or Fear Themes: Infrequent.
- Alcohol, Tobacco, or Drug Use or References: Infrequent.

### Medical or Wellness

- Medical or Treatment Information: Infrequent.
- Health or Wellness Topics: None. The app does not author or provide a
  health/wellness program.

### Sexuality or Nudity

- Mature or Suggestive Themes: Infrequent.
- Sexual Content or Nudity: Infrequent.
- Graphic Sexual Content and Nudity: None.

### Violence

- Cartoon or Fantasy Violence: None.
- Realistic Violence: Infrequent.
- Prolonged Graphic or Sadistic Realistic Violence: None.
- Guns or Other Weapons: Infrequent.

### Chance-Based Activities

- Gambling: No.
- Simulated Gambling: None.
- Contests: None.
- Loot Boxes: No.

### Additional Information

- Made for Kids: No.
- Override to Higher Age Rating: Not Applicable.
- Age Suitability URL: leave blank unless a dedicated page is published.

These frequency answers describe incidental material that can occur in
user-selected general-interest articles and podcasts. If the product boundary
changes to unrestricted in-app web navigation, a social feed, direct messaging,
or a catalog of mature material, this questionnaire must be redone.

## Extensions and permissions

### Share extension

Suggested description:

> Add a user-selected web page, URL, text selection, public podcast/audio link,
> PDF, Markdown file, or plain-text file to the local Spoken Margins library.
> The extension acts only when the user invokes the system share sheet and
> writes the selected payload to the app's private shared container.

### Safari Web Extension

Suggested description:

> Send selected text or a readable extraction of the active Safari page to
> Spoken Margins for local listening. The extension uses active-tab access only
> after the user presses an extension action. It does not run continuously,
> retain browsing history, inject advertising, or transmit page content to a
> developer server.

Permission explanation:

- `activeTab`: identify the page the user is explicitly sending.
- `scripting`: run the packaged readable-text extraction on that active page
  after the user chooses an action.
- `nativeMessaging`: write the resulting payload to the containing app's local
  app-group container and open Spoken Margins.
- No persistent host permissions or content scripts are declared.

### Widget and Live Activity extension

Suggested description:

> Display local playback state and provide compact playback/interjection
> controls. It has no analytics, advertising, network transport, or independent
> account state.

## Standard EULA and versioned Spoken Margins Terms

- Leave App Store Connect on Apple's Standard EULA. Do not supply a custom
  EULA.
- Spoken Margins Terms of Use version 1.0 are bundled in the app and published
  at `https://spokenmargins.proximitytoprogress.com/terms/`.
- A fresh installation falls back to the iOS system voice until the current
  terms version is affirmatively accepted.
- Selecting James or Lily presents the complete terms with an explicit Agree
  and Enable On-Device Voice action. Not Now leaves the system voice enabled.
- Acceptance version and date are stored locally. A future material terms
  version will require new acceptance before the affected feature is enabled.
- The renderer has a second acceptance guard, so another runtime path cannot
  initialize Supertonic before acceptance.
- The complete OpenRAIL-M license remains bundled and readable in Settings.

This layered approach avoids publishing the owner's residential address or
personal telephone number in a custom EULA. It does not remove any independent
App Store review-contact or EU DSA trader obligations. Legal/product-owner
review must still confirm that the affirmative terms flow is an enforceable
agreement satisfying paragraph 4(a) of the bundled OpenRAIL-M license.

## Final entry checklist

- [ ] Build 0.1 (8) processed and attached to the external tester group.
- [ ] Privacy, Terms, and Support URLs entered and rechecked.
- [ ] App Privacy response published and Product Page Preview inspected.
- [ ] Content Rights owner/legal attestation complete.
- [ ] Export compliance complete for the processed build.
- [ ] Age-rating answers entered and generated ratings recorded.
- [ ] Share, Safari, and Widget/Live Activity behavior disclosed accurately.
- [ ] No Apple Watch support claimed.
- [ ] Apple Standard EULA retained; App Store Connect custom EULA field is empty.
- [ ] Terms version 1.0 legally approved, published, and matched to the bundled
  copy.
- [ ] Clean-install test confirms James/Lily are gated while the iOS system
  voice remains available before acceptance.
- [ ] Beta description, What to Test, feedback email, and review contact entered.
- [ ] Dedicated reviewer key tested from a clean install and pasted only into
  App Store Connect.
- [ ] Review notes contain exact AI and extension steps.
- [ ] External tester group created, processed build attached, and submitted to
  TestFlight App Review.

## Audit and stopping rules

Stop submission if any of the following is true:

- a placeholder remains in App Store Connect;
- the build or SHA differs from the identity at the top of this file without an
  updated validation record;
- the reviewer key fails Listening Map, summary, or follow-up generation from a
  clean installation;
- App Privacy answers differ from the binary, privacy manifests, or public
  privacy policy;
- content-rights permission cannot be supported for a source type or selected
  territory;
- App Store Connect requests export documentation that has not been cleared;
- the generated age rating conflicts with the answers;
- any metadata claims watchOS support;
- the public and bundled Terms differ, legal review is incomplete, or
  Supertonic can initialize without acceptance of the current terms version.

## Apple references checked July 23, 2026

- App Review Guidelines:
  https://developer.apple.com/app-store/review/guidelines/
- App privacy details and the definition of collection:
  https://developer.apple.com/app-store/app-privacy-details/
- App information, including Content Rights:
  https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
- Age-rating categories and values:
  https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/
- Export compliance overview:
  https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance
- Apple's Standard EULA:
  https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
- TestFlight test information:
  https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information
