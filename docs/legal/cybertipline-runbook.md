# Runbook: a reported abuse-material link (owner steps)

For #2235 and D18 in [attorney-questions.md](attorney-questions.md). Nothing in this file is legal advice; counsel marks up D18. **Nobody opens held content, including you.** The tipline and law enforcement open it. No stored content goes in this repository.

## What the server does by itself

1. Taking a link down at once, blind, is #2239's job. **Hold comes before takedown:** a plain takedown deletes the ciphertext, and a `hold` run after it can keep only the reported link. The report form does this itself: an abuse-material report runs the hold, with the full link the form sent, and then takes the link down. The hold's report id in the access log is `form-` and the reporter's reference number; a later `hold` run never changes it, so note the CyberTipline's own id on the issue. You still run `smserver takedown` yourself for anything the form did not catch, and `hold` first if the report came some other way.
2. A link is held when an abuse-material report comes through the form, or when you run the `hold` command below. Until then the normal 30-day expiry applies.
3. A held link is moved out of the serving folder (`/var/lib/smserver/links`) into `/var/lib/smserver/links-held`, a folder only the `smserver` user can open (mode 0700). The server has no call that reads it back.
4. The daily sweep deletes each held link one year after the hold began and writes a line to `/var/lib/smserver/links-held/access.log`. The log has event names, link ids, report ids and dates, and a line for each `show-reported-link` read. It never has content, keys or client addresses.
5. Packets and previews are already encrypted on the sender's phone. The reported full link, which carries the key, is the sensitive file, so the disk under `/var/lib/smserver` must be encrypted at rest (step A below).

## One-time steps

A. Confirm the disk under `/var/lib/smserver` is encrypted at rest with your provider (volume encryption). Write the answer in the issue, not here.
B. Register as an electronic service provider with the NCMEC CyberTipline and note the report process for abuse-material tips. Counsel confirms what a tip must contain when it arrives without a key (D18).

## When a report arrives

1. The abuse-material report form sends the link id and the full link. Do not open the link.
2. File the CyberTipline report as the tipline asks, forwarding the full link unread. If the form held the link (if the command says `not held`, do step 3 first) and you do not have the reported link in the email or the form's notification, read it back without opening the content (#3120):

   ```
   runuser -u smserver -- smserver show-reported-link -state /var/lib/smserver LINKID
   ```

   It prints only the reported links the hold kept, one per line (more than one when someone posted a junk link beside the real one; forward them all), and never the packet or the preview. A link with control or invisible characters in it prints with spaces in their place and a note saying so; the held file is unchanged. The link includes its key, so it also lands in your terminal's scrollback: clear it when you are done. It writes a `show-reported-link` line with the link id to `/var/lib/smserver/links-held/access.log`, never the link or its key. If the log cannot be written it prints nothing and says why. Note the report id the tipline gives you.
3. The form has already held the link, so the full link is in the held folder; skip to step 4 unless the report came by email or the form held no link (an empty or wrong link field is dropped). In that case put the full link in a file readable by the `smserver` user only, then hold the link. Replace `REPORTID` and `LINKID`:

   ```
   runuser -u smserver -- smserver hold -state /var/lib/smserver -report REPORTID -link-file /tmp/reported-link.txt LINKID
   shred -u /tmp/reported-link.txt
   ```

   It prints `link taken down and held for one year`. Running it again for the same link is harmless: it never restarts the year or changes the report id, and it adds each reported link it has not seen before. The link file must hold between 1 byte and 64 KB.

   The form can be posted by anyone who knows a link id, so a held link keeps up to five different reported links, in the files `reported-link` and `reported-link-2` to `reported-link-5`, and a junk link posted first cannot push out the real one. A sixth different link is not kept and the access log gets a `link-dropped` line with the link id. Your own `hold` run is not limited to five.
4. Check the hold: `ls /var/lib/smserver/links-held` lists the link id. Do not open the files inside; `show-reported-link` is the only way to read any of them.

## When the hold cap is reached

The report form is public and anyone can upload a link and report it, so the server caps what it will keep for a year: **500 held links, 5 GiB held in total, 50 new holds a UTC day, and 5 holds a day from one client network.** These numbers are a default taken on #3120, not the owner's final call; they are `DefaultHoldLimits` in `research/B4/server/internal/links/hold.go` and `HoldsPerClientPerDay` in the server.

At a cap the server does not fall back to a plain takedown, because that deletes the ciphertext. It stops serving the link, keeps its content and the reported link (key included) for 30 days from the report, and tells you:

