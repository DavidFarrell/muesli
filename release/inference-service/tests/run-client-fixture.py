#!/usr/bin/env python3
"""Build actual signed model-free XPC fixtures against the real Swift job owner.

These tests do not qualify the Python backend, models, child group, or private
source grants. All source files are newly generated under /private/tmp.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("identity")
    parser.add_argument("--modes", default="0,1,2,3,4,5,6,7,8,9,10,12,13,14,15,16,17")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    src = Path(__file__).resolve().parent.parent
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    compile_args = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-fmodules", "-arch", "arm64", "-mmacosx-version-min=26.2", "-Wall", "-Wextra", "-Werror", f"-fmodules-cache-path={args.output / 'clang-cache'}"]
    objects = []
    for name in ("InferenceProtocolV2", "MuesliNativeProcessObserver"):
        obj = args.output / (name + ".o")
        run(compile_args + ["-c", src / (name + ".m"), "-o", obj])
        objects.append(obj)
    host = args.output / "FixtureHost"
    run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors", "-target", "arm64-apple-macos26.2", "-module-cache-path", args.output / "swift-cache", "-import-objc-header", src / "ClientProbe-Bridging.h", src / "BackendXPCJobOwner.swift", src / "SourceCapabilityOwner.swift", src / "tests/ClientFixtureHost.swift", *objects, "-framework", "Foundation", "-framework", "Security", "-o", host])
    sandbox = args.output / "Service.entitlements"
    sandbox.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
    reports = []
    for mode in [int(x) for x in args.modes.split(",")]:
        app = args.output / f"case-{mode}/InferenceProof.app"
        service = app / "Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc"
        for bundle, identifier, executable, package in ((app, "paidiaconsulting.MuesliApp.InferenceProof", "InferenceProof", "APPL"), (service, "paidiaconsulting.MuesliApp.InferenceService", "InferenceService", "XPC!")):
            (bundle / "Contents/MacOS").mkdir(parents=True)
            info = dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable, CFBundlePackageType=package, CFBundleVersion="1", LSMinimumSystemVersion="26.2")
            if package == "APPL":
                info["LSUIElement"] = True
            else:
                info["XPCService"] = dict(ServiceType="Application")
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run(["cp", host, app / "Contents/MacOS/InferenceProof"])
        run(compile_args + [f"-DMUESLI_FIXTURE_MODE={mode}", src / "tests/ClientFixtureService.m", src / "SourceLeaseAdmission.m", src / "InferenceProtocolV2.m", "-framework", "Foundation", "-o", service / "Contents/MacOS/InferenceService"])
        run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", "--entitlements", sandbox, service])
        run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", app])
        run(["codesign", "--verify", "--deep", "--strict", app])
        result = run([app / "Contents/MacOS/InferenceProof", mode], capture_output=True, text=True, timeout=65)
        (args.output / f"case-{mode}.stderr").write_text(result.stderr)
        report = json.loads(result.stdout)
        (args.output / f"case-{mode}.json").write_text(json.dumps(report, indent=2, sort_keys=True))
        if mode in (1, 12, 13, 15, 17):
            passed = not report["start_succeeded"] and report["bookmark_calls"] == 0 and not report["actual_observation_started"]
            if mode == 12 and report["actual_observation_started"]:
                passed = report["completed"] and report["bookmark_calls"] == 0 and report["completion_failure"] is not None
            if mode == 13:
                passed = passed and 45 <= report["elapsed_seconds"] < 47
            if mode in (15, 17):
                passed = passed and 0.4 <= report["elapsed_seconds"] < 2
            if mode == 17:
                passed = passed and report["start_failure"] == "Original admission owner retired."
        else:
            passed = report["completed"] and report["kernel_pid"] == report["reservation_pid"] and report["exclusive_available_after_actual_exit"]
            if mode in (0, 3, 5, 7, 14):
                passed = passed and report["start_succeeded"] and report["operation_status"] == 0 and report["completion_failure"] is None and not report["exclusive_available_after_start"] and report["stdout_bytes"] > 0 and report["registered_identity_matches_kernel"]
            else:
                passed = passed and not report["start_succeeded"] and report["completion_failure"] is not None
            if mode == 5:
                passed = passed and report["kernel_signal"] == 9
            else:
                passed = passed and report["kernel_exit_code"] == 125
            if mode == 7:
                passed = passed and report["elapsed_seconds"] >= 0.9
            if mode == 8:
                passed = passed and report["elapsed_seconds"] >= 0.9
            if mode == 14:
                passed = passed and report["bookmark_calls"] == 1 and 9 <= report["elapsed_seconds"] < 12
            if mode in (9, 10, 16):
                passed = passed and report["exclusive_available_after_start"] and report["operation_status"] == -1 and report["stdout_bytes"] == 0 and report["elapsed_seconds"] >= 8
            if mode == 16:
                passed = passed and report["bookmark_calls"] == 1 and report["elapsed_seconds"] >= 17
        report["passed"] = bool(passed)
        reports.append(report)
        print(json.dumps({"mode": mode, "passed": bool(passed), "start_failure": report.get("start_failure"), "completion_failure": report.get("completion_failure")} ), flush=True)
    summary = {"passed": all(x["passed"] for x in reports), "reports": reports, "scope": __doc__}
    (args.output / "results.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
    if not summary["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
