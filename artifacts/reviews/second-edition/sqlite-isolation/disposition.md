# Repair disposition

The two controlled follow-discovery tests and the imported-podcast transcript test now request the model-owned SQLite store through a DEBUG-only, unit-test-guarded accessor. They keep the real app repository and intended asynchronous discovery/transcription behavior, while removing an unintended concurrent SQLite connection. No production busy retry, sleep or altered assertion was introduced. Suspended follow continuations are resumed on exceptional exit. Temporary-root teardown checks weak model/store references and never unlinks files while those owners remain live; a retained UUID directory stays in the test host temporary area for later cleanup. This is deliberately narrower than changing production bootstrap scheduling or awaiting remote onboarding downloads.

Verification is pending the frozen app run. Prior failed attempts remain in the run manifests; their passes are not aggregated into a fictional complete pass.
