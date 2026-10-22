# Security policy

## Reporting a vulnerability

Please report security problems privately. Don't open a public issue or pull request for them.

1. Open https://github.com/Spoken-Margins/spoken-margins-native/security/advisories/new (this repository's **Security** tab, then **Report a vulnerability**).
2. Say what you found, how to reproduce it, which build or commit you tried it on, and what an attacker could do with it.
3. If you can, include a small proof of concept. Don't include anyone's real data.

If that page isn't available to you, open a public issue titled "Security contact request" with no details. A maintainer will arrange a private channel.

Spoken Margins has one maintainer, so replies take days, not hours. There is no bounty. We'll tell you when a report is confirmed, when it is fixed, and, with your permission, credit you in the fix.

## What counts

Reports about any of these are welcome:

- the app and its Safari, share and widget extensions;
- reading `.spokenmargins` packets and share links (decryption, unzip, path handling, anything that could write outside the app's folders or crash on a hostile packet);
- the end-to-end encryption of share links, where the server should only ever hold bytes it can't read;
- the optional server code under `research/B4/`;
- anything that exposes a listener's Library, recordings, or the access tokens they connect (Readwise, Raindrop) to someone else.

Out of scope: bugs that need a jailbroken or already-compromised phone, social engineering, denial of service by sending very large amounts of traffic, and problems in other people's software (report those upstream; [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists what we use).

## Supported versions

Only the newest TestFlight build and the `next` branch get fixes. There is no public App Store release yet.

## Disclosure

Please give us a reasonable time to fix a problem before you publish it. We'll tell you what we plan, and we won't ask you to wait without a reason.