1. The server log has the line `reports: HOLD CAP REACHED`, and `/var/lib/smserver/links-held/access.log` has a line with `"event":"cap"`, the link id and which cap it was. Look for them with `grep '"event":"cap"' /var/lib/smserver/links-held/access.log`. The reporter sees the normal "this link has been taken down" page.
2. **You have 30 days from the report.** After that the daily sweep deletes the content and the parked reported link, and nothing is left to hold.
3. Hold the ones you decide to keep with the `hold` command above. Your own `hold` run is not limited by the caps. Use the CyberTipline's report id as `REPORTID`, or `cap-` and the date if you have none yet.
4. If the cap is full of junk, free room first by ending the holds you are sure are junk with `release-hold`, or raise the cap. A raised cap is a code change in `hold.go`, so ask first.

The cap cannot tell a real report from a junk one. That is why it alerts you instead of choosing.

## Reading the reports (the owner's daily look)

Every report the form files is a record on the box: reference, date, category, link id and the written reason if one was given. Read them with:

```
runuser -u smserver -- smserver reports -state /var/lib/smserver -since 24h
```

`-since` takes hours (`168h` is a week); `-category abuse_material` shows one category. Each report prints on one line, with its reason under it, and ends with a count. The last word on the line says what the link is now: `taken down`, `taken down, held`, `disabled, NOT held yet`, `expired` or `no such link`, or `STILL SERVED`. **`STILL SERVED` means the report did not take the link down.** Run `smserver takedown -state /var/lib/smserver LINKID` on it (for an abuse-material report, `hold` first, as above). **`disabled, NOT held yet`** is an abuse-material link the form could not hold (a failure or a cap): the content is kept 30 days from the report, so make the hold now (see "When the hold cap is reached").

The command never opens a link's content. A link with its key pasted into a reason shows as `[link removed]`, in every category, so reading a report cannot open the link. The key stays in the hold. Records go after 90 days.

## A law-enforcement request, or ending a hold early

Give law enforcement the folder `/var/lib/smserver/links-held/LINKID` exactly as it is, through the channel they name. Then, only if they ask for the hold to end or you are told to delete it, run:

```
runuser -u smserver -- smserver release-hold -state /var/lib/smserver -reason "law-enforcement request, their reference" LINKID
```

The reason goes in the access log. Otherwise leave the hold alone: the daily sweep deletes it at one year.

## Clubs (#1799)

A club is a box of sealed packets, not a link, and it works the same way with different names. The report route is `POST /api/v1/clubs/ID/report`; the form is the app's, because only the app has the read proof a post-level report needs. Everything below is `smserver club ...` with `-state /var/lib/smserver`, run as the `smserver` user like the commands above. Nothing here opens a club's content.

- **An abuse-material report holds first, then ends the club.** The held copy is `/var/lib/smserver/clubs-held/CLUBID` (the header, `posts/`, `disabled/`, and the reported invite links, key included, in `reported-link` to `reported-link-5`). The log is `clubs-held/access.log`, with the same lines as for links. The year runs from the hold, `hold.json` has the date, and the daily sweep deletes the copy at one year.
- **Forward the links:** `smserver club show-reported-link -state /var/lib/smserver CLUBID` prints them, one per line (open none of them), and logs the read.
- **The hold cap is the links' numbers** (500 clubs, 5 GiB, 50 a UTC day, and 5 holds a day from one client network, counted together with link holds for the client allowance). At a cap the club is disabled, keeps its content and its reported link for 30 days from the report, and the server logs `HOLD CAP REACHED, club disabled`. Hold it by hand: `smserver club hold -state /var/lib/smserver -report REPORTID CLUBID` (add `-link-file FILE` if the report came by email). Your own run is not capped.
- **A reported club or post that is not abuse material** is disabled at once, blind. A club keeps its content 30 days from the report, a post until its club ends; then the sweep deletes it. A club's member sees "this club has ended"; anyone else sees nothing.
- **Reading the reports:** `smserver reports` lists club reports too, as `club CLUBID` (and `post N`), with what the club is now: `taken down`, `taken down, held`, `disabled`, `post disabled`, `expired`, `no such club`, or **`STILL SERVED` / `post STILL SERVED`, which means the report did not stop it**. Fix those with `smserver club disable CLUBID [POST]`, or `smserver club takedown CLUBID` (for abuse material, `club hold` first).
- **Turning every club off at once:** `smserver switch -public /var/www/smserver clubs off`.
- **Ending a hold early** (a law-enforcement request): `smserver club release-hold -state /var/lib/smserver -reason "law-enforcement request, their reference" CLUBID`.

## Renewal and checks

- The year runs from the day you ran `hold`. `hold.json` in the held folder has the exact date; read only that file if you must check it.
- If `smserver` logs `links: held-link sweep failed`, nothing was deleted early. Fix the cause (disk, permissions) and the next daily sweep retries.
