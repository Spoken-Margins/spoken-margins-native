"""Serial M5 checks. Run only after the phone UI plan ends, with source frozen."""
import datetime
import importlib.util
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("verification", ROOT / "scripts/verify-tests.py")
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)
PHONE = "856FA6EF-5E03-4120-939B-F0EF42A804E8"
IPAD = "BEBBB4FD-E13C-457C-A41F-DD7DF02B5C51"
SMALL = "09B39C91-F60E-497E-9F7C-AAD8740FBAC3"


def command(args):
    subprocess.run(args, cwd=ROOT, check=True)


def named_plan(name, device):
    command([sys.executable, "scripts/verify-tests.py", "--plan", name, "--device", device])


def evidence_run(suffix, label, body):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    run = verification.Run(ROOT / "artifacts/test-runs" / f"{stamp}-{suffix}", label)
    run.manifest["toolchain"] = verification.capture(["xcodebuild", "-version"])
    try:
        body(run)
        if verification.input_identity() != run.manifest["input_sha256"]:
            raise RuntimeError("Inputs changed during verification")
        run.manifest["status"] = "verified"
    except Exception as error:
        run.manifest.update(status="failed", error=str(error))
        raise
    finally:
        run.save()
        print("Evidence:", run.output / "manifest.json", flush=True)


def small_phone(run):
    run.manifest["destination"] = {"udid": SMALL, "name": "iPhone SE (3rd generation)", "os": "18.6"}
    derived = ROOT / ".build/verification/SpokenMarginsUISeams"
    base = ["xcodebuild", "-configuration", "Debug", "-project", "SpokenMarginsNative.xcodeproj",
            "-scheme", "SpokenMarginsUISeams", "-testPlan", "UISeams", "-destination", f"id={SMALL}",
            "-derivedDataPath", str(derived)]
    cases = {"SpokenMarginsAppUITests/Gate1FlowUITests/" + name for name in (
        "testLibraryCompactRowStaysDense",
        "testPlaybackPrimaryActionsRemainVisibleWithLongTitleAndAccessibilityText",
        "testWrittenMarginSaveSearchStarAndDiscardPreserveTheSource",
        "testBuild23LayoutRegressionsRemainOperableAtAccessibilityType")}
    run.command("build-for-testing", base + ["build-for-testing"], timeout=900)
    run.command("bundle-contracts", [sys.executable, "scripts/verify-bundle.py",
                str(derived / "Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app")])
    run.command("simulator-boot", ["xcrun", "simctl", "boot", SMALL], timeout=60)
    run.command("simulator-ready", ["xcrun", "simctl", "bootstatus", SMALL, "-b"], timeout=180)
    run.command("xcode-tests", base + ["test-without-building", "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES", "-resultBundlePath", str(run.output / "tests.xcresult")]
                + ["-only-testing:" + case for case in sorted(cases)], timeout=700, expected=cases, tests=True)


def generic_builds(run):
    for name, platform in (("simulator", "iOS Simulator"), ("device", "iOS")):
        run.command("generic-" + name, ["xcodebuild", "-configuration", "Debug", "-project",
                    "SpokenMarginsNative.xcodeproj", "-scheme", "SpokenMarginsApp", "-destination",
                    "generic/platform=" + platform, "-derivedDataPath",
                    str(ROOT / ".build/verification/SecondEditionGenericBuild"), "build"], timeout=900)



if __name__ == "__main__":
    named_plan("ui", IPAD)
    command(["xcrun", "simctl", "shutdown", IPAD])
    evidence_run("ui-small-ios18", "UISeams: four small-phone iOS 18 routes", small_phone)
    command(["xcrun", "simctl", "shutdown", SMALL])
    named_plan("adapters", PHONE)
    named_plan("speech-canary", PHONE)
    # UI test launches can leave a normal app host behind. Restart before app-host injection.
    command(["xcrun", "simctl", "shutdown", PHONE])
    named_plan("release", PHONE)
    evidence_run("generic-builds", "Generic simulator and device builds", generic_builds)
    print("All remaining serial M5 execution checks passed.", flush=True)
