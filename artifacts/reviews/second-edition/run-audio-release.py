"""Finish M5 after the device-layout checks have passed."""
import runpy
h = runpy.run_path("artifacts/reviews/second-edition/run-remaining-checks.py", run_name="helpers")
h["named_plan"]("adapters", h["PHONE"])
h["named_plan"]("speech-canary", h["PHONE"])
h["command"](["xcrun", "simctl", "shutdown", h["PHONE"]])
h["named_plan"]("release", h["PHONE"])
h["evidence_run"]("generic-builds", "Generic simulator and device builds", h["generic_builds"])
print("Audio, release and generic build checks passed.", flush=True)
