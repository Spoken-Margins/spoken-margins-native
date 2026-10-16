# Four tabs: Library, Shows, Margins, Settings

**The idea.** Give every home a name on the tab bar and make a show a place you go, not a feed that comes to you. **Shows** lists the shows you follow, sorted by newest episode, each row showing its unplayed count, the newest title and a play button; Quiet shows sink to a collapsed group at the bottom. The Following stream and Manage feeds both disappear, because the Shows tab is both at once: you see what is new there, and you follow, quiet and unfollow there. The **Library** holds items only, one list you can sort. **Settings** gets the fourth tab, which makes voice, storage and help cheap and puts the rare import jobs one named tap away. Margins are newest first and a row plays its moment. A noisy show never floods anything: it is one row with a bigger number.

## Taps

| Job | As built | Proposed | Route |
| --- | --- | --- | --- |
| Import an OPML file | 6 | 4 | Add (plus) > Import from another app tile (the file picker opens at once) |
| Follow a podcast from a link | 5 | 3 | Add (plus) |
| Unfollow a show | 5 | 3 | Shows tab |
| Find the Margin you added most recently | 1 | 1 | Margins tab |
| Hear a Margin's moment | 3 | 2 | Margins tab > Margin row (plays this moment) |
| Share one Margin with a friend | 5 | 3 | Margins tab > chevron on a Margin row (details) > Share this Margin (square.and.arrow.up) |
| See an item's details | 1 | 1 | Library row (title area) |
| Add an article from the clipboard | 2 | 2 | Add (plus) |
| Write a Margin while listening | 2 | 2 | Mini player (Open Now Playing) > square.and.pencil 'Write a Margin' |
| Open the Timeline for what's playing | 2 | 2 | Mini player (Open Now Playing) > Timeline (pane switch) |
| Change the reading voice | 4 | 3 | Settings tab |
| Free up storage | 5 | 3 | Settings tab |
| Export all Margins | 6 | 2 | Margins tab > Export all Margins (toolbar) |
| Get help | 2 | 2 | Settings tab > "How Spoken Margins Works" (questionmark.circle) |
| See new episodes from a show you follow | 1 | 1 | Shows tab |
| Open a Margin packet a friend sent | 2 | 2 | open a .spokenmargins packet file (Files, Mail, AirDrop, Messages) |

Still over the ceiling: importing an OPML file (4), a once-per-listener job.

## Problems it solves

1. Newest Margin: top of the Margins tab.
2. Dates: the Item screen's header, and the Library's Added and Published sorts; the Shows tab is dated by newest episode.
3. Clusters: the Library's sort control; shows are their own cluster, on their own tab.
4. The noisy show: one row on Shows, with a count; Quiet moves it to the collapsed group; its episodes enter the Library only when played.
5. Now Playing: untouched.
6. Settings: a tab, six sections, long groups collapsed. Feed management is next door on Shows, not inside Settings and not on the Library.

## What it makes worse

- Four tabs instead of three. Each tab is narrower, and the tab bar is the busiest it has been.
- There is no single list of today's new episodes across shows. He sees counts on Shows and opens each show. If he listens by day rather than by show, this is the wrong proposal.
- Settings on the tab bar gives a junk drawer a permanent seat. The six-section discipline has to hold, or it becomes the old Settings with a bigger door.
- The Add sheet carries Browse and Import tiles, so from the Shows tab "+" opens the same sheet as from the Library; a newcomer may expect a shows-only sheet.

**The one thing taken out:** the Following stream. Nothing arrives; you go to the show.

**What would show it is wrong:** he opens Shows and taps into three shows in a row to collect the day's episodes. That is Stream's job.

## The screens that change most

```
 Shows                            +  |   Show: The Daily          Quiet ○    |   Settings
 ─────────────────────────────────── |   ──────────────────────────────────── |   ───────────────────────────────────
 The Daily      3 new   Oct 16 ▶  ›  |   Following since March   [Unfollow]   |   Voice         Kitten · Ava       ›
 Hard Fork      1 new   Tue    ▶  ›  |                                        |   Storage       1.2 GB · Clear 400 MB
 Nautilus              last wk    ›  |   Oct 16  ▶ The Daily: Oct 16    17m   |   Notes folder  iCloud/Margins     ›
 Hakai                 Oct 2      ›  |   Oct 15  ▶ The Daily: Oct 15    22m   |   Import & export
 Quiet (2)                   Show ▾  |   Oct 14  ▶ The Daily: Oct 14    19m   |     Listening Edition              ›
                                     |   Oct 13  ▶ The Daily: Oct 13    21m   |     Export sessions to a folder    ›
                                     |   …                                    |     Show all (2 more)
                                     |                                        |   Help                             ›
 ─────────────────────────────────── |   ──────────────────────────────────── |   About & legal                    ›
 ▶ Tides · 12:40 ────────── ● 🎙     |   ▶ Tides · 12:40 ────────── ● 🎙      |   ───────────────────────────────────
 [Library] [Shows] [Margins] [Settings]                                       |   [Library] [Shows] [Margins] [Settings]
```

On Shows, ▶ plays the show's newest unplayed episode and › opens the show. The "+" opens the Add sheet, which carries Paste a link, Browse podcasts and writers, and Import from another app.
