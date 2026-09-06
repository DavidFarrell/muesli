import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import pytest

from diarise_transcribe.meeting_lease import ENVIRONMENT_KEY, LOCK_NAMES


def identity(path):
    value = path.stat()
    return {"device": value.st_dev, "inode": value.st_ino}


def token_for(folder):
    for name in LOCK_NAMES:
        (folder / name).touch(mode=0o600, exist_ok=True)
    return {"version": 1, "folder": str(folder), "directory": identity(folder),
            "locks": {name: identity(folder / name) for name in LOCK_NAMES}}


def environment(token):
    return dict(os.environ, **{ENVIRONMENT_KEY: json.dumps(token), "PYTHONDONTWRITEBYTECODE": "1"})


def run(code, token, *arguments):
    return subprocess.run([sys.executable, "-B", "-c", code, *map(str, arguments)],
                          env=environment(token), capture_output=True, text=True, timeout=10)


def assert_exclusive_blocked(folder, name):
    with (folder / name).open("r+") as handle:
        with pytest.raises(BlockingIOError):
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)


def wait_for(predicate, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.01)
    assert predicate(), "Timed out waiting for actual child state"


def test_valid_pin_is_shared_fixed_order_noninheritable_and_bounds_source_paths(tmp_path):
    token = token_for(tmp_path)
    result = run('''
import fcntl, json, os, sys
import diarise_transcribe
from diarise_transcribe import meeting_lease as lease
assert lease._PROCESS_PIN is not None
assert len(lease._PROCESS_PIN.descriptors) == 3
assert all(fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY for fd in lease._PROCESS_PIN.descriptors)
assert all(not os.get_inheritable(fd) for fd in lease._PROCESS_PIN.descriptors)
lease.validate_source_path(lease._PROCESS_PIN.folder / "audio")
try: lease.validate_source_path(lease._PROCESS_PIN.folder.parent / "foreign")
except lease.MeetingLeaseError: pass
else: raise AssertionError("outside source admitted")
print(json.dumps({"pinned": True}))
''', token)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"pinned": True}


@pytest.mark.parametrize("mutation", ["directory", "access", "backend", "version", "missing_lock", "symlink_lock", "hardlink_lock"])
def test_changed_or_unowned_identities_fail_closed_without_creating_source(tmp_path, mutation):
    meeting = tmp_path / "meeting"
    meeting.mkdir()
    token = token_for(meeting)
    if mutation == "directory":
        token["directory"]["inode"] += 1
    elif mutation == "access":
        token["locks"][LOCK_NAMES[0]]["inode"] += 1
    elif mutation == "backend":
        token["locks"][LOCK_NAMES[1]]["inode"] += 1
    elif mutation == "version":
        token["version"] = True
    else:
        path = meeting / LOCK_NAMES[1]
        original = tmp_path / "lock-copy"
        path.rename(original)
        if mutation == "symlink_lock":
            path.symlink_to(original)
        elif mutation == "hardlink_lock":
            path.hardlink_to(original)
    result = run("import diarise_transcribe; from pathlib import Path; Path(__import__('sys').argv[1]).mkdir()", token,
                 meeting / "must-not-exist")
    assert result.returncode != 0
    assert "MeetingLeaseError" in result.stderr
    assert not (meeting / "must-not-exist").exists()
    if mutation == "missing_lock":
        assert not (meeting / LOCK_NAMES[1]).exists()


def test_recreated_same_path_and_new_locks_do_not_authorize_delayed_child(tmp_path):
    meeting = tmp_path / "meeting"
    meeting.mkdir()
    old = token_for(meeting)
    meeting.rename(tmp_path / "archived")
    meeting.mkdir()
    token_for(meeting)
    result = run("import diarise_transcribe; from pathlib import Path; Path(__import__('sys').argv[1]).mkdir()", old,
                 meeting / "audio")
    assert result.returncode != 0
    assert not (meeting / "audio").exists()


