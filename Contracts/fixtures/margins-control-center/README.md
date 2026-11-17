# Margins control center cases

`cases.json` holds language-neutral cases for the Margins tab and the arrival preview (part of #3216). Each case gives an item's Margins, the playhead and the Autoplay setting, and says what the list and its controls must show. SessionKit runs every case in `MarginsControlCenterCasesTests`. The web prototype can run the same file, so both follow one set of rules.

- **Schema:** `Contracts/schemas/margins-control-center-cases.schema.json`. `scripts/validate-contracts.py` checks the file against it.
- **Times** are source milliseconds in the listener's copy.
- **Margins are listed oldest first.** That order breaks ties between Margins at the same time, and orders replies under one parent.
- **`sender`** is `"you"` for the listener's own Margin; any other name is a friend, one shared packet per friend.
- **`listenedMs`** above 0 means heard. Reading a Margin's words never marks it heard.
- **`parentId`** naming an id that isn't in the case is a reply whose parent is missing from this Library.

The rules each case checks are named in its `rule` field:

1. `order`: threads by the time of their first Margin, unplaced last; replies under their parent.
2. `hearing` and `opensOnMarginsTab`: an item with an unheard friend's Margin opens on the Margins tab.
3. `words`: blank, missing or placeholder words show as words coming.
4. `leadIn`: the quoted source text before a Margin, cut to 110 characters at a whole word.
5. `starred`: only your own Margins can be starred.
6. `autoplay`: with Unheard, only an unheard friend's Margin plays; All plays every Margin; Off plays a tone for each.
7. `nextMargin`: it stops only at a thread's first Margin, never at a reply. Under Unheard it goes to the next thread holding an unheard friend's Margin. Before that Margin's 20 s lead-in it seeks to the lead-in; inside the lead-in it goes straight in. It never goes back and never past it. `firstToPlayId` is the thread's first unheard friend's Margin unless Autoplay is All, otherwise its first Margin.
8. `countdown`: the pill's `m:ss` clock to the next Margin, rounded up.
9. `startWithUnheard`: the lead-in of the first thread holding an unheard friend's Margin. "Start from the beginning" is 0:00.

The file also carries the constants and the control labels, so a port can check its wording against SessionKit's.

The names and words are synthetic. Never add a real listener's Margins here.
