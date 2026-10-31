# Runbook: a reported abuse-material link (owner steps)

For #2235 and D18 in [attorney-questions.md](attorney-questions.md). Nothing in this file is legal advice; counsel marks up D18. **Nobody opens held content, including you.** The tipline and law enforcement open it. No stored content goes in this repository.

## What the server does by itself

1. Taking a link down at once, blind, is #2239's job. Nothing here changes it. **Run `hold` before `smserver takedown`:** a plain takedown deletes the ciphertext, and a `hold` run after it can keep only the reported link.
2. A link is held only when you run the `hold` command below. Until then the normal 30-day expiry applies.
3. A held link is moved out of the serving folder (`/var/lib/smserver/links`) into `/var/lib/smserver/links-held`, a folder only the `smserver` user can open (mode 0700). The server has no call that reads it back.
4. The daily sweep deletes each held link one year after the hold began and writes a line to `/var/lib/smserver/links-held/access.log`. The log has event names, link ids, report ids and dates. It never has content, keys or client addresses.
5. Packets and previews are already encrypted on the sender's phone. The reported full link, which carries the key, is the sensitive file, so the disk under `/var/lib/smserver` must be encrypted at rest (step A below).

## One-time steps

A. Confirm the disk under `/var/lib/smserver` is encrypted at rest with your provider (volume encryption). Write the answer in the issue, not here.
B. Register as an electronic service provider with the NCMEC CyberTipline and note the report process for abuse-material tips. Counsel confirms what a tip must contain when it arrives without a key (D18).

## When a report arrives

1. The abuse-material report form sends the link id and the full link. Do not open the link.
2. File the CyberTipline report as the tipline asks, forwarding the full link unread. Note the report id it gives you.
3. On the box, put the full link in a file readable by the `smserver` user only, then hold the link. Replace `REPORTID` and `LINKID`:

   ```
   runuser -u smserver -- smserver hold -state /var/lib/smserver -report REPORTID -link-file /tmp/reported-link.txt LINKID
   shred -u /tmp/reported-link.txt
   ```

   It prints `link taken down and held for one year`. Running it again for the same link is harmless: it never restarts the year or changes the report id, and it only adds the reported link if the first run had none. The link file must hold between 1 byte and 64 KB.
4. Check the hold: `ls /var/lib/smserver/links-held` lists the link id. Do not open the files inside.

## A law-enforcement request, or ending a hold early

Give law enforcement the folder `/var/lib/smserver/links-held/LINKID` exactly as it is, through the channel they name. Then, only if they ask for the hold to end or you are told to delete it, run:

```
runuser -u smserver -- smserver release-hold -state /var/lib/smserver -reason "law-enforcement request, their reference" LINKID
```

The reason goes in the access log. Otherwise leave the hold alone: the daily sweep deletes it at one year.

## Renewal and checks

- The year runs from the day you ran `hold`. `hold.json` in the held folder has the exact date; read only that file if you must check it.
- If `smserver` logs `links: held-link sweep failed`, nothing was deleted early. Fix the cause (disk, permissions) and the next daily sweep retries.
