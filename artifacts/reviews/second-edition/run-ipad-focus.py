import runpy
h = runpy.run_path("artifacts/reviews/second-edition/run-remaining-checks.py", run_name="helpers")
v = h["verification"]
def check(run):
    device = h["IPAD"]
    run.manifest["destination"] = {"udid": device, "name": "Spoken Margins Test Suite iPad", "os": "26.5"}
    base = ["xcodebuild", "-configuration", "Debug", "-project", "SpokenMarginsNative.xcodeproj", "-scheme", "SpokenMarginsUISeams", "-testPlan", "UISeams", "-destination", "id=" + device, "-derivedDataPath", str(h["ROOT"] / ".build/verification/SpokenMarginsUISeams")]
    cases = {"SpokenMarginsAppUITests/Gate1FlowUITests/" + name for name in ("testRecordingExclusivelyOwnsTheAccessibleExperience",)}
    run.command("build-for-testing", base + ["build-for-testing"], timeout=900)
    run.command("xcode-tests", base + ["test-without-building", "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES", "-resultBundlePath", str(run.output / "tests.xcresult")] + ["-only-testing:" + case for case in sorted(cases)], timeout=300, expected=cases, tests=True)
h["evidence_run"]("ipad-margin-focus", "iPad voice Margin recovery", check)
