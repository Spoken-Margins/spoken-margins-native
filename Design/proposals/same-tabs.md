# Same tabs, straighter paths (the control)

**The idea.** Change nothing about where the three tabs are or what they are called, and fix only the paths: Margins keep their grouping by item with Share beside each heading, but the groups are ordered by their newest Margin and that Margin is labelled; a Margin row plays its moment and its chevron opens details with Share this Margin; dates on the Item screen; a gear on the Library instead of its options menu; Export all Margins as one button that hands a bundle to the share sheet; Clear reproducible audio on Settings itself; Unfollow without its confirmation (an Undo toast instead); Following folds a noisy show to one row and can set it Quiet; Manage feeds keeps its jobs but gets a Paste button and opens the file picker at once for an OPML import. This is not a new structure. It is the control: it shows how much of the tap-count gain comes from path fixes alone, so the three structural proposals have to earn their keep on guessability, screen count and the noisy show, not on taps.

## Taps

| Job | As built | Proposed | Route |
| --- | --- | --- | --- |
| Import an OPML file | 6 | 5 | Following tab > "Follow a feed" / "N feeds · Manage" row > "Import from another app" (square.and.arrow.down) |
| Follow a podcast from a link | 5 | 4 | Following tab > "Follow a feed" / "N feeds · Manage" row |
| Unfollow a show | 5 | 4 | Following tab > "Follow a feed" / "N feeds · Manage" row |
| Find the Margin you added most recently | 1 | 1 | Margins tab |
| Hear a Margin's moment | 3 | 2 | Margins tab > Margin row (plays this moment) |
| Share one Margin with a friend | 5 | 3 | Margins tab > chevron on a Margin row (details) > Share this Margin (square.and.arrow.up) |
| See an item's details | 1 | 1 | Library row (title area) |
| Add an article from the clipboard | 2 | 2 | Add (plus) |
| Write a Margin while listening | 2 | 2 | Mini player (Open Now Playing) > square.and.pencil 'Write a Margin' |
| Open the Timeline for what's playing | 2 | 2 | Mini player (Open Now Playing) > Timeline (pane switch) |
| Change the reading voice | 4 | 3 | gearshape, Settings (toolbar) |
| Free up storage | 5 | 3 | gearshape, Settings (toolbar) |
| Export all Margins | 6 | 2 | Margins tab > Export all Margins (toolbar) |
| Get help | 2 | 2 | gearshape, Settings (toolbar) > "How Spoken Margins Works" (questionmark.circle) |
| See new episodes from a show you follow | 1 | 1 | Following tab |
| Open a Margin packet a friend sent | 2 | 2 | open a .spokenmargins packet file (Files, Mail, AirDrop, Messages) |
| Share all of an item's Margins | 3 | 3 | Margins tab > Share (square.and.arrow.up), 'Share Margins from <item>' > Share N (square.and.arrow.up) |

Still over the ceiling: importing an OPML file (5), following a show from a link (4) and unfollowing one (4), all because Manage feeds is still two taps deep.

## Problems it solves

1. Newest Margin: yes, the first group, labelled.
2. Dates: on the Item screen; the Library's sort is a smaller change here (Added and Published only).
3. Clusters: not really; the Library stays as it is, with collections.
4. The noisy show: folded in Following, Quiet from its Manage menu, but it still has a tab of its own to fill.
5. Now Playing: untouched.
6. Settings: tidied, but Manage feeds still sits under Following and still carries Browse and Import.

## What it makes worse

- Nothing a current listener would notice, which is also its weakness: "Following" stays a stream that fills, and Manage feeds stays a second-level screen that holds four unrelated jobs.
- A newcomer still has to learn that following a show is under Following → Manage feeds, not under + or Settings.

**The one thing taken out:** the Library's options menu.

**What would show it is wrong:** after these fixes he still asks where a show lives; then the problem was structure, and one of the other three is needed.

## How it grows

It has no place for a friend's story or a book club, and this file should say so plainly. Following is a stream of feed entries, Manage feeds is a list of feeds, and the Library is items. A friend's activity could be forced into the Following stream as one more kind of entry, and a club's thread could hang off an item's Margins group, but neither has a home a newcomer could name, and "Manage feeds" cannot hold a person. Adding one is exactly the structural change the control exists to avoid. If friends and clubs are coming, this proposal is a stopgap, not a destination.

## The screens that change most

```
 Margins                 Export all ⚙ |   Following                          ⚙ |   Settings
 ─────────────────────────────────── |   ──────────────────────────────────── |   ───────────────────────────────────
 Tides           3 Margins · Share   |   6 feeds · Manage                 ›   |   Voice         Kitten · Ava       ›
 ▶ 18%  Sam: "the bit I meant" Shared›|  Today                                |   Storage       1.2 GB · Clear 400 MB
 ▶ 23%  "salt marsh: check…"        ›|   ▸ The Daily · 3 new              ›   |   Notes folder  iCloud/Margins     ›
 ▶ 61%  "the second tide…"  Newest  ›|   ▶ Why cities hum   Nautilus    18m   |   Import & export
 Hard Fork       1 Margin · Share    |   Yesterday                            |     Listening Edition              ›
 ▶ 41:10 "agents as interns" (🎙)   ›|   ▸ Hard Fork · 1 new              ›   |     Export sessions to a folder    ›
 A short history of salt  1 · Share  |   ▶ A short history of salt      41m   |     Show all (2 more)
 ▶ 02:12 "Roman roads"             ›|   ──────────────────────────────────── |   Help                             ›
 ─────────────────────────────────── |   ▶ Tides · 12:40 ────────── ● 🎙      |   About & legal                    ›
 ▶ Tides · 12:40 ────────── ● 🎙     |   [Library] [Following] [Margins]      |
 [Library] [Following] [Margins]     |                                        |
```

On Margins, tapping a row plays the moment; › opens the Margin's details, where Share this Margin lives. Groups are ordered by their newest Margin, so Tides comes first; inside a group the rows keep source order, and the newest Margin carries the Newest label. Share beside a heading shares that item's Margins, as today.
