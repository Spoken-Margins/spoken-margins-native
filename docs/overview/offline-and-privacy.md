# Offline use and privacy

This page lists what the app does with no network, and every kind of network request it makes, so you can check the claims against the code. Paths are relative to the repository root; `{app}/…` means `App/SpokenMarginsApp/Sources/SpokenMarginsApp/` and `{kit}/…` means `Packages/SessionKit/Sources/`. For the overall layout see the [architecture overview](architecture.md).

The app has no analytics, advertising or crash-reporting library: its only third-party code dependencies are ONNX Runtime and ZIPFoundation (`Packages/SessionKit/Package.swift`), and a search of `{app}/` and `Packages/` finds no tracking identifier or advertising API. The privacy statement the project publishes is `Site/privacy/index.html`.

## What works with no network

- **Listening to saved articles, PDFs and text.** Imported text is stored in the Library. `{kit}/SessionKit/OfflinePlayability.swift` holds the rules for what plays offline and how the app explains it when something cannot.
- **Narration.** The Kitten fallback voice, the Supertonic voices (James and Lily) and the installed iOS voices all run on the phone. The first two are bundled in the app (`App/SpokenMarginsApp/Resources/Kitten` and `App/SpokenMarginsApp/Resources/Supertonic`). Nothing downloads a voice today.
- **Podcasts that are downloaded.** A podcast item with a saved file plays offline. Streaming needs a network. Items added to the Library download on Wi-Fi only; a download on cellular happens only when the listener asks for it (`{app}/PodcastDownloadCoordinator.swift`).
- **Recording Margins.** Spoken Margins are transcribed on the device: speech recognition is set to require on-device recognition and fails rather than send audio away (`{kit}/SessionKitAudio/AudioAdapters.swift`). iOS itself may download a speech model from Apple.
- **Summaries.** Summaries use Apple's on-device model where the phone supports it (`{app}/LocalFoundationModels.swift`).
- **Exporting and importing packets.** Both are local file operations (`{kit}/SessionKitSharing/`, which contains no networking code). Sending the file is up to you.
- **The first-run tour** has a bundled fallback if its download cannot happen.

## What reaches the network, by kind

### You asked for it

These happen because you added, opened or played something. They go to the publisher or to Apple, not to the project's server.

- Importing a link: a hidden web view loads the page over HTTPS with images, scripts, styles and fonts blocked, a non-persistent data store and no cookies kept (`{app}/AppOwnedReadablePageExtractor.swift`). Web PDFs, pasted feed links and podcast links are fetched the same way you would open them; resolving a podcast link may ask Apple's iTunes Search or lookup service (`{kit}/SessionKitFeeds/PublicPodcastLinkResolver.swift`).
- Following a source and refreshing it: feed requests to the publisher with a short-lived session and no cache (`{kit}/SessionKitFeeds/FollowedSourceCoordinator.swift`).
- Searching in the catalog drawer sends what you type to Apple's iTunes Search (`{kit}/SessionKit/ITunesSearchSourceResolver.swift`). Show artwork loads from the publisher or Apple.
- Playing a podcast streams it from the publisher.
- Opening a Spoken Margins share link downloads the sealed packet from the project's server (`{kit}/SessionKit/ShareLinkOpening.swift`, `{app}/ShareLinkOpener.swift`).

### Automatic

- **Followed sources refresh** when the app opens, when it returns to the foreground, and in a background refresh that is scheduled only if you follow at least one source (`{app}/FollowedSourceBackgroundRefreshController.swift`). Requests go to the feed hosts. New items wait in Following by default; adding them to the Library automatically is a per-show choice (`{kit}/SessionKit/FeedNewItemPolicy.swift`).
- **At launch** the app fetches the first-run tour (a manifest, then an audio file of up to 64 MB) from the project's server, unless you deleted the tour (`{app}/Gate1AppModel.swift`).
- **The starter podcast catalog** is refreshed from the project's server when the catalog drawer opens. The drawer opens by itself on first run if the Library is empty (`{kit}/SessionKit/SourceCatalogStore.swift`, `{app}/CatalogDrawer.swift`).
- **After an import,** the app may fetch the publisher's transcript or audio to line the text up with the recording (`{app}/PublisherAudioTextMapper.swift`). A shared Substack link may also fetch the publisher's own voiceover (`{app}/SharedLinkVoiceover.swift`).
- The app watches connectivity (`{app}/ConnectivityMonitor.swift`) to explain offline states; that sends nothing.