def test_archive_wins_before_child_pin_without_any_folder_recreation(tmp_path):
    meeting = tmp_path / "meeting"
    meeting.mkdir()
    token = token_for(meeting)
    with (meeting / LOCK_NAMES[0]).open("r+") as archive:
        fcntl.flock(archive, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = run("import diarise_transcribe", token)
        assert result.returncode != 0
        assert "Meeting ownership unavailable" in result.stderr
        meeting.rename(tmp_path / "archived")
    result = run("import diarise_transcribe; from pathlib import Path; Path(__import__('sys').argv[1]).mkdir(parents=True)",
                 token, meeting / "audio")
    assert result.returncode != 0
    assert not meeting.exists()


@pytest.mark.parametrize("module,arguments", [
    ("diarise_transcribe.muesli_backend", []),
    ("diarise_transcribe.muesli_backend", ["--no-live"]),
    ("diarise_transcribe.muesli_backend", ["--live-asr-only"]),
    ("diarise_transcribe.muesli_backend", ["--source-recording", "--no-live"]),
    ("diarise_transcribe.reprocess", []),
    ("diarise_transcribe.local_assets", []),
    ("diarise_transcribe", []),
])
def test_every_app_entry_mode_pins_before_entrypoint_or_model_imports(tmp_path, module, arguments):
    token = token_for(tmp_path)
    token["directory"]["inode"] += 1
    target = tmp_path / "must-not-create"
    if module.endswith("muesli_backend"):
        arguments = ["--output-dir", str(target), *arguments]
    elif module.endswith("reprocess"):
        arguments = [str(target), *arguments]
    elif module == "diarise_transcribe":
        arguments = ["--in", str(target), "--out", str(target / "transcript.txt")]
    result = subprocess.run([sys.executable, "-B", "-m", module, *arguments], env=environment(token),
                            capture_output=True, text=True, timeout=10)
    assert result.returncode != 0
    assert "Meeting folder identity changed" in result.stderr
    assert not target.exists()


def test_pin_survives_main_return_and_non_daemon_worker_until_real_exit(tmp_path):
    meeting = tmp_path / "meeting"
    meeting.mkdir()
    token = token_for(meeting)
    ready, release = tmp_path / "ready", tmp_path / "release"
    code = '''
import sys, threading, time
from pathlib import Path
import diarise_transcribe
ready, release = map(Path, sys.argv[1:])
def worker():
    ready.write_text("ready")
    while not release.exists(): time.sleep(0.01)
threading.Thread(target=worker, daemon=False).start()
# The entry/main thread returns while the worker still owns the source.
'''
    child = subprocess.Popen([sys.executable, "-B", "-c", code, str(ready), str(release)], env=environment(token),
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(ready.exists)
        assert child.poll() is None
        for name in LOCK_NAMES:
            assert_exclusive_blocked(meeting, name)
        release.touch()
        assert child.wait(timeout=5) == 0
        for name in LOCK_NAMES:
            with (meeting / name).open("r+") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    finally:
        if child.poll() is None:
            child.kill()
        child.communicate(timeout=5)


@pytest.fixture(scope="module")
def native_parent(tmp_path_factory):
    """Build the actual Swift admission owner, not a Python model of its lease."""
    if sys.platform != "darwin":
        pytest.skip("The app's native admission owner requires macOS")
    folder = tmp_path_factory.mktemp("native-admission-parent")
    repo = Path(__file__).resolve().parents[3]
    app = repo / "MuesliApp/MuesliApp"
    protocol = (app / "MicAudioForwarder.swift").read_text().split("/// Abstraction over a monotonic time source")[0]
    (folder / "FrameSending.swift").write_text(protocol)
    harness = folder / "ParentHarness.swift"
    harness.write_text('''
import Foundation
@main struct ParentHarness {
    static func main() async throws {
        let args = CommandLine.arguments
        let folder = URL(fileURLWithPath: args[1])
        let owner = BackendAdmissionOwner()
        let attempt = try owner.start(protecting: folder, timeoutSeconds: 10) {
            BackendAdmissionOwner.Resources(backend: try BackendProcess(
                command: Array(args.dropFirst(2)), workingDirectory: folder))
        }
        guard case .ready = await attempt.waitUntilReady() else { fatalError("admission did not become ready") }
        _ = try attempt.claim()
        FileHandle.standardOutput.write(Data("parent-ready\\n".utf8))
        while true { try await Task.sleep(for: .seconds(1)) }
    }
}
''')
    binary = folder / "ParentHarness"
    sources = ["CapturedMicAudio.swift", "MeetingFileAccess.swift", "ShutdownWorkRegistry.swift", "BackendAdmissionOwner.swift", "BackendProcess.swift",
               "BackendOutputReader.swift", "TaskCompletion.swift", "WriteBacklogTracker.swift"]
    transport = repo / "release/inference-service"
    native_objects = []
    for name in ("InferenceProtocolV2", "MuesliNativeProcessObserver", "SourceLeaseAdmission"):
        object_file = folder / (name + ".o")
        compiled = subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fblocks", "-fmodules",
                                   "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
                                   "-fmodules-cache-path=" + str(folder / "clang-cache"),
                                   "-c", str(transport / (name + ".m")), "-o", str(object_file)],
                                  capture_output=True, text=True, timeout=60)
        assert compiled.returncode == 0, compiled.stderr
        native_objects.append(str(object_file))
    result = subprocess.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                             "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
                             "-module-cache-path", str(folder / "module-cache"),
                             "-import-objc-header", str(transport / "ClientProbe-Bridging.h"),
                             str(folder / "FrameSending.swift"), *[str(app / name) for name in sources],
                             str(transport / "BackendXPCJobOwner.swift"), str(transport / "SourceCapabilityOwner.swift"), *native_objects,
                             "-framework", "Foundation", "-framework", "Security",
                             str(harness), "-o", str(binary)], capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stderr
    return binary


