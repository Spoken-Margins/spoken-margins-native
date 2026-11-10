"""The ids the lane runner gives its own `Lane report <id> — …` comments (#3951).

A Test Desk report is any lane report whose id is NOT one of these. The rule lives here once, and `desk-batch.py`
and `sm_status.py` both import it: they each kept a copy, and a fix to one (#3943 added `scripted-journeys-`) did
not reach the other. The runner's ids: `pr<N>-r<run>` (a PR's lane run), `integration-<sha7>`, and
`journeys-<sha7>` / `scripted-journeys-<sha7>` (ops/testdesk/sm_integration_run.py, phone-build).
"""
import re

RUNNER_ID = re.compile(r'(pr\d+-r\d+|integration-|(?:scripted-)?journeys-)', re.I)
