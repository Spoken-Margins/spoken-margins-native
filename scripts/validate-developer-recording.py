#!/usr/bin/env python3
"""Validate a capture JSON file or the existing diagnostics export containing it."""
import json
import sys
from pathlib import Path
import jsonschema
schema = json.loads((Path(__file__).resolve().parents[1] / 'schemas/developer-recording.schema.json').read_text())
data = json.loads(Path(sys.argv[1]).read_text())
if 'developerRecording' in data:
    data = json.loads(data['developerRecording'])
jsonschema.Draft202012Validator(schema).validate(data)
print(f"Developer recording verified: {len(data['events'])} events")