### Only if you turn it on

All of these default to off and are set in Settings.

- **Help make listening maps** (`communityMapUploadOptIn`, `{app}/SettingsScreen.swift`): sends the transcript of a public episode, a hash of the episode's identifier, its length and language, with links removed, to the project's server (`{kit}/SessionKit/CommunityMapUpload.swift`). It never sends your Margins and carries no installation identifier. The server passes the transcript to Anthropic's API to draft a map, as the privacy page explains. The server can switch this off without an app update.
- **Look up community maps** (`communityMapLookupOptIn`, `{app}/CommunityMapFetchService.swift`): asks the server for a map for the episode you are about to hear. That request reveals the episode and your network address to the server, which is why it is opt-in. With it off the app does not even fetch the server's configuration.
- **Readwise Reader or Raindrop** (`{kit}/SessionKit/ReadLaterClient.swift`): you paste your own token, which is kept in the Keychain. If you also turn on sending Margins to Readwise, the app sends Margin text and its source context to Readwise's highlights API while it is open (`{kit}/SessionKit/ReadwiseHighlightClient.swift`, `{app}/ReadwiseHighlightSync.swift`). Recordings are not sent.
- **Sharing Diagnostics** is a file you build and send yourself. URLs and file paths are redacted before it is written (`{kit}/SessionKit/DiagnosticsExport.swift`); item titles may be included, so look before you send it.

### Not in the app

- The app can open a share link but has no screen that creates one or uploads a packet. The sealing code exists and is tested (`{kit}/SessionKit/ShareLinkSealing.swift`); a feature that uses it would come with its own opt-in.
- There is no club mailbox, relay, SharePlay, CloudKit or push-notification code.
- The remote AI-provider code is compiled in but disabled by a release flag (`SMRemoteProviderExperienceEnabled` in `project.yml`), so no request to a third-party model can be made.
- The Safari extension, the share extension, the Live Activity extension and the Watch code make no network requests of their own. The Safari and share extensions write what you shared to a container the app reads (`App/SpokenMarginsBrowserTextExtension/Sources/SafariWebExtensionHandler.swift`, `App/SpokenMarginsShareExtension/Sources/SourceLinkShareViewController.swift`).

## What stays on the phone

- The Library database, your Margins, recordings and transcripts (`{app}/Gate1AppModel.swift` chooses the file in Application Support).
- A log of listening time, Margins and finishes for followed sources, kept as a local file (`{kit}/SessionKit/ListeningSignalRecorder.swift`). It holds titles, times and counts, never Margin text or audio, and has no upload code. It leaves the phone only if you export it.
- Rendered voice audio and downloaded podcast files are excluded from backups (`{app}/PodcastDownloadCoordinator.swift`, `{kit}/SessionKitSupertonic/RenderedSpeechDiskCache.swift`).

## What is encrypted end to end

Share links seal the packet and its preview with AES-256-GCM before upload. The 32-byte key is generated on the sender's phone and travels in the link's `#` fragment, which a browser or app never sends to a server, so the server holds only unreadable bytes (`{kit}/SessionKit/ShareLinkSealing.swift`; server side in `research/B4/server/internal/links/`). Server requests from the app use ephemeral sessions with no cookies, cache or credentials, and go only to the project's own host (`{kit}/SessionKit/BridgePublicTransport.swift`).

## How the server stays out of the way

The app asks the server for a small configuration that can switch each server feature off. A missing, unreadable or week-old configuration means every server feature is off (`{kit}/SessionKit/ServerConfig.swift`), so an unreachable server never blocks listening. The server's logging rules are in `research/B4/DESIGN.md` and its Caddy configuration `research/B4/deploy/caddy-global.caddy`: no access logs, and error logs without addresses, headers or map and link paths. These files describe what the server is set up to do; they cannot prove what a running server does.
