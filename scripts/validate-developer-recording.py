#!/usr/bin/env python3
"""Validate a capture JSON file or the existing diagnostics export containing it."""
import json
import sys
from pathlib import Path
import jsonschema
schema = json.loads((Path(__file__).resolve().parents[1] / 'schemas/developer-recording.schema.json').read_text())
data = json.loads(Path(sys.argv[1]).read_text())
validator = jsonschema.Draft202012Validator(schema)
recordings = {key: json.loads(data[key]) for key in ('developerRecording', 'playbackEvents') if key in data}
if not recordings:
    recordings = {'capture': data}
for label, capture in recordings.items():
    validator.validate(capture)
    print(f"Developer recording verified ({label}): {len(capture['events'])} events")
