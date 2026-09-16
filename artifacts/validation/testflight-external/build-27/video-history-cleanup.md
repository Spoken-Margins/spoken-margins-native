# Video history cleanup — September 16, 2026

Owner authorized removing video recordings from tracking and unpublished history.
All 21 current recordings (649,153,778 bytes) remain on disk, ignored by Git.
Nine unpublished commits were rewritten. Every non-video tree entry (path, mode,
and object identity) was checked for equality for each rewritten commit.
No application source changed; builds and product validation were not repeated.
Remote history was not rewritten or pushed. Both active branches remain descendants
of their remote tips. The Build 27 tag now targets the equivalent cleaned source;
the original uploaded source identity remains authoritative for the uploaded binary.
Historical evidence documents retain original SHAs and local video paths deliberately.

Recovery backup outside the repository:
`/Users/colemiller/Documents/GitHub/repository-backups/spoken-margins-native-2026-09-16/before-video-cleanup.bundle`

The verified bundle preserves original branches and annotated tags. That directory
also contains the cleanup script, commit map and SHA-256 manifest for local videos.
For recovery, clone the bundle into a separate directory; do not reset this checkout.
The backup intentionally retains the original storage cost outside the working repo.

## Original → cleaned commits

| Original | Cleaned |
| --- | --- |
| `4fbb131b7c7b1c8a86aabd6a6474ed7ec3c0cb60` | `c98548969c55f1bf8133195961a30bfb9b1d6786` |
| `39e8b4ecf7453ab1f643b4df7f9b02a1640a0d52` | `0b077f1b732fbff29c4bfea02617820ef398851c` |
| `79d9357efc64331f9dd595fb5f7564bb4aafd6dc` | `1b69632d0b602f5713f62a6c0deb71da86c3e3d7` |
| `adeb923fc1d081b19dfe9d650b50ac9fb036535a` | `eb09f054ccb369e5169c7bd58ace9dbfa2daad08` |
| `ac85375759f2533f320225affef9fb3296bbbf9e` | `7a51808a5326dcd2fa93a945aabadf907e9d97ef` |
| `de9dc82060a19c435d4045c30f957c04a4dbe871` | `2c6a5e7cb757f83231d9a10655e83e807ed3a999` |
| `ad533d6604dbacf892df85dc06f36d63c2f97a08` | `92e44d604da66a4f3cfdb337fdc44dcf081e9dff` |
| `6432044bdc5ebff4691a69bee2699c309222ebac` | `69f9ce075186b2b17e7988b601dd40ee71d3904b` |
| `c81d5dbd7b7d081369a2baf36a05c6833f92d7a3` | `93f97e16e7eb3a77db4af2b712e02d09d7c51b6e` |
