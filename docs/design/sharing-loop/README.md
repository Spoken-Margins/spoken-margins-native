# Sharing loop: screen inventory (#3216)

Proposals for the sharing loop start from screenshots of the real app, taken on a test simulator, never from a code summary (Cole, 2026-11-02). This file lists the screens a listener meets in the loop. The Test Desk run requested on this PR captures each one on `main`.

| Step | Screen | How it's reached |
|---|---|---|
| 1 | Add to Library sheet, medium detent (half screen) and large | Library, the "+" button |
| 1 | Link or Podcast form, including podcast search | Add sheet, first tile |
| 4 | What appears after a friend's packet imports | `COOP=1` seed relaunch |
| 4 | Item screen with unheard friend Margins, top and bottom | After import |
| 4 | The "New Margins to hear" dialog | Item screen, Continue |
| 5 | Now tab during a review lead-in and during the friend's Margin | Dialog, "Hear new Margins first" |
| 5 | Now tab when a friend's Margin arrives in normal playback | Play through 5:00 |
| 5 | Margins tab with the friend's Margin | Playback screen |
| 6-7 | Share flow for the item, each screen up to the system share sheet | Item screen, Share |

Screenshots stay in `artifacts/` on the Mac (git-ignored). Only fixture and simulator content.
