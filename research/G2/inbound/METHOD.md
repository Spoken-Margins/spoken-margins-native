# Inbound content method

How Spoken Margins chooses, writes, keeps current and measures pages that people find by searching, such as "podcast notes in Obsidian" or "read PDFs aloud on iPhone". This is the method only. **Nothing is published without the owner**, and writing the pages is a follow-up once the owner approves this (G2 brief, "Out of scope").

The pages are written by the maker of Spoken Margins, and they say so at the top. They aren't reviews and don't pose as a neutral third party. What makes them worth reading anyway is that every claim about another product comes from `comparison.json`, with a source and a date the reader can check.

## 1. Choosing topics

### Where topic ideas come from

| Source | What it tells us | How to get it |
| --- | --- | --- |
| Search autocomplete | People search this exact phrase (existence, not volume) | `python3 research/G2/inbound/suggest.py > research/G2/inbound/suggest-<date>.json`. The 2026-09-28 snapshot is committed. |
| Segment interviews (M1) | The words people use for the job, and what they tried before | The five questions per segment in `M1-segments.md` |
| Community questions | Questions asked repeatedly on the Obsidian Forum, subreddits (read in a browser; reddit.com is blocked from cloud sessions) | Manual, dated notes |
| Search Console, once a page is live | Real queries, impressions, clicks and position per page ([Google help](https://support.google.com/webmasters/answer/7576553?hl=en), read 2026-09-28) | Owner's Search Console account |

No paid keyword tools are needed to start. Autocomplete can't give volumes, so the first pages are bets that Search Console will confirm or kill within 8–12 weeks (section 4).

### Scoring a topic

Score each candidate phrase 0–2 on five questions, and write only topics that score 7 or more **and** get 2 on "honest win".

| Question | 0 | 1 | 2 |
| --- | --- | --- | --- |
| **Intent**: does the searcher want to *do* the job Spoken Margins does? | Wants something else (a definition, a different platform) | Browsing a category ("best X") | Has the job now ("take notes on podcasts in Obsidian", "read PDF aloud iPhone") |
| **Segment fit**: which M1 segment, in M1's order | None | Students or creators (3rd–4th) | PKM or listen-to-read (1st–2nd) |
| **Honest win**: does `comparison.json` show a documented difference that matters for this job? | No, or we'd lose on the main point | Only a minor difference | Yes, sourced in the data file |
| **Can they use it today?** | Needs something we don't have (Android, desktop, a web app) | Works with a caveat the page states | Works in a build the searcher can install. **Until an external TestFlight public link is live (after Beta App Review) or the App Store release (#175), no topic scores above 1 here.** |
| **Evidence it's searched** | Not in autocomplete | Close variants only | The phrase, or near variants, appear in the dated snapshot |

**Excluded on principle:** pages that only attack a competitor ("Speechify is bad"); "alternative" pages for products we can't replace on the searcher's platform (for example "speechify alternative android" or "chrome extension"); pages whose main point is a feature on the roadmap rather than in the build.

### The 2026-09-28 snapshot, scored

On 2026-09-28 the app is internal TestFlight only, so no searcher can install it and every row below scores at most 1 on "usable today". **Precondition for publishing any page: a live external TestFlight public link or the App Store listing.**

From `suggest-2026-09-28.json` (Google autocomplete, US English, read 2026-09-28). Autocomplete lists phrases, not volumes.

| Candidate (phrases seen in autocomplete) | Intent | Fit | Honest win | Usable today | Searched | Total |
| --- | --- | --- | --- | --- | --- | --- |
| Podcast notes in Obsidian ("obsidian podcast notes", "obsidian podcast plugin", "obsidian podcast transcript", "voice notes to obsidian", "voice memo to obsidian") | 2 | 2 | 2 (the only row documented with articles, PDFs and podcasts in one app plus spoken notes at the moment; Snipd leads on `transcripts` and `ai_summaries`) | 1 (typed Margins only until #171; not installable until external TestFlight) | 2 | **9** |
| Read PDFs aloud on iPhone ("read pdf aloud iphone free", "can my iphone read a pdf to me", "pdf read aloud app iphone", "read research papers aloud", "read scientific papers aloud") | 2 | 2 | 2 (free, no account, notes at the moment; voice quality is not a win, so the page doesn't claim it) | 1 (scientific-PDF cleanup is C1 work in progress; not installable until external TestFlight) | 2 | **9** |
| Taking notes on readings by listening ("how to take notes on readings in grad school", "how to read and listen at the same time", "text to speech for college students") | 2 | 1 | 2 | 1 (not installable until external TestFlight) | 2 | **8** |
| Speechify alternative, free, iPhone ("speechify alternative free app", "speechify free alternative for iphone") | 2 | 2 | 1 (price and no account are wins; voices and platforms are not) | 1 | 2 | 8, but excluded for now: a head-to-head page invites a voice comparison we'd lose until C2 lands |
| Snipd alternatives ("snipd alternative", "snipd free alternative", "snipd vs pocket casts") | 1 | 2 | 1 (Snipd leads on `transcripts`, `ai_summaries` and `hands_free_capture`) | 1 | 2 | 7, but "honest win" is 1: fold into the Obsidian page instead |
| Podcast book club app ("podcast book club discord", "book club app with friends") | 1 | 1 | 1 (margin.fm clubs share text only, but we have no live group feature) | 0 | 2 | 5: wait for F1 |

## 2. Page templates

Every page, whatever its type, has these fixed parts:

1. **Maker line, first:** "Written by the maker of Spoken Margins, one of the apps below. Every claim about another app links to its source and the date we checked it."
2. **The answer in the first paragraph**, including when another app is the better choice.
3. **Comparison table from the data file**, generated by `render_table.py` and never typed by hand. Unknowns show as "Not documented", never "No". The renderer leaves out the data file's internal notes, so the page's prose states any caveat a reader needs.
4. **"When Spoken Margins isn't the right choice"**: platform limits (iPhone and iPad on iOS 26+ only), missing features, and where a competitor leads, all from the data file.
5. **Checked-on date** for the table, plus a short change log at the bottom.
6. **No reviews, ratings or testimonials** unless a named person gave written permission for that exact quote. No invented usage numbers.
7. **Public sources for our own claims.** The Spoken Margins row cites this private repository, and `render_table.py` refuses to render those sources without `--draft`. Before any page ships, give that row public sources (the App Store listing or public release notes) in the data file.
8. **Screenshots of Spoken Margins only**, taken from the shipped build (stream G1 can generate them). No screenshots of other apps.

The three templates:

**A. Workflow how-to** ("How to take podcast notes in Obsidian"). The searcher has a job. The page gives 3–4 ways to do it, most of them without Spoken Margins, then the comparison table, then step-by-step instructions for each way. This is the most useful and least salesy type, so it's the default.

**B. Best-for list** ("Apps that read PDFs aloud on iPhone"). The searcher is choosing. It opens with the criteria and why they matter for this job, then one section per app. Each section says what the app is for, cites the table cells, and says who should pick it. Spoken Margins is not automatically first: put the apps in the order the criteria give.

**C. Two-app comparison** ("Spoken Margins and Snipd"). Use it only where the scoring allows and both apps plausibly fit the same job. It covers what each is for, the table, where each one leads (sourced), and which to choose when. Avoid titles like "X vs Y: which is better".

## 3. Keeping pages current

The comparison data file is the only place facts about other products live. A page never states one from memory.

- **Generating tables:** `python3 research/G2/inbound/render_table.py --apps <ids> --fields <fields>` prints a Markdown table with a footnote per cell (source title, URL, date checked). It **refuses to run** if any cell's newest check is older than 90 days, so a page can't be regenerated from stale data. It also refuses sources in this private repository unless `--draft` is passed. The outline commands below need `--draft` until our own row has public sources.
- **Prose that names another app's feature** cites the same source as the data file entry, with a footnote. If the fact isn't in the data file, add it there first (with a source) and then write the sentence.
- **Each page's front matter lists the app ids and fields it uses**, for example `comparison: {apps: [snipd, readwise-reader, spoken-margins], fields: [voice_notes_anchored, export_markdown_pkm]}`. When a refresh (`REFRESH.md`) changes a value, `grep` the pages for that app id to find which pages to regenerate and re-read.
- **Cadence:** follow `REFRESH.md` (monthly for the five closest rivals, quarterly for the rest). A published page is also re-checked before any edit, and at least once a quarter. After a Spoken Margins release, update our own row first, since features we add or fix change the "when not to use us" section too.
- **Corrections:** if a vendor or reader reports an error, fix the data file the same day with the new source, regenerate the pages, and note the correction in the page's change log.

## 4. Measuring whether it works

What we measure, without adding trackers to the pages:

| Stage | Signal | Where it comes from |
| --- | --- | --- |
| Found | Impressions and average position for the page's target phrases | Search Console, filtered by page ([filtering help](https://support.google.com/webmasters/answer/17011165?hl=en), read 2026-09-28) |
| Chosen | Clicks and click-through rate | Search Console |
| Tried | Sign-ups through the page's own TestFlight public link (one tester group per page; public links can have a tester limit and device/OS criteria, and App Store Connect shows public link metrics: [Apple](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/), read 2026-09-28) | App Store Connect |
| Kept | Testers from that group who export a Margin in their first week. The app has no analytics and TestFlight can't send testers a question, so this counts only what testers report: a follow-up email to testers who give an address, and feedback they send through TestFlight. An opt-in in-app question after the first export would be more complete, but adding one is an owner decision. | Email replies, TestFlight feedback |

External TestFlight needs Beta App Review first (same Apple page), which is an owner step. After the App Store release (#175), replace the TestFlight link with App Store campaign links, and "Tried" becomes App Store Connect's per-campaign downloads.

**Decision points (our judgement, not benchmarks):**

- **Week 8:** a page with under 100 impressions for its target phrases is either mis-targeted (check which queries Search Console does show) or the topic is too small. Re-target once, then drop it.
- **Week 12:** keep a page that brings at least 5 TestFlight sign-ups, with at least 1 reporting an exported Margin. Since "Kept" counts only voluntary reports, zero reports from 5 sign-ups means "ask again", not "failed". Otherwise fold the page's useful parts into a stronger page.
- **Across pages:** compare sign-up-to-first-export rates between segments. That's the M1 test run through a second channel.

**What we won't do:** buy links, write guest posts that hide the affiliation, post the pages into communities that ban self-promotion, or change a competitor's cell without a new source.

## 5. Example outlines

Three outlines, one per segment, for the top-scoring topics. The tables named here are generated from `comparison.json`, and the notes in brackets are for the writer. No page is written or published until the owner approves this method.

### Outline 1 (PKM): "How to take podcast notes in Obsidian: four ways, compared"

- **Target phrases:** obsidian podcast notes; obsidian podcast plugin; obsidian podcast transcript; voice notes to obsidian.
- **Template:** A (workflow how-to).
- **Maker line** and the one-paragraph answer. If you want podcast transcripts and AI summaries, use Snipd: its official plugin syncs your snips to the vault with transcripts, AI summaries and your notes (`snipd.export_markdown_pkm`). If you want your own notes, anchored to the moment across podcasts, articles and PDFs, with no account, Spoken Margins does that. It's a free beta through TestFlight, for iPhone and iPad on iOS 26+, and its spoken notes don't reach the vault yet (#171).
- **The four ways:**
  1. By hand: pause, then type into Obsidian mobile. Obsidian has no core way to anchor a note to an audio timestamp (`obsidian.text_notes_anchored`). A timestamp link can come from the podcast app's share-from-moment feature (`apple-podcasts.share_note_at_moment`, `pocket-casts.share_note_at_moment`).
  2. Snipd plus its native plugin (launched 2025-11-26: [Snipd blog](https://www.snipd.com/blog/sync-snips-to-obsidian-plugin)).
  3. Readwise Reader: send it the episode, highlight the transcript, and Readwise exports the highlights to Obsidian. Reader doesn't play the podcast audio (`readwise-reader.plays_podcasts`: partial).
  4. Spoken Margins, then the notes folder.
- **Table:** `render_table.py --apps obsidian,snipd,readwise-reader,spoken-margins --fields plays_podcasts,voice_notes_anchored,text_notes_anchored,hands_free_capture,transcripts,export_markdown_pkm,account_required,price_paid`
- **Step-by-step for each way.** [Spoken Margins steps come from `docs/pkm-workflows.md` and the shipped Settings copy: pick the vault folder, Send Test Note, turn on Save Margins to Notes Folder. A screenshot of the resulting note in Obsidian.]
- **What the note looks like in the vault** for each way. [Only our own output is shown as an image; the others are described from their docs.]
- **When not to use Spoken Margins:** Android or desktop listening; wanting full transcripts; wanting spoken notes in the vault today (#171).
- **Change log.**

**Held until:** #171 ships, or the page states the limitation in the answer paragraph, as above.

### Outline 2 (listen-to-read): "Apps that read PDFs aloud on iPhone, and what happens to your notes"

- **Target phrases:** read pdf aloud iphone free; can my iphone read a pdf to me; pdf read aloud app iphone; read research papers aloud.
- **Template:** B (best-for list).
- **Maker line.** Answer: iPhone's built-in Speak Screen is free and already installed [add a sourced row to the data file first]. Speechify and ElevenReader also run on Android and the web (`platforms`). Spoken Margins is a free beta through TestFlight with no account, for iPhone and iPad on iOS 26+. It adds spoken or typed notes at the moment, and uses on-device voices. [Say nothing about other apps' voice counts or quality unless a sourced voices field is added to the data file.]
- **Criteria and why they matter:** cost and account; voices (described, not rated); how PDF clutter such as headers and footnotes is handled; taking a note without stopping; getting notes out.
- **Table:** `render_table.py --apps speechify,elevenreader,voice-dream-reader,readwise-reader,spoken-margins --fields reads_pdfs_aloud,text_notes_anchored,voice_notes_anchored,export_markdown_pkm,on_device_privacy,account_required,price_free_tier,price_paid,platforms`
- **One section per app:** what it's for, a sourced strength, a sourced limit, who should pick it. [Voice Dream's 2024 subscription reversal is history, not a current fact; leave it out unless the data file adds it with a source.]
- **Scientific papers:** what goes wrong (running headers, footnotes, references read out) and which apps say they handle it. [Spoken Margins claims this only once stream C1's work ships.]
- **Accessibility note:** VoiceOver support is being checked (#207). Don't recommend the app to blind readers until #207 is done.
- **When not to use Spoken Margins:** you need Android, Windows or a Chrome extension; you want the most natural voice today (C2 in progress).
- **Change log.**

**Held until:** Speak Screen is added to the data file with a source; ideally also C2's voice work, so the page can describe the voice honestly.

### Outline 3 (students): "How to take notes on readings by listening: a method for grad seminars"

- **Target phrases:** how to take notes on readings in grad school; how to read and listen at the same time; read academic papers aloud; text to speech for college students.
- **Template:** A (workflow how-to), method first, tools second.
- **Maker line.** Answer: listening gets you through more of the reading, but only if you capture reactions as you go. A spoken note at the moment you disagree is the cheapest capture. Then turn those notes into two or three seminar questions.
- **The method, tool-neutral:**
  1. Skim the structure first.
  2. Listen at a comfortable speed.
  3. Capture at the moment: say "claim", "question" or "disagree" plus one sentence.
  4. After listening, sort the captures into three seminar questions.
  5. Cite from the notes. [Link #206 as a known gap for citation export.]
- **Ways to do step 3:**
  - Your university's licensed TTS plus a notes app. [UChicago and Stanford examples from M1's sources.]
  - Social annotation your instructor assigns: Hypothesis (graded on institutional tiers, text notes; `hypothesis` in the data file). Perusall is widely used and has built-in read-aloud ([Perusall](https://www.perusall.com/overview), per M1), but add a Perusall record to the data file before the page names it.
  - Spoken Margins (spoken notes at the moment; free TestFlight beta, iPhone and iPad on iOS 26+).
- **Table:** `render_table.py --apps hypothesis,notebooklm,speechify,spoken-margins --fields reads_pdfs_aloud,voice_notes_anchored,text_notes_anchored,group_listening,export_markdown_pkm,account_required,price_free_tier`
- **Keeping courses apart:** folders by course. [Spoken Margins can't group by course yet (#208); say so.]
- **When not to use Spoken Margins:** your course runs on Perusall or Hypothesis for credit; your study group isn't on iPhone or iPad.
- **Change log.**

**Held until:** the owner's student interviews (M1) confirm the "capture at the moment" pain in students' own words. Use their wording, with permission, only if they agree to be quoted.
