import runpy
h = runpy.run_path("artifacts/reviews/second-edition/run-remaining-checks.py", run_name="helpers")
v = h["verification"]
import json

def check(run, device, name, os):
    run.manifest["destination"] = {"udid": device, "name": name, "os": os}
    base = ["xcodebuild", "-configuration", "Debug", "-project", "SpokenMarginsNative.xcodeproj", "-scheme", "SpokenMarginsUISeams", "-testPlan", "UISeams", "-destination", "id=" + device, "-derivedDataPath", str(h["ROOT"] / ".build/verification/SpokenMarginsUISeams")]
    cases = {"SpokenMarginsAppUITests/Gate1FlowUITests/testBuild23LayoutRegressionsRemainOperableAtAccessibilityType"}
    run.command("build-for-testing", base + ["build-for-testing"], timeout=900)
    devices = json.loads(v.capture(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
    chosen = next(d for group in devices.values() for d in group if d["udid"] == device)
    if chosen["state"] != "Booted":
        run.command("simulator-boot", ["xcrun", "simctl", "boot", device], timeout=60)
    run.command("simulator-ready", ["xcrun", "simctl", "bootstatus", device, "-b"], timeout=180)
    run.command("xcode-tests", base + ["test-without-building", "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES", "-resultBundlePath", str(run.output / "tests.xcresult")] + ["-only-testing:" + case for case in sorted(cases)], timeout=300, expected=cases, tests=True)

for key, name, os in [("SMALL", "Spoken Margins Small Phone iOS 18", "18.6"), ("IPAD", "Spoken Margins Test Suite iPad", "26.5")]:
    h["evidence_run"]("layout-" + key.lower(), "Accessibility layout: filter, keyboard and Timeline", lambda run: check(run, h[key], name, os))
    h["command"](["xcrun", "simctl", "shutdown", h[key]])
