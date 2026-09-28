# PKM users (Obsidian, Notion, Logseq, Readwise, "second brain" and Zettelkasten) as an early-adopter segment for Spoken Margins

All URLs accessed 2026-09-28 unless stated otherwise. "Page date" is the date the page itself shows. Method: about 20 search and fetch calls. Reddit's JSON endpoints were blocked from this environment (the fetch did not return JSON), so subreddit sizes come from a third-party tracker (GummySearch), not from Reddit itself. I could not read individual Reddit threads, so the user voice below comes from the Obsidian Forum.

## Jobs: capturing ideas while walking or commuting, getting highlights into a vault, processing a read-later backlog by ear

### Takeaway
All three jobs are documented. The best evidence is on the Obsidian Forum, where people ask how to capture notes by voice while walking and listening, and where users of Snipd's Obsidian sync report friction. I found no user posts, from any year, specifically about processing a read-later backlog by ear. Only vendor docs cover that job. The strongest pull is podcast highlights landing in the vault. Articles and PDFs by ear have much weaker evidence.

### Cited Findings
- **Walking and listening, wanting voice capture.** On 2023-09-03 (older source, flagged), user "EvolvingRichie" asked how to capture notes with speech-to-text *while walking and listening to audiobooks* and complained that earbud microphones are poor.
  - Replies (2023-09-04) suggested Siri with AirPods, and Snipd for podcast "snipping".
  - On 2023-09-06 the poster said they had bought a Snipd subscription because it met their exact need, and was waiting for audiobook support.
  - [Obsidian Forum, "How to capture notes verbally"](https://forum.obsidian.md/t/how-to-capture-notes-verbally/66455)
- **Voice capture straight into the vault is an established niche with several products.**
  - The Voice MD plugin is pitched for "when you are walking, commuting, leaving a meeting" so that speech lands as Markdown in the vault: [Voice MD plugin page](https://community.obsidian.md/plugins/voice-md).
  - Voice Inbox for Obsidian (iOS) is sold on "capture on the go, transcribe, sync with your vault": [App Store](https://apps.apple.com/us/app/voice-inbox/id6452678291).
  - Quick Draft for Obsidian (iOS) covers type, dictate or snap capture into Obsidian: [App Store](https://apps.apple.com/us/app/-/id6748142801).
  - A 2026 vendor guide lists "four real options" for voice notes in Obsidian and calls the Whisper plugin "the community standard" for in-editor voice: [ThoughtMic guide](https://thoughtmic.com/guides/voice-notes-for-obsidian). This is a vendor source, so it is biased.
- **Getting podcast highlights into the vault: the plugin thread shows both demand and friction.** Snipd staff ("KevinBen") posted the native Obsidian plugin in Share & showcase on 2025-11-26. The thread has 12 replies. [Obsidian Forum thread](https://forum.obsidian.md/t/snipd-plugin-to-sync-your-podcast-highlights-to-obsidian-with-transcript-ai-summary-and-rich-metadata/108426)
  - Pain points reported:
    - The Snipd.base file is not generated (blake_lmt, Dec 19).
    - Settings panel scaling breaks on Android (Think3r, Dec 19).
    - Frequent crashes on iOS and trouble viewing YAML front matter (bloominstation, Dec 3).
    - Full sync times out repeatedly (aarontimo, Feb 21).
  - Feature requests:
    - Customizable properties, which are not supported (Glass, Dec 2).
    - **Full transcript import with time-coded audio sync**, not just highlights (Escir, Mar 25).
  - The reply months after November 2025 are presumably 2025–2026. The fetch returned only month and day.
- **Snipd's earlier integration thread in Share & showcase** also exists, which suggests a years-long history: [Obsidian Forum, Snipd integration thread 26499](https://forum.obsidian.md/t/snipd-integration-podcast-highlights-with-transcript-notes-summary-metadata/26499). I did not fetch it, so its date is unverified.
- **Snipd's own framing.** It says the plugin "closes the gap between listening and learning" for people "using Obsidian as their primary knowledge management tool or second brain". Output is one file per episode, with the transcript of the highlighted moment, an AI summary, the user's notes, an audio replay link, guests, books mentioned and episode metadata. [Snipd blog](https://www.snipd.com/blog/sync-snips-to-obsidian-plugin), page date 2025-11-26.
- **Read-later by ear (vendor evidence only).**
  - Readwise Reader text-to-speech lets you "listen to virtually any document using the highest quality AI voices". It works on PDFs in text view and on EPUBs.
  - You can highlight while listening by mapping a headphone double- or triple-tap to "highlight" (Account settings > Headphone gestures).
  - It needs an internet connection and cannot be used offline.
  - [Readwise Docs, Text-to-Speech](https://docs.readwise.io/reader/docs/faqs/text-to-speech). No page date.

### Inferences
- The recurring shape of the job is: listen hands-free, mark the moment with minimal effort, and have it show up in the vault as Markdown with context. Spoken Margins' anchored Margins exported as per-Margin Markdown fit this job directly.
- The Escir request (full transcript with time-coded audio) and the Readwise headphone-highlight feature show that this segment values **jumping back to the exact moment**. That is Spoken Margins' core anchor idea.
- The 2023 thread shows the pain of earbud microphone quality for spoken capture. Spoken Margins' spoken Margins will meet the same problem.

### Gaps
- I could not read Reddit threads (blocked), so there is no dated Reddit user voice. Searches did not surface Obsidian Forum threads about "listening through a read-later backlog".
- There are no numbers on how many PKM users listen to articles as opposed to reading them.

## Tools they use now for audio to notes (with numbers where available)

### Takeaway
Snipd is the clear incumbent for turning podcasts into notes, with a free native Obsidian plugin (November 2025) plus Readwise sync. For articles, Readwise Reader text-to-speech with headphone highlighting covers much of the Spoken Margins pitch. Airr, the earlier podcast-highlight app, is reported deprecated (April 2024). Voice memos plus transcription are served by several Obsidian-specific apps and plugins.

### Cited Findings
- **Snipd, Obsidian plugin.**
  - Free, native, syncs automatically with no manual export. Snipd claims "hundreds of thousands of people" use Snipd. [Snipd blog](https://www.snipd.com/blog/sync-snips-to-obsidian-plugin), 2025-11-26.
  - I found no audited user count.
- **Snipd, Readwise sync.** Snips sync automatically to Readwise, with an option to sync only starred, edited or tagged snips. Readwise then pushes them to Obsidian, Notion and others. Sources: [Snipd Help Center](https://support.snipd.com/en/articles/10226077-sync-your-snips-to-readwise) and [Readwise Docs, Import from Snipd](https://docs.readwise.io/readwise/docs/importing-highlights/snipd). Neither page was fetched, so both claims rest on search snippets.
- **Snipd company.**
  - Zurich-based. Raised a $700k pre-seed in March 2022 (older, flagged).
  - Snipd creates AI chapters and lets you highlight by tapping AirPods.
  - Sources: [Tech.eu, 2022-03-03](https://tech.eu/2022/03/03/swiss-startup-plugs-in-700000-to-rollout-ai-powered-podcast-player/), [TechCrunch, 2022-08-16](https://techcrunch.com/2022/08/16/how-snipd-is-using-ai-to-unlock-knowledge-in-podcasts/). Search snippets only.
- **Snipd pricing, per a competitor's page.** A subscription "ranging between $4 and $40 per month" with a limited free tier, and AI features are paid: [Podshot, Snipd alternatives](https://www.podshot.ai/tools/snipd-alternatives). Podshot is a competitor and the range is implausibly wide, so treat it as unreliable. Snipd's own pricing page was not checked.
- **Airr.** Reported "deprecated in April 2024 after a long period of minimal updates", with no official reason: [Podshot, Snipd vs Airr](https://www.podshot.ai/compare/snipd-vs-airr). This is a competitor source and not confirmed by Airr. The Airr X account still exists: [@AirrAudio](https://x.com/airraudio?lang=en).
- **Podwise.** Transcribes and summarizes podcasts, and integrates with Notion, Readwise, Obsidian and Logseq, per [Podshot](https://www.podshot.ai/tools/snipd-alternatives). Secondary source.
- **Readwise Reader text-to-speech.** AI voices, headphone-gesture highlighting, PDFs in text view, online only: [Readwise Docs](https://docs.readwise.io/reader/docs/faqs/text-to-speech). I did not verify Reader's pricing.
- **Voice capture into Obsidian.** Voice MD plugin, the Whisper plugin, Voice Inbox for Obsidian, and Quick Draft for Obsidian. Sources are as cited in the Jobs section.
  - The [Audio Notes plugin](https://www.obsidianstats.com/plugins/obsidian-audio-notes) lets you take notes on audio files inside Obsidian. Not fetched.
- **Adjacent reversed flow.** "Audio Brief" is a forum project that turns notes into AI-generated podcasts inside Obsidian: [Obsidian Forum](https://forum.obsidian.md/t/audio-brief-turn-your-notes-into-ai-generated-podcasts-inside-obsidian/111182). Not fetched.
- **Obsidian plugin ecosystem scale.** Kepano (Obsidian CEO) posted that plugins reached "100 million total downloads": [kepano on X](https://x.com/kepano/status/2005833628673040661?lang=en). The post appears to date from late December 2025.
- **Matter and Glasp.** Not researched in the budget. I have no sourced numbers.

### Inferences
- Spoken Margins competes with Snipd on podcasts and with Readwise Reader on articles and PDFs. Both already reach the vault, one through a native plugin and one through Readwise export. Its differentiators for this segment are:
  - one anchored-note model across articles, PDFs *and* podcasts
  - spoken Margins as audio anchored in the source
  - shareable packets that replay at the same place
  - no account and no subscription during TestFlight
- The Snipd plugin complaints (sync timeouts, crashes, rigid properties) suggest that simple, predictable per-Margin Markdown files with editable frontmatter could be a genuine plus. This is inference, not tested.

### Gaps
- I found no verified Snipd user count, pricing or retention. There are no Readwise Reader user numbers, and no Matter or Glasp data.
- I did not check whether Snipd exports to Logseq or Notion natively. Via Readwise it reaches Notion.

## Where they gather (with audience sizes)

### Takeaway
The segment is large and concentrated in a few places:
- r/Notion (~472k) and r/ObsidianMD (~365k, growing ~46%/yr), then r/PKMS (~79k), r/Zettelkasten (~40k) and r/logseq (~20k)
- the Obsidian Forum and Discord
- creators Nick Milo (~333–346k YouTube) and Tiago Forte (373k YouTube, 13k+ Circle members)

Obsidian itself claims more than 1.5M monthly active users, but that figure comes from secondary posts.

### Cited Findings
- **Subreddit sizes.** All figures are from GummySearch pages fetched 2026-09-28. The r/ObsidianMD page shows "Data updated September 20, 2026". Reddit's own counts could not be read.

  | Subreddit | Members | Source |
  |---|---|---|
  | r/ObsidianMD | 365k (+115k/yr, +46.2%) | [GummySearch r/ObsidianMD](https://gummysearch.com/r/ObsidianMD/) |
  | r/Notion | 472k | [GummySearch r/Notion](https://gummysearch.com/r/Notion/) |
  | r/PKMS | 79k | [GummySearch r/PKMS](https://gummysearch.com/r/PKMS/) |
  | r/Zettelkasten | 40k | [GummySearch r/Zettelkasten](https://gummysearch.com/r/Zettelkasten/) |
  | r/logseq | 20k | [GummySearch r/logseq](https://gummysearch.com/r/logseq/) |

  In r/ObsidianMD, "showcase" is the second most common flair after "help".
- **Obsidian user base.**
  - Kepano posted, around August 2025, that Obsidian has "7 full-time employees" and "~1 million users per employee": [kepano on X](https://x.com/kepano/status/1953867671302537474). Taken literally that implies about 7M users, which conflicts with the next claim, so it is loose rhetoric.
  - "Over 1.5 million active users" and "5 million downloads" come from a third-party X post: [Aakash Gupta on X](https://x.com/aakashgupta/status/2040622458651529502), around 2026. It is not primary.
  - A $25M ARR claim comes from [BigGo Finance](https://finance.biggo.com/news/iVboYp0Bga3fZL9MJEv_), also secondary.
  - Treat all of these as unverified.
- **Nick Milo, Linking Your Thinking.** YouTube at 333K+ subscribers, with another source showing 346K: [YouTube channel](https://www.youtube.com/@linkingyourthinking). The number came from search snippets; the page was not fetched.
- **Tiago Forte, Building a Second Brain.** From his 2025 annual review, [Forte Labs](https://fortelabs.com/blog/tiago-fortes-2025-annual-review/) (page date 2026-01-12, updated 2026-02-03):
  - "373k" YouTube subscribers and "over 4.8M views in 2025"
  - Circle community "over 13k members"
  - "63k people subscribed to our newsletter *this year*". That is new sign-ups in 2025, not the total list.
  - A BASB app launched in 2025
  - YouTube drove 53% of audience growth
- **Eleanor Konik's Obsidian Roundup appears to have ended.** A 2024-11-06 forum thread asks for an "Alternative to Eleanor Konik's Obsidian Roundup" and refers to it in the past tense: [Obsidian Forum](https://forum.obsidian.md/t/alternative-to-eleanor-koniks-obsidian-roundup/91120).
  - Recommended replacements: PKM Weekly by Ed Nico ([ednico.substack.com](https://ednico.substack.com/)), Obsidian Plugin Stats by Ganessh Kumar ([obsidian-plugin-stats.vercel.app](https://obsidian-plugin-stats.vercel.app/)), the Obsidian changelog and blog, and Discord #updates and #content-updates.
  - Konik now writes the "Manuscriptions" Substack: [eleanorkonik.com](https://www.eleanorkonik.com/). Subscriber count not found.
- **Obsidian Forum "Share & showcase" category.** It exists and is used by commercial apps. Snipd posted its plugin there (links above).

### Inferences
- The best-matched and fastest-growing pool is r/ObsidianMD plus the Obsidian Forum, because Spoken Margins already exports Markdown to an Obsidian folder. Notion and Logseq audiences are reachable only after direct export exists.
- YouTube is where PKM audiences grow (53% of Forte's growth). A short demo video is the right format.

### Gaps
- I could not verify these creators or their audiences:
  - Zsolt Viczián (Excalidraw plugin)
  - TfTHacker
  - Prakash Joshi Pax
  - Tony Tan
  - Readwise community size
  - Obsidian Discord member count
  - r/readwise size
- The names above are not verified, so don't use them as channels without checking.
- There is no primary Obsidian user count with a date.

## Product gaps that would stop PKM users

### Takeaway
The biggest blockers are three:
- **Platform reach.** iOS 26+ only, with no Android or desktop, while Snipd users post from Android and iOS alike.
- **No text for spoken Margins.** Audio Margins without a transcript are not searchable or linkable in a vault.
- **No bridge to Readwise.** There is no Readwise highlight sync, which is where many of these users' highlights already flow.

No Logseq or Notion direct export matters less for the first test, given that Obsidian is the largest vault-based pool.

### Cited Findings
- **Obsidian users are cross-platform, including Android.** A user in the Snipd plugin thread reports an Android bug on a Samsung S22+: [Obsidian Forum](https://forum.obsidian.md/t/snipd-plugin-to-sync-your-podcast-highlights-to-obsidian-with-transcript-ai-summary-and-rich-metadata/108426).
- **Obsidian runs on every major operating system**, per [Aakash Gupta on X](https://x.com/aakashgupta/status/2040622458651529502). Secondary source.
- **Users expect text and transcripts with the audio link.** Snipd exports a transcript, AI summary and audio replay link for each highlight. A user still asked for *full* transcripts with time-coded audio. Sources: [Snipd blog](https://www.snipd.com/blog/sync-snips-to-obsidian-plugin) and the forum thread above.
- **Users expect customizable frontmatter.** The request for customizable properties was refused in the Snipd plugin thread (same thread).
- **Readwise is a hub.** Snipd syncs to Readwise, and Readwise exports on to Obsidian, Notion and others: [Readwise Docs, Import from Snipd](https://docs.readwise.io/readwise/docs/importing-highlights/snipd). Search snippet only.
- **Competitors reach Logseq and Notion.** Podwise integrates with Notion, Readwise, Obsidian and Logseq: [Podshot](https://www.podshot.ai/tools/snipd-alternatives). Secondary source.
- **Audiobooks are a stated want.** The 2023 thread asked for audiobook support in addition to podcasts: [Obsidian Forum](https://forum.obsidian.md/t/how-to-capture-notes-verbally/66455).

### Inferences, ranked by likely impact
1. **Spoken Margins must export as transcribed text** (plus the audio link) to be useful in a vault.
2. **iOS 26+ with no Android or desktop.** This limits reach, but TestFlight testers self-select, so it may not block a test.
3. **No Readwise export.** Readwise users would want Margins going *back into* Readwise, not only queues coming in from it.
4. **No Logseq or Notion export.**
5. **No podcast transcript search.** This is lower priority, because Snipd already sets the bar.

Readwise Reader's online-only text-to-speech could be a Spoken Margins advantage if its text-to-speech runs on-device. Check before claiming it.

### Gaps
- There is no direct evidence of how PKM users react to iOS-26-only or TestFlight-only distribution.
- I have no data on Snipd's export to Logseq.

## Smallest two-week test of real interest

### Takeaway
Take a one-post showcase with a demo vault note and a short video, posted in the channels that explicitly allow sharing things you made. Then count TestFlight sign-ups and comments. Post it in three places:
- Obsidian Forum Share & showcase
- Discord #content-update
- r/ObsidianMD with the showcase flair, from an account that has already participated

Obsidian's code of conduct allows sharing tools that integrate with Obsidian, but forbids promotion-only accounts and scrutinizes paid content more closely. A free app with no account is on the safe side.

### Cited Findings
- **Obsidian code of conduct.** It says: "We encourage sharing what you've made for Obsidian—guides, videos, utilities, tools, and more."
  - Discord's designated channel is `#content-update`.
  - "Exclusive self-promotion", meaning promoting your content "without otherwise participating in the community", is not tolerated. Moderators judge what is "excessive" and expect meaningful engagement first.
  - Shared work must "support, enhance, or integrate with Obsidian". Paid content gets heightened review.
  - The code applies to the Forum, Discord and Reddit.
  - Source: [Obsidian Help, Community code of conduct](https://obsidian.md/help/community-code-of-conduct). No page date.
- **Precedent.** Snipd, a commercial app, announced its Obsidian plugin in the Forum's Share & showcase and drew 12 replies with feature requests: [Obsidian Forum](https://forum.obsidian.md/t/snipd-plugin-to-sync-your-podcast-highlights-to-obsidian-with-transcript-ai-summary-and-rich-metadata/108426).
- **r/ObsidianMD has an active "showcase" flair**, the second most common: [GummySearch](https://gummysearch.com/r/ObsidianMD/).
- I could not read r/ObsidianMD's own sidebar rules (Reddit blocked). The rules for r/PKMS, r/Zettelkasten and r/Notion were also not verified.

### Inferences (proposed test design, not sourced)
- **Days 1–3.** Build a demo vault note: one article, one PDF and one podcast episode, each with Margins exported as Markdown with frontmatter (source, timestamp or anchor, deep link). Record a 60–90 s screen video of the flow: listen while walking, tap to Margin, the file appears in Obsidian.
- **Days 3–4.** Post once each to Obsidian Forum Share & showcase and Discord #content-update. Post to r/ObsidianMD with the showcase flair only if the posting account has prior participation, and check the sidebar rules first.
- **Signal to measure.** Use a TestFlight public link or a simple waitlist form. Measure clicks to sign-ups, sign-ups to installs, and whether installs produce at least one exported Margin. Also count comments that ask for Android or desktop, transcripts, or Readwise and Logseq. These tell you which gap blocks the segment.
- **Pass bar.** None was found in the sources. The owner should set one in advance, for example a number of installs that export a Margin within a week.
- **Positioning.** Lead with what Snipd and Reader don't do: one anchored-note model across articles, PDFs *and* podcasts, spoken notes that replay in place, and shareable packets. Don't lead with "podcast notes", where Snipd is entrenched.

### Gaps
- Unverified subreddit-specific self-promotion rules, including any ratio rules or required flair.
- No benchmarks for conversion rates of Obsidian showcase posts.
