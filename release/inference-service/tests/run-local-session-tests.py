#!/usr/bin/env python3
"""Compile real session/package/source-owner logic with model-free test factories."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--client-source", type=Path)
    parser.add_argument("--owner-source", type=Path)
    parser.add_argument("--session-source", type=Path)
    parser.add_argument("--optimized", action="store_true")
    parser.add_argument("--identity", help="Also run the signed model-free active-job integration case.")
    parser.add_argument("--native-only", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    assert str(out).startswith("/private/tmp/")
    out.mkdir(parents=True, exist_ok=False)
    transport = Path(__file__).resolve().parent.parent
    repo = transport.parents[1]
    app = repo / "MuesliApp/MuesliApp"
    client = args.client_source or transport / "BackendXPCJobOwner.swift"
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    run(["python3", repo / "scripts/write-build-identity.py", "--root", repo, "--output", out / "identity"])
    bridge = out / "Session-Bridging.h"
    bridge.write_text('#import "' + str(transport / "ClientProbe-Bridging.h") + '"\n#import "' + str(repo / "release/source-access-service/SourceAccessProtocol.h") + '"\n')
    protocol = out / "FrameSending.swift"
    protocol.write_text((app / "MicAudioForwarder.swift").read_text().split("/// Abstraction over a monotonic time source")[0])
    sources = [app / (name + ".swift") for name in ("CapturedMicAudio", "MeetingFileAccess", "ShutdownWorkRegistry",
        "BackendAdmissionOwner", "BackendProcess", "BackendOutputReader", "TaskCompletion", "WriteBacklogTracker",
        "BuildIdentity", "PackagedInferenceRuntime", "LocalInferenceSession")]
    sources += [protocol, out / "identity/EmbeddedBuildIdentity.swift", client, args.owner_source or transport / "SourceCapabilityOwner.swift"]
    if args.session_source:
        sources[sources.index(app / "LocalInferenceSession.swift")] = args.session_source
    swift = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
             "-strict-concurrency=complete", "-warnings-as-errors", "-target", "arm64-apple-macos26.2",
             "-module-cache-path", out / "swift-cache", "-import-objc-header", bridge]
    # Production definitions first: no factory/transport test API is compiled.
    run(swift + ["-typecheck", *sources])
    objects = []
    for name in ("InferenceProtocolV2", "MuesliNativeProcessObserver", "SourceLeaseAdmission"):
        obj = out / (name + ".o")
        run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-fmodules", "-arch", "arm64", "-mmacosx-version-min=26.2",
             "-Wall", "-Wextra", "-Werror", "-fmodules-cache-path=" + str(out / "clang-cache"),
             "-c", transport / (name + ".m"), "-o", obj])
        objects.append(obj)
    harness = transport / "tests/LocalInferenceSessionTests.swift"
    inputs = [*sources, harness, Path(__file__).resolve(), repo / "release/source-access-service/SourceAccessProtocol.h",
              transport / "tests/ClientFixtureService.m"]
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    (out / "source-inputs.json").write_text(json.dumps(hashes, indent=2, sort_keys=True))
    run(swift + ["-D", "MUESLI_SOURCE_OWNER_TESTING", "-D", "MUESLI_LOCAL_INFERENCE_TESTING",
                 *(["-O", "-whole-module-optimization"] if args.optimized else ["-Onone", "-D", "DEBUG"]),
                 *sources, harness, *objects, "-framework", "Foundation", "-framework", "Security", "-o", out / "SessionTests"])
    executable = out / "SessionTests"
    if args.identity:
        bundle = out / "InferenceProof.app"
        service = bundle / "Contents/XPCServices/paidiaconsulting.MuesliApp.InferenceService.xpc"
        for path, identifier, name, package in ((bundle, "paidiaconsulting.MuesliApp.InferenceProof", "InferenceProof", "APPL"),
                (service, "paidiaconsulting.MuesliApp.InferenceService", "InferenceService", "XPC!")):
            (path / "Contents/MacOS").mkdir(parents=True)
            info = dict(CFBundleIdentifier=identifier, CFBundleExecutable=name, CFBundlePackageType=package,
                        CFBundleVersion="1", LSMinimumSystemVersion="26.2")
            info.update({"LSUIElement": True} if package == "APPL" else {"XPCService": {"ServiceType": "Application"}})
            (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        executable = bundle / "Contents/MacOS/InferenceProof"
        shutil.copyfile(out / "SessionTests", executable); executable.chmod(0o755)
        run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-fmodules", "-arch", "arm64", "-mmacosx-version-min=26.2",
             "-Wall", "-Wextra", "-Werror", "-fmodules-cache-path=" + str(out / "clang-cache"),
             "-DMUESLI_BACKEND_FIXTURE=1", "-DMUESLI_BACKEND_EVENT_COUNT=1", transport / "tests/ClientFixtureService.m",
             transport / "SourceLeaseAdmission.m", transport / "InferenceProtocolV2.m", "-framework", "Foundation",
             "-o", service / "Contents/MacOS/InferenceService"])
        entitlements = out / "Service.entitlements"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
        run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", "--entitlements", entitlements, service])
        run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", bundle])
        run(["codesign", "--verify", "--deep", "--strict", bundle])
        for path, label, expected in ((bundle, "host", {}), (service, "service", {"com.apple.security.app-sandbox": True})):
            data = run(["codesign", "-d", "--entitlements", "-", "--xml", path], capture_output=True).stdout
            actual = plistlib.loads(data) if data.strip() else {}
            assert actual == expected, (label, actual)
            (out / (label + "-actual-entitlements.plist")).write_bytes(plistlib.dumps(actual))
    if args.native_only and not args.identity:
        parser.error("--native-only requires --identity")
    result = subprocess.run([str(executable), str(out / "generated"), *(["active-native-job"] if args.native_only else [])], capture_output=True, text=True, timeout=65)
    (out / "stdout.json").write_text(result.stdout)
    (out / "stderr.log").write_text(result.stderr)
    unchanged = all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
    try:
        report = json.loads(result.stdout)
    except ValueError:
        report = {"passed": False, "failures": ["No valid test report."]}
    report.update(host_status=result.returncode, source_inputs_unchanged=unchanged, optimized=args.optimized)
    report["passed"] = bool(report["passed"] and result.returncode == 0 and unchanged)
    if args.identity and not args.native_only:
        native = subprocess.run([str(executable), str(out / "native-generated"), "active-native-job"], capture_output=True, text=True, timeout=65)
        (out / "native-stdout.json").write_text(native.stdout); (out / "native-stderr.log").write_text(native.stderr)
        try:
            native_report = json.loads(native.stdout)
        except ValueError:
            native_report = {"passed": False, "failures": ["No native fixture report."]}
        native_report["host_status"] = native.returncode
        report["native_integration"] = native_report
        report["passed"] = bool(report["passed"] and native_report["passed"] and native.returncode == 0)
    unchanged = all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
    report["source_inputs_unchanged"] = unchanged
    report["passed"] = bool(report["passed"] and unchanged)
    (out / "results.json").write_text(json.dumps(report, indent=2, sort_keys=True))
    print(json.dumps(report, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
