#!/usr/bin/env python3
"""Signed model-free tests of the actual BackendProcess/admission/journal stack.

Only new private temporary sources and compile-time service faults are used.
This does not qualify models, production packaging, private grants or archiving.
Run outside an enclosing sandbox: native peer observation requires libproc.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid


CASES = {"normal": 0, "signal": 5, "reject": 6, "disconnect": 7,
         "cancel_before_ack": 8, "slow_reserve": 14, "retired_reserve": 17,
         "blocked_write": 0, "blocked_finalsync": 0, "write_failure": 0,
         "finalsync_failure": 0}


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("identity")
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--optimized", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    if not str(output).startswith("/private/tmp/"):
        parser.error("Use a new /private/tmp output directory.")
    output.mkdir(parents=True, exist_ok=False)
    src = Path(__file__).resolve().parent.parent
    repo = src.parents[1]
    app_sources = repo / "MuesliApp/MuesliApp"
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    compile_args = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-fmodules", "-arch", "arm64",
                    "-mmacosx-version-min=26.2", "-Wall", "-Wextra", "-Werror",
                    f"-fmodules-cache-path={output / 'clang-cache'}"]
    objects = []
    inputs = []
    for name in ("InferenceProtocolV2", "MuesliNativeProcessObserver", "SourceLeaseAdmission"):
        source = src / (name + ".m")
        obj = output / (name + ".o")
        run(compile_args + ["-c", source, "-o", obj])
        objects.append(obj)
        inputs.append(source)
    sources = ["CapturedMicAudio.swift", "MeetingFileAccess.swift", "ShutdownWorkRegistry.swift",
               "BackendAdmissionOwner.swift", "BackendProcess.swift", "BackendOutputReader.swift",
               "TaskCompletion.swift", "WriteBacklogTracker.swift"]
    original_protocol = app_sources / "MicAudioForwarder.swift"
    protocol = output / "FrameSending.swift"
    protocol.write_text(original_protocol.read_text().split("/// Abstraction over a monotonic time source")[0])
    host = output / "BackendProcessFixtureHost"
    swift_sources = [*[app_sources / name for name in sources], src / "BackendXPCJobOwner.swift",
                     src / "tests/BackendProcessFixtureHost.swift"]
    run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
         "-strict-concurrency=complete", "-warnings-as-errors", "-target", "arm64-apple-macos26.2",
         "-module-cache-path", output / "swift-cache", "-import-objc-header", src / "ClientProbe-Bridging.h",
         *(["-O", "-whole-module-optimization"] if args.optimized else ["-Onone", "-D", "DEBUG"]),
         protocol, *swift_sources, *objects, "-framework", "Foundation", "-framework", "Security", "-o", host])
    inputs += [*swift_sources, original_protocol, src / "tests/ClientFixtureService.m",
               src / "InferenceProtocolV2.h", src / "SourceLeaseAdmission.h",
               src / "MuesliNativeProcessObserver.h", src / "ClientProbe-Bridging.h", Path(__file__).resolve()]
    input_hashes = {str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    (output / "source-inputs.json").write_text(json.dumps(input_hashes, indent=2, sort_keys=True))
    sandbox = output / "Service.entitlements"
    sandbox.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
    reports = []
    traces = []
    for scenario in args.cases.split(","):
        mode = CASES[scenario]
        case = output / scenario
        app = case / "InferenceProof.app"
        service = app / "Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc"
        for bundle, identifier, executable, package in (
                (app, "paidiaconsulting.MuesliApp.InferenceProof", "InferenceProof", "APPL"),
                (service, "paidiaconsulting.MuesliApp.InferenceService", "InferenceService", "XPC!")):
            (bundle / "Contents/MacOS").mkdir(parents=True)
            info = dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable,
                        CFBundlePackageType=package, CFBundleVersion="1", LSMinimumSystemVersion="26.2")
            info.update({"LSUIElement": True} if package == "APPL" else {"XPCService": {"ServiceType": "Application"}})
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copyfile(host, app / "Contents/MacOS/InferenceProof")
        (app / "Contents/MacOS/InferenceProof").chmod(0o755)
        # A sandboxed service cannot write the host's fixture directory. One
        # unique generated trace lives in its existing private container tmp.
        # No source grant or new entitlement is used to communicate test state.
        trace = Path.home() / "Library/Containers/paidiaconsulting.MuesliApp.InferenceService/Data/tmp" / ("backend-fixture-" + uuid.uuid4().hex + ".txt")
        run(compile_args + [f"-DMUESLI_FIXTURE_MODE={mode}", "-DMUESLI_BACKEND_FIXTURE=1",
                            f"-DMUESLI_BACKEND_EVENT_COUNT={601 if scenario == 'normal' else 1}",
                            '-DMUESLI_FIXTURE_TRACE_PATH="' + str(trace) + '"',
                            src / "tests/ClientFixtureService.m", src / "SourceLeaseAdmission.m",
                            src / "InferenceProtocolV2.m", "-framework", "Foundation",
                            "-o", service / "Contents/MacOS/InferenceService"])
        run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", "--entitlements", sandbox, service])
        run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", app])
        run(["codesign", "--verify", "--deep", "--strict", app])
        for bundle, label, expected in ((app, "host", {}), (service, "service", {"com.apple.security.app-sandbox": True})):
            entitlements = run(["codesign", "-d", "--entitlements", "-", "--xml", bundle], capture_output=True).stdout
            actual = plistlib.loads(entitlements) if entitlements.strip() else {}
            (case / (label + "-actual-entitlements.plist")).write_bytes(plistlib.dumps(actual))
            assert actual == expected, (label, actual)
        source = case / "generated-source"
        source.mkdir(mode=0o700)
        original = source / "synthetic-source.txt"
        original.write_bytes(b"MODEL-FREE GENERATED SOURCE SENTINEL\n")
        original.chmod(0o400)
        before = original.stat()
        before_hash = hashlib.sha256(original.read_bytes()).hexdigest()
        try:
            result = subprocess.run([str(app / "Contents/MacOS/InferenceProof"), scenario, str(source), str(trace)],
                                    capture_output=True, text=True, timeout=65)
        except subprocess.TimeoutExpired as error:
            # subprocess.run kills and reaps only this host. The fixture
            # service independently has its own fixed55-second alarm.
            result = subprocess.CompletedProcess([], -999,
                (error.stdout or b"").decode() if isinstance(error.stdout, bytes) else error.stdout or "",
                (error.stderr or b"").decode() if isinstance(error.stderr, bytes) else error.stderr or "")
        (case / "stdout.jsonl").write_text(result.stdout)
        (case / "stderr.log").write_text(result.stderr)
        if trace.exists():
            (case / "service-events.txt").write_bytes(trace.read_bytes())
        traces.append((trace, case, service / "Contents/MacOS/InferenceService"))
        try:
            report = json.loads(result.stdout)
        except ValueError:
            report = {"scenario": scenario, "passed": False, "failures": ["Host did not return a JSON report."]}
        after = original.stat()
        report["source_unchanged"] = ((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                                      == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                                      and before_hash == hashlib.sha256(original.read_bytes()).hexdigest())
        report["host_status"] = result.returncode
        report["passed"] = bool(report["passed"] and result.returncode == 0 and report["source_unchanged"])
        (case / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True))
        reports.append(report)
        print(json.dumps({"scenario": scenario, "passed": report["passed"], "failures": report.get("failures", [])}), flush=True)
    # Wait for each exact traced fixture executable to disappear, including
    # source-free retired reservations that never arm an observer. Never send
    # a signal to a PID discovered from a stale trace; the service alarm owns
    # its independent fallback. PID reuse with a different executable is gone.
    cleanup = []
    deadline = time.monotonic() + 60
    for trace, case, executable in traces:
        pids = {int(line.split()[1]) for line in trace.read_text().splitlines()} if trace.exists() else set()
        for pid in pids:
            while time.monotonic() < deadline:
                status = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
                if status.returncode != 0 or status.stdout.strip() != str(executable):
                    break
                time.sleep(.05)
            status = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
            cleanup.append({"pid": pid, "exact_fixture_exited": status.returncode != 0 or status.stdout.strip() != str(executable)})
        if trace.exists():
            (case / "service-events.txt").write_bytes(trace.read_bytes())
    unchanged = all(hashlib.sha256((repo / name).read_bytes()).hexdigest() == digest for name, digest in input_hashes.items())
    summary = {"passed": unchanged and all(x["passed"] for x in reports) and all(x["exact_fixture_exited"] for x in cleanup), "reports": reports,
               "fixture_cleanup": cleanup,
               "source_inputs_unchanged": unchanged, "optimized": args.optimized, "scope": __doc__}
    (output / "results.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
    if not summary["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