def start_native_parent(native_parent, tmp_path, *, allow_import):
    meeting = tmp_path / "meeting"
    meeting.mkdir()
    control = tmp_path / "control"
    control.mkdir()
    if allow_import:
        (control / "import").touch()
    child_script = tmp_path / "child.py"
    child_script.write_text('''
import json, os, sys, time
from pathlib import Path
meeting, control = map(Path, sys.argv[1:])
(control / "spawned").write_text(str(os.getpid()))
while not (control / "import").exists(): time.sleep(0.01)
try:
    import diarise_transcribe
    from diarise_transcribe.meeting_lease import validate_source_path
    validate_source_path(meeting, meeting_root=True)
except Exception as error:
    (control / "outcome").write_text(json.dumps({"state": "rejected", "error": str(error)}))
    sys.exit(7)
(control / "outcome").write_text(json.dumps({"state": "pinned"}))
while not (control / "finish").exists(): time.sleep(0.01)
# Prove that a surviving worker can still write only while its own pins prevent archive.
validate_source_path(meeting, meeting_root=True)
(meeting / "child-finished").write_text("preserved")
(control / "exiting").touch()
''')
    parent = subprocess.Popen([str(native_parent), str(meeting), sys.executable, "-B", str(child_script),
                               str(meeting), str(control)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1",
                                                 PYTHONPATH=str(Path(__file__).resolve().parents[1] / "src")))
    wait_for((control / "spawned").exists)
    pid = int((control / "spawned").read_text())
    return parent, pid, meeting, control


