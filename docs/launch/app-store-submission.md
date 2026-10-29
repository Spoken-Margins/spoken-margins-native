# App Store submission answers (DRAFT)

**Status: DRAFT for Cole's review. Nothing here has been entered in App Store Connect, posted or published.** This page drafts the answers #175 needs and checks them against the code on `next` at `70f043f` (2026-09-30). Paths are shortened:

- `A/` is `App/SpokenMarginsApp/Sources/SpokenMarginsApp/`.
- `M` is `A/Gate1AppModel.swift`.
- `SK/` is `Packages/SessionKit/Sources/`.

Re-check the citations if the network code changes before submission.

## 1. App Privacy ("nutrition label")

### Short answer

- **Does the app collect data?** Draft answer: **Yes, one type: "Other User Content", linked to the user, not used for tracking.** The reason is the optional Readwise sync (row 12): when a listener turns on "Send Margins to Readwise", Margin text and the passage around it go from the phone to their own Readwise account. Over-declaring is safe; under-declaring is the compliance risk (owner's walkthrough on #175, 2026-10-17). Whether that sync is "collection" at all is attorney question 7 ([attorney-questions.md](../legal/attorney-questions.md)). Nothing else is collected, on one condition (question Q1): the owner's server must keep no logs that tie an IP address to a request beyond serving it.
- **Tracking:** No. The app has no ad or analytics SDK and never calls App Tracking Transparency, AdServices, `ASIdentifierManager` or `identifierForVendor`. The only packages are onnxruntime 1.24.2 and ZIPFoundation 0.9.20.

### What leaves the device

Apple counts data as "collected" when it leaves the device and the developer or the developer's partners can keep it longer than it takes to answer the request. The app has no account, backend database, analytics or crash SDK. Everything that does leave the device:

| # | When | Where it goes | What goes out | Code |
|---|---|---|---|---|
| 1 | **Every launch, automatically** | `spokenmargins.proximitytoprogress.com/onboarding/v1/manifest.json`, then its tour audio (the owner's server) | Nothing beyond the request itself (IP address) | `M:15623`, `SK/SessionKit/GuidedOnboardingCoordinator.swift:42`, `:64`, `:86`, `:95` |
| 2 | First run: the podcast drawer opens by itself | `spokenmargins.proximitytoprogress.com/onboarding/catalog/v1/` (owner's server), then each show's artwork from the show's own publisher or image host (about 25 hosts, #1732) | Nothing beyond the request | `SK/SessionKit/SourceCatalogStore.swift:32`, `:168-174`; `A/CatalogDrawer.swift:59`, `:232` |
| 3 | Following a show or site (user), then an **automatic refresh** at launch, at most every 6 hours | The feed or site the user followed; `substack.com` for Substack links | The feed URL (a private feed URL can carry a token), plus ETag and If-Modified-Since | `A/FollowedSourceCoordinator.swift:197`, `:292`, `:334`, `:349`; `SK/SessionKitFeeds/SubstackPublicationResolver.swift:119`; `M:15622` |
| 4 | User pastes or shares a podcast link; also when **importing someone else's packet** | `itunes.apple.com/lookup` and `/search`, `open.spotify.com/oembed` and `/embed`, publisher pages and feeds | The pasted link. For a Spotify link, the episode title as a search term | `A/PublicPodcastLinkResolver.swift:402-421`, `:1284`, `:1388`, `:1410`; packet import `M:8208` |
| 5 | After a podcast import that lists transcripts, **automatically** | The publisher's transcript URL | Nothing beyond the request | `M:12196` (scheduled at `M:3277`) |
| 6 | Playback (user), offline download (**automatic on Wi-Fi**, user-only on cellular), and transcribing a short window of a streamed episode's audio after a Margin is recorded (**automatic**) | The episode's audio host | The enclosure URL | `SK/SessionKitAudio/AudioAdapters.swift:1855`, `:3615-3626`; `A/PodcastDownloadCoordinator.swift:453`, `:472`; `SK/SessionKit/PodcastDownloads.swift:153-158` |
| 7 | User adds an article (share, paste, Safari extension handoff, followed article, Read Later) | The article's site, in a hidden non-persistent web view with page scripts and images blocked | The article URL | `A/AppOwnedReadablePageExtractor.swift:53-69` |
| 8 | User shares a PDF link | The PDF's host | The PDF URL | `M:3557` |
| 9 | User connects Readwise Reader or Raindrop.io, and taps Refresh | `readwise.io/api/v3/list/`, `api.raindrop.io/rest/v1/raindrops/0` | The user's own access token. It is kept in the Keychain as `WhenUnlockedThisDeviceOnly` (`A/ReadLaterModel.swift:21`, `M:16835`) | `SK/SessionKit/ReadLaterClient.swift:29-36`; `A/ReadLaterModel.swift:52` |
| 10 | **Removed (#2845).** The OpenAI client and its settings are no longer in the app, so nothing is sent to `api.openai.com` | — | — | `git grep api.openai.com -- App Packages/SessionKit/Sources` finds nothing |
| 11 | First on-device transcription | Apple's speech-model download (`AssetInventory`) | The locale | `SK/SessionKitAudio/AudioAdapters.swift:226-229` |
| 12 | **Off by default.** The listener turns on "Send Margins to Readwise" in Settings. Then the app checks once a minute while it is open, including Margins that already exist when it is first turned on | `readwise.io/api/v2/highlights/` (Readwise, with the listener's own token; no Spoken Margins server) | For each Margin with text: the Margin text (as the note; for a spoken Margin, its transcribed words), the source passage around it (as the highlight), the item's title, author, a shareable source URL (private feed links are dropped), category and creation time. Recording audio is not sent | `A/ReadwiseHighlightSync.swift:12`, `:33-45`, `:89-114`; `SK/SessionKit/ReadwiseHighlightClient.swift:8-52`, `:79`; toggle text `A/PKMSettingsViews.swift:427-430` |

Also checked, and nothing leaves the device:

- **Speech recognition** runs on the device. Every request sets `requiresOnDeviceRecognition = true` (`SK/SessionKitAudio/AudioAdapters.swift:297`).
- **Microphone recordings** (Margins) stay in local files. They leave only when the user exports a packet through the share sheet (`A/SharingExperience.swift:868`, `A/ExportScreen.swift:116`, `:204`).
- **Packets** hold the Margins' audio and text, the source URLs, fingerprints, and an optional sender label the user types (`A/SharingExperience.swift:79`, `:287`). The app never uploads a packet: no share-link server is wired up, and the entitlements hold only the app group.
- **ShazamKit** matches against a catalog built on the device (`SK/SessionKitAudio/PodcastAnchorEvidence.swift:285`, `:354`), never Shazam's servers.
- **Share, Safari and widget extensions** make no network calls. The Live Activity has no push (`pushType: nil`).
- **Not present anywhere:** analytics, crash reporting SDKs, MetricKit upload, remote push, CloudKit or iCloud, Sign in with Apple, location, contacts, photos, health, StoreKit.
- **Never called today:** a server-config fetch (`SK/SessionKit/BridgeManifestStore.swift:11-12`) and a podcast name search (`SK/SessionKit/ITunesSearchSourceResolver.swift`) exist, but nothing creates them. Re-check this page if either gets wired up.

### Answer per data type

Every answer below is **Not collected** except one: **User content: other** is declared as collected, linked to the user, not used for tracking, because of the Readwise sync (row 12). That is the conservative reading; the other answers make "Linked to identity" and "Used for tracking" moot. The reason column says why.

| Apple data type | Answer | Why |
|---|---|---|
| Contact info: name, email, phone, address, other | Not collected | No account or sign-in. The packet sender label is typed by the user and goes only where they send the file (row "Packets" above) |
| Health, fitness | Not collected | No HealthKit |
| Financial: payment, credit, other | Not collected | No StoreKit, no purchases |
| Location: precise, coarse | Not collected | No Core Location. The owner's server sees IP addresses at launch (row 1); see Q1 |
| Sensitive info | Not collected | — |
| Contacts | Not collected | — |
| User content: audio | Not collected | Recordings stay on the device and are shared only as a file the user sends |
| User content: other (Margin text, notes) | **Collected: "Other User Content", linked to the user, not used for tracking** | Only if the listener turns on "Send Margins to Readwise": Margin text and the passage around it go to their Readwise account (row 12). Everyone else's Margin text stays on the device and is shared only as a file the user sends. It would also be "shared with OpenAI" if `SMRemoteProviderExperienceEnabled` is turned on (row 10) |
| User content: emails or texts, photos or videos, gameplay, customer support | Not collected | Support is by email from the user's own mail app |
| Browsing history | Not collected | Article and feed URLs go only to the site itself (rows 3, 7) |
| Search history | Not collected | Episode titles go to Apple's iTunes Search to answer the request (row 4). The app keeps no search history of its own |
| Identifiers: user ID, device ID | Not collected | None created or sent |
| Purchases | Not collected | — |
| Usage data: product interaction, advertising, other | Not collected | Playback events are logged on the device only (`M:628`). Diagnostics go out only when the user copies them into an email (`A/SettingsScreen.swift:351`) |
| Diagnostics: crash, performance, other | Not collected | No crash SDK. Crash logs reach the developer only through Apple's own opt-in sharing (Xcode Organizer). Check Apple's current guidance on declaring that at submission (#175, "Crash reporting through Xcode Organizer") |
| Surroundings, body | Not collected | — |
| Other data | Not collected | Readwise and Raindrop tokens go only to the user's own account at that service (row 9). The Margin text sent to Readwise is under "User content: other" above |

### Mismatches with the privacy manifests

The answers agree with `App/SpokenMarginsApp/Sources/PrivacyInfo.xcprivacy`: it declares `NSPrivacyTracking` false and one collected data type, `NSPrivacyCollectedDataTypeOtherUserContent` (linked, not tracking, purpose App Functionality), which matches the label above. The required-reason API declarations didn't agree with the code in three places. All three are now fixed:

1. **Disk space, main app.** `Packages/SessionKit/Sources/SessionKit/OfflineStorageLedger.swift` (`physicallyAvailableBytes()`) reads `volumeAvailableCapacityForImportantUsageKey` before writing offline audio. Fixed: the manifest now declares `NSPrivacyAccessedAPICategoryDiskSpace` with reasons `E174.1` and `85F4.1` (a refused download tells the listener how many bytes are free), and this is the only disk-space call in the app and SessionKit. Issue: #514.
2. **System boot time, main app.** `ProcessInfo.processInfo.systemUptime` measures elapsed time, for example at `M:646`, `A/SupertonicSpeechPlaybackClient.swift:259` and `A/AutomaticMarginNoteGatherer.swift:19`. Fixed: the manifest now declares `NSPrivacyAccessedAPICategorySystemBootTime` with reason `35F9.1`. Every `systemUptime` read in the app and SessionKit is subtracted from another reading to time something inside the app; no raw uptime value is stored or sent. Issue: #515.
3. **File timestamps, widget.** The widget compiles all of `App/Gate2Shared/Sources` (`project.yml:142-146`), including `SourceLinkHandoff.swift:130-137` and `SpokenMarginsPackageHandoff.swift:96-103`, which read `.contentModificationDateKey`. Its manifest (`App/SpokenMarginsGate2Widget/Sources/PrivacyInfo.xcprivacy`) declares only `UserDefaults`. Fixed: it now declares `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1`, as the Share extension does. Issue: #516. The Share extension and Safari extension manifests match their code.

### The privacy policy doesn't match either

The draft label above describes the app. The public privacy policy (`Site/privacy/index.html`) says the app "connects to outside services only when needed to retrieve a source you select or when you deliberately share". That misses several things the table shows:

- the launch-time fetches from the developer's own server (rows 1 and 2);
- automatic feed refresh, transcript fetches and Wi-Fi downloads (rows 3, 5, 6);
- a recipient's device fetching the source URLs in a packet someone sent them (row 4);
- Readwise and Raindrop (row 9). The policy now covers the optional Readwise sync of Margin text (`Site/privacy/index.html:12-13`); check it matches row 12 when #455 lands.

It also says there is "no developer-operated … backend", but rows 1 and 2 use one. Updating the policy is #455's job; this list is its input.

### Questions for Cole

- **Q1. Server logs.** Does the VPS web server keep access logs (IP address, time, path) for `/onboarding/`? If they're kept only briefly for security, the label stays at "Other User Content" alone. If they're kept longer, or used for anything else, answer "Coarse location" or "Other data" as collected, not linked, not tracking. My pick: keep logs short-lived and say so in the privacy policy.

## 2. App Review notes (DRAFT)

> DRAFT. Spoken Margins needs no account and has no purchases. Everything below works on a fresh install.
>
> **Podcasts:**
> 1. On first launch the "Popular podcasts" drawer opens. Follow any show and open an episode.
> 2. Tap Play.
> 3. While it plays, tap the record button to speak a Margin, or type one. The Margin is anchored to that moment in the episode.
>
> **Articles and PDFs:**
> 1. In Safari, open any article and share it to Spoken Margins, or paste its link into Add.
> 2. The app reads the article aloud.
> 3. Text PDFs work the same way.
>
> **Guided tour:** the library starts with a "Welcome to Spoken Margins" item and a Guided Tour.
>
> **Sharing:**
> 1. Open a Margin and choose Share.
> 2. This exports a `.spokenmargins` file through the iOS share sheet.
> 3. Opening that file on another device imports the Margins, placed in that listener's own copy of the source.
> 4. The attached demo file [DEMO PACKET — TO PREPARE] shows this on a public podcast episode.
>
> **Voices:** the James and Lily voices run on the device. They require accepting the in-app Terms of Use, which supplement Apple's standard EULA. The system voice works without it.
>
> **Permissions:** the microphone is used only to record the Margins you speak. Speech recognition runs on the device.
>
> **Background audio** keeps narration and podcasts playing with the screen locked.
>
> Contact: [SUPPORT CONTACT — TO FILL].

Facts behind the draft:

- First-run content: `M:1836-1848` and `M:2569` (welcome item), `M:1850` and `M:1961` (Guided Tour), `A/CatalogDrawer.swift:45` (the bundled starter catalog, 133 shows since #1732).
- Content types: `A/ExperienceAddSourceFlow.swift:441-449`.
- Package type: `project.yml:92-114`.
- Terms gate: `docs/legal/spoken-margins-terms.md`.
- Purpose strings: `project.yml:119-120`.
- Background modes: `project.yml:122-124`.
- There's no free-text podcast search in this build (#471 would add one), so the notes point the reviewer at the drawer or a pasted link.
- **Demo packet:** the repo has none. `Contracts/fixtures/interjection-packages` holds JSON descriptions, not packets. Before submitting, export one from a TestFlight build on a public episode and attach it.

## 3. Listing (DRAFT)

**Name:** Spoken Margins (`project.yml:67`). **Subtitle, DRAFT:** "Talk back to what you listen to".

**Description, DRAFT:**

> DRAFT. Spoken Margins turns articles, PDFs and podcasts into something you can listen to and answer back.
>
> Listen to a podcast episode, or have an article or PDF read aloud by an on-device voice. When something strikes you, speak or type a Margin. It's pinned to that exact moment in the source.
>
> Share your Margins as a small file. A friend opens it and hears your thoughts at the right place in their own copy of the same episode or article.
>
> - Podcasts from Apple Podcasts, Spotify or RSS links, plus a starter list of popular shows.
> - Articles from Safari, the share sheet or a pasted link, and text PDFs.
> - Natural on-device voices; nothing you record is uploaded.
> - No account, no ads, no tracking.

**Keywords, DRAFT** (100 characters max; this is 96): `podcast,notes,annotate,read aloud,text to speech,listening,margins,articles,pdf,voice memo,share`

**Category:** Productivity (`project.yml:68`, `LSApplicationCategoryType`). **Secondary, DRAFT:** Education.

**Age rating questionnaire, DRAFT:**

| Question | Draft answer | Why |
|---|---|---|
| Unrestricted web access | No | No in-app browser. The only web view is hidden and pulls text from a link the user adds (`A/AppOwnedReadablePageExtractor.swift:30-60`) |
| User-generated content, messaging or chat | No | Margins are shared only as files the user sends. There's no public feed, profile or comment |
| Violence, sexual content, drugs, gambling, horror, medical | None | The app ships no such content |
| Profanity or crude humor; mature themes | **Cole's call, Q2** | See below |
| Contests, loot boxes, in-app purchases | None | No StoreKit |
| Parental controls, age assurance | None | — |

**Q2. Explicit shows in the starter list.** 48 of the 192 bundled podcasts are marked explicit (`Site/onboarding/catalog/v1/catalog.json`, bundled via `project.yml:33`). The model carries the flag (`SK/SessionKit/SourceCatalog.swift:112`), but the drawer neither shows nor filters it. The options:

1. Hide explicit shows from the starter list. The low rating stays honest, at the cost of fewer starter shows.
2. Keep them and answer "infrequent/mild" for profanity and mature themes. That gives a higher age rating.

My pick is option 1, as a small follow-up. Users can still add any feed they like, as in any podcast app.

**Support URL, DRAFT:** `https://spokenmargins.proximitytoprogress.com/support/` (`Site/support/index.html`; the app links it at `A/SettingsScreen.swift:340`). **Privacy policy URL, DRAFT:** `https://spokenmargins.proximitytoprogress.com/privacy/`. **Support contact:** [SUPPORT CONTACT — TO FILL]. Check both URLs are live before submitting.

**Export compliance:** `ITSAppUsesNonExemptEncryption: false` (`project.yml:116`). The app uses only HTTPS and Apple's own encryption.

## 4. Developer-only UI in a Release build

**None is reachable by a user.**

- **Settings → Developer** (reset library, sample content, runtime profile, the listening-map editor) is inside `#if DEBUG` (`A/SettingsScreen.swift:368-414`).
- **"Create Recipient Test Session"** (#150) shows only in Debug (`A/Gate1RootView.swift:138-148`).
- **The OpenAI settings** are hidden by the Info.plist switch (row 10 above).
- **The `spokenmargins://` URL handler** (`M:8386-8454`) has no reset or seed routes.
- **The extensions** have no developer UI.

Test hooks are still compiled into Release, though. None has a button; they can only be reached with a launch argument or environment variable, which Xcode and XCTest can pass and a user or App Review can't. One of them deletes the library, so they should still be compiled out: issue #517.

- `--ui-testing` calls `resetAndSeed()`, which deletes the library and loads a fixture (`M:1830`, `M:2479`). Other `--ui-testing` hooks install fake resolvers and seed data (`M:1041`, `:1288`, `:1304`, `:1341`, `:1349`, `:14877`, `:14900`).
- `SPOKEN_MARGINS_UI_TEST_RECORDING=1`, with `--ui-testing`, swaps the microphone for a recorder that writes a generated tone, and speech recognition for a fixed transcript (`UITestingLaunchSeedWriter.swift`, #685).
- A second "Create Recipient Test Session" button with no guard sits in a view nothing opens (`A/SharingExperience.swift:932`).
- `project.yml:34-37` bundles the test fixtures (about 2 MB) into the app for `resetAndSeed`.

Copy that reads as internal, for the listing pass rather than an issue: `A/SettingsScreen.swift:264` ("disabled in this release") and `A/HelpScreen.swift:85-86` ("future server-hosted option").

## 5. Download size input for #175

Since #1820 the app no longer bundles Supertonic; listeners download it in Settings › Voices. The download is all 23 files (the 16 model files marked `downloaded` in the manifest, the licences and the notice), 148,065,254 bytes, and the app shrinks by the 147,709,674 bytes of model files. Before #1820, the bundled Supertonic 3 INT8 voice was **148,065,254 bytes (148.1 MB, 141.2 MiB)** across 23 files. The four ONNX models are 144,508,203 bytes of that. Source: the sum of `bytes` in `App/SpokenMarginsApp/Resources/Supertonic/asset-manifest.json`. The onnxruntime framework comes on top of that. The real download and install sizes come from App Store Connect's size report for a TestFlight build.

## 6. Licenses and the EULA (#449 item 7)

Checked on `next` at `c951fdb` (2026-10-01). Paths are shortened: `L/` is `App/SpokenMarginsApp/Resources/Supertonic/licenses/`.

### The listing's license text

`docs/legal/spoken-margins-terms.md` already settles the structure: the App Store listing uses **Apple's Standard EULA**, with no custom EULA in App Store Connect. The versioned Spoken Margins Terms of Use supplement it.

- Bundled copy: `App/SpokenMarginsApp/Resources/Legal/SPOKEN_MARGINS_TERMS_OF_USE.txt`.
- Public copy: `https://spokenmargins.proximitytoprogress.com/terms/` (`Site/terms/index.html`).
- The Terms carry the Open RAIL-M paragraph 5 and Attachment A restrictions as an enforceable provision (`SPOKEN_MARGINS_TERMS_OF_USE.txt:18-20`), as paragraph 4(a) requires.
- The app asks the listener to accept the Terms before James or Lily speaks, and checks acceptance again where it renders speech.

The Standard EULA field can't carry extra text, so the listing points to the restrictions in two places:

1. **Last line of the description, DRAFT:**
   > DRAFT. The on-device voices are licensed under the Open RAIL-M License, whose use restrictions are part of the Spoken Margins Terms of Use: https://spokenmargins.proximitytoprogress.com/terms/
2. **App Review notes:** the "Voices" paragraph in section 2 already says the voices require accepting the Terms, which supplement Apple's Standard EULA.

**Q3, for the attorney (#455).** Is a supplement the listener accepts before the voice speaks enough for paragraph 4(a)? Paragraph 4(a) covers any agreement "governing the use and/or distribution" of the model. The model ships to every user under the Standard EULA, but only listeners who choose James or Lily accept the Terms (`SPOKEN_MARGINS_TERMS_OF_USE.txt:10`). The alternative is a custom EULA in App Store Connect: Apple's Standard EULA terms plus the Terms of Use, so everyone who downloads the app agrees to the restrictions.
- **Keep the supplement, as built.** Nothing to change. The gate already covers the only use of the model, but distribution to listeners who never accept is the open point.
- **Custom EULA.** It covers distribution too. It's one more document to keep in step with the Terms.

My pick: ask the attorney. If the answer isn't clear before submission, use the custom EULA, because it's the cautious reading and costs one paste in App Store Connect.

### Every bundled third-party license

| Component | Where it ships | License | App Store distribution | What it asks of us | Met? |
|---|---|---|---|---|---|
| Supertonic 3 model and preset voices (Supertone) | App, `Resources/Supertonic` | BigScience Open RAIL-M (`L/SUPERTONIC_MODEL_OPENRAIL-M.txt`) | Allowed. Paragraph 4 permits distribution "in any medium", subject to 4(a)–(d) | 4(a) restrictions as an enforceable provision and notice to users; 4(b) a copy of the license; 4(c) notices on modified files; 4(d) keep attribution | 4(a): built (the Terms and the voice gate), but whether it's enough is Q3. 4(b): yes, the license is bundled and shown in Settings > Support & Privacy > Legal > On-Device Voice (`App/SpokenMarginsApp/Sources/SpokenMarginsApp/SupertonicLegalView.swift:19-23`). 4(c): **partly**. `L/THIRD_PARTY_NOTICES.txt` says the INT8 graphs are modified, quantized derivatives that were renamed, but the license asks for "prominent notices" on the modified files, and the `.onnx` files themselves carry none: #630. 4(d): yes, the same notice |
| Supertonic Swift inference code (Supertone) | App | MIT (`L/SUPERTONIC_CODE_MIT.txt`) | Allowed | Keep the copyright and permission notice | Yes, bundled and linked from the same screen |
| INT8 model conversion (k2-fsa sherpa-onnx) | App (the converted graphs) | Apache-2.0 (`L/SHERPA_ONNX_APACHE-2.0.txt`) | Allowed | Section 4: a copy of the license, notice of changes, and any NOTICE file | Yes. The license is bundled and linked, and the change is described in `L/THIRD_PARTY_NOTICES.txt` |
| ONNX Runtime 1.24.2 (Microsoft), via `onnxruntime-swift-package-manager` | App, linked framework | MIT (`L/ONNXRUNTIME_MIT.txt`) | Allowed | Keep the notice | Yes, bundled and linked |
| ONNX Runtime's own third-party components | Inside the framework | Listed in `L/ONNXRUNTIME_THIRD_PARTY_NOTICES.txt`: MIT, BSD, Apache-2.0 (including OpenSSL), zlib, Boost, ISC, the Unlicense (G3log), the PIL/HPND license, public domain (SQLite), the Intel Simplified Software License, and MPL-2.0 (Eigen) | Allowed. None is GPL or LGPL; the only copyleft is Eigen's MPL-2.0, which is file-level | Keep the notices. MPL-2.0 §3.2 also asks that recipients be told where Eigen's source is | Yes. The file is bundled and linked unchanged. Microsoft's notice gives its source-request address, and Eigen is unmodified and public at gitlab.com/libeigen/eigen |
| ZIPFoundation 0.9.20 (Thomas Zoechling) | App, Swift package | MIT (`App/SpokenMarginsApp/Resources/Legal/ZIPFoundation-LICENSE.txt`) | Allowed | Keep the notice "in all copies" | The file is in the app bundle, but no screen shows it. Fine for MIT; adding it to the Legal screen is good practice (#630) |
| Defuddle 0.19.5 (Steph Ango) | App, Safari extension and Share extension, compiled into `browserTextCapture.js` and `SourceLinkPreprocessor.js` | MIT (`App/SharedResources/Defuddle-LICENSE.txt`, and a copy in the Share extension) | Allowed | Keep the notice | The file is bundled beside each script but not shown in the app |
| Defuddle's bundled dependencies: turndown, temml, mathml-to-latex, @xmldom/xmldom | The same two scripts | MIT (per `package-lock.json`) | Allowed | Keep each notice | **No.** `Tools/BrowserExtraction/build.mjs` builds with `legalComments: "none"` and copies only Defuddle's LICENSE, so these notices ship nowhere: #630 |
| Swift packages | — | — | — | — | Only onnxruntime and ZIPFoundation (`Packages/SessionKit/Package.swift:21-30`, `Package.resolved`). `swift-crypto` is Linux-only (`Package.swift:139-142`) and never ships |

Data bundled in the app that isn't open-source software:

- **Starter podcast catalog.** `Site/onboarding/catalog/v1/catalog.json` is bundled (`project.yml:33-34`). Since #1732 it is built from a hand-picked list of shows (`research/B1/shows.json`), and each row's title, author, description and artwork URL come from that show's own feed. It carries no Apple chart data and no Apple-hosted artwork; `scripts/validate-contracts.py` fails the build if either returns. It used to be built from Apple's Top Charts RSS feeds: see "The starter podcast catalog" below (#632).
- **Test fixtures and traces.** `Contracts/fixtures` (about 2 MB, including iTunes Search responses and OPML from real feeds) and `Contracts/traces` are bundled (`project.yml:35-38`) only for the test hooks. #517 already plans to stop shipping the test hooks; these folders should leave the Release build with them.

No bundled license forbids App Store distribution or conflicts with Apple's Standard EULA. None is GPL or LGPL, and the only copyleft is Eigen's file-level MPL-2.0, satisfied by the source pointer above.

Follow-up issues: #630 (notices for Defuddle's bundled dependencies, a modified-files notice beside the model, and an in-app screen for every license) and #632 (the starter catalog's terms).

### The starter podcast catalog (#632)

Checked 2026-10-03 on `next` at `b26e133`. This is research, not legal advice.

**Settled 2026-10-17 (#1732):** Cole picked option 3 below, and the bundled catalog is rebuilt that way, so the rest of this section describes the catalog before that change (content version 2). It is kept as the record of why. Search results in the podcast list's search field (#471) still load artwork from Apple's image server; that is a separate path.

**Short answer: not clearly allowed.** No public Apple term we found grants a right to bundle a list built from the Top Charts feeds in an app. (Apple Media Feeds, the bulk data "for partners to fully incorporate aspects of content into a website or app", is a partner program we're not in.) The artwork terms that do exist allow it only on pages that promote it, beside a link to Apple's store, which the drawer doesn't have. So the question goes to the attorney (Q19 in `docs/legal/attorney-questions.md`, #455).

**What ships.** `catalog.json` (content version 2) has 200 shows:
- **192 from Apple.** They come from 12 US Top Charts genre feeds on the legacy iTunes RSS endpoint (`https://itunes.apple.com/us/rss/toppodcasts/limit=40/genre=<id>/json`), filled in through the iTunes Lookup API (`provenance` ids `apple-top-us-*` and `itunes-lookup`).
  - Each row bundles the title, author, the publisher's feed URL, the Apple Podcasts id, the chart rank and the explicit flag (48 of the 192 are explicit).
  - Each row also bundles an `artworkURL` on Apple's image server (`is1-ssl.mzstatic.com`). The image isn't in the bundle: the drawer loads it from Apple at runtime (`CatalogDrawer.swift:269`). The drawer shows no Apple attribution and no link to Apple Podcasts.
- **8 hand-picked** Substack publications (`hand-picked-writers`), with Substack-hosted artwork. They are not affected.

**The terms that apply.**

1. **The chart feeds carry no license.** The feeds themselves say only `"rights": "Copyright 2008 Apple Inc."` (legacy endpoint) or `"copyright": "Copyright © 2026 Apple Inc. All rights reserved."` (the current `rss.marketingtools.apple.com` API), as fetched 2026-10-03. Apple's marketing-tools page describes the RSS Feed Generator only as: "You can add these feeds to your website or view them using a standard RSS feed reader." ([Marketing Resources & Tools](https://performance-partners.apple.com/tools)). The generator site links no terms of its own.
2. **Apple's website Terms of Use may cover the rest.** They govern apple.com and the sites it links to; whether that reaches the feed endpoints and the `mzstatic` image server is itself a question for the attorney. They say: "Except as expressly provided in these Terms of Use, no part of the Site and no Content may be copied, reproduced, republished, uploaded, posted, publicly displayed, encoded, translated, transmitted or distributed in any way (including "mirroring") to any other computer, server, Web site or other medium for publication or distribution or for any commercial enterprise, without Apple's express prior written consent." "Content" includes "the design, structure, selection, coordination, expression, "look and feel" and arrangement of such Content" ([Apple Website Terms of Use](https://www.apple.com/legal/internet-services/terms/site.html)). A ranked chart is a selection and arrangement.
3. **Artwork and Lookup data come under the Search API's Promo Content terms.** "Developers may use promotional content in the API, including previews of songs, music videos, album art and App icons only to promote store content and not for entertainment purposes." In full, Promo Content may be used "for the purposes of promoting the subject of the Promo Content; provided such Promo Content: (i) is placed only on pages that promote the content on which the Promo Content is based; (ii) is proximate to a "Download on iTunes" or "Download on App Store" badge (as approved by Apple) that acts as a link directly to pages within iTunes where consumers can purchase the promoted content; [...] (v) is not used for independent entertainment value apart from its promotional purpose; and (vi) is not used to promote any other goods or services." ([iTunes Search API, Legal](https://performance-partners.apple.com/search-api)). The drawer shows Apple-hosted artwork with no Apple badge or link, inside an app that is not Apple Podcasts.
4. **App Review checks for permission.** Guideline 5.2.2: "If your app uses, accesses, monetizes access to, or displays content from a third-party service, ensure that you are specifically permitted to do so under the service's terms of use. Authorization must be provided upon request." Guideline 5.2.1: "Don't use protected third-party material such as trademarks, copyrighted works, or patented ideas in your app without permission" ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)). We have no authorization to show.

**What is probably fine.** Plain facts, such as a show's title, author and feed URL, are generally not protected one by one, and podcast apps routinely show the artwork a publisher puts in its own public feed (`<itunes:image>`). Rebuilding the rows from each publisher's feed avoids Apple's terms for everything except the choice of shows.

**Options for the attorney question:**
1. **Keep it as built.** Nothing changes. It relies on the terms above not reaching a bundled list, and on App Review not asking for authorization.
2. **Fetch it only from the server.** The app stops bundling `catalog.json` and downloads it on first run. This doesn't change the answer: the server, a public website, would republish the same Apple-derived list and artwork links. It also leaves first-run onboarding empty when the network is down.
3. **Rebuild it from the publishers' own feeds.** The catalog build reads each show's title, author and artwork from its own RSS feed. It drops the Apple chart ranks and the `mzstatic` artwork URLs, and picks the shows by hand per subject, informed by several public lists rather than copied from one chart. The drawer code doesn't change. This costs one build-script change and a curation pass.

**My pick: option 3** before submission, whatever the attorney says about option 1. It costs little and leaves nothing to show App Review under 5.2.2. The attorney question is still worth asking: whether choosing shows while looking at Apple's charts is a problem, and whether option 1 is safe for the TestFlight beta in the meantime.
