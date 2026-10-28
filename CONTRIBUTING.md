# Contributing

Thanks for your interest in Spoken Margins.

## Who can open pull requests

For now, only collaborators on this repository open pull requests. Issues and discussion are welcome from anyone. If you'd like to contribute code, open an issue first and say so.

This is temporary. Once the project has momentum, it plans to move from the GNU AGPLv3 to the Mozilla Public License 2.0 (MPL-2.0) and open up contributions.

## Why contributions need an agreement

Changing the licence later needs the agreement of everyone who holds copyright in the code. So the project accepts no code from anyone who hasn't agreed to the terms below. They keep the planned move to MPL-2.0 possible.

## The terms

Every commit you contribute must carry a `Signed-off-by:` line (`git commit -s`). By adding it, you agree to both of these:

1. **The Developer Certificate of Origin 1.1** (https://developercertificate.org/). In short: you wrote the change, or you have the right to submit it under this project's licence.
2. **A licence grant to the project.** You license your contribution under the GNU Affero General Public License, version 3 only, with the App Store permission in `COPYING.iOS`. You also grant Proximity to Progress LLC, which owns the project, and anyone it passes the project to, a perpetual, worldwide, non-exclusive, royalty-free, irrevocable licence to use, copy, modify and distribute your contribution, and to relicense it under the Mozilla Public License 2.0.

You keep the copyright in your contribution.

Until 28 October 2026 this grant named Cole Miller. On that date he assigned the project, and the grants made to him, to Proximity to Progress LLC.

Don't submit code you copied from elsewhere unless its licence is compatible and you say where it came from. Third-party components are listed in `THIRD_PARTY_NOTICES.md`.

## Not legal advice

This file explains the project's terms in plain words. It is not legal advice. The project's owner chose this licence without a lawyer. A lawyer's review is planned only before three things: share links for the public, Listening Maps for the public, and a public App Store release.

## Checking for secrets

Before you push, run `scripts/check-gitleaks.sh`. It scans tracked files, plus new files you haven't ignored, with [gitleaks](https://github.com/gitleaks/gitleaks) (`brew install gitleaks`) and fails on anything that looks like a key or token. `scripts/check-gitleaks.sh --all-refs` scans every commit instead. If gitleaks isn't installed, the script says it skipped.

A hit that is truly not a secret, such as a made-up token in a test, goes in `.gitleaks.toml` with a one-line reason. Name the file and, where you can, the exact value; never a whole folder. Don't change a fixture just to quiet the scan.
