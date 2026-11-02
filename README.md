# metrics

Data branch written once a day by the `pipeline-dashboard` workflow (#2379). It holds `events-YYYY-MM.jsonl`,
one JSON event per line: ids, enums and numbers only. It has no app code, and no workflow runs on it.
The summary is the pinned "Pipeline value" issue. Read the files with `scripts/pipeline_events.py report --out <folder>`.
