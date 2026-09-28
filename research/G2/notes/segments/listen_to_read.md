# Candidate segment 4: heavy "listen-to-read" adults

Accessed 2026-09-28 for every source below. How to read the tags: "(fetched)" means I read the page itself. "(snippet)" means the claim comes from a search-result summary of that page and still needs a direct read before anyone quotes it. Reddit pages (the JSON API and the site) and some AppleVis and Perkins pages returned 403 or no data from this environment, so there are no direct Reddit quotes here.

## Size and behavior

### Takeaway
The segment is large and proven to pay. Speechify alone says it has 60M+ users, and its marketing is built around dyslexia and ADHD. The underlying populations are also big: about 15.5M US adults have a current ADHD diagnosis (2023 data), dyslexia estimates run 5–20% depending on the definition, and roughly 49.5M US adults report some vision loss (2024 NHIS). There is modest evidence that TTS helps reading comprehension, drawn mostly from students.

### Cited Findings
- On its homepage, Speechify claims "60M+ Users" and "1M+ 5-star reviews", an iOS rating of 4.7 from 435k ratings, a 4.6 Chrome extension rating, and a "2025 Apple Design Award". The footer reads © 2026. The founder writes "I am dyslexic", and a testimonial says "I have ADHD and I love to read but have piles of book that I never touched". (fetched, no page date) — [speechify.com](https://speechify.com/)
- A third-party estimate puts Speechify at about $17.6M ARR with a $100M valuation (2024). This is an unverified aggregator and conflicts with the scale of the 60M-user claim, so treat it as low confidence. (snippet) — [GetLatka](https://getlatka.com/companies/speechify.com)
- ElevenReader (ElevenLabs): about 2.4M Android downloads and roughly 1.6k downloads a day as of Aug 2025, per third-party app-store trackers. (snippet) — [AppBrain](https://www.appbrain.com/app/elevenreader/io.elevenlabs.readerapp); [AppstoreSpy](https://appstorespy.com/android-google-play/io.elevenlabs.readerapp-trends-revenue-statistics-downloads-ratings)
- ADHD: in Oct–Nov 2023, an estimated 15.5 million US adults (6.0%) had a current ADHD diagnosis, and about half were diagnosed in adulthood. 84.5% were under 50. About a third were getting no treatment. 61% of women were diagnosed as adults, against 40% of men. Published in CDC MMWR 73(40), 10 Oct 2024. (snippet of the primary source) — [CDC MMWR](https://www.cdc.gov/mmwr/volumes/73/wr/mm7340a1.htm); [PMC copy](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11466376/)
- Dyslexia: the International Dyslexia Association says "perhaps as many as 15–20% of the population" have some symptoms, such as slow or inaccurate reading. The share with a diagnosis as a specific learning disability is lower (commonly quoted as 5–17%, depending on the definition). (snippet; the IDA page date is not shown) — [IDA Dyslexia Basics](https://dyslexiaida.org/dyslexia-basics/)
- Adult dyslexia persists. A 2020 meta-analysis of 178 studies (Reis et al., cited in the Frontiers paper) found persistent deficits in adult text-reading fluency, d = 1.76. (snippet) — [Frontiers 2022](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2022.866543/full)
- Does TTS help comprehension? A meta-analysis of 22 studies from 1993–2013 (n = 2,942, grade 3 through postsecondary) found an average effect of 0.35 (95% CI 0.14–0.56). Between-subjects designs showed 0.61. Within-subject designs showed 0.15, which was not significant. Published 2018; older evidence, and about students rather than working adults. (snippet) — [PubMed 28112580](https://pubmed.ncbi.nlm.nih.gov/28112580/)
- Vision: according to AFB's analysis of the 2024 NHIS, 49.5M US adults report some vision loss, 3.8M have significant trouble seeing even with glasses, and 420k cannot see at all. (snippet) — [AFB NHIS facts](https://afb.org/research-and-initiatives/statistics/adults-vision-loss-nhis); see also [CDC Vision Loss Fast Facts](https://cdc.gov/vision-health/data-research/vision-loss-facts/index.html)

### Inferences
- "People with a reason to listen rather than read" is a population in the tens of millions in the US alone. The binding constraint is reaching them, not market size.
- About half of adults with ADHD were diagnosed as adults, and most are under 50. That lines up well with iPhone owners on a current iOS version.
- The comprehension evidence is modest and mostly from school-age readers. Spoken Margins shouldn't claim it improves comprehension. It can claim that it helps you capture a thought without stopping.

### Gaps
- There's no independent, dated figure for Speechify monthly actives (60M+ is cumulative marketing), and none for ElevenReader iOS installs.
- No figures found for how much TTS gets used inside Pocket, Matter or Readwise Reader.
- No Apple data found on Speak Screen or Spoken Content usage.
- I found no rigorous survey showing what share of ADHD adults use TTS or audio to read. The Reddit pages that summarise this are Speechify's own blog, a vendor source ([speechify.com/blog/reddit-adhd](https://speechify.com/blog/reddit-adhd/)), so they're excluded as evidence.

## Jobs and pain points

### Takeaway
The jobs are these: get through a reading backlog hands-free, stay focused ("audio anchors attention"), and keep a thought without breaking flow. The documented pains are PDF narration that reads running headers, footers and footnotes aloud, subscription and billing distrust, and capture while listening that stays weak or limited to highlights.

### Cited Findings
- Backlog: the Speechify testimonial quoted above ("piles of book that I never touched") is marketing, but it states the job exactly. — [speechify.com](https://speechify.com/)
- PDF noise: accessibility practitioners note that headers and footers read in the middle of a sentence break the flow, and that screen-reader users find them "quite annoying" (W3C WAI mailing list, 2015 and 2019, older sources). A product exists just to fix this: Paper2Audio advertises cutting "footnotes, references, page headings". (snippet) — [W3C WAI-GL 2015](https://lists.w3.org/Archives/Public/w3c-wai-gl/2015AprJun/0222.html); [W3C publ-wg 2019](https://lists.w3.org/Archives/Public/public-publ-wg/2019Aug/0026.html); [Paper2Audio](https://www.paper2audio.com/)
- Capture while listening, as incumbents do it: Readwise Reader lets you highlight while listening by triple-tapping AirPods. TTS works only on PDFs in text view and needs an internet connection ("can't be used while your device is offline"). There's no documented spoken-note capture. (fetched, no page date) — [Readwise TTS docs](https://docs.readwise.io/reader/docs/faqs/text-to-speech)
- Matter bundles "HD text-to-speech" with "unlimited highlighting with note-taking integrations" in Premium. (snippet, third-party review) — [Readless 2026](https://www.readless.app/blog/matter-app-pricing-2026)
- Speechify promotes voice typing so you can "dictate notes without breaking flow" (vendor blog). The incumbent sees the same job. — [Speechify blog](https://speechify.com/blog/reddit-adhd/)
- Speechify's Trustpilot complaints centre on billing: a forced trial with card details, annual renewal charges, and trouble cancelling. Reviewers generally praise its voices as not robotic. (snippet) — [Trustpilot](https://www.trustpilot.com/review/speechify.com)

### Inferences
- The combination of a spoken note anchored to a moment and then replayed at that spot, exportable as Markdown, isn't documented in any of the incumbents I checked. Readwise has highlight-by-gesture, and Speechify has dictation for writing.
- A free app with no account is a real point of difference against billing distrust.
- Cleaning up PDF headers and footnotes is a known, specific pain. If Spoken Margins already skips them, lead with it. If it doesn't, expect complaints.

### Gaps
- I couldn't retrieve first-person Reddit posts (403). Collect them by hand, for example by searching r/ADHD and r/dyslexia for "text to speech notes".

## Tools used now (prices with dates)

### Takeaway
Paid incumbents cost $60–160 a year. Pocket is gone as of July 2025. The Voice Dream episode shows that blind and low-vision users react strongly to losing features they paid for.

### Cited Findings
- **Speechify:** Premium $139/yr or $29/mo, "as of August 2026". About 25% off for students. (snippet, third-party) — [TextToLab](https://texttolab.com/blog/speechify-pricing); [Fluxnote](https://fluxnote.io/guides/speechify-pricing-guide-2026)
- **ElevenReader:** the free plan has 10 hours of text-to-audio a month and 1,000+ voices. Ultra is $11/mo, or $8.25/mo billed annually, with unlimited TTS and 20 audiobook hours. Speed up to 4×. No page date. (fetched) — [elevenreader.io/pricing](https://elevenreader.io/pricing)
- **NaturalReader (personal):** Lite $79/yr, Plus $119/yr, Pro $159/yr. The free tier has unlimited non-AI voices and 20k characters a day of Lite voices. Includes a Chrome extension. (snippet) — [NaturalReader Help](https://help.naturalreaders.com/en/articles/8854700-plans-pricing-personal-version)
- **Voice Dream Reader:** the developer sold it to Applause Group in 2023. In Apr 2024 existing buyers were told they'd lose core functions (for example, adding to the Library) on 1 May 2024 unless they subscribed at $79/yr, discounted to $59. After backlash Applause reversed this and said existing features stay free for purchasers, with new features possibly on subscription. Part of the anger was that the sale hadn't been communicated to the blind community. (fetched) — [Michael Tsai, 2024-04-08](https://mjtsai.com/blog/2024/04/08/voice-dream-reader-switches-to-subscriptions/); [Six Colors, Apr 2024](https://sixcolors.com/link/2024/04/another-app-switches-to-a-subscription-model/); [Mosen.org](https://mosen.org/voicedream/); [AppleVis thread](https://www.applevis.com/forum/ios-ipados/applause-has-backed-down-purchased-voice-dream-features-will-stay) (403 when fetched); [Perkins](https://www.perkins.org/resource/voice-dream-reader-subscription-controversy/) (403)
- **Readwise Reader:** TTS uses "top-tier AI voices" (the Readwise FAQ credits Unreal Speech), requires a connection, and supports highlight-by-gesture. (fetched docs, see above) — [Readwise docs](https://docs.readwise.io/reader/docs/faqs/text-to-speech)
- **Matter:** free basic TTS. Premium is $8/mo or $60/yr for HD TTS. (snippet, 2026 third-party) — [Readless](https://www.readless.app/blog/matter-app-pricing-2026)
- **Pocket:** shut down 8 Jul 2025, with export available until 8 Oct 2025, when data was deleted. Premium subscriptions were refunded. (snippet) — [9to5Mac, 2025-05-22](https://9to5mac.com/2025/05/22/mozilla-announces-shutdown-of-pocket/); [gHacks, 2025-05-23](https://www.ghacks.net/2025/05/23/mozilla-to-shut-down-pocket-in-july-2025-fakespot-is-closing-too/)
- **Apple Speak Screen / Spoken Content:** built into iOS for free. I didn't fetch a current Apple page, so this is a gap for feature detail.

### Inferences
- Pocket refugees are users who have recently been displaced. Spoken Margins imports Readwise Reader and Raindrop, not Pocket exports. Many Pocket users moved elsewhere in 2025, so the Readwise and Raindrop import is the relevant path.
- The Voice Dream history means "free, no account, your data stays on device" will land with the AppleVis audience. But they'll ask what happens when pricing arrives, so answer that up front.

### Gaps
- Voice Dream's current subscription price (2026) not verified.
- No Apple usage data for Speak Screen.

## Where they gather

### Takeaway
The large venues are r/ADHD (about 2.3M members) and the accessibility-specific AppleVis. AppleVis forbids promotional posts but has an app directory with accessibility ratings, and that's the legitimate way in.

### Cited Findings
- r/ADHD: 2.3M members, per third-party tracker GummySearch. Undated, and the live count couldn't be read (403). (snippet) — [GummySearch](https://gummysearch.com/r/ADHD/)
- AppleVis rules: it discourages using the site to promote your own site, podcast or product. A press release "posted solely to promote a product or service will be removed". (snippet) — [AppleVis guidelines](https://applevis.com/help/guidelines)
- The AppleVis app directory accepts submissions (Submit content → Apps) and carries community accessibility ratings. (snippet) — [AppleVis forum](https://www.applevis.com/forum/ios-ipados/submitting-apps-app-directory); [AppleVis directory ratings](https://www.applevis.com/blog/announcing-enhancement-applevis-app-directories-accessibility-ratings)
- The Voice Dream controversy was debated on AppleVis, Mosen.org (Jonathan Mosen, a blind accessibility commentator), Six Colors and Michael Tsai's blog. Together these form a reachable cluster of Apple and accessibility commentators (see links above).

### Inferences
- The best-fit sub-segment for a two-week test is probably ADHD and heavy-reader adults on iPhone, not blind VoiceOver users. VoiceOver users hold apps to a high accessibility bar and share verdicts publicly on AppleVis, so a weak first impression there would last.

### Gaps
- Couldn't get live subscriber counts or self-promotion rules for r/dyslexia, r/Blind, r/audiobooks, r/speechify or r/ADHD because Reddit was blocked. r/ADHD is known to restrict product promotion, but I couldn't verify its current rule text. Check the sidebars by hand before posting.
- No accessibility newsletter or podcast audiences found with dated numbers. Candidates to check: Double Tap (AMI), the Mosen at Large podcast, and the AppleVis podcast.

## Gaps that would stop them

### Takeaway
Voice quality is the main barrier. Incumbents sell "human-like" neural voices, and even the free tiers (ElevenReader: 1,000+ voices) set the bar. After that: iPhone-only, iOS 26+, TestFlight friction, no web or Chrome extension, and unverified VoiceOver accessibility.

### Cited Findings
- Speechify reviewers praise its voices as "doesn't sound robotic". That's the expectation Spoken Margins' on-device voices will be compared against. (snippet) — [Trustpilot](https://www.trustpilot.com/review/speechify.com)
- ElevenReader's free tier (10 hrs a month, 1,000+ voices, web and mobile sync) sets the bar for free. (fetched) — [ElevenReader pricing](https://elevenreader.io/pricing)
- Speechify, ElevenReader and NaturalReader are all cross-platform, including web, Chrome extension, and Android for ElevenReader. (fetched/snippet above)
- Readwise Reader TTS doesn't work offline. On-device TTS does, which is a small edge for commuters on the subway. (fetched) — [Readwise docs](https://docs.readwise.io/reader/docs/faqs/text-to-speech)

### Inferences
- Before the better bundled voice ships, expect "sounds robotic" to be the first objection from people coming from Speechify or ElevenReader. Test with people who currently use Apple Speak Screen or free voices, not paying Speechify users.
- The ADHD sub-segment includes Android and Windows users, and many readers start from a desktop Chrome tab. No web or Chrome capture limits them to iPhone and iPad-first readers.
- Until Spoken Margins has been through a VoiceOver audit, don't invite blind users. A bad AppleVis rating is public and lasting.

### Gaps
- No data on the share of this segment on iOS 26+.

## Smallest two-week test

### Takeaway
Recruit 10–20 iPhone users on iOS 26 who already listen to articles or PDFs, through one post in an allowed venue (for example a subreddit's weekly thread) plus direct invites. Measure whether they record at least three Margins in week one and are still using it in week two.

### Cited Findings
- AppleVis forbids promotional posts, so it can't be the recruiting channel until the app has a directory listing. — [AppleVis guidelines](https://applevis.com/help/guidelines)
- Pocket's export deadline has passed (8 Oct 2025). A "Pocket refugee" hook is stale. Use Readwise and Raindrop import instead. — [9to5Mac](https://9to5mac.com/2025/05/22/mozilla-announces-shutdown-of-pocket/)

### Inferences
Proposed design (inference, not sourced):
1. **Screener (days 1–3):** a short form asking whether they already use TTS or read-aloud at least weekly, which app, which device and iOS version, and how they currently capture thoughts. It optionally asks about ADHD, dyslexia or eye strain (voluntary, not required, and never used to exclude anyone).
2. **Onboarding:** a TestFlight link, one task ("import 5 things from your queue or add 3 articles/PDFs"), and a 60-second demo of recording a spoken Margin.
3. **Signals (days 4–14):** activation is 3 or more Margins recorded in week one. Retention is at least one session in week two. Also watch whether anyone exports to Markdown or shares a packet, which is the pull toward PKM or sharing. Finish with a short exit survey asking "What would stop you switching from X?", expecting voice quality as the answer.
4. **Pass bar (suggested):** at least 40% activate, and at least 25% are still active in week two. Also, voice quality isn't the top reason for stopping for more than half of respondents.
5. **Compare segments:** run the same screener and metrics for students and PKM users, so the four hypotheses are measured the same way.

### Gaps
- No benchmark activation or retention rates for TestFlight betas of this kind were found. The pass bars above are judgement, not sourced figures.
