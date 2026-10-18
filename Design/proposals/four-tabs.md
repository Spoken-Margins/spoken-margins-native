# Four tabs: Library, Following, Margins, Settings

**The idea.** Give every home a name on the tab bar and make a show a place you go, not a feed that comes to you. **Following** lists everything you follow, one row each, sorted by newest: today that is shows, each row with "N new", the newest episode's title and a play button; later a friend and a book club are rows in the same list (see How it grows). Quiet shows sink to a collapsed group at the bottom. The old Following stream and Manage feeds both disappear: the tab lists what is new, and a show's own screen is where Quiet and Unfollow live, which keeps the brief's rule about landing screens. Following's plus opens its own sheet, **Follow a show or a friend**: Paste (a copied show link is followed at once, with Undo), Browse shows and writers, Import from another app. The **Library**'s plus means only "add a source", and the Library holds items only, one list you can sort. **Settings** gets the fourth tab, which makes voice, storage and help cheap. Margins stay grouped by item, with Share beside each item's heading; groups are ordered by their newest Margin, which carries a Newest label. A noisy show never floods anything: it is one row with a bigger number.

## Taps

| Job | As built | Proposed | Route |
| --- | --- | --- | --- |
| Import an OPML file | 6 | 5 | Following tab > Follow (plus) > Import from another app tile (the file picker opens at once) |
| Follow a podcast from a link | 5 | 3 | Following tab > Follow (plus) |
| Unfollow a show | 5 | 3 | Following tab > Show row |
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
| See new episodes from a show you follow | 1 | 1 | Following tab |
| Open a Margin packet a friend sent | 2 | 2 | open a .spokenmargins packet file (Files, Mail, AirDrop, Messages) |
| Share all of an item's Margins | 3 | 3 | Margins tab > Share (square.and.arrow.up), 'Share Margins from <item>' > Share N (square.and.arrow.up) |

Still over the ceiling: importing an OPML file (5), a once-per-listener job. It was 4 when the import tile sat on the Library's Add sheet; moving it to the Follow sheet, where it belongs, costs one tap.

## Problems it solves

1. Newest Margin: the first group on the Margins tab, labelled Newest.
2. Dates: the Item screen's header, and the Library's Added and Published sorts; Following is dated by newest episode.
3. Clusters: the Library's sort control; shows are their own cluster, on their own tab.
4. The noisy show: one row on Following, with a count; Quiet moves it to the collapsed group; its episodes enter the Library only when played.
5. Now Playing: untouched.
6. Settings: a tab, six sections, long groups collapsed. Feed management is one tap away on each show's screen, not inside Settings and not on any tab.

## What it makes worse

- Four tabs instead of three. Each tab is narrower, and the tab bar is the busiest it has been.
- There is no single list of today's new episodes across shows. He sees counts on Following and opens each show. If he listens by day rather than by show, this is the wrong proposal.
- Settings on the tab bar gives a junk drawer a permanent seat. The six-section discipline has to hold, or it becomes the old Settings with a bigger door.
- Two plus buttons that do different things: the Library's adds a source, Following's follows. The sheet titles carry the difference ("Add", "Follow a show or a friend").
- Importing an OPML list costs 5, one more than when the tile sat on the Library's Add sheet.

**The one thing taken out:** the Following stream. Nothing arrives; you go to the show.

**What would show it is wrong:** he opens Following and taps into three shows in a row to collect the day's episodes. That is Stream's job.

## How it grows

Following is already a list of things you follow, sorted by newest with a count, so a friend and a club are two more kinds of row in it, not new screens on the tab bar.

- **A friend's story** is a row on Following: "Sam · listening to Tides · 2 new Margins". It opens a Friend screen: what they are listening to now, and the Margins they left, newest first, each one playable at its moment in your own copy. Follow a friend from the same Follow sheet, by pasting their invite link.
- **A book club** is a row on Following: "Salt Club · A short history of salt, ch. 4 · 3 new in the thread". It opens a Club screen: the current item with a play button, and the thread of Margins the members left on it. Join a club the same way, from an invite link.
- The count on each row means "new since you looked": episodes for a show, Margins for a friend, posts for a club. One sort, one count, three kinds of row.
- Quiet works the same for all three, and lives on the Friend and Club screens as it does on the Show screen.

## The screens that change most

```
 Following                        +  |   Show: The Daily          Quiet ○    |   Follow a show or a friend      Cancel
 ─────────────────────────────────── |   ──────────────────────────────────── |   ───────────────────────────────────
 The Daily      3 new   Oct 16 ▶  ›  |   Following since March   [Unfollow]   |   ┌ Browse shows ┐ ┌ Import from  ┐
 Sam  friend    2 new   Tides     ›  |                                        |   │ and writers  │ │ another app  │
 Salt Club      3 new   ch. 4     ›  |   Oct 16  ▶ The Daily: Oct 16    17m   |   └──────────────┘ └──────────────┘
 Hard Fork      1 new   Tue    ▶  ›  |   Oct 15  ▶ The Daily: Oct 15    22m   |
 Nautilus              last wk    ›  |   Oct 14  ▶ The Daily: Oct 14    19m   |   [        Paste        ]
 Quiet (2)                   Show ▾  |   …                                    |   A copied show or invite link is
                                     |                                        |   followed at once. Undo in the toast.
 ─────────────────────────────────── |   ──────────────────────────────────── |
 ▶ Tides · 12:40 ────────── ● 🎙     |   ▶ Tides · 12:40 ────────── ● 🎙      |
 [Library] [Following] [Margins] [Settings]                                   |
```

On Following, ▶ plays the show's newest unplayed episode and › opens the show, friend or club. The "+" opens the Follow sheet; the Library's "+" opens the Add sheet, which adds a source and nothing else. The friend and club rows are what the tab grows into; they are not in the flow map yet.
