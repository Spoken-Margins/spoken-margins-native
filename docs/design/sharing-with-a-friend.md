# Sharing with a friend: a reimagining

Spoken Margins · design doc · 4 October 2026 · designed against `next` at `1744dff`

Mockups only. Nothing here is built, filed or tried on a device. Code facts are cited with `file:line` on `next`; anything I inferred rather than checked says so.

## The short version

1. **The thing you share is a moment, not a file.** A moment is a few seconds of the source, then your voice, then a little of what came after. One Margin is one moment. Several Margins become a short **cut**: "Cole's cut of *Planet Money*, 3 moments, 4 minutes".
2. **Sending takes two taps.** Tap Share on any Margin or item. A half sheet shows exactly what your friend will hear, with a Play button. Tap **Send link**. The iOS share sheet opens with your contacts at the top.
3. **Your friend's first listen takes two taps.** They tap the link in Messages. The app opens on one card: your name, your words, the show, and a big Play. They tap Play and hear the lead-in, your voice, and the episode carrying on.
4. **Friends without the app still get it.** The same link opens a phone web page with your words, a short quote either side, the episode and a link to the exact spot in the original. Installing the app and tapping the link again picks up where the page left off.
5. **They answer by voice, in place.** After each moment there is a **Reply** button: hold to talk. Their reply comes back to you as a link, and you hear it right after your own moment. Three friends on one episode become a conversation you listen to.

The key technical move: **nothing new has to cross into Build 29 as a requirement.** The cut and the replies ride in optional packet artifacts. Build 29's reader skips optional artifact kinds it doesn't know (frozen reader, `Packages/SessionKit/Tests/ShippedReader/SessionKitSharing/InterjectionPackageArchive.swift:501-504`), so a friend on Build 29 still gets the Margins as plain shared Margins. The cut renders with the same renderer the "Getting back to notes" design proposes (`ListenBackRenderer`), so the app gains one way to stitch audio, not two, and no new playback state machine.

## 1. Where this flow stands today

### What exists (on `next`)

