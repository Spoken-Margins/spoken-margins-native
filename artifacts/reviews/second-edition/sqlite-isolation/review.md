# SQLite isolation diagnosis

All four scoped input hashes matched before review.

## Mechanism

This is test-lifecycle interference, not evidence of a second-edition runtime regression.

`testFollowDiscoveryRechecksSubscriptionsBeforePublishing` creates a model with a private SQLite connection, calls `resetAndSeed`, then immediately opens a second `SQLiteSessionStore` against the same `library.sqlite` ([`Gate1AppModelWorkflowTests.swift:3262`](../../../../App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift:3262), [`Gate1AppModelWorkflowTests.swift:3264`](../../../../App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift:3264)). Reset configures offline services, which starts an untracked `Task` that writes the offline-storage budget and performs ledger work through the model's connection ([`Gate1AppModel.swift:13631`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift:13631)). The test's second connection writes the subscription at line 3276 while that startup task can still write. `SQLiteSessionStore` serializes only each individual connection and has no busy handler/timeout; `sqlite3_step` therefore returns `SQLITE_BUSY` (extended code 5) immediately ([`SQLiteSessionStore.swift:12`](../../../../Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift:12), [`SQLiteSessionStore.swift:713`](../../../../Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift:713)). This exactly matches the current failure.

The earlier `SQLITE_IOERR_VNODE` evidence has a separate, concrete cause. These tests register `defer { removeItem(root) }` before local `model` and auxiliary `store` instances go out of scope ([`Gate1AppModelWorkflowTests.swift:3258`](../../../../App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift:3258), [`SpokenMarginsPackageHandoffTests.swift:285`](../../../../App/SpokenMarginsAppTests/SpokenMarginsPackageHandoffTests.swift:285)). A `defer` executes during return/unwind while those objects still retain SQLite/WAL/SHM descriptors. The historical log explicitly reports “vnode unlinked while in use” for each test's `*.sqlite`, `-wal`, and `-shm` files, followed by 6922. That cleanup fault can be triggered after the original assertion/write failure and then corrupts the evidence for later operations.

## Smallest deterministic repair

Do not await or restructure `configureOfflineServices`: its existing bootstrap also refreshes Guided Onboarding and can use remote work, so it is not a suitable test readiness boundary.

Add one internal, test-only `Gate1AppModel` accessor that returns the already-open model-owned `SQLiteSessionStore` after `resetAndSeed` (for example, `testingStore() throws -> SQLiteSessionStore`, guarded to unit tests). Change only these callers to use that object rather than constructing `SQLiteSessionStore(path:)`:

1. `testFollowDiscoveryRechecksSubscriptionsBeforePublishing` for seed writes, the injected `offerFollowSuggestionIfEligible` store, and the subscription/decision assertions.
2. `testLateFollowDiscoveryCannotPublishUnderAnotherItem`, which has the identical second-store pattern at lines 3290–3304.
3. `testImportedPodcastRequestsTranscriptFallbackAndResolvesFuzzyContext` for its asynchronous inspection/polling store.

This preserves the intended same-repository app behavior: the model's bootstrap, delayed discovery, test mutation, and imported-podcast resolution are serialized by the one existing `SQLiteSessionStore.connectionLock`; it does not suppress any assertion or replace the deliberate discovery race. There is no existing accessor to reuse.

For the three temporary-root tests, replace `defer { removeItem(root) }` with teardown that runs only after the test has resumed every held continuation and released the model/store references. The current bootstrap task is untracked and may retain its SQLite handle while Guided Onboarding refresh is pending, so do not block on that network work merely to delete a test directory. If the test harness cannot obtain a lifecycle-complete model release, leave its UUID temp root for process/suite cleanup rather than unlinking a live WAL file. A later dedicated lifecycle change can make bootstrap cancellation/close observable, but it is not required to remove the auxiliary-connection lock.

Do not paper over either condition with a generic SQLite retry or a test rerun. The app normally owns one store connection; this test deliberately creates two, so the present failure does not establish user-visible persistence contention. If a product requirement introduces multiple same-file processes, add a separately specified busy/coordination policy with its own tests.

No test, build, Xcode, or simulator run was performed in this diagnosis.
