# Git publication blocker after successful internal distribution

Build 27 is uploaded and Testing in internal Margins (seven testers). Code is committed at `adeb923fc1d081b19dfe9d650b50ac9fb036535a`. The atomic Git push was stopped before publication after preflight found these historical blobs above GitHub’s 100 MiB limit:

- `artifacts/reviews/second-edition/ui-inset-diagnosis/A1942035-6AC4-4069-B0CC-A63BF3ABDDF7.mp4`: 114,272,622 bytes.
- `artifacts/reviews/second-edition/ui-integrated-third/0E2BF64E-8139-4411-ACE9-BCBA0654B5ED.mp4`: 107,325,101 bytes.

The unpublished range contains about 894 MB of blob data overall. The push was canceled locally (exit 143); no server rejection is claimed. Read-only remote reconciliation confirms provisional remains `fdbceda0dd840a541653ac6fe84957ffd6bec704`, triage remains Build 26, and the Build 27 tag is not present remotely.

Proposed resolution requiring owner decision: preserve the original uploaded source and complete unpublished history in a local backup, retain both video files on disk, remove only these two generated recordings from unpublished Git history, prevent re-adding them, and verify application/configuration/test inputs remain identical. Record the original-to-published commit mapping in the release handoff, then push the cleaned descendant history and mapped release tag without overwriting existing remote commits. This changes unpublished commit SHAs, including the release-source identity, so it is not silently applied.

Alternative: migrate the recordings to Git LFS, also rewriting unpublished history and requiring LFS storage. No history rewrite, LFS migration, local video deletion, or remote force push has been performed.
