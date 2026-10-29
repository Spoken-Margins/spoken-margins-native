# Privacy Policy redline (DRAFT)

> **DRAFT. Not legal advice.** A redline of `Site/privacy/index.html` (effective August 10, 2026) against what the app on `next` actually does, for Cole and an attorney to review (#455, part of #173). Nothing here is published, and `Site/` is unchanged.

## Read this first

1. **The live policy is wrong today in two places, whether or not share links ship.** It says the app "has no developer-operated … backend", but every launch fetches the tour from Cole's server. And it says the app connects out "only when needed to retrieve a source you select", but followed feeds refresh, transcripts load and episodes download on Wi-Fi without a tap. The table below cites each.
2. **Share links aren't in the app yet.** `next` has no code that uploads anything to any server (the only POST requests are the OpenAI calls, which are off). The share-link sections are written from the #486 and #487 design as revised by the 2026-10-20 decisions (D15 to D21 in `docs/legal/attorney-questions.md`; #2235 to #2239, #1728): a sealed preview, no full source text in a link, blind takedown on report, and the strike ladder. They must be checked against the shipped feature.
3. **OpenAI code is removed from the app (#2845).** There is no flag to turn on. The OpenAI paragraph can be dropped from the policy; if a remote provider ever returns, it comes back with its own paragraph.
4. **One owner check before publishing (the App Store draft's Q1).** The repo's server config writes no web access log: the Caddy site block has no `log` directive, and the error log strips IP addresses and headers (`research/B4/deploy/caddy-site.caddy`, `caddy-global.caddy` on `ws/b4-bridge`; `research/B4/DESIGN.md` §5). Cole should confirm nothing else on the VPS (the hosting provider's firewall, another proxy, fail2ban) keeps IP addresses for longer. The draft below assumes it doesn't. Cole's decision (2026-09-30): no visitor logs. Abuse such as a flood of requests is handled without them: the rate limiter keeps only scrambled IP addresses, in memory, reset every hour, and never on disk (`research/B4/DESIGN.md` §5 table). If an attack ever needs more, a protection service in front of the server (for example Cloudflare) can block it, but that service would see every visitor's IP address, so the policy would then have to name it before it is turned on.
5. **Listening maps aren't in the app yet.** The server side is #551 (`research/B4/DESIGN.md` §10); the phone's upload is #552 and showing maps is #553. The maps paragraph names Anthropic because the server sends each transcript to Anthropic's API to make the map. Check its retention wording against Anthropic's commercial terms at the time of publishing.
6. **Blanks** are marked `[[like this]]`.

Markup: ~~struck~~ text is removed; **bold** text is added; unmarked text is unchanged. Paths are relative to the repo root; `A/` is `App/SpokenMarginsApp/Sources/SpokenMarginsApp/`, `SK/` is `Packages/SessionKit/Sources/`, and `M` is `A/Gate1AppModel.swift`.

## Every outbound connection on `next`

| # | When | Where it goes | What it sends | Code |
|---|---|---|---|---|
| 1 | **Every launch, automatically**, until the listener deletes the tour | `spokenmargins.proximitytoprogress.com/onboarding/v1/manifest.json`, then the tour audio (Cole's server) | A plain request: network address and user agent, nothing else | URL `SK/SessionKit/GuidedOnboardingCoordinator.swift:42`; requests `:64`, `:86`, `:95`; started at launch `M:15618`, skipped after deletion `M:15623` |
| 2 | The podcast list opens by itself on first run with an empty library, or from "Browse podcasts and writers" in Following | `spokenmargins.proximitytoprogress.com/onboarding/catalog/v1/` (Cole's server), then each show's artwork from the show's own publisher or image host, about 25 hosts (#1732) | A plain request | URL `SK/SessionKit/SourceCatalogStore.swift:32`; request `A/CatalogDrawer.swift:59`; artwork `:232`; opens itself at `A/Gate1RootView.swift:75` |
| 3 | The listener follows a show or site; then **automatically** at launch and each time the app comes to the front, at most every 6 hours per feed; and a feed lookup when an item is opened | The followed feed or site (it may probe `/feed`, `/rss` and similar), `substack.com` for Substack links | The feed or page address, which for a private feed can contain a token | Session `A/FollowedSourceCoordinator.swift:55-60`; fetch `:286-292`; 6-hour rule `:197-199`; launch `M:15617`; app becomes active `M:2009` → `M:3731`; lookup on open `M:759-761`; Substack `SK/SessionKitFeeds/SubstackPublicationResolver.swift:205`, `:239` |
| 4 | The listener adds a podcast link (paste, share sheet, Shortcut, app link) | The link's page and the show's feed; Podcasting 2.0 chapter files; for Apple links `itunes.apple.com/lookup`; for Spotify links `open.spotify.com/oembed` and `/embed`, then `itunes.apple.com/search` | The link. For a Spotify link, the episode title Spotify returns is sent to Apple's search. Requests identify the app as `SpokenMargins/0.1` | `SK/SessionKitFeeds/PublicPodcastLinkResolver.swift:223-224`, `:235`, `:402-428`, `:733`, `:797-900`, `:1283`, `:1386-1411` |
| 5 | Right after a podcast import whose feed lists a transcript, **automatically** | The publisher's transcript address | A plain request | Scheduled `M:3272`; fetched `M:12180-12191` |
| 6 | Playing an episode that isn't downloaded | The episode's audio host | The audio address | `SK/SessionKitAudio/AudioAdapters.swift:1855-1856` |
| 7 | After every podcast import, **automatically on Wi-Fi**; on cellular only when the listener starts it | The episode's audio host | The audio address | Rules `SK/SessionKit/PodcastDownloads.swift:153-163`; requests `A/PodcastDownloadCoordinator.swift:443-472`; after import `M:3270`; resumes on Wi-Fi `A/PodcastDownloadCoordinator.swift:368-374` |
| 8 | The listener adds an article (share, paste, Safari extension, a followed site's new article, Raindrop) | The article's site, loaded in a hidden private web view that blocks outside scripts, images, styles, fonts, media and fetch requests (the page's own inline script still runs), cookies discarded afterwards | The article address | `A/AppOwnedReadablePageExtractor.swift:43-69`, `:89-95`; triggers `M:3186`, `M:16104`, `M:9893` |
| 9 | The listener shares a PDF link | The PDF's host | The PDF address | `M:3548-3552` |
| 10 | The listener connects Readwise Reader or Raindrop.io and taps Connect, Refresh or More | `readwise.io/api/v3/list/`, `api.raindrop.io/rest/v1/raindrops/0` | The listener's own access token. It stays in the device Keychain (this device only, when unlocked). Nothing is written back to the service | `SK/SessionKit/ReadLaterClient.swift:29-36`; `A/ReadLaterModel.swift:5-8`, `:29-52`; Keychain `M:16830` |
| 11 | A listener imports a packet someone sent them and confirms | The source address the sender put in the packet (https only), then rows 4 and 7; the download is allowed on cellular because the listener confirmed | The source address | Confirm `M:7976` → `M:7995`; resolve `M:8187-8208`, https only `M:8366-8368`; download `M:8041-8045` |
| 12 | The first on-device transcription on iOS 26 | Apple, to download the speech model | The language | `SK/SessionKitAudio/AudioAdapters.swift:226-229`; recognition stays on the device, `:297` |
| 13 | **Removed (#2845).** The app had an OpenAI path behind a build flag; the code is gone | — | — | `git grep api.openai.com -- App Packages/SessionKit/Sources` finds nothing |
| 14 | **Not built yet (#486, #487).** The listener creates a share link (on only in internal TestFlight builds until the LLC exists, its DMCA designated agent is registered and its page is live, and it holds media liability insurance, #2236). At a strike, the server asks the app for a DeviceCheck token | Cole's server, `POST /api/v1/links`; at a strike, the server calls Apple's DeviceCheck service | The packet (Margins, their audio and text, a capped source excerpt around each Margin, source title and address, any sender name typed) and the page's preview, both encrypted on the device with a key that stays in the link. No full source text. The App Attest key (see the installation-key paragraph), from which the server keeps only a keyed hash. During a pause, the server-signed "sharing paused until" token. At a strike, a short-lived DeviceCheck token, which the server passes to Apple to set two bits | #486, #487, #1728, #2237 |
| 15 | **Not built yet (#552).** A listener who opted in plays an episode that has no map yet | Cole's server, `POST /api/v1/maps/transcripts`; the server forwards the transcript to Anthropic's API | The episode's transcript, an episode code, its length and language. No install key | #551, #552 |
| 16 | **Not built yet (#553).** The app looks for a map of the episode being played | Cole's server, `GET /api/v1/maps/<episode code>` | The episode code | #551, #553 |
| 17 | **Added in this change (#471).** The listener types at least two letters in the podcast list's search field and pauses (about 0.3 s); only when they type | `itunes.apple.com/search` (Apple), then show artwork from `is1-ssl.mzstatic.com` | The typed words, the media type, a result limit and a country code, in one plain request each pause. No listener identifier. Nothing is sent when the field is empty or shorter than two letters | `SK/SessionKit/PodcastNameSearch.swift`; `SK/SessionKit/ITunesSearchSourceResolver.swift:49-58`; `A/CatalogDrawer.swift` (`makeSearcher`) |
| 18 | **Not built yet (#1819; the site side is #1818).** The listener opens Settings › Voices, or taps to download a voice | `spokenmargins.proximitytoprogress.com/voices/v1/catalog.json` (Cole's server), then each voice file from the publisher named in the catalog (today `huggingface.co`) or from Cole's server at `/voices/files/`, whichever the catalog lists first | A plain request for the same signed catalog and the same files for every listener: no identifier, cookie or query string. The publisher's host sees the request like any web request (network address, user agent) | `scripts/voice_catalog.py`; `Contracts/schemas/voice-model-catalog.schema.json`; #1816, #1819 |
| 19 | **Not built yet (#2239).** Anyone reports a link with "Report this link", on the share page or in the app | Cole's server | The link id, a category, the written reason when the form asks for one, and a contact email if the reporter gives one. No key, except in the abuse-material category, where the form sends the full link, which is forwarded with the written reason, if any, to the CyberTipline | #2235, #2239 |

Checked, and nothing leaves the device: speech recognition (`requiresOnDeviceRecognition = true`, `SK/SessionKitAudio/AudioAdapters.swift:297`); the Supertonic voices, which are bundled, not downloaded (`project.yml:23-25`); ShazamKit, which matches against a catalog built on the device (`SK/SessionKitAudio/PodcastAnchorEvidence.swift:281-285`, `:352-359`); notifications, which are local only (`A/ListeningReadyNotifications.swift:10-23`, no push entitlement); the Share, Safari and widget extensions, which make no network calls; and diagnostics, which leave only when the listener copies them into an email. There is no analytics, crash-reporting, advertising, CloudKit or MetricKit code; the only packages are onnxruntime, ZIPFoundation and swift-crypto (`Packages/SessionKit/Package.swift:22-27`). The server-config fetch in `SK/SessionKit/BridgeManifestStore.swift:11-12` and `SK/SessionKit/ITunesSearchSourceResolver.swift` exist but nothing on `next` calls them; re-check this table when either is wired up.

---

## The redline

**Privacy Policy**

Effective ~~August 10, 2026~~ **[[date]]** · Beta version 0.1

Spoken Margins is a local-first reading and listening app. Your library, recordings, transcripts, listening history, and settings stay on your device. ~~The app connects to outside services only when needed to retrieve a source you select or when you deliberately share or export content.~~ **The app connects to outside services to retrieve the sources you select or follow, to fetch app content such as the introductory tour from our server, and when you deliberately share or export content. Each is described below.**

### What stays on your device

Imported text and files, saved links, listening maps, playback history, interjection audio and transcripts, session exports, and settings are stored locally. Spoken Margins has no ~~developer-operated~~ account system ~~or backend~~ and includes no advertising, analytics, or tracking service. **It does use a small server that we operate, described below.** *(Table rows 1, 2 and 14.)*

**### Our server**

**Spoken Margins fetches the introductory tour and the list of starter podcasts from our server at spokenmargins.proximitytoprogress.com. The tour is checked each time the app opens, until you delete it; the podcast list is fetched when you open it, and it opens by itself the first time you use the app with an empty library. These requests carry only what every web request carries, such as your network address, and no account, library, or recording data.** *(Rows 1 and 2.)*

**Our server does not keep IP addresses or a log of individual requests. It keeps an hourly count of which services were used and whether they worked, and deletes it after 14 days.** *(`research/B4/DESIGN.md` §5; owner check 4 above.)*

**[[When share links ship:]] If you create a share link, the app encrypts the packet you chose on your device and uploads it to our server: your Margins, their audio and text, a short excerpt of the source around each Margin, the source's title and address, and any sender name you typed. The packet does not include the full text of the source. The preview the link's page shows is encrypted the same way. The key is part of the link and is never sent to our server [[confirm against the shipped feature: the key is in the part of the link browsers don't send]], so our server stores only data it cannot read. Anyone with the link can open a page that decrypts in their browser and shows your Margin text with its excerpt, the source title and the show, and can download the packet. Previews of the link in messages and on social media show only a generic title. We never serve the source's own audio. A link and its packet are deleted 30 days after you create it. Anyone can report a link from its page or from the app, and you can ask us to remove one at the address below.** *(Row 14, #486, #487.)*

**For an item with no web address, such as a pasted article or a PDF, the app sends the item as a `.spokenmargins` file in the same message as the link, through Messages, AirDrop or another app you choose. That file, with the item's full text, goes directly to the people you send it to and never passes through our server.** *(#487.)*

**Alongside each link, our server keeps a keyed hash of the sending installation's key (see the next paragraph): a scrambled code that lets the server count reports against the same installation without knowing which installation it is. It is kept for 90 days and for as long as a pause on link sharing lasts.** *(#1728, #2239.)*

**[[When share links ship:]] Reports. When someone reports a link, our server stops serving it at once. Nobody reads the reported content. We keep a report record: the link's id, the category the reporter chose, the date, and the written reason when the form asked for one (a reporter's second report within 7 days, in any category). We also keep keyed hashes of the reporter's device or reply email address and of the sending installation's key, only to count reports within 7 days (for reporters) and 90 days (for senders) and to keep track of a pause on link sharing; [[how long the report record and the hashes are kept after that]]. If you give a contact email with a report, we use it only to reply about that report and keep it [[for how long]]. The sender's app shows only "A link you shared was taken down after a report", which does not say who reported the link or why.** *(Row 19, #2239.)*

**If a report says a link contains child sexual abuse material, the report form sends the full link, including its key. We do not open it. We forward it, with the reporter's written reason if the form asked for one, to the National Center for Missing & Exploited Children's CyberTipline, and hold the stored link and the report for one year in restricted storage, with access limited and logged, as 18 U.S.C. § 2258A(h) provides. They are then deleted. Only the CyberTipline and law enforcement open them.** *(Row 19, #2235.)*

**[[When listening maps ship:]] If you turn on sharing listening maps, the app uploads the transcript of an episode you play to our server, with a code for the episode (not for you), and the episode's length and language. Nothing that identifies you or your device is sent with it. Our server sends the transcript to Anthropic, an AI service, which writes a listening map: the episode's scenes, each with a short title and summary in its own words. Our server keeps the transcript in memory only, never writes it to disk, drops it as soon as the map is made, and never shares it. Anthropic handles it under its commercial terms [[confirm at publishing: not used for training; how long Anthropic keeps it]]. The map is kept and given to anyone whose app asks for that episode; it says nothing about who uploaded the transcript. To find a map, the app sends only the episode's code.** *(Rows 15 and 16, #551.)*

**[[When voice downloads ship (#1819):]] When you open Settings › Voices or choose to download a voice, the app fetches a signed list of voices from our server. The list is the same for everyone and the request carries no account or identifier. The voice files then download from the publisher's own server (today Hugging Face), or from ours where the voice's licence lets us host a copy, and the publisher or our server sees the request like any web request. Our server does not log it. Voices that need your agreement to their use restrictions show them first, and the download starts only after you agree.** *(Row 18.)*

**[[When a feature that sends something to the server ships (B4 design §7):]] The first time you use a feature that sends something to our server, your device creates a random key for this installation, and Apple confirms to our server that it belongs to a genuine copy of Spoken Margins. Apple does not tell us who you are or which device you use. The server keeps the key's public half, a counter, and the dates it was created and last used, only to prevent abuse, and deletes it after 90 days without use. If an installation sends more requests than allowed, the server notes its key for 30 days so repeated abuse can be blocked.**

**[[When share links ship (#1728):]] If links shared from an installation are reported twice within 90 days, that is a strike. The first strike pauses creating share links for a week, the second for a month, and the third ends it. To keep a strike when the app is removed and reinstalled, our server uses Apple's DeviceCheck service: the app gives our server a short-lived token, and our server asks Apple to set two bits that Apple keeps for that device, with the month they were last set. The bits record only the strike step. We never receive or store an identifier for your device. During a pause, our server gives the app a signed "sharing paused until" note with the end date; the app keeps it and shows it when it tries to create a link, and deleting the app deletes it. Sending `.spokenmargins` files directly is never affected.** *(Row 14.)*

### Source and podcast requests

When you import or play a link, Spoken Margins contacts the selected website, podcast feed, or public media host to retrieve the requested material. **This includes the show's feed, its episode page, chapter and transcript files the feed lists, and the episode audio.** To resolve podcast links, the app may send the selected link ~~or episode search terms~~ to Spotify's public metadata service ~~or~~**, and the link or, for a Spotify link, the episode's title** to Apple's public podcast search and lookup services. Those services and source hosts receive the information normally included with a network request, such as the requested URL and network address, and handle it under their own terms and privacy policies. *(Rows 4 to 6.)*

**Articles you add are loaded from their website in a private, hidden browser view that stops the page from loading scripts, images and other resources from elsewhere, and discards its cookies afterwards.** *(Row 8.)*

**When you follow a show or website, Spoken Margins checks it for new items when the app opens or comes to the front, at most every six hours. A private feed address that contains a token is sent to that feed's own host only. When you open an item, Spoken Margins also checks the item's website for a feed you could follow, which can include Substack for a Substack newsletter.** *(Row 3.)*

Podcast playback and ~~optional~~ offline ~~caching~~ **downloads** use public media URLs supplied by podcast publishers. **After you add an episode, Spoken Margins downloads it automatically on Wi-Fi; on cellular it streams instead, unless you choose to download.** Spoken Margins does not send your recordings, transcripts, library, or internal database identifiers to the developer **except in a share link you create**. *(Row 7.)*

**When you import Margins someone shared with you, your device fetches the source address the sender included, so that source's host sees the request.** *(Row 11.)*

**### Read Later services**

**If you connect Readwise Reader or Raindrop.io, Spoken Margins uses the access token you enter to read your saved items from that service, only when you tap Connect, Refresh, or More. The token is stored in your device's Keychain and sent only to that service. Spoken Margins does not change anything in your account. Items from Raindrop.io are then loaded from their original websites.** *(Row 10.)*

**### Your own OpenAI key**

**[[Publish when the feature is turned on, or now:]] If you enter your own OpenAI API key and use a feature that needs it, Spoken Margins sends the text that feature needs, such as the source text, your Margins, and your question, directly to OpenAI with your key, and asks OpenAI not to store the response. OpenAI handles that data under its own terms and privacy policy. The key is stored in your device's Keychain. Nothing is sent to OpenAI unless you enter a key and agree.** *(Row 13.)*

### On-device speech and intelligence

Spoken interjection transcription requests on-device speech recognition. **The first time, iOS may download its speech model from Apple.** Installed system voices, bundled voices, and supported local intelligence features process their input on the device. Availability is controlled by the operating system, installed resources, language, and device capabilities. Spoken Margins does not operate a server for this processing. *(Row 12.)*

### Sharing, extensions, and support

The Share extension and Safari extension write only the item you explicitly share or capture into the app's private shared container. The Safari extension runs only when you invoke Selected Text or Readable Page; it does not continuously read browsing activity.

When you use the system share sheet, copy an export, or email support, the destination you choose receives the content you select. Diagnostics are created locally for you to review and are not sent automatically. A diagnostics file holds timings, states, routes and short codes; it holds no article titles, web addresses, file names, Margin text or transcripts, and the codes that stand for your library items can't be turned back into titles.

### Deletion and retention

You can move library items to Recently Deleted, permanently delete them in the app, or remove the app to remove its local app data. **Removing the app does not delete a share link you already created; it expires after 30 days, or you can ask us to remove it sooner. A reported link stops being served at once and is deleted on its normal date, except that a link reported as child sexual abuse material and forwarded to the CyberTipline is held for one year in restricted storage and then deleted. Removing the app does not remove a strike recorded with Apple's DeviceCheck.** An upgrade from an earlier private beta may archive an old local test database before creating the current database; the app reports that archive in its diagnostics.

### Contact

Questions or privacy requests: resists.fabric-0o@icloud.com. **[[Add the copyright agent for takedowns once designated; see terms-draft.md 5C. Add links to "Report this link", the content policy and the intimate-image removal process (#2238, #2239).]]**

### Changes

This policy may change as beta features evolve. The effective date above will be updated when material practices change.

---

## Why each strike

| Struck or changed | Why | Evidence |
|---|---|---|
| "connects to outside services only when needed to retrieve a source you select" | The tour loads at every launch, the podcast list opens by itself on first run, followed feeds refresh on their own, transcripts load after import, and episodes download on Wi-Fi without a tap | Rows 1, 2, 3, 5, 7 |
| "developer-operated … backend" | The app contacts Cole's server at every launch | Row 1 |
| "episode search terms" | The only search is the episode title from a Spotify link, sent to Apple | `PublicPodcastLinkResolver.swift:235`, `:418-428` |
| "optional offline caching" | Downloads start by themselves on Wi-Fi after an import | Row 7 |
| "does not send … to the developer" (qualified) | A share link will upload the packet | Row 14 |

Also missing today and added above: Readwise and Raindrop (row 10), a packet recipient's fetches (row 11), Apple's speech-model download (row 12), and OpenAI (row 13).
