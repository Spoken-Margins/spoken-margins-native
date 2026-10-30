# Spoken Margins on the web

A mobile-first, installable web app (PWA): find and follow podcasts, and Substacks that offer the
publisher's or Substack's own voice, play them, and add written and voice Margins. It has no
text-to-speech. Margins travel as `.spokenmargins` files that the iPhone app imports. Tracking issue: see
`git log -- Web/` for the issue each change names.

## Layout and owners

One writer per folder while the first wave runs in parallel.

| Folder | What | Tested by |
| --- | --- | --- |
| `src/shared/` | Types every module shares (`model.ts`) and tiny helpers | `npm run test:web` |
| `src/sources/` | Podcast search, RSS parsing, Substack voice detection, the feed-read path | `npm run test:web` |
| `src/packet/` | `.spokenmargins` read and write, voice recording to `.m4a`, share-link sealing (off) | `npm run test:web` |
| `src/app/` and the Vite project files | The React UI: Four tabs, Library, player, Margin capture | `Web/package.json` scripts |

## Rules

- **Logic is plain TypeScript with no packages.** `npm run test:web` (root) runs every
  `Web/src/**/*.test.ts` with `node --test` on Node 24's type stripping, inside the fast plan
  (`scripts/verify-tests.py`). So use erasable syntax only (no `enum`, `namespace` or parameter
  properties) and write relative imports with `.ts`.
- **The UI has its own `package.json`** (Vite, React, Playwright). Its tests run in the thread that changes
  it and are reported on the PR. They aren't in the merge gate yet: that needs a workflow change, which is
  the owner's tap.
- **Share links are built but off.** Creating one is behind a build-time flag that every hosted build
  leaves off. It turns on in a new build after the DMCA designated agent is registered (owner, 2026-10-20),
  never from a server switch (2026-10-17).
- **Feeds:** read directly from the browser first. Only when a feed blocks that, ask once and then read
  it through the Spoken Margins server, which keeps nothing. A Substack post page is read only when the
  listener taps that post (owner, 2026-10-21).
- **Packets stay importable by Build 32 and Build 34.** Voice Margins are AAC in `.m4a`.

## Android wrapper (#2981)

`android/` is a Capacitor project that serves the same Vite build in an Android WebView. Inside it, feeds,
Substack pages and podcast search are read with Android's own HTTP stack (`src/sources/native-http.ts`), so no
site blocks the read and there is no relay and no consent question. The read path picks that transport itself;
every rule about what is read and when stays in `read.ts` and `search.ts`.

- `npm run android:sync` builds the web app and copies it into `android/`.
- `npm run android:build` also runs Gradle and writes `android/app/build/outputs/apk/debug/app-debug.apk`.
  It needs JDK 21 (`JAVA_HOME`) and an Android SDK whose licences are already accepted (`ANDROID_HOME`, or
  `sdk.dir` in the git-ignored `android/local.properties`). Gradle fetches the missing SDK platform itself.
- **Packets in the app (#3009).** The WebView has no Web Share and ignores a blob download, so "Save or send"
  writes the file to the app's cache (Filesystem plugin) and opens Android's share sheet (Share plugin). A packet
  opened with or shared to the app arrives through the App plugin and is read with Filesystem; the file picker
  shows every file there, because Android reports `.spokenmargins` as `application/octet-stream`. The choice is
  `src/app/logic/native-packets.ts`; the browser keeps its download link and Web Share.
- Nothing here is verified on a device until someone installs the APK.