| Step | What happens | Where |
|---|---|---|
| Sender entry | Every entry (playback Share, Margins tab item Share, Timeline icon, item page "Export latest session") goes to the **Export** screen first, then "Share Margins (N)". There is no per-Margin share. | `ExportScreen.swift:16-35`, `PlaybackScreen.swift:244`, `ExperienceMarginsScreen.swift:116` |
| Sender flow | Four stages: Choose Margins (with a collapsed "Sharing options" group: sender name, acoustic evidence, an embedding-rights toggle, copyright notices) → Review one Margin at a time (Original / Cleaned / Text, word removal, editable excerpts) → write, read back and verify the packet → share sheet. | `Build23SenderSharingExperience.swift`, stages in `Build23SharingSeams.swift:10` |
| What's sent | A `.spokenmargins` ZIP file only. Share sheet subject: "Spoken Margins shared session". No link. | `Gate1AppModel.swift:13748-13883`, `SharingExperience.swift:865-909` |
| Packet | Margins with voice and text, bounded anchor excerpts (≤500 characters each side), optional acoustic evidence, listening map, phrase sketches, conversation artifact. Never the source audio. Sender is a free-text label, unsigned. | `InterjectionPackageArchive.swift`, `SharingModels.swift:251`, `:970` |
| Recipient opens | File opens the app (or goes through the Share extension's inbox). Verified, deduplicated by digest, matched to a Library item. | `Gate1AppModel.swift:8358-8370`, `:7850-7917`, `:8323` |
| Recipient preview | "Shared Margins", "Integrity checked", title, "Shared by …", count, "Source transport", "Item contents". **The Margins' words aren't shown and can't be heard before Import.** | `Build23RecipientSharingExperience.swift:58-235` |
| After Import | Podcasts: found by link, added, download queued. Text pasted into the packet: installed. **An article shared by link: saved with no item at all** (`itemId = nil`), so its Margins can never be placed. "Imported shared Margins. Playback has not started." | `Gate1AppModel.swift:7981-7990` |
| Placement | Podcast placement runs once the whole episode file is on the phone: ShazamKit flanks, transcript fallback, fusion. Until then: "Matching positions in your episode". | `resolveImportedPodcastCommentary` (`Gate1AppModel.swift:16161`), `PodcastAnchorEvidence.swift` |
| First listen | Four ways: the item page's "Listen" (voice alone, no context); a Timeline tap (#158: 30 s lead-in, the voice, then the episode carries on, through `MarginMomentConductor`); passive playback cues (companion / guided / fresh; the app never sets which); "Play this moment" (own Margins only). | `Gate1AppModel.swift:7188-7269`, `:2243`, `MarginMoment.swift:31`, `:7314` |
| Replies | SessionKit has the whole model: reply links, a conversation artifact Build 29 ignores, a reply graph. **The app uses none of it**; there is no Reply button. | `MarginConversation.swift`, `SharingFoundation.swift:37`, `:286-303` |
| Co-op | Hot-spot grouping exists in SessionKit (#475), unused. The three-packet merge (#468) is on a branch, not `next`. | `MarginLayerSynthesis.swift` |
| Links | None in the app. The server side is built and waiting: PR #725 holds a packet for 30 days behind `/l/<id>`, with a landing page (Margin text, quotes, source link, install button, report). App side #487 and universal links #488 are `ready`. | PR #725, #487, #488 |

### Taps today

| Task | Today | Proposed |
|---|---|---|
| Share one Margin with a friend | Not possible on its own. Shortest path for an item: Share → Share Margins (N) → Review N → Share N → share sheet → contact: **5 + contact**. From the item page: about 10. | **2 + contact** |
| Share all of an item's Margins | Same as above | **2 + contact** |
| Friend with the app hears the first Margin | Tap file → open in Spoken Margins → Import → find the Shared Margins card or the Timeline → Listen: **about 5**, and they hear the voice without the moment | **2**: tap link, Play |
| Friend without the app sees what you said | Impossible: a file they can't open | **1**: tap link |
| Friend replies | Impossible | **Hold Reply, talk, release, Send: 3 + contact** |

### What gets in the way

1. **Sharing starts in the wrong place.** Every path goes through "Export", which is about notes, and then through four stages built for auditing a packet rather than sending a thought. D4 quotes you: "If it takes five or six clicks to share something with a friend, you're never going to do it."
2. **The sender reads paperwork first.** Copyright notices, "Include acoustic evidence", "I have the right to privately embed this linkless material", and errors like "The recipient preview is stale. A package-affecting choice changed. Build and verify a fresh preview before sharing." These protect real things (the accepted 12 September policy, `docs/external-testflight-sharing-decision.md`), but they sit in front of the one action people came for.
3. **Failure is a dead end.** A streamed episode's Margins can fail with "episode fingerprint spine is out of bounds" and no way forward (#536, found on your phone).
4. **What arrives is a file.** A grey document in Messages called "…shared session". Someone without the app has nothing to open.
5. **The recipient has to accept before they can listen.** The preview leads with integrity and "Source transport", and hides the words and the voice.
6. **The first listen is the weakest part.** After Import nothing plays. The obvious button ("Listen") plays the voice with no context, which is the one way a Margin makes no sense. The good version (#158's moment) is hidden behind a Timeline tap.
7. **Podcast placement waits for the full download.** A friend who streams sees "Matching positions in your episode" and gets an approximate position.
8. **Articles shared by link go nowhere.** The import keeps the Margins but never fetches the article.
9. **There's no way back.** A friend can't answer, so sharing is a broadcast, not a conversation.

## 2. Three bold directions

### A. Send this moment (one Margin, one link)

The unit of sharing becomes a single moment, sent as a link with a rich preview in Messages. The link opens the app straight into playing the moment, or opens a web page for people without the app. Think "share a timestamped clip", except the clip is your thought about the episode and the episode itself is never copied.

- **Good:** the smallest change with the biggest felt difference. Uses work that's built or ready (#725, #487, #488, #158).
- **Bad:** one moment at a time. Doesn't help the "here are my six notes on this episode" case, and there's no reply, so it stays a broadcast.

### B. Hear it with me (the cut, and replies) — recommended

Sharing an item sends a **cut**: your moments in order, each with a short lead-in, played as one short listen. Your friend hears the episode the way you heard it, through your reactions, in four or five minutes. They can then play the whole episode with your Margins coming up as they go. After each moment they can hold **Reply** and talk. Their replies come back to you as a cut of their own.

- **Good:** it's what makes Spoken Margins different from sending a podcast link. It turns sharing into a conversation without a server or accounts. One moment (direction A) is just a cut of length one, so A is the first step of B.
- **Bad:** more to build. Rendering a cut needs the friend's copy of the episode on the phone (there's a fallback, below). Replies need the reply plumbing wired into the app for the first time.

### C. The listening room (a club with a server)

A shared space per item or per group. Anyone with the invite link sees everyone's Margins arrive without passing files around, gets a notification when a friend has finished and left Margins, and can join a live session where everyone plays the episode in sync over FaceTime (SharePlay), each from their own copy.

- **Good:** effortless once set up. It's the "book club" F1 M3 describes, and it's where hot spots (#475) become worth having.
- **Bad:** a server that holds people's voices and reading for as long as the club lives, so end-to-end encryption, accounts or invite keys, moderation and cost all become real before anyone hears anything. F1 says to do the serverless version first, and I agree.

### Why B, with A as its first step and a door left open to C

B delivers what sharing is for: your friend hears what you heard, and answers. It builds on what's on `next` (the moment conductor, the reply model, the link server) rather than starting new systems. Starting with a single moment (A) means the first slices land fast and you can feel the difference on the phone early. C's group features (new-to-me, hot spots, a group cut) fall out of B once packets from several friends merge (#468), so C becomes "B, plus a server to carry the packets" later.

## 3. The recommended design in detail

The clickable mockup is at https://claude.ai/artifact/E6LrL8jUiETYVyr4Uj58qP (private to you). The words below are the spec.

### 3.1 The unit: a moment

A **moment** is one Margin played in place:

1. **Lead-in:** the source just before the Margin. Default 20 seconds for podcasts, the sentence or two before it for articles and PDFs. (Today's moment uses 30 s, `MarginMoment.swift:31`; for a friend who doesn't know the episode, 20 s is enough to orient and keeps a 5-moment cut under 5 minutes. A reversible default; see §5.)
2. **The Margin:** the sender's voice. Original or cleaned, as the sender chose. A written Margin is read by the device voice and labelled "read by your phone", never presented as the sender's voice (the policy's rule on synthetic voice).
3. **Carry-on:** 3 seconds of the source after the Margin, faded out, so it doesn't end on a cut-off word.

A **cut** is an ordered list of moments with an optional spoken intro from the sender ("Sam, the bit at 20 minutes is the one I was telling you about"). The intro is recorded like any Margin.

### 3.2 Sending: the Send sheet

**Where you start.** A Share button (the standard iOS share icon) on:
- any Margin: the Margin row's swipe or long-press, the Margin page, the "Near here" Margins on the Now view, and the Timeline;
- any item: the item page, the Margins tab's item header, More on the playback screen, and the end-of-episode card ("Send your Margins to someone").

**Tap 1 opens the Send sheet.** It's a half sheet, one screen, no stages:

```
┌──────────────────────────────────────┐
│ Send to a friend                Done │
│                                      │
│ ┌──────────────────────────────────┐ │
│ │ ▶  Cole's cut · Planet Money      │ │  ← the card your friend sees;
│ │    "Middlegarchs are the new …"   │ │    Play lets you hear it first
│ │    3 moments · 4 min              │ │
│ └──────────────────────────────────┘ │
│                                      │
│ Moments    This one · Starred (3) · All (6) │
│ From       Cole                    › │
│ Includes   Your voice, 3 short quotes,│
│            matching data           › │
│ ⓘ Only share what you're allowed to › │
│                                      │
│ [ Edit moments ]   [ Send link  ]    │  ← Send link is the big one
│              Send as a file          │
└──────────────────────────────────────┘
```

- **Defaults.** From a Margin: "This one". From an item: Starred if any are starred, else All (today's rule, `Gate1AppModel.swift:13175-13207`). Voice: cleaned if a cleaned version exists, else original. Name: remembered (`sharingSenderDisplayLabel`); the first time, it asks once.
- **Play on the card** plays exactly what the friend will hear. You can check it by ear, which is how you check everything.
- **Includes** is one line that names what actually goes out: your voice or words, how many quotes, and matching data. Tapping it opens today's options (acoustic evidence on/off, per-Margin Original / Cleaned / Text). The accepted policy says acoustic evidence must be "explicitly visible and reversible before preview"; this line keeps it visible and one tap from reversible.
- **The copyright line** is the accepted wording, shown in full the first time you share and in the Includes page every time; on the sheet after that it's one line. That placement is an amendment to the 12 September policy, so it's your call (§5, decision 2).
- **Edit moments** opens today's review screen, unchanged: trim the lead-in, change Original / Cleaned / Text, edit excerpts, reorder, record an intro. It's there for when you want it, not a step you must pass.

**Tap 2, Send link,** builds and verifies the packet (as today), uploads it (#487), and opens the iOS share sheet with the link. The share sheet's top row is your recent contacts, so it's one more tap to a person. The link carries a rich preview (title, your first words, the show, "3 moments · 4 min"), supplied by the app itself (`LPLinkMetadata`). Messages builds the bubble on the sender's phone from that, so the server doesn't need to be asked (inference from how Messages previews work; check on a device).

**Send as a file** is today's `.spokenmargins` file, for AirDrop, a friend on Build 29 without links, or when the server is off. When the links service is off or the upload fails, the sheet says "Links aren't available right now. Send as a file instead?" with the file button already in place (#487's rule).

**Never a dead end.** If an optional piece fails its own check (the #536 spine error is one), the packet is rebuilt without that piece, and the sheet says in one line what changed: "Sent without episode matching. Sam's app will place your Margins by time." The full reason stays in diagnostics.

### 3.3 Your friend has the app

**Tap 1: the link.** With universal links (#488) it opens the app. With the file, it opens through "Open in Spoken Margins" as today.

**What they see: one card, not an import form.**

```
┌──────────────────────────────────────┐
│  C   Cole sent you 3 moments          │  ← initial in a circle, not a color
│      from Planet Money                │
│                                       │
│  Middlegarchs are the new Oligarchs   │
│                                       │
│  "This is the housing point again."   │  ← first moment's words
│   at 20:41                            │
│                                       │
│        (  ▶  Hear Cole's cut  )       │  ← 4 min
│                                       │
│  Play the episode with Cole's notes › │
│  Not now                              │
└──────────────────────────────────────┘
```

- Verification runs in the background exactly as today. Only a failure is shown, in one plain line ("This share is damaged. Ask Cole to send it again.").
- Opening the link adds the share to a **From friends** shelf on Home and to the item's Margins. That's an addition, never a change to anything they had, and one swipe removes it. It replaces the Import / Cancel step (§5, decision 1). Nothing plays until they tap Play.
- "Not now" leaves it on the From friends shelf with an unplayed dot.

**Tap 2: Play.** The cut plays in the normal Now Playing screen, with one chapter per moment ("Cole · 20:41"), so speed, skip, the Lock Screen and AirPods all work. The dock's chapter row reads "Moment 1 of 3 · Cole". After the last moment: "That's Cole's cut. Keep listening from 21:03?" with the episode ready to carry on from the last moment.

**How the cut gets the episode audio.**
- **The episode is already on the phone** (downloaded, or in the Library): the app finds the moments (today's placement, `resolveImportedPodcastCommentary`), renders the cut to one file with chapters, and plays that. It's the same renderer as the "Getting back to notes" design's `ListenBackRenderer`. A friend's cut is a listen-back plan with someone else's voice in it.
- **The episode isn't on the phone yet** (the common case for a friend): the first moment plays straight away through today's moment conductor on the stream (#158's path: lead-in, voice, carry-on), so they hear something within seconds. The rest of the episode downloads behind it; once it's in, the remaining moments are placed and rendered. If the download is slow, each later moment plays on the stream the same way, labelled "about here" until placed. (A bolder option for later: place moments **while streaming the lead-in**, by matching the sender's "before" fingerprint against the audio the stream tap already captures (#154). That would remove the wait for the download. It's an inference that needs a spike; slice 14.)
- **Articles and PDFs:** the lead-in is the sentence before the Margin, read by the device voice. If the article isn't on the phone, the app fetches it from the shared link with the existing extractor (`AppOwnedReadablePageExtractor`), which fixes today's "imported with no item" gap. If it can't fetch (paywall, offline), the cut still plays from the packet's own quote (the ≤500-character excerpt before the Margin), labelled "quoted from the article".

**Afterwards.** The Margins live on the item, in the sender's style (hollow blue diamond, the same as the playback design), and come up as the friend listens to the whole episode. "Play the episode with Cole's notes" sets companion mode for this layer (the packet's `suggestedRevealMode`, which the app has never set).

### 3.4 Replying by voice

- During and after each moment, the dock's Add a Margin button reads **Reply to Cole**. Hold to talk, release to save. It's the same recording path as any Margin, so cleaning, transcription and leveling all apply. The reply is attached to Cole's Margin with SessionKit's existing `MarginReplyLink`, not to a time in the audio.
- At the end of the cut, if they replied: "Send your 2 replies to Cole" → the same Send sheet, preset to "Replies (2)", → share sheet with Cole's conversation at the top (it's who sent the link, when the share came from Messages; otherwise they pick).
- **Cole gets them back as a cut.** Opening the reply link: "Sam replied to 2 of your moments". Play gives, for each: the lead-in, a 3-second reminder of Cole's own Margin (faded), then Sam's reply. Cole can reply to the reply; replies stack behind the Margin they answer, exactly as the playback design's reply stacks draw them.
- **Build 29 friends** see replies as plain shared Margins at the parent's position, which the conversation artifact was designed for (`MarginConversation.swift`; F1 M2 wording).

### 3.5 Your friend doesn't have the app

The same link opens a phone web page (PR #725's page, plus three small additions):

```
┌──────────────────────────────────────┐
│  Cole shared 3 moments                │
│  from Planet Money                    │
│  Middlegarchs are the new Oligarchs   │
│                                       │
│  20:41                                │
│  ❝ …and the houses those wages buy   │  ← quoted from the source,
│    keep getting further away.❞        │    ≤500 characters
│  Cole: "This is the housing point     │
│  again."                              │
│  ── Open the episode at 20:41 ›       │  ← the public episode page
│                                       │
│  [ Get Spoken Margins to hear it ]    │
│  Have the app? Open in Spoken Margins │
│  Report this link                     │
└──────────────────────────────────────┘
```

- **#725 as built** already gives the words, the quotes, the show and title with a link to the public source, an install button and "Report this link". No source audio, ever, and no scripts.
- **Addition 1: go to the exact spot in the original.** For articles, the source link carries a text fragment (`#:~:text=`) so Safari scrolls to and highlights the passage. For podcasts, the page shows the time next to the episode link; whether a podcast page can take a start time differs by host and is to be checked, so v1 only shows it.
- **Addition 2: "Open in Spoken Margins"** downloads the packet (`/l/<id>/packet`, already in #725). That works for a friend on Build 29, which has no universal links.
- **Addition 3: after installing, tap the link again.** The page says so in one line. iOS gives an app no reliable way to know which link brought someone to install it, so the honest path is the second tap. (An App Clip that plays the moment without installing is possible later and is a public App Store decision; §5, decision 4.)
- **Your voice on the web page** is not in v1: #725's test forbids any audio element. It's the thing that would make the page feel like the app, so it's decision 3, tied to end-to-end encrypted links.

### 3.6 Listening together

Serverless first, as F1 says.

- **Several friends, one episode.** When packets from two or more people land on the same episode, they merge into one item with attributed layers (#468). The From friends shelf then shows "**3 friends, 9 new moments** on Planet Money", and Play gives a **group cut**: everyone's new moments in episode order, each introduced by a short spoken name ("Sam, at 20 minutes"), replies right after the Margin they answer. "New" means not yet heard on this phone (#469), and your own Margins are never "new" (the 24 September correction in the parked co-op plan).
- **Crowded spots.** When three or more Margins fall within 45 seconds, the cut plays them as one stop and says so ("Three of you reacted here"), using the hot-spot grouping already in SessionKit (#475).
- **Sending back to the group** is the Send sheet with "New since you got it" as the moment choice, sent to the group chat. Everyone's app merges the same way.
- **Later (direction C):** a server-held room so nobody passes links, and SharePlay to listen live in sync over FaceTime, each person streaming their own copy. Neither is in this plan's slices.

### 3.7 Edge cases

| Case | What happens |
|---|---|
| The friend already has the episode | The share joins the existing item. No duplicate (today's matcher, `Gate1AppModel.swift:8323`). |
| The friend's copy has different ads | Placement handles it as today (zero false-confident placements is the gate). Unplaced moments play at the sender's time, labelled "about here". Never silently wrong. |
| A private feed (Patreon, Supercast) | The private URL never leaves the sender's phone (`ShareableLinkPolicy`, #168). The friend sees "Cole listened on a private feed. Add your own feed link to hear it in place." (#454). The words and voice still play. |
| A Margin recorded within 16 s of a start or seek (no "before" fingerprint) | Placed from the "after" fingerprint and neighbours, or labelled "about here". |
| Text-only Margin | Read by the device voice, labelled "Cole wrote:". |
| The same link opened twice | Nothing duplicates (digest dedupe, as today). Opens the same card. |
| The link has expired (30 days) | App: "This share has expired. Ask Cole to send it again." Web: #725's "isn't available" page. A file share never expires. |
| Links switched off on the server | The Send sheet offers the file; links already sent show the expired message. Nothing else in the app changes (the kill-switch rule, `research/B4/DESIGN.md` §4). |
| Friend on Build 29 | Gets plain shared Margins (no cut, no reply threading) from the file, or from the web page's "Open in Spoken Margins". |
| Friend offline | The card shows; Play says "You're offline. Cole's voice will play, and the episode will join in when you're back." |
| Someone forwards the link | Anyone with the link can open it for 30 days; the Send sheet's Includes page says so (accepted policy wording: "Recipients can keep or forward this file"). |
| Abuse | "Report this link" on the page and in the app's ⋯ menu; the owner takes down by id (`smserver takedown`, #725). |

### 3.8 Privacy

- **What the server holds:** for v1, exactly #725: the packet and a small preview (texts, quotes ≤500 characters, title, show, public source link) for 30 days, under an unguessable 128-bit id. No account, no address book, no IP or id in logs.
- **What it never holds:** the source audio, private feed links, anything about who opened a link.
- **The better version (decision 3):** encrypt the packet and preview on the phone and put the key in the link's `#` part, which browsers never send to a server. The server then can't read the Margins at all; only people with the whole link can. The cost: the page needs a small script to decrypt, and other apps' link previews (WhatsApp, Signal) can't show the words, only "Cole shared 3 moments". Messages still can, since the sender's phone builds that bubble (to verify).
- **Identity is a name you type.** It isn't verified, and the card says "From Cole" without claiming more, as today. Signing is out of scope (#22).

### 3.9 Accessibility

- **Everything you read, you can hear.** The Send sheet's card plays what your friend will hear. The friend's card plays. The web page shows plain text that Safari's Listen to Page can read.
- **Short, plain copy.** One idea per line. No "integrity", "transport", "capability" or "package" in anything a listener sees; those stay in diagnostics.
- **Colour never carries meaning alone.** Yours is a solid amber diamond, a friend's is a hollow blue diamond (the playback design's rule). Senders are an initial in a circle. Unplayed is a dot plus the word "new". Placed versus "about here" is said in words.
- **Large targets.** Play is at least 64 pt; every other control at least 44 pt. Hold-to-reply has a tap-to-start, tap-to-stop alternative for people who can't hold.
- **VoiceOver** reads the card as "Cole sent you 3 moments from Planet Money. First: This is the housing point again, at 20 minutes 41. Hear Cole's cut, button, 4 minutes." Dynamic Type sizes all text; at accessibility sizes the card scrolls instead of truncating.

## 4. What it needs

### From packets (all readable by Build 29)

| Need | How | Build 29 sees |
|---|---|---|
| Moments in an order, lead-in lengths, the intro | New **optional** artifact `listening_cut` (`listening-cut.v1`): ordered Margin ids, lead-in ms per moment, which Margin is the intro, a title. Not in `requiredCapabilities`. | Skips it (`default:` branch, frozen reader `InterjectionPackageArchive.swift:501-504`). Shows the Margins, intro included, as plain shared Margins. |
| Replies | The existing optional `conversation` artifact (`margin-conversation.v1`) with `MarginReplyLink`s. | Replies as plain Margins, as designed. |
| Reveal mode | Set the existing `suggestedRevealMode` to `companion`. | Already an allowed key and value. |
| Never a dead end | Export drops an optional artifact that fails its own validation and records why. | Same packet shape as today. |
| Proof | Every new packet shape goes through `ShippedReaderRoundTrip`. | — |

No new required capability and no new manifest key. The From friends shelf and "new to me" state are local to the phone; whatever stores them must be additive so Build 29 can still open the database (the AGENTS.md rule; #469 owns "new to me").

### From the server

- **v1:** PR #725 as built, then switched on by you. Plus the page's three additions in §3.5 (a text-fragment link, the time label, "after installing, tap again").
- **Later, with decision 3:** an encrypted-blob mode (the server stores ciphertext; the page decrypts with the `#` key) and, optionally, the sender's voice on the page.
- **Never:** source audio, accounts, a contact list.

### App pieces

| Piece | Where | Built on |
|---|---|---|
| `ShareDraft`: the Send sheet's defaults and the "Includes" summary, as a value | SessionKitSharing | Today's candidate rules (`Gate1AppModel.swift:13175-13207`), `ShareableLinkPolicy` |
| `ShareLinkClient` | SessionKit | #487 as specified |
| `ListeningCutPlan`: moments → ordered plan (lead-ins, intro, names, merged hot spots) | SessionKit | `MarginMoment`, `MarginLayerSynthesis` (#475), reply graph |
| Cut rendering | SessionKitAudio | The notes design's `ListenBackRenderer` (shared, not duplicated) |
| Stream-first first moment | App, thin | `MarginMomentConductor` (#158 path) |
| Send sheet, friend card, From friends shelf | App views | Thin call sites only; no new `Gate1AppModel` state |

## 5. Decisions for you

1. **Let opening a shared link go straight to the card, with no Import step.** It adds to the Library (one swipe removes it) and never plays by itself. **My pick: yes.** It's most of the "two taps to hear it". Blocks slice 7.
2. **Move the copyright notice.** Show the accepted wording in full on someone's first share and on the Includes page every time; one line on the Send sheet after that. The wording itself doesn't change. **My pick: yes.** It's an amendment to the 12 September policy, so it's yours. Blocks slice 3's final copy (it can ship with the notice in full meanwhile).
3. **End-to-end encrypted links, and your voice on the web page.** Encrypted links mean the server can't read Margins; the page gains a small script. Voice on the page would only be offered with encrypted links. **My pick: encrypted links yes (after #725 v1 ships), voice on the page yes but off by default per share.** It's public-facing, so it's yours. Blocks slices 15 and 16 only.
4. **An App Clip** so a friend without the app hears the moment without installing. **My pick: not now.** It needs App Store distribution and a size budget; revisit after the invite beta (#453). Blocks nothing.

Reversible defaults I'm taking (veto any): a 20 s lead-in for friends' cuts (your own "Play this moment" keeps 30 s); cleaned voice when available; "Send link" as the big button and file as the second; a group cut introduces each person by name.

## 6. Proposed slices

Each is S or M and ships something you can see or hear. Ordered so a friend can hear a moment from a link as early as possible. "Cloud" means buildable and testable without the Mac. Lane tiers follow `docs/workstreams/test-lane.md`.

| # | Slice | Size | Where | Tier | Notes |
|---|---|---|---|---|---|
| 0 | Merge #725 (server links); you deploy and switch `links` on | — | — | T0 | Built. Your deploy. |
| 1 | #487: Send link uploads the packet and shares the URL | M | Cloud | T2 | `ready` today |
| 2 | `ShareDraft` in SessionKitSharing: defaults (this one / starred / all), remembered name, cleaned-if-available, the Includes summary; Build 29 round trip | S | Cloud | T1 | Packet audit (Codex) |
| 3 | The Send sheet: one screen with Play-what-they'll-hear, Send link, Send as a file, Edit moments (today's review screen) | M | Mac | T3 | Thin call sites; copy waits on decision 2 |
| 4 | A Share action on every Margin (row, page, Near here, Timeline) and the end-of-episode card | S | Mac | T2 | Removes the Export detour |
| 5 | Never a dead end: rebuild without a failing optional artifact and say so in one line | S | Cloud | T1 | Builds on #536's fix; packet audit |
| 6 | Rich link preview from the app (`LPLinkMetadata`: title, first words, show, count) | S | Mac | T2 | Owner check: the bubble in Messages |
| 7 | #488: universal links open the app on the shared item | M | Mac | T3 | `ready`, `where:mac` |
| 8 | The friend's card replaces the import preview; From friends shelf on Home; first moment plays on the stream through the conductor | M | Mac | T3 | Waits on decision 1 |
| 9 | Articles shared by link fetch the article on open; the quote fallback when they can't | M | Cloud (resolver) + Mac (wiring) | T2 | Fixes `itemId = nil` |
| 10 | `listening_cut` optional artifact: writer, reader, Build 29 frozen-reader test, schema | S | Cloud | T1 | Packet audit |
| 11 | `ListeningCutPlan` in SessionKit: order, lead-ins, intro, names, hot-spot merging; host tests | M | Cloud | T1 | Uses #475 |
| 12 | Render the cut with `ListenBackRenderer` and play it as chaptered audio | M | Mac | T3 | After the notes design's renderer slice; audio audit |
| 13 | Reply to Cole: hold-to-reply from the dock during a cut, stored as `MarginReplyLink` | M | Mac | T3 | First app use of the reply model |
| 14 | Spike: place a moment while streaming the lead-in, from the "before" fingerprint | M | Mac | T3 + owner by ear | Inference to test; drop if it can't meet the zero-false-confident gate |
| 15 | Send replies back; open a reply link as "Sam replied to 2 moments" and play them in context | M | Mac | T3 | Conversation artifact; Build 29 test |
| 16 | Web page additions: text-fragment link, time label, "Open in Spoken Margins" (packet download), "tap again after installing" | S | Cloud | T0 | Server and page only |
| 17 | Group cut: "3 friends, 9 new moments", names spoken, own Margins excluded | M | Mac | T3 | After #468 and #469 land |
| 18 | Encrypted links (`#` key), then optional sender voice on the page | M | Cloud + Mac | T1 / T2 | Waits on decision 3 |

**Waits on the shared moment type (added 4 Oct, owner review).** Slices 8, 11, 12 and 14 don't start until #807 merges. #807 is one SessionKit type that owns every lead-in: Play this moment (30 s), this design's 20 s cut with its 3 s carry-on, and Listen Back's 8 s. `ListeningCutPlan` takes its lead-ins from it.

**Owner checks, in order:** after 6 and 7, send yourself a link and tap it (two minutes). After 12, send a friend a cut of three moments and ask them to listen (ten minutes). After 15, have them reply.

## 7. How this lines up with what exists

- **D4 (share)** M1's "two taps to share" is slices 2–6. D4 put links out of scope until a web endpoint exists; #725 is that endpoint.
- **D5 (player)** owns the dock; this uses its chapter row and "Add a Margin" spot for Reply, and its diamond and reply-stack rules.
- **F1 (co-op)** M1 is #468/#469; M2's review-and-reply is slices 13 and 15; M3's server is direction C, not planned here.
- **C4 (anchors)** owns placement; slice 14 is the only new placement work and is gated on the same benchmark.
- **"Getting back to notes"** (the sibling design in this folder) owns `ListenBackRenderer`; slice 12 uses it, so whichever lands first builds it once.
- **The invite beta (#453)** leads with "a Margin on their own episode, as a link". Slices 0, 1, 6 and 16 are what that first message needs.
- Related issues: #14, #22, #158, #159, #168, #169, #454, #468, #469, #475, #486, #487, #488, #536.

## Sources checked

`AGENTS.md`; `docs/workstreams/streams/D4-share.md`, `F1-coop.md`, `D1-design.md`, `D5-player.md`, `B4-bridge.md`; `docs/external-testflight-sharing-decision.md`; `docs/podcast-anchor-plan.md`; `docs/journeys.md` (J5); `docs/growth/invite-beta-plan.md`; `research/B4/DESIGN.md` on `ws/b4-bridge`; `docs/co-op-experience-plan-2026-09-24.md` on `park/co-op-2026-09-24` (reference only); issues #429, #486, #487, #488, #536, #468; PR #725; the playback round-two design artifact; the sender, recipient, import and conductor code on `next` at `1744dff` as cited above.
