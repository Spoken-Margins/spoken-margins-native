# D1 directions (M1)

Three clickable, phone-sized prototypes of a redesigned Spoken Margins, for the owner to pick from (stream D1, issue #194). Each page is self-contained: open it on a phone and the page is the app. On a wider screen the phone sits next to a guide with tasks and the tap table.

| Direction | Page | Navigation idea |
| --- | --- | --- |
| A · Four Rooms | [a-rooms.html](a-rooms.html), [artifact](https://claude.ai/artifact/KsrRoxtV5THC1AtRFjQ4yP) | Four tabs: Home, Following, Library, Margins. Full-screen player from a mini-player. Closest to Build 29. |
| B · The Deck | [b-deck.html](b-deck.html), [artifact](https://claude.ai/artifact/Mw4cgXUvyr6MHceLWFF4P5) | Now Playing is the root screen. Home, Following, Library and Margins are panes of one drawer. You record by pressing and holding. |
| C · Notebook | [c-notebook.html](c-notebook.html), [artifact](https://claude.ai/artifact/AEq8V4usWFc8mfY2pGq2dR) | Two tabs, Notebook and Listen, with a record button between them. Your and your friends' Margins are the home screen. |

Tap **Tasks** (on a phone) and then **Try** on a task. The counter in the top strip counts every tap from the task's start screen until the task is done. The budgets below are those counts.

## Tap budgets

| Task | A | B | C | Today |
| --- | --- | --- | --- | --- |
| Share a Margin to a friend | 2 | 2 | 2 | 8–10 |
| Follow what's playing | 1 | 1 | 1 | — |
| Follow a podcast on first run | 2 | 1 | 1 | no first run |
| Record a Margin | 2 | 1 (hold) | 2 | — |
| Export this week as a note | 3 | 3 | 2 | ~5, plus 6–8 to set up the folder |
| Open a shared packet and hear it | 2 | 2 | 2 | — |

"Today" gives the counts from the brief. The first export to a new notes folder adds 2 taps for the Files picker, once, in every direction.

The system surfaces are the same in all three directions: the iOS share sheet (with a preview of what the recipient gets and a note that the private feed link is left out), the incoming-packet card and the export sheet. That keeps the comparison about navigation and look.

## Rebuilding

The pages are built from `src/`. After editing, run:

```bash
python3 Design/D1-directions/build.py            # rewrites the three pages here
python3 Design/D1-directions/build.py <outdir>   # also writes artifact fragments (no <head>) to <outdir>
```

`smoke.mjs` walks each task's path in Chromium and prints the measured taps. `shots.mjs` makes a contact sheet of named screens. Both need Playwright (`NODE_PATH=$(npm root -g) node smoke.mjs …`).

All shows, people and quotes are made up.
