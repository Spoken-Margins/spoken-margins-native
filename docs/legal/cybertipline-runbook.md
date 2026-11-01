# Runbook: a reported abuse-material link (owner steps)

For #2235 and D18 in [attorney-questions.md](attorney-questions.md). Nothing in this file is legal advice; counsel marks up D18. **Nobody opens held content, including you.** The tipline and law enforcement open it. No stored content goes in this repository.

## What the server does by itself

1. Taking a link down at once, blind, is #2239's job. **Hold comes before takedown:** a plain takedown deletes the ciphertext, and a `hold` run after it can keep only the reported link. The report form does this itself: an abuse-material report runs the hold, with the full link the form sent, and then takes the link down. The hold's report id in the access log is `form-` and the reporter's reference number; a later `hold` run never changes it, so note the CyberTipline's own id on the issue. You still run `smserver takedown` yourself for anything the form did not catch, and `hold` first if the report came some other way.
2. A link is held when an abuse-material report comes through the form, or when you run the `hold` command below. Until then the normal 30-day expiry applies.
3. A held link is moved out of the serving folder (`/var/lib/smserver/links`) into `/var/lib/smserver/links-held`, a folder only the `smserver` user can open (mode 0700). The server has no call that reads it back.
4. The daily sweep deletes each held link one year after the hold began and writes a line to `/var/lib/smserver/links-held/access.log`. The log has event names, link ids, report ids and dates. It never has content, keys or client addresses.
5. Packets and previews are already encrypted on the sender's phone. The reported full link, which carries the key, is the sensitive file, so the disk under `/var/lib/smserver` must be encrypted at rest (step A below).

## One-time steps

A. Confirm the disk under `/var/lib/smserver` is encrypted at rest with your provider (volume encryption). Write the answer in the issue, not here.
B. Register as an electronic service provider with the NCMEC CyberTipline and note the report process for abuse-material tips. Counsel confirms what a tip must contain when it arrives without a key (D18).

## When a report arrives

1. The abuse-material report form sends the link id and the full link. Do not open the link.
2. File the CyberTipline report as the tipline asks, forwarding the full link unread. Note the report id it gives you.
3. The form has already held the link, so the full link is in the held folder; skip to step 4 unless the report came by email or the form held no link (an empty or wrong link field is dropped). In that case put the full link in a file readable by the `smserver` user only, then hold the link. Replace `REPORTID` and `LINKID`:

   ```
   runuser -u smserver -- smserver hold -state /var/lib/smserver -report REPORTID -link-file /tmp/reported-link.txt LINKID
   shred -u /tmp/reported-link.txt
   ```

   It prints `link taken down and held for one year`. Running it again for the same link is harmless: it never restarts the year or changes the report id, and it adds each reported link it has not seen before. The link file must hold between 1 byte and 64 KB.

   The form can be posted by anyone who knows a link id, so a held link keeps up to five different reported links, in the files `reported-link` and `reported-link-2` to `reported-link-5`, and a junk link posted first cannot push out the real one. A sixth different link is not kept and the access log gets a `link-dropped` line with the link id. Your own `hold` run is not limited to five.
4. Check the hold: `ls /var/lib/smserver/links-held` lists the link id. Do not open the files inside.

## When the hold cap is reached

The report form is public and anyone can upload a link and report it, so the server caps what it will keep for a year: **500 held links, 5 GiB held in total, 50 new holds a UTC day, and 5 holds a day from one client network.** These numbers are a default taken on #3120, not the owner's final call; they are `DefaultHoldLimits` in `research/B4/server/internal/links/hold.go` and `HoldsPerClientPerDay` in the server.

At a cap the server does not fall back to a plain takedown, because that deletes the ciphertext. It stops serving the link, keeps its content and the reported link (key included) for 30 days from the report, and tells you:

1. The server log has the line `reports: HOLD CAP REACHED`, and `/var/lib/smserver/links-held/access.log` has a line with `"event":"cap"`, the link id and which cap it was. Look for them with `grep '"event":"cap"' /var/lib/smserver/links-held/access.log`. The reporter sees the normal "this link has been taken down" page.
2. **You have 30 days from the report.** After that the daily sweep deletes the content and the parked reported link, and nothing is left to hold.
3. Hold the ones you decide to keep with the `hold` command above. Your own `hold` run is not limited by the caps. Use the CyberTipline's report id as `REPORTID`, or `cap-` and the date if you have none yet.
4. If the cap is full of junk, free room first by ending the holds you are sure are junk with `release-hold`, or raise the cap. A raised cap is a code change in `hold.go`, so ask first.

The cap cannot tell a real report from a junk one. That is why it alerts you instead of choosing.

## A law-enforcement request, or ending a hold early

Give law enforcement the folder `/var/lib/smserver/links-held/LINKID` exactly as it is, through the channel they name. Then, only if they ask for the hold to end or you are told to delete it, run:

```
runuser -u smserver -- smserver release-hold -state /var/lib/smserver -reason "law-enforcement request, their reference" LINKID
```

The reason goes in the access log. Otherwise leave the hold alone: the daily sweep deletes it at one year.

## Renewal and checks

- The year runs from the day you ran `hold`. `hold.json` in the held folder has the exact date; read only that file if you must check it.
- If `smserver` logs `links: held-link sweep failed`, nothing was deleted early. Fix the cause (disk, permissions) and the next daily sweep retries.
