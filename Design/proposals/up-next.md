# Up next: a bounded shortlist, Library, Margins

**The idea.** This is the owner's own suggestion, answered as a challenge: a suggestion screen beside a one-dimensional library you can sort. The Following tab becomes **Up next**, a ranked shortlist that fits one screen: continue listening, one card per show with its newest unplayed episode ("and 2 more" opens the Show screen), items you added but have not started, and a shared Margin waiting to be heard. It is capped, not a stream, so a show that posts three times a day takes one card and a Quiet show takes none. The Library holds items only and becomes the sortable list the owner described, with clusters built from metadata: date added, published, publisher, topic. Feed management gets one home, **Shows you follow** under Settings, with the Show screen beneath it; its Paste follows a copied show link at once, with Undo. The Library's plus means only "add a source". Settings is a gear on every tab. Margins stay grouped by item, with Share beside each item's heading; groups are ordered by their newest Margin, which carries a Newest label.

## Taps

| Job | As built | Proposed | Route |
| --- | --- | --- | --- |
| Import an OPML file | 6 | 5 | gearshape, Settings (toolbar) > Shows you follow (row) > "Import from another app" (square.and.arrow.down) |
| Follow a podcast from a link | 5 | 3 | gearshape, Settings (toolbar) > Shows you follow (row) |
| Unfollow a show | 5 | 3 | Up next tab > 'and N more' on a show's card |
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
| See new episodes from a show you follow | 1 | 1 | Up next tab |
| Open a Margin packet a friend sent | 2 | 2 | open a .spokenmargins packet file (Files, Mail, AirDrop, Messages) |
| Share all of an item's Margins | 3 | 3 | Margins tab > Share (square.and.arrow.up), 'Share Margins from <item>' > Share N (square.and.arrow.up) |

Still over the ceiling: importing an OPML file (5), a once-per-listener job.

## Problems it solves

1. Newest Margin: the first group on the Margins tab, labelled Newest.
2. Dates: the Item screen's header, and the Library's Added and Published sorts.
3. Clusters: the Library's sort control, and Up next groups by show.
4. The noisy show: one card, never more, and none when Quiet. Its episodes never enter the Library until played.
5. Now Playing: untouched.
6. Settings: six sections, and feed management is a single row in it, Shows you follow, which is where a newcomer who thinks "subscriptions are a setting" will look.

## What it makes worse

- Up next is a judgment call made by the app. The first time it hides something he wanted, trust drops, and the only way back is the Library or the show's screen.
- Unfollowing a show with no card on Up next costs 4 (gear, Shows you follow, the show, Unfollow).
- Seeing every new episode of one show costs 2 (Up next, "and N more"), and there is no place that lists all new episodes across shows.
- Following a show from a link runs through Settings (gear, Shows you follow, Paste): 3 taps, but none of them is a word a newcomer would guess.
- It is the closest of the four to the rejected Today and Home directions. The difference is that it is bounded and tap-first, not shelves and icons, but the owner may not see that difference.

**The one thing taken out:** the Library's options menu, as in Stream. Also: no "see all" at the bottom of Up next; the Library is the see-all.

**What would show it is wrong:** his first tap after launch is usually Library, not Up next. Then the shortlist is dead weight and Stream or Four tabs should take its place.

## How it grows

Up next is a shortlist of what deserves your next listen, so friends and clubs enter it as two more card groups, each capped like the others.

- **From your friends:** one card per friend with something new, "Sam · 2 new Margins on Tides", with a play button for the newest Margin's moment and "and 1 more" opening the Friend screen: what they are listening to and their Margins, newest first.
- **Your clubs:** one card per club, "Salt Club · chapter 4 · 3 new in the thread", with a play button for the current chapter and the card opening the Club screen with the thread.
- Friends and clubs you follow are listed under Settings beside Shows you follow, as "People and clubs", which is where following, Quiet and leaving live. Follow from an invite link pasted there.
- The cap is the cost: with shows, friends and clubs all wanting a card, Up next has to drop something every day, and the app chooses what.

## The screens that change most

```
 Up next                          ⚙ |   Settings                             |   Shows you follow                  +
 ─────────────────────────────────── |   ──────────────────────────────────── |   ───────────────────────────────────
 Continue                            |   Voice        Kitten · Ava        ›   |   [ Paste a show link ]  Browse · Import
 ▶ Tides · ch. 3, 12:40 left         |   Storage      1.2 GB · Clear 400 MB   |   ─────────────────────────────────
 From your shows                     |   Notes folder  iCloud/Margins     ›   |   The Daily        3 new · today   ›
 ▶ The Daily: Oct 16   17m  and 2 more|  Shows you follow   6 shows        ›   |   Hard Fork        1 new · Tue     ›
 ▶ Hard Fork: AI week   52m          |   Import & export                      |   Nautilus          · last week    ›
 Added, not started                  |     Listening Edition              ›   |   Hakai             · Oct 2        ›
 ▶ How whales sleep    Hakai   12m   |     Export sessions to a folder    ›   |   Quiet (2)                    Show ▾
 From your friends                   |     Show all (2 more)                  |
 ▶ Sam · 2 new on Tides   and 1 more |   Help                             ›   |
 ─────────────────────────────────── |   About & legal                    ›   |
 ▶ Tides · 12:40 ────────── ● 🎙     |   ──────────────────────────────────── |
 [ Up next ] [ Library ] [ Margins ] |   ▶ Tides · 12:40 ────────── ● 🎙      |
```

Up next never scrolls past about eight cards. Settings shows two rows per long group, then "Show all". Shows you follow is the old Manage feeds moved and sorted by newest episode; Paste there follows at once. The "From your friends" group is what the shortlist grows into; it is not in the flow map yet.