def cleanup_native_parent(parent, pid):
    if parent.poll() is None:
        parent.kill()
    parent.communicate(timeout=5)
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def test_actual_swift_parent_death_does_not_release_surviving_child_pins(native_parent, tmp_path):
    parent, pid, meeting, control = start_native_parent(native_parent, tmp_path, allow_import=True)
    try:
        wait_for((control / "outcome").exists)
        outcome = json.loads((control / "outcome").read_text())
        assert outcome["state"] == "pinned", outcome
        parent.kill()  # Actual abrupt app-owner death, no shutdown callbacks.
        assert parent.wait(timeout=5) < 0
        os.kill(pid, 0)
        for name in LOCK_NAMES:
            assert_exclusive_blocked(meeting, name)
        (control / "finish").touch()
        wait_for((control / "exiting").exists)
        def released():
            handles = []
            try:
                for name in LOCK_NAMES:
                    handle = (meeting / name).open("r+")
                    handles.append(handle)
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                return False
            finally:
                for handle in handles:
                    handle.close()
        wait_for(released)
        assert (meeting / "child-finished").read_text() == "preserved"
    finally:
        cleanup_native_parent(parent, pid)


@pytest.mark.parametrize("recreate", [False, True])
def test_actual_parent_death_before_child_pin_cannot_recreate_archived_source(native_parent, tmp_path, recreate):
    parent, pid, meeting, control = start_native_parent(native_parent, tmp_path, allow_import=False)
    try:
        # Native Process.run has spawned the child, but package admission has not run.
        parent.kill()
        assert parent.wait(timeout=5) < 0
        with (meeting / LOCK_NAMES[0]).open("r+") as archive:
            fcntl.flock(archive, fcntl.LOCK_EX | fcntl.LOCK_NB)
            meeting.rename(tmp_path / "archived")
        if recreate:
            meeting.mkdir()
            token_for(meeting)  # Same pathname, different directory and lock identities.
        (control / "import").touch()
        wait_for((control / "outcome").exists)
        outcome = json.loads((control / "outcome").read_text())
        assert outcome["state"] == "rejected", outcome
        assert outcome["error"].startswith("Meeting"), outcome
        assert not (meeting / "child-finished").exists()
        if not recreate:
            assert not meeting.exists()
        assert not (tmp_path / "archived/child-finished").exists()
    finally:
        cleanup_native_parent(parent, pid)


@pytest.mark.parametrize("module", ["diarise_transcribe.muesli_backend", "diarise_transcribe.reprocess",
                                     "diarise_transcribe", "diarise_transcribe.local_assets"])
def test_required_app_flag_without_native_pin_cannot_fall_back(tmp_path, module):
    target = tmp_path / "must-not-create"
    arguments = ["--meeting-lease-required"]
    if module.endswith("muesli_backend"):
        arguments += ["--output-dir", str(target)]
    elif module.endswith("reprocess"):
        arguments += [str(target)]
    elif module == "diarise_transcribe":
        arguments += ["--in", str(target), "--out", str(target / "transcript.txt")]
    env = dict(os.environ)
    env.pop(ENVIRONMENT_KEY, None)
    result = subprocess.run([sys.executable, "-B", "-m", module, *arguments], env=env,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode != 0
    assert "requires an independent meeting pin" in result.stderr
    assert not target.exists()



@pytest.mark.parametrize("module", ["diarise_transcribe.muesli_backend", "diarise_transcribe.reprocess"])
def test_valid_app_pin_cannot_be_used_for_another_source_folder(tmp_path, module):
    meeting = tmp_path / "meeting"
    meeting.mkdir()
    token = token_for(meeting)
    target = tmp_path / "foreign"
    arguments = ["--meeting-lease-required"]
    if module.endswith("muesli_backend"):
        arguments += ["--output-dir", str(target)]
    else:
        arguments += [str(target)]
    result = subprocess.run([sys.executable, "-B", "-m", module, *arguments], env=environment(token),
                            capture_output=True, text=True, timeout=15)
    assert result.returncode != 0
    assert "outside the admitted meeting" in result.stderr
    assert not target.exists()
