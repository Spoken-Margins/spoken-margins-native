# Privacy Policy redline (DRAFT)

> **DRAFT. Not legal advice.** A redline of `Site/privacy/index.html` (effective August 10, 2026) against what the app on `next` actually does, for Cole and an attorney to review (#455, part of #173). Nothing here is published, and `Site/` is unchanged.

## Read this first

1. **The live policy is wrong today in two places, whether or not share links ship.** It says the app "has no developer-operated … backend", but every launch fetches the tour from Cole's server. And it says the app connects out "only when needed to retrieve a source you select", but followed feeds refresh, transcripts load and episodes download on Wi-Fi without a tap. The table below cites each.
2. **Share links aren't in the app yet.** `next` has no code that uploads anything to any server (the only POST requests are the OpenAI calls, which are off). The share-link section is written from the #486 design (30 days, report button, takedown) and must be checked against the shipped feature.
3. **OpenAI is off in this build** (`SMRemoteProviderExperienceEnabled: false`, `project.yml:117`, read at `App/SpokenMarginsApp/Sources/SpokenMarginsApp/LocalFoundationModels.swift:12-17`). The OpenAI paragraph can be published now or held until the flag turns on; publishing it early is harmless.
4. **One owner check before publishing (the App Store draft's Q1).** The repo's server config writes no web access log: the Caddy site block has no `log` directive, and the error log strips IP addresses and headers (`research/B4/deploy/caddy-site.caddy`, `caddy-global.caddy` on `ws/b4-bridge`; `research/B4/DESIGN.md` §5). Cole should confirm nothing else on the VPS (the hosting provider's firewall, another proxy, fail2ban) keeps IP addresses for longer. The draft below assumes it doesn't.
5. **Blanks** are marked `[[like this]]`.

Markup: ~~struck~~ text is removed; **bold** text is added; unmarked text is unchanged. Paths are relative to the repo root; `A/` is `App/SpokenMarginsApp/Sources/SpokenMarginsApp/`, `SK/` is `Packages/SessionKit/Sources/`, and `M` is `A/Gate1AppModel.swift`.

## Every outbound connection on `next`

| # | When | Where it goes | What it sends | Code |
|---|---|---|---|---|
| 1 | **Every launch, automatically**, until the listener deletes the tour | `spokenmargins.proximitytoprogress.com/onboarding/v1/manifest.json`, then the tour audio (Cole's server) | A plain request: network address and user agent, nothing else | URL `A/GuidedOnboardingCoordinator.swift:30`; requests `:52`, `:74`, `:83`; started at launch `M:15618`, skipped after deletion `M:15623` |
| 2 | The podcast list opens by itself on first run with an empty library, or from "Browse top podcasts" | `spokenmargins.proximitytoprogress.com/onboarding/catalog/v1/` (Cole's server), then show artwork from `is1-ssl.mzstatic.com` (Apple) | A plain request | URL `SK/SessionKit/SourceCatalogStore.swift:32`; request `A/CatalogDrawer.swift:59`; artwork `:232`; opens itself at `A/Gate1RootView.swift:75` |
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
| 13 | **Off in this build.** If turned on, when the listener enters their own OpenAI key and uses a remote feature | `api.openai.com` (`/v1/responses`, `/v1/chat/completions`, `/v1/models`) | The listener's key, plus the text the feature needs: source text, Margins and questions. Responses are requested with `store: false` | `A/OpenAIResponsesClient.swift:30`, `:121-133`; `A/Gate1ProviderRequestFactory.swift:14-26`; `M:867`, `M:8736-8755`; key in Keychain `M:944`; off by `project.yml:117` |
| 14 | **Not built yet (#486).** The listener creates a share link | Cole's server, `POST /api/v1/links` | The packet (Margins, their audio and text, source title and address, any sender name typed) and a text preview | #486 |

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

**[[When share links ship:]] If you create a share link, the app uploads the packet you chose to our server: your Margins, their audio and text, the source's title and address, and any sender name you typed. Anyone with the link can open a page that shows your Margin text, the source title and the show, and can download the packet. We never serve the source's own audio. A link and its packet are deleted 30 days after you create it, or sooner if it is reported and removed. Anyone can report a link from its page, and you can ask us to remove one at the address below.** *(Row 14, #486.)*

**[[When a feature that sends something to the server ships (B4 design §7):]] The first time you use a feature that sends something to our server, your device creates a random key for this installation, and Apple confirms to our server that it belongs to a genuine copy of Spoken Margins. Apple does not tell us who you are or which device you use. The server keeps the key's public half, a counter, and the dates it was created and last used, only to prevent abuse, and deletes it after 90 days without use. If an installation sends more requests than allowed, the server notes its key for 30 days so repeated abuse can be blocked.**

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

When you use the system share sheet, copy an export, or email support, the destination you choose receives the content you select. Diagnostics are created locally for you to review and are not sent automatically.

### Deletion and retention

You can move library items to Recently Deleted, permanently delete them in the app, or remove the app to remove its local app data. **Removing the app does not delete a share link you already created; it expires after 30 days, or you can ask us to remove it sooner.** An upgrade from an earlier private beta may archive an old local test database before creating the current database; the app reports that archive in its privacy-safe diagnostics.

### Contact

Questions or privacy requests: resists.fabric-0o@icloud.com. **[[Add the copyright agent for takedowns once designated; see terms-draft.md 5C.]]**

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
