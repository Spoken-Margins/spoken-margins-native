# G1 · guides: how-to guides that update themselves

**Outcome.** Short visual guides for the workflows people need:
- add a podcast from Apple Podcasts, and from Spotify;
- add an article from Safari;
- add a PDF;
- follow a source;
- record a Margin;
- share Margins;
- open Margins someone shared with you;
- get your Margins into your notes.

Each guide has step screenshots and a short animation (GIF or video). All are generated from the current build by one command, so when the app changes the guides change with it. Readable inside the app's Help, offline, and on the website.

**Why.** These workflows are what new listeners struggle with, and they keep changing. Hand-made guides would go stale within a build or two.

**Where.** Mac, through the lane: generation drives the simulator.

**Waits for.** I15 (stable UI identifiers, A2 M1). Ideally D1's direction, but since regeneration is the point, don't wait for the redesign to finish.

## Starting points

- No screenshot automation exists: no fastlane, no snapshot tests. `Gate1FlowUITests.captureScreen` attaches screenshots as test evidence.
- The scripted UI plans were retired from routine testing because they were slow and crashed simulators. **Guide generation isn't a test gate.** It runs on request or once per TestFlight candidate, through the lane's simulator discipline.
- `simctl io recordVideo` can capture simulator video.
- The simulator has no Spotify app, and some cross-app flows (Apple Podcasts share sheet) can't be shown there.
- In-app `HelpScreen` is static and stale. `Site/` is a small static site deployed to the owner's VPS.
- #120 wanted onboarding recordings as a beta QA gate. These guides can double as that evidence.

## Milestones

**M1: Generator and the first five guides.**
- Done when one command, run through the lane, produces Markdown, PNG steps and a GIF for at least five in-app workflows in under 20 minutes.
  - A step whose control identifier is missing fails loudly, naming the guide and step, so a UI change that breaks a guide is noticed.

**M2: All the guides, in the app and on the site.**
- Done when:
  - Every workflow above has a guide.
  - Cross-app steps the simulator can't show use an owner-recorded clip or a clearly marked illustration, and the generator lists which ones need the owner.
  - Help shows the guides offline.
  - The site has a page per guide.
  - Regeneration is part of the release checklist, as one line in the owner overlay's "Releasing a build".

## Must not break

The lane's simulator limits. Generation queues like any T4 request.

## Out of scope

Voice-over narration (not needed, per the owner). Marketing videos (G2 may reuse the output).
