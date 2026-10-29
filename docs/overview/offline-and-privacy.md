# Offline use and privacy

This page lists what the app does with no network, and every kind of network request it makes, so you can check the claims against the code. Paths are relative to the repository root; `{app}/…` means `App/SpokenMarginsApp/Sources/SpokenMarginsApp/` and `{kit}/…` means `Packages/SessionKit/Sources/`. For the overall layout see the [architecture overview](architecture.md).

The app has no analytics, advertising or crash-reporting library. Its Swift dependencies are ONNX Runtime and ZIPFoundation (`Packages/SessionKit/Package.swift`); the page-reading script for Safari and link import bundles five JavaScript libraries, listed in `App/SharedResources/BundledJavaScript-NOTICES.txt`. A search of `App/` and `Packages/` finds no tracking identifier or advertising API. System crash and memory-exit reports (MetricKit) are written only to the local Diagnostics log (`{app}/MemoryExitMetricsSubscriber.swift`). The app declares no tracking in its Apple privacy manifest (`App/SpokenMarginsApp/Sources/PrivacyInfo.xcprivacy`), which also declares one collected data type, "other user content", for app functionality. The privacy statement the project publishes is `Site/privacy/index.html`.

## What works with no network

- **Listening to saved articles, PDFs and text.** Imported text is stored in the Library. `{kit}/SessionKit/OfflinePlayability.swift` holds the rules for what plays offline and how the app explains it when something cannot.
- **Narration.** The Kitten fallback voice, the Supertonic voices (James and Lily) and the installed iOS voices all run on the phone. Kitten is bundled in the app (`App/SpokenMarginsApp/Resources/Kitten`). Supertonic is a free download from Settings › Voices (#1819, #1820), fetched only when the listener taps Download; until then Kitten reads.
- **Podcasts that are downloaded.** A podcast item with a saved file plays offline. Streaming needs a network. Items added to the Library download on Wi-Fi only; a download on cellular happens only when the listener asks for it (`{app}/PodcastDownloadCoordinator.swift`).
- **Recording Margins.** Spoken Margins are transcribed on the device. The older recogniser path is set to require on-device recognition and fails rather than send audio away; the newer one uses Apple's on-device speech transcriber (`{kit}/SessionKitAudio/AudioAdapters.swift`). iOS itself may download a speech model from Apple.
- **Summaries.** Summaries use Apple's on-device model where the phone supports it (`{app}/LocalFoundationModels.swift`).
- **Exporting and importing packets.** Both are local file operations (`{kit}/SessionKitSharing/`, which contains no networking code). Sending the file is up to you.
- **The first-run tour** has a bundled fallback if its download cannot happen.

## What reaches the network, by kind

### You asked for it

These happen because you added, opened or played something. They go to the publisher or to Apple, not to the project's server.

- Importing a link: a hidden web view loads the page over HTTPS with a non-persistent data store, so no cookies or cache are kept. For ordinary pages, rules block images, styles, scripts, fonts and media; a shared Claude or ChatGPT conversation page needs its own scripts to render, so those pages are allowed to run them (`{app}/AppOwnedReadablePageExtractor.swift`). Web PDFs, pasted feed links and podcast links are fetched the same way you would open them; resolving a podcast link may ask Apple's iTunes Search or lookup service, or, for a Spotify link, Spotify's public oEmbed and embed pages (`{kit}/SessionKitFeeds/PublicPodcastLinkResolver.swift`).
- Following a source and refreshing it: feed requests to the publisher with a short-lived session and no cache (`{kit}/SessionKitFeeds/FollowedSourceCoordinator.swift`).
- Searching in the catalog drawer sends what you type to Apple's iTunes Search (`{kit}/SessionKit/ITunesSearchSourceResolver.swift`). Show artwork loads from the publisher or Apple.
- Playing a podcast streams it from the publisher.
- Opening a Spoken Margins share link downloads the sealed packet from the project's server (`{kit}/SessionKit/ShareLinkOpening.swift`, `{app}/ShareLinkOpener.swift`).

### Automatic

- **Followed sources refresh** when the app opens, when it returns to the foreground, and in a background refresh that is scheduled only if you follow at least one source (`{app}/FollowedSourceBackgroundRefreshController.swift`). Requests go to the feed hosts. New items wait in Following by default; adding them to the Library automatically is a per-show choice (`{kit}/SessionKit/FeedNewItemPolicy.swift`).
- **At launch** the app fetches the first-run tour (a manifest, then an audio file of up to 64 MB) from the project's server, unless you deleted the tour (`{app}/Gate1AppModel.swift`).
- **The starter podcast catalog** is refreshed from the project's server when the catalog drawer opens. The drawer opens by itself on first run if the Library is empty (`{kit}/SessionKit/SourceCatalogStore.swift`, `{app}/CatalogDrawer.swift`).
- **After an import,** the app may fetch the publisher's transcript or audio to line the text up with the recording (`{app}/PublisherAudioTextMapper.swift`). A shared Substack link may also look up the publisher's own voiceover (`{app}/SharedLinkVoiceover.swift`).
- The app watches connectivity (`{app}/ConnectivityMonitor.swift`) to explain offline states; that sends nothing.

### Only if you turn it on

All of these default to off and are set in Settings.

- **Help make listening maps** (`communityMapUploadOptIn`, `{app}/SettingsScreen.swift`): sends the transcript of a public episode, a hash of the episode's identifier, its length and language, with links removed, to the project's server (`{kit}/SessionKit/CommunityMapUpload.swift`). It never sends your Margins and carries no installation identifier. The server passes the transcript to Anthropic's API to draft a map, as the privacy page explains. The server can switch this off without an app update.
- **Look up community maps** (`communityMapLookupOptIn`, `{app}/CommunityMapFetchService.swift`): asks the server for a map for the episode you are about to hear. That request reveals the episode and your network address to the server, which is why it is opt-in. With it off the app does not even fetch the server's configuration.
- **Readwise Reader or Raindrop** (`{kit}/SessionKit/ReadLaterClient.swift`): you paste your own token, which is kept in the Keychain. If you also turn on sending Margins to Readwise, the app sends Margin text and its source context to Readwise's highlights API while it is open (`{kit}/SessionKit/ReadwiseHighlightClient.swift`, `{app}/ReadwiseHighlightSync.swift`). Recordings are not sent. If you turn on Send Margins to Readwise, your Margin text and the passage it is attached to go to your own Readwise account. That is why the App Store privacy label lists user content as linked to you.
- **Sharing Diagnostics** is a file you build and send yourself. Web addresses and file paths under `/private`, `/Users` and `/var` are replaced with placeholders before it is written (`{kit}/SessionKit/DiagnosticsExport.swift`). Item titles may be included, so look before you send it.

### Not in the app

- The app can open a share link but has no screen that creates one or uploads a packet. The sealing code exists and is tested (`{kit}/SessionKit/ShareLinkSealing.swift`); a feature that uses it would come with its own opt-in.
- There is no club mailbox, relay, SharePlay, CloudKit or push-notification code. The app does post local notifications from the phone itself (`{app}/ListeningReadyNotifications.swift`); they send nothing.
- There is no remote AI-provider code: the OpenAI client and its settings were removed (#2845), so no request to a third-party model can be made. Summaries use Apple's on-device model.
- The Safari extension, the share extension, the Live Activity extension and the Watch code make no network requests of their own. The Safari and share extensions write what you shared to a container the app reads (`App/SpokenMarginsBrowserTextExtension/Sources/SafariWebExtensionHandler.swift`, `App/SpokenMarginsShareExtension/Sources/SourceLinkShareViewController.swift`).

## What stays on the phone

- The Library database, your Margins, recordings and transcripts (`{app}/Gate1AppModel.swift` chooses the file in Application Support).
- A log of listening time, Margins and finishes for followed sources, kept as a local file (`{kit}/SessionKit/ListeningSignalRecorder.swift`). It holds source titles and categories, times, counts, and events such as shares, exports and dismissals (`{kit}/SessionKit/ListeningSignals.swift` lists the fields; the schema is `Contracts/schemas/i4-engagement.schema.json`). It never holds Margin text, transcripts, audio or feed addresses, and has no upload code. It leaves the phone only if you export it.
- Rendered voice audio and downloaded podcast files are excluded from backups (`{app}/PodcastDownloadCoordinator.swift`, `{kit}/SessionKitSupertonic/RenderedSpeechDiskCache.swift`).

## What is encrypted end to end

Share links are designed so the server never holds readable content. The packet and its preview are sealed with AES-256-GCM, and the 32-byte key lives in the link's `#` fragment, which a browser or app does not send to a server (`{kit}/SessionKit/ShareLinkSealing.swift`; server side in `research/B4/server/internal/links/`). The app today can open such a link but has no screen that creates one, so this is the design the sealing code and server implement, and it is tested, not a feature a listener can use yet.

The requests to the project's server for configuration and community maps use ephemeral sessions with no cookies, cache or credentials, and only the project's own host (`{kit}/SessionKit/BridgePublicTransport.swift`). The first-run tour and the starter catalog use ordinary URL sessions to the same host (`{app}/GuidedOnboardingCoordinator.swift`, `{app}/CatalogDrawer.swift`).

## How the server stays out of the way

The app asks the server for a small configuration that can switch each server feature off. A missing, unreadable or week-old configuration means the features it gates (the bridge, device attestation and community maps) are off (`{kit}/SessionKit/ServerConfig.swift`). The tour, the catalog and opening a share link are not gated that way; if the server cannot be reached they fail or fall back, and listening is never blocked. The server's logging rules are in `research/B4/DESIGN.md` and its Caddy configuration `research/B4/deploy/caddy-global.caddy`: no access logs, and error logs without addresses, headers or map and link paths. These files describe what the server is set up to do; they cannot prove what a running server does.
