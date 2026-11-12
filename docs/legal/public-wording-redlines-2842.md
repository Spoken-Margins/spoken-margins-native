> **Draft for the owner and counsel, not live wording.** Nothing in `Site/`, the web app or the app changes until the owner says which items to publish (#2842, cluster run #3519). Line numbers are as of `origin/main` 47e529f.

# #2842 item 2: what the public words say vs what the code does (draft wording for the owner)

Read-only survey, 2026-11-06, `origin/main` at 47e529f. Nothing was changed, pushed or posted. Every draft below is for the owner to accept or change. Public wording is his call.

Paths: `S/` = `App/SpokenMarginsApp/Sources/SpokenMarginsApp/`, `SK/` = `Packages/SessionKit/Sources/`, `B4/` = `research/B4/server/`.

## Facts checked live today (they change the urgency)

1. **The live site is behind the repo.** `https://spokenmargins.proximitytoprogress.com/privacy/` and `/terms/` redirect to `spokenmargins.com`. They differ from `Site/` only in the contact line (the live pages still show the iCloud relay address, not the LLC email and Skokie mailbox the owner chose on 2026-11-05) and the footer links. Everything else in this file applies to both copies. Line numbers below are `Site/`'s.
2. **Share links are already on for internal testers.** Build 35 (tag `testflight/0.1-build-35`, c150aab) contains `S/ShareLinkSender.swift`, and the owner chose to upload it "with share links turned on" (docs/decisions.md 2026-11-05). The live server config (`/api/v1/config.json`, serial 5, fetched today) has `"links": {"enabled": true}`. So a Build 35 tester can make a link today. The privacy page says the app never does that.
3. **What Build 35 testers have that the page doesn't mention.** It also has the typed podcast search, the Type III Audio lookup and the random sender id. Build 34 has the podcast search too. Build 32, the external build, has none of these.
4. **What a link holds on the server today.** It holds only the sealed packet, the sealed preview and an expiry date (`B4/internal/links/store.go:15-19`, `:44-45`). The app sends no App Attest key and no permit: there is no `DCAppAttestService` in `App/` or `Packages/`, and `smserver.service:39` does not set the require-permit flag. So the server ties no link to any sender today.
5. **The web app is live.** It runs at `app.spokenmargins.com` and is outside the four surfaces this file checks. See the note at the end.

---

## A. Wrong today on the live site

### A1. Typed podcast search goes to Apple, and the page doesn't say so (Builds 34 and 35)

- **Current text.** Site/privacy/index.html:8: "To resolve podcast links, the app may send the selected link to Spotify's public metadata service or Apple's public podcast search and lookup services. For a Spotify link, the episode title can also be sent to Apple's search service."
- **Why it's wrong.** Words typed in the podcast list's search box go to `https://itunes.apple.com/search` as `term` (`SK/SessionKit/ITunesSearchSourceResolver.swift:37-41`). This happens once the box holds at least 2 letters (`SK/SessionKit/PodcastNameSearch.swift:19`, `:40`). It is wired in `S/CatalogDrawer.swift:111`. The page only covers links.
- **Draft. Add after that sentence:**
  > When you type at least two letters in the podcast search box, the app sends what you typed to Apple's public podcast search to find shows. It sends it only while you type. The request carries your words and your network address, as any web request does, and no identifier of ours.

### A2. Type III Audio isn't named (Build 35)

- **Current text.** Site/privacy/index.html:8-10 lists the hosts the app contacts. Type III Audio isn't one of them.
- **Why it's wrong.** Opening, playing or sharing a LessWrong or EA Forum post calls `https://api.type3.audio/narration/find` with the post's address (`SK/SessionKitFeeds/TypeIIIAudioNarration.swift:6-13`, `:19`; caller `S/SharedLinkVoiceover.swift:38`). The audio then streams from `dl.type3.audio`. To line the text up with the audio, the app reads the recording once into a temporary file (`S/PublisherAudioTextMapper.swift:140`).
- **Draft. Add to "Source and podcast requests":**
  > When you open, play or share a post from LessWrong or the EA Forum, the app asks Type III Audio once whether it has a narration of that post. It sends only the post's address. If there is a narration, it streams from Type III Audio. The app may read it once to line it up with the text, then deletes that copy.

### A3. "Not sent to our server" and "does not upload" are false for Build 35 testers

- **Current text.**
  - Site/privacy/index.html:11: "Your Margin recordings and Margin text are not sent to our server."
  - Site/privacy/index.html:18: "This build shares packets as files; it does not upload them to a developer-hosted sharing service."
- **Why it's wrong.**
  - Build 35 compiles link creation in (`project.yml:24-39`, `SM_SHARE_LINK_CREATION`), and the server has links on (fact 2).
  - "Share as Link" uploads the sealed packet and preview to `POST /api/v1/links` (`SK/SessionKit/ShareLinkUpload.swift:1-7`, `:172`, `:197-226`).
  - The packet includes recordings and Margin text (`SK/SessionKit/ServerSendConsent.swift:46-58`, the consent alert's own words).
  - The server keeps it 30 days (`B4/internal/links/store.go:18`).
- **Draft.**
  - Replace :11's sentence with:
    > Your Margin recordings and Margin text are not sent to our server, except locked inside a share link you choose to make (see Share links).
  - Replace :18's sentence with:
    > Packets you send as files go only where you send them and never pass through our server.
  - **Add a short beta section.** It is written to match today's code only: no App Attest key and no sender record.
    > **Share links (test builds only).** Some test builds can make a share link. Nothing is sent until you agree, the first time. The app locks the Margins you chose with a new key before anything leaves your phone. That covers their audio and text, a short excerpt of the source around each one, the source's title and address, and any sender name you typed. The key is only in the link, after the "#", and that part is not sent to our server. Our server stores the locked copy, which it cannot read. Anyone who has the link can open it. The link stops working after 30 days, and the locked copy is then deleted. If someone reports a link, our server stops showing it at once. It keeps a record of the report for 90 days: the link's id, the kind of problem, the date, and any words the reporter wrote.
  - **Code for each claim in that section:**
    - Consent first: `ShareLinkUpload.swift:199`, `S/ShareLinkSender.swift:52`.
    - Sealed on the phone, key in the `#` part: `ShareLinkUpload.swift:4-6`, `:225`.
    - 30 days, then content deleted with only the expiry kept: `store.go:18`, `:44-45`.
    - Report takedown: `B4/internal/api/links.go:426` (the abuse-material hold branch is `:357-418`).
    - The report record and its 90 days: `B4/internal/reports/reports.go:1-10`, `:47-53`; `B4/cmd/smserver/main.go:290-293`.
  - **What this section deliberately leaves out.** The one-year hold for abuse-material reports (`B4/internal/links/hold.go:15`, `:82`) is real code. The forwarding to the CyberTipline is a manual runbook (`docs/legal/cybertipline-runbook.md`). I'd put that sentence in the public version (B3), not the beta paragraph. Tell me if you want it now.

### A4. Packets carry a random sender id, and the page doesn't say so (Build 35)

- **Current text.** Site/privacy/index.html:18: "A shared packet can contain the Margin recordings and text, source references, and other material shown in its review."
- **Why it's wrong.** Every exported packet now carries the phone's random sender id (`S/Gate1AppModel+ShareExport.swift:188`, commit 69c264d, 2026-11-05, in Build 35). It is the same for everything that phone shares (the owner's call, 2026-11-05: one id per phone). It isn't shown in the review.
- **Draft. Add after that sentence:**
  > Each packet you share also carries a random code made on your phone. It is the same for everything you share from this phone, so a friend can hide all your Margins at once. It is not made from your name, your account or your device.
- **Stale comment.** The code comment at `SK/SessionKit/SenderIdentity.swift:4-6` still says "one id per friendship or group". It should say one per phone. That is a small code-comment fix for an app thread.

### A5. How long map transcripts are kept

- **Current text.** Site/privacy/index.html:15: "The map service removes its transcript input after generating a map and periodically removes stale transcript input once it is 24 hours old."
- **Why it's wrong.** The code is stricter, so the page is inaccurate rather than unsafe:
  - transcripts are held in memory only and never written to disk (research/B4/DESIGN.md §10, #1730);
  - the maximum age is 2 hours (`B4/internal/maps/store.go:16`, `TranscriptMaxAge = 2 * time.Hour`; swept at `B4/cmd/smserver/main.go:264`).
- **Draft.**
  > The server holds the transcript in memory only and never writes it to disk. It drops the transcript as soon as the map is made, or after two hours at most.

### A6. The OpenAI line is stale

- **Current text.** Site/privacy/index.html:16: "Remote OpenAI features are unavailable in this build."
- **Why it's wrong.** The code is removed, not merely off (#2845; `docs/launch/app-store-submission.md:33`). The app's own Settings says "Spoken Margins has no third-party AI provider or API key setting" (`S/SettingsScreen.swift:430`).
- **Draft.**
  > The app has no remote AI feature of its own. The only AI that works off your device is the optional community map service described above.

### A7. Terms §5 contradicts the privacy page (the most visible mismatch)

- **Current text.** Site/terms/index.html:10: "Local library data, recordings, transcripts, and settings remain on your device. Outside services receive information only when needed to retrieve a source you select or when you deliberately share or export content to a destination you choose."
- **Why it's wrong.** All of these happen without a select-or-share tap:
  - the tour is fetched from our server at every launch (`SK/SessionKit/GuidedOnboardingCoordinator.swift:42`; started from `S/Gate1AppModel.swift:3061`);
  - followed feeds refresh by themselves (`S/Gate1AppModel+LazyServices.swift`, FollowedSourceCoordinator);
  - episodes download by themselves on Wi-Fi (`SK/SessionKit/PodcastDownloads.swift:153-158`);
  - once turned on, Send Margins to Readwise sends Margin text every minute (`S/ReadwiseHighlightSync.swift:41`);
  - Help make listening maps uploads episode transcripts (`SK/SessionKit/CommunityMapUpload.swift:408`);
  - in Build 35, share links upload to our server.

  The privacy page already says most of this, so the Terms and the privacy page disagree.
- **Redline already drafted.** `docs/legal/terms-draft.md:47` patches the second sentence, but it still says data "remain on your device unless you share or export them". That misses Readwise and community maps.
- **Draft.** Shorter, and points to the policy:
  > **5. Privacy.** The Privacy Policy describes what Spoken Margins keeps and what it sends, and to whom. Your recordings, Margins and settings are kept on your device. They leave it when you share or export them, or when you turn on a feature that sends them, such as Send Margins to Readwise or Save Margins to Notes Folder. To work, the app also contacts the websites, feeds and services that hold the sources you choose or follow, some of them automatically, and our own server for the introductory tour, the podcast list and the features you turn on.
- **No re-acceptance needed.** This changes no obligation of the listener's, so §7 doesn't force re-acceptance. Bump the version to 1.1 and the effective date.

### A8. The App Store draft is stale today (not entered in App Store Connect, so not public)

`docs/launch/app-store-submission.md`:

- **:41** says "The app never uploads a packet: no share-link server is wired up". False since #487. Replace it with a row: "Share as Link (internal builds with `SM_SHARE_LINK_CREATION`) → `POST /api/v1/links` → sealed packet and preview, unreadable by the server, 30 days".
- **:45** says the server-config fetch and `ITunesSearchSourceResolver` are "never called today". Both are called now:
  - the config fetch: `S/BridgeService.swift:24`, used by `S/ShareLinkSender.swift:42`, `S/CommunityMapUploadService.swift:147` and `S/CommunityMapFetchService.swift:66`;
  - the search: A1.
- **Rows the table is missing:**
  - podcast name search (A1);
  - Type III Audio (A2);
  - community map upload and lookup (`SK/SessionKit/CommunityMapUpload.swift:408`, `SK/SessionKit/CommunityMapFetch.swift:355`; server forwards to Anthropic).
- **Draft for the maps row:**
  > Off by default. When on, an episode's transcript, an episode code, its length and language go to our server, which sends the transcript to Anthropic to write a map. No install key. Transcript held in memory, dropped after the map or 2 hours.
- **The label answer for maps.** I'd keep "Not collected": it is a public episode's text, it is not linked to anyone, and it is not kept. Confirm that with the lawyer as part of the Listening Maps gate.

---

## B. Becomes wrong when share links reach testers beyond Build 35, or the public

The owner's 2026-11-05 design (docs/decisions.md, "Share-link abuse design") is not in the app yet. Write these only when the code ships. Each paragraph must match the shipped code, not the plan.

### B1. App Attest, check-and-forget

- **Status (2026-11-12, #2239).** Built in the app, inside the link build: `AppAttestDeviceProvider` and `AttestedServerClient` make the key after consent, on the first sender check. The in-app consent alert is `ShareLinkConsentCopy` at `disclosureVersion` 2 and now says so. The app has no App Attest entitlement yet (the owner's Apple account must enable the capability), so on a real phone the attestation fails and the link is made without a permit, as before. The draft below still says the server "forgets which installation sent it"; the shipped server does not (#3313 ties a link to a keyed hash of the install until the link expires), so this paragraph must be rewritten to match before it is published.
- **Draft:**
  > Before your phone makes its first share link, it creates a random key for this installation of the app. Apple confirms to our server that the key belongs to a genuine copy of Spoken Margins. Apple does not tell us who you are or which device you use. When you upload a link, our server checks the key and then forgets which installation sent it: the key is not logged and not stored with the link. Deleting the app deletes the key.
- **Fix before this ships.** DESIGN.md §2 says the server keeps "public key, counter, environment, two day-precision dates" per install for 90 days idle. That is a record, so "forgets" only means "not tied to the link". Say so:
  > Separately, our server keeps the key's public half, a counter and the dates it was made and last used, deleted after 90 days without use.

### B2. Sealed sender, strikes and DeviceCheck

- **Code and design disagree today.** The server holds the *older* design. `B4/internal/senders/senders.go:1-15` and `B4/internal/api/sender.go:11-19` tie a keyed hash of the attested key id to each link id until the link expires. The owner's 2026-11-05 decision replaces that with a sealed tag that the server can open only with the sender key a report carries. The wording below follows the decision. Don't publish it until the server matches. Flag this to whoever builds #1728.
- **Draft:**
  > Each link carries a locked tag that says which installation made it. Only the link's own key can open the tag, so our server can't. A report sends the part of the key that opens the tag and nothing else, so we can count reports against the sender without seeing what they shared. If links from one installation are reported twice within 90 days, link sharing from it pauses: a week the first time, a month the second, and for good the third time. To keep a pause through a reinstall, our server uses Apple's DeviceCheck. Apple keeps two bits for your device, and we never receive an identifier for it. Sending `.spokenmargins` files directly is never affected.
- **The Android paragraph (#2981), when built:**
  > On Android, Google's Play Integrity does the same job, and Google sees each integrity check.

### B3. Abuse-material reports (one-year hold)

- **Code:** `B4/internal/links/hold.go:15`, `:82`, `:166`.
- **Draft:**
  > If a report says a link holds child sexual abuse material, the report includes the full link. We don't open it. We send it to the National Center for Missing & Exploited Children's CyberTipline, as US law requires. We keep the link and the report for one year in restricted storage, then delete them.
- **Check first.** The forwarding is manual (`docs/legal/cybertipline-runbook.md`). "We send it" is a promise the owner keeps by hand. Confirm it with the lawyer.

### B4. Deletion and retention

- **Current text.** Site/privacy/index.html:20 says nothing about links.
- **Draft. Add:**
  > Removing the app does not delete a share link you made. It stops working after 30 days, or you can ask us to remove it sooner. A reported link stops being shown at once.

  Add "Removing the app does not undo a sharing pause recorded with Apple" only once DeviceCheck ships.

### B5. Web and reports

- **Live text.** The web app at `app.spokenmargins.com` opens and reports links. Its reports are rate-limited in memory only (`B4/internal/reports/reports.go:6-10`).
- **Draft:**
  > Anyone can report a link from its page or from the app, without an account. To stop someone flooding reports, our server briefly remembers a scrambled form of the reporter's network address, in memory only, for up to 7 days. It is never written to disk.

  The 7 days is `ReasonWindow` (`B4/internal/reportrules/reportrules.go:103`).

### B6. App Store answers (`docs/launch/app-store-submission.md`)

- **:59, "User content: audio: Not collected".**
  - **Becomes doubtful.** Link uploads hold encrypted audio for 30 days.
  - **Uncertain point.** Whether data the developer cannot read counts as "collected" under Apple's definition is a question for the lawyer. I could not confirm Apple's current text.
  - **My pick.** Declare it, as the doc's own rule says over-declaring is safe (:15): "Audio Data: collected, not linked to you, not used for tracking, App Functionality."
  - **Draft reason:** "Only if the listener makes a share link: the Margins' audio is uploaded locked with a key that stays in the link; the server can't read it; deleted after 30 days."
- **:60, "Other User Content".** Already declared for Readwise. Add the share-link reason: "Margin text and a short source excerpt, locked, in a share link the listener makes; deleted after 30 days."
- **:64, "Identifiers: None created or sent".**
  - **Becomes false** once App Attest ships: there is a per-install key record on the server for 90 days (DESIGN.md §2), plus the DeviceCheck bits.
  - **Draft.** Follows DESIGN.md §7's own recommendation: "Device ID: collected, not linked to you, not used for tracking, App Functionality (fraud prevention). A random per-install key confirmed by Apple App Attest; the server keeps its public half and dates, deleted after 90 days unused. Not tied to links or reports."
  - **Not an identifier we collect.** The random sender id (A4) travels only inside packets the listener sends. In a link it is inside the locked packet, so it isn't one.
- **:15 and :49, "one type".** Update the count to match the rows above.

### B7. Terms §5

If A7's wording is used, nothing more is needed: "share" covers links. If the old redline is kept instead, add ", including a share link".

### B8. Map upload tokens (#743, off)

- **Status.** `B4/internal/api/maptokens.go`; DESIGN.md §10-11.
- **Draft, when `mapUploadToken` is turned on:**
  > Before uploading a transcript, the app uses its installation key to get a few anonymous passes from our server. The upload carries one pass, which proves it comes from a genuine copy of the app without saying which one.

---

## C. Depends on the #2034 host check: does the VPS keep IP addresses?

#2034 is open. The repo side holds:

- Caddy has no access log, and the error log deletes `remote_ip` and `client_ip` (`research/B4/deploy/caddy-global.caddy:3-15`).
- The journal keeps 14 days (`research/B4/deploy/journald@smserver.conf`).
- The rate limiter hashes the network address with a per-process secret, in memory only (`B4/internal/api/api.go:428-432`).

Still unchecked on the box: journald contents, ufw/iptables logging, fail2ban, and the provider's own logs.

### C1. Server logs paragraph

- **Current text.** Site/privacy/index.html:6-7: "Like other web requests, they expose a network address to the server while it responds. Our web server is configured without request access logs. Its error logging removes client network addresses and request headers."
- **True as written today.** It describes configuration, not the whole box. Keep it until #2034 is done.
- **Draft if #2034 finds nothing that keeps addresses:**
  > Our server sees your network address while it answers, as every web server must. It does not keep it. To stop floods of requests, it keeps a scrambled form of the address in memory, never on disk, for an hour (up to 7 days for reports). Its logs are hourly counts of which services were used and whether they worked, kept for 14 days.
- **Draft if something does keep addresses:**
  > Our server's [[firewall / hosting provider]] records network addresses for [[N days]] to protect against attacks. We don't use them for anything else.

### C2. Map lookup

- **Current text.** Site/privacy/index.html:14: "our server can see your device's IP address, as any web server can."
- **Draft. Add only after #2034 passes:** "It does not keep it."

### C3. App Store Q1 and Location

- **Current text.** `docs/launch/app-store-submission.md:15`, `:56` and `:92` all rest on "the owner's server must keep no logs that tie an IP address to a request".
- **If #2034 passes:** keep "Not collected" and close Q1.
- **If it fails:** declare "Coarse location" or "Other data": collected, not linked, not tracking.

### C4. Web reports "keep no IP"

The owner's 2026-11-05 point 3 is met in the server code (in-memory keyed hash only). The public sentence (B5) still rests on #2034 for the box.

---

## D. Microphone and speech prompts

These are app config: `project.yml` → `xcodegen generate` → `Info.plist`. They need an app-code thread and a build. The words a listener sees in a system alert are the owner's taste.

### D1. Speech recognition prompt: understates what it is used for

- **Current text.** `project.yml:200` and `App/SpokenMarginsApp/Info.plist:76`: "Spoken Margins turns your spoken Margins into text so you can search and copy them."
- **Why it's wrong.** The same permission also transcribes *source* audio:
  - podcast episodes, to place Margins: `S/ImportedPodcastPlacementCoordinator.swift:128`, `S/Gate1AppModel.swift:2840`;
  - Listening Maps: `S/EpisodeMapPreparer.swift:305`;
  - publisher narrations, to line up text: `S/PublisherAudioTextMapper.swift:140`.

  All of these go through `SystemSourceTranscriptionClient` (`SK/SessionKitAudio/AudioAdapters.swift:4462`). The prompt also doesn't say recognition is on-device, which the code enforces: `requiresOnDeviceRecognition = true` (`AudioAdapters.swift:308`), and a refusal when `supportsOnDeviceRecognition` is false (`:4228`, `:4494`, `:4585`).
- **Draft:**
  > Spoken Margins turns speech into text on this iPhone: your spoken Margins, so you can search and copy them, and podcast audio, so it can place Margins and build Listening Maps.
- **What not to add.** Don't add "the text never leaves your phone". A phone-made episode transcript is uploaded when Help make listening maps is on (`S/CommunityMapUploadService.swift:36`), and Margin text goes to Readwise when that is on.

### D2. Microphone prompt, iPhone: true today and with links

- **Current text.** `project.yml:199`: "Spoken Margins records your spoken Margins while you listen. Recordings stay on your phone unless you choose to share them."
- **Still true with links.** A share link is a choice to share. Readwise and community maps never send recording audio (`docs/launch/app-store-submission.md:35`). No change.

### D3. Microphone prompt, Watch: true

- **Current text.** `project.yml:253`: "Spoken Margins records the Margins you speak on your Watch and sends them to your iPhone."
- **Still true.** No change. Optionally match D2 by adding: "where they stay unless you choose to share them."

No other `NS*UsageDescription` keys exist in `project.yml` or any app `Info.plist`. Grepped: only these three.

---

## Outside the four surfaces (flag only)

- **The web app's Settings says "Nothing is sent to us".** `app.spokenmargins.com` is live, and `Web/src/app/screens/Settings.tsx:61` says "Your shows, your place in each episode and your Margins stay in this browser. Nothing is sent to us." But:
  - after a consent pop-up, the relay sends a feed or page address of a show the listener follows to our server (`B4/internal/relay/relay.go:1-3`; `smserver.service:39` `-relay-origins`);
  - opening a link fetches the packet from our server.

  The privacy page doesn't cover the web app at all, and the web app links only to the copyright page. That needs a web-thread fix and a web section in the policy.
- **The contact change hasn't been deployed.** The 2026-11-05 contact change is in `Site/` but not live (fact 1). Deploying `Site/` is the owner's step.

## My pick

1. **Go live now.** Publish A1–A7 together, with Terms 1.1, in the same deploy that carries the new contact address.
   - It describes builds testers already hold.
   - Share links in a private beta were cleared before the lawyer (docs/decisions.md 2026-10-20 and 2026-11-02).
   - A3's beta paragraph claims only what today's code does.
2. **Fix the App Store draft (A8) in the same docs PR.** It isn't public.
3. **Wait for the lawyer.** These wait for the shipped code and the lawyer, and go up with the public share-link release: B1–B3 and B5 (App Attest, sealed sender and strikes, DeviceCheck and Play Integrity, the CyberTipline hold), B4, and the App Store label changes in B6.
4. **Wait for #2034.** C1–C3 wait only for the host check, not the lawyer. Do #2034 before any of B goes out, as #2034 itself says.
5. **Separate app thread.** D1 needs one and the owner's yes on the words.
