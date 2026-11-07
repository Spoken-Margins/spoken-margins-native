# Product areas

Spoken Margins does four things for a listener, in order: it gets content in, plays it well, lets them answer it, and lets them pass it on. Each issue belongs to exactly one of these areas, or to Groundwork, and carries its label: `area: get it in`, `area: hear it well`, `area: answer it`, `area: pass it on` or `area: groundwork` (owner, 2026-11-07, #3636). An hourly check on the Mac (`scripts/area_labels.py`) adds `needs-area` to an open issue with none or with two; whoever files or picks up the issue sets one. If an issue seems to need two, it is usually two issues. The labels replaced the GitHub Project board's Area field (#2173), which cloud sessions could not read. Streams ([workstreams/](workstreams/README.md)) and milestones still decide what gets worked on and when; an area says what "excellent" means for the work.

The areas come from the owner's voice memo of 2026-10-05 (about 21:50–38:30), regrouped on 2026-10-12. In the memo, review and co-op share one backbone, so they share an area here. Social work is only what passing things between people adds.

**How to use this when you scope or finish an issue:** read the standards for its area. A change that breaks one is not done. A gap you notice against one gets its own issue in that area, not a fix folded into your PR.

## Every area: learnable the first time

A new listener understands each area's main flow the first time they meet it, without a manual. That means a short guided first use, empty states that explain, and help reachable from where the flow happens. This is a standard every area owes, not a separate area (#852). The Test Desk's fresh-install journeys check it.

## 1. Get it in

Sources, following, the feeds screen, filtering, the Home screen, and importing links, files, books and PDFs. Streams B1–B4, D2, D3, G1. Code: `SessionKitFeeds`, `SessionKitEPUB`, the following coordinator, Quick Access and file import.

- Anything a listener wants to hear reaches the Library in one step from where they found it (share sheet, link, Files), or the app says plainly why it can't.
- A listener can narrow a noisy feed by interest and by how much time they have ("15 minutes", "two hours") without writing a filter expression.
- Nothing the app learns about what a listener follows leaves the phone in a form that identifies them. Shared metadata is downloaded in bulk or as a sample and matched on the phone.

## 2. Hear it well

Voices, reading PDFs and articles aloud, the player, chapters, listening maps, Skim, the Lock Screen, Live Activity and watch. Streams C1–C3, D5, E3. Code: `SessionKitAudio`, `SessionKitSupertonic`, listening maps and scene starts, the Skim bridge, the map preparer.

- Every way of moving through a podcast also works on an article or a PDF, and the reverse: chapters, Skim, Next chapter with its summary, Margins.
- Navigating audio comes close to skimming a page: chapter titles are good enough that the owner doesn't rewrite them, and a listener can find a passage.
- What narration skips (figures, tables, equations) can be seen from the playback screen.
- It works on the device, for free, on the oldest supported iPhone and in Low Power Mode. Server voices may sound better but never unlock a function.
- The hardest case to aim at: a difficult PDF, played on the watch alone.

## 3. Answer it

Margins and everything built on them: capturing a Margin, rejoinders, the weekly review, the morning brief, and the conversation half of co-op. Streams E1, E2. Code: Margin capture and voice playback, the Margin parts of `SessionKit`.

- One backbone serves the review, the brief and co-op: a lead-in, a Margin, a rejoinder, and a reply to that rejoinder, moved through quickly by voice or touch.
- Leaving a Margin never loses the listener's place.
- A quick Margin can become a lasting note in the listener's own notes.
- A review plays the Margins that matter, not every Margin of the week (#201).
- It is excellent without on-device AI. AI may improve it, never unlock it.

## 4. Pass it on

Packets, share links, shared Margins landing in the right place, friends, stories, book clubs, classrooms, and the server that carries them. Streams C4, D4, F1. Code: `SessionKitSharing`, `CoopPacket`, packet import, bulk share.

- A packet exported by a new build opens in the last shipped build, unless the owner accepted a break.
- A shared Margin plays at the right moment in the recipient's own copy, or says how far off it may be.
- Anything that identifies a person (a voice Margin does) reaches the server only end-to-end encrypted (#805).
- What costs money per listener is paid for by the listener, except one book club and about five friends (#736).

## Groundwork

Not a product area: the pipeline, the test lane, test honesty, the model split and anything else that makes the four areas cheaper and safer to change. Streams A1–A3. Its standard is the Solid Ground target in `AGENTS.md`: later builds arrive faster, and the Test Desk catches bugs before they reach the owner's phone.

An issue that seems to serve no area, such as growth research or a settings change, takes the area its listener benefit lands in; growth research is `area: pass it on`. Groundwork has no milestone: it is a lane that always runs, and a groundwork item joins a release milestone only when it blocks that release.
