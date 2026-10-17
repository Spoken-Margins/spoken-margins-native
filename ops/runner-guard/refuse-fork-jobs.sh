#!/bin/bash
# Job-started hook for the self-hosted runners (sm-vps, sm-vps-t1, sm-lane*). See README.md.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/refuse_fork_jobs.py"
