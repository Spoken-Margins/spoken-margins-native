# D1 directions, round two (M1 redo)

Three clickable, phone-sized prototypes of a redesigned Spoken Margins, for the owner to pick from (stream D1, issue #194). This round replaces the first attempt in the parent folder, which the owner found cluttered and without a clear direction for a user. The old pages stay there for comparison.

Each page is self-contained: open it on a phone and the page is the app. On a wider screen the phone sits next to a guide with the disclosure tiers, the intended user paths, the tasks and the tap table.

| Direction | Page | The idea | What it hides |
| --- | --- | --- | --- |
| 1 · Player | [1-player.html](1-player.html), [artifact](https://claude.ai/artifact/BXPvxs7Vcbji1Y7jCNxC5n) | The app is Now Playing. Two doors in the top corners: Shelf (what to listen to) and Notebook (what you said). No tabs. | Browsing, Margins, settings: all behind a door. |
| 2 · Today | [2-today.html](2-today.html), [artifact](https://claude.ai/artifact/HEmcs9H8AWrv8xJVkjzKS1) | A daily paper. Today (what's new), Saved, Notes. The player is a sheet from the mini-player, and the mini-player has the mic. | Feed management, export, the player itself. |
| 3 · Notebook | [3-notebook.html](3-notebook.html), [artifact](https://claude.ai/artifact/CLyu85kPMmR9BqjhG4Zeog) | Your Margins are the home screen. Listen is the other tab. The mic sits between them and never moves. | Everything about listening that isn't a Margin. |

## What changed from round one

- **One job per screen.** Each landing screen has one hero, one list and at most one secondary row. Feed management, settings, diagnostics and badges never appear on a landing screen.
- **Disclosure tiers are written down.** Every guide lists what is on screen, one tap away, two taps away, and never on landing, so the owner can judge the intent, not just the pixels.
- **Theory of mind.** Every guide narrates the first minute, a typical day, the sharing moment and Sunday's export.
- **Two-tap target, three-tap ceiling.** The counter names the state in words and colour (blue within target, orange at or over the ceiling). Three taps is flagged for review; more than three is a fail.
- **Tap targets are 44 pt or larger everywhere** (#151), and the primary action sits in the bottom third (#148, #149).
- **The next Margin ahead is always visible** in the player, with Skim (#115, #167).
- The share sheet preview is one line, not a card.

## Tap budgets

Measured by walking each path with real clicks at 375×812 and 390×844 in Chromium. They match the on-screen counter. Target 2 (1 where a single control does it), ceiling 3.

| Task | 1 · Player | 2 · Today | 3 · Notebook | Round one (A/B/C) | Today's app |
| --- | --- | --- | --- | --- | --- |
| Share a Margin to a friend | 2 | 2 | 2 | 2/2/2 | 8–10 |
| Follow what's playing | 1 | 1 | 1 | 1/1/1 | — |
| Follow a podcast on first run | 1 | 1 | 1 | 2/1/1 | no first run |
| Record a Margin | 1 hold (2 tap) | 1 hold (2 tap) | 1 hold (2 tap) | 2/1/2 | — |
| Export this week as a note | **3** (2 from Notebook) | 2 | 2 | 3/3/2 | ~5, +6–8 to set up |
| Open a shared packet and hear it | 2 | 2 | 2 | 2/2/2 | — |

"Hold" means press and hold the mic and let go to save; a plain tap opens the recording sheet, and Save makes it two. The first export to a new notes folder adds the Files picker (2 taps, once) in every direction.

The system surfaces are the same in all three: the iOS share sheet (one-line preview of what the recipient gets, private feed link left out) and the incoming packet card. Directions 1 and 3 export through a sheet that previews the note; direction 2 saves the note straight to the folder and confirms with a toast. That keeps the comparison about navigation and disclosure.

## Rebuilding and checking

The pages are built from `src/`:

```bash
python3 Design/D1-directions/v2/build.py            # rewrites the three pages here
python3 Design/D1-directions/v2/build.py <outdir>   # also writes copies for publishing
```

Serve the folder with any static server (`python3 -m http.server --directory Design/D1-directions/v2`). In a browser console, `Engine.walk('share', ['.mg [data-share="m1"]', '.person[data-arg="Priya"]'])` runs a task programmatically and returns the measured taps. `audit.js` (paste it into the console) opens every screen and sheet and reports horizontal overflow, elements outside the phone and tap targets under 44 pt.

All shows, people and quotes are made up.
