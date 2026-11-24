# First run, persona by persona

**Purpose:** the personas cluster run #5030 (Cluster B) walks through a cold install, and the scenario the Test Desk runs for each. Findings are added below each persona after the desk's run, from its captures.
**Status:** run by the Test Desk on 2026-11-22, T4 on PR #5032, `main` at 2c4276d, one cold install per persona on a test simulator with real taps. Captures are kept on the desk (`artifacts/lane/pr5032/`), not in the repository. Not covered: real VoiceOver (P9 read the accessibility tree only), anything heard, publishing a share link, sending to Readwise.

## Personas

Sources: `docs/workstreams/streams/G2-growth.md:15-17` (students, PKM people, creators with communities) and the jobs table in #4679. P6 (researcher) and P9 (VoiceOver) are added here; neither is validated with a real person.

| # | Persona | Job (#4679) | Arrives by | First ten minutes, likely |
|---|---|---|---|---|
| P1 | Talk-back listener | Talk back to what I hear | Cold download | Plays something, tries a Margin |
| P2 | Friend who got a file | Respond to someone | A `.spokenmargins` file | Hears the friend's Margin, answers |
| P3 | Student | Get through assigned material | Cold | Brings a reading (PDF or article link) |
| P4 | Professor | See that students thought | Cold | Looks for a way to give a class prompts and get replies |
| P5 | PKM / vault person | Fill my vault | Cold | Makes a Margin, looks for export to notes |
| P6 | Researcher | Hear a difficult paper | Cold | Adds a paper PDF, looks for figures and chapters |
| P7 | Community creator | Run a book club / share with people | Cold | Looks for sharing with a group |
| P8 | Meetings person | Margins in meetings and calls | Cold | Looks for live recording or a transcript import |
| P9 | VoiceOver listener | Any of the above | Cold | Drives the first run with VoiceOver on |

## Rules for every walkthrough

- A fresh test simulator, or the app deleted and reinstalled between personas, so each one is a real cold install. Never a real Library.
- Allow every permission prompt. Mute the simulator's audio before the first Play.
- One screenshot per step, kept in `artifacts/`. Note the clock and what is playing.
- "Short" means: what a first-time listener cannot work out without help. Write it as the screen and the words on it.

## Findings

| Persona | Taps to first sound | Taps to first Margin | First point a newcomer is stuck | Issue |
|---|---|---|---|---|
| P1 talk-back | 2 | 4 | iOS's Speech prompt on first Save with no word from the app, then "Saved · transcript failed · Retry" | #4715, #5016 |
| P2 friend's file | 3 | 8 | "Skip to Sam's Margins" said "Next Margin in 5 min. It won't play by itself." and nothing played | none: the fixture's audio address can't be reached; a follow-up run with real silent audio passed (lands 20 s before the Margin, Sam plays, the end card follows) |
| P3 student | 10 (7 without a refused link) | none | An arXiv abstract link is refused after about 41 s with an unlabelled spinner; the PDF link works | #5049 |
| P4 professor | as P3 | 1 written | No class or collect-replies path; sharing is one-to-one | #5033 |
| P5 PKM | 3 | 5 | Done on the drawer leads to Terms, then Welcome plays by itself; export exists but sits under Margin › More, with no saved message | #5034 |
| P6 researcher | 3; the paper at 10 | none | A PDF added by link waits for Start; the bottom Timeline row sits under the switcher; Figure 1 and both tables have no rows | #5035 |
| P7 community creator | 2 | 4 | Share opens a long consent dialog; Welcome plays on under the share sheet; no group option | #5033, #1799 |
| P8 meetings | 2 | n/a | Live Session sits 6 taps from launch, under Add to Library. A session that seemed to start from a top-right tap was not reproduced: the setup screen has no control there | #4678 |
| P9 VoiceOver (tree only) | 2 | card reached | Unlabelled search fields; the Settings tab reads "gearshape.fill" | #5036 |

What held up:
- A friend's file as the first launch opens the friend's item, with no drawer and no Terms, and the line after an answer is clear: "To send it to Sam (synthetic), tap Share below. You pick which of your Margins go."
- Export to Markdown works and writes YAML front matter with a link back into the app.
- The OPML preview, its switches and "Follow N" behave as their Design expects.
- No crashes in nine installs.

Other defects filed from these runs: #5050 (sound under the share flow), #5051 (export gives no confirmation), #5052 (add sheet stays open after Follow). Noted on existing issues: #4714 (the drawer's two exits differ), #448 (Expand chapter taps land on the switcher), #5036 (accessibility tree findings).

Design checks: the six Designs posted in run #5030 were checked against these captures. #4711, #4713, #4715, #4784 and #4920 needed no change. #4723 was amended: at the largest text size Following titles break inside words, so its rows stack at accessibility sizes.
