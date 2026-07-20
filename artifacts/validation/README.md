# Human Validation Records

This directory is for product-owner validation evidence.

Automated tests, traces, builds, and screenshots belong in verification summaries. A flow should be marked `human_validated` only after the product owner uses it and accepts it.

Use one Markdown file per validation pass under `gate-N/` with:

- date
- build number and commit SHA
- device and OS
- in-scope flow
- out-of-scope items
- verification summary
- pass/fail result
- product-owner notes
- known issues found during use
