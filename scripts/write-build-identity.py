#!/usr/bin/python3
"""Generate immutable, content-addressed build provenance. No user data is read.

Archive/install and MUESLI_REQUIRE_IDENTIFIED_BUILD=YES require clean Git input.
Ordinary exported-source builds explicitly retain unknown Git provenance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

BACKEND = "backend/fast_mac_transcribe_diarise_local_models_only"
INPUTS = {
    "runtime_lock": BACKEND + "/uv.lock",
    "runtime_project": BACKEND + "/pyproject.toml",
    "runtime_configuration": BACKEND + "/uv.toml",
    "xcode_project": "MuesliApp/MuesliApp.xcodeproj/project.pbxproj",
    "entitlements": "MuesliApp/MuesliApp/MuesliApp.entitlements",
    "debug_entitlements": "MuesliApp/MuesliApp/MuesliApp.Debug.entitlements",
    "schemas": "scripts/build-schemas.json",
    "generator": "scripts/write-build-identity.py",
}
SETTINGS = ("CONFIGURATION", "SDK_NAME", "SDK_VERSION", "XCODE_VERSION_ACTUAL",
            "ARCHS", "SWIFT_VERSION", "SWIFT_OPTIMIZATION_LEVEL",
            "SWIFT_DEFAULT_ACTOR_ISOLATION", "MACOSX_DEPLOYMENT_TARGET",
            "PRODUCT_BUNDLE_IDENTIFIER", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION")
FLAG_SETTINGS = ("OTHER_SWIFT_FLAGS", "OTHER_CFLAGS", "OTHER_LDFLAGS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
                 "GCC_PREPROCESSOR_DEFINITIONS", "ENABLE_APP_SANDBOX", "ENABLE_HARDENED_RUNTIME",
                 "CODE_SIGN_ENTITLEMENTS", "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY",
                 "SWIFT_APPROACHABLE_CONCURRENCY", "ENABLE_CODE_COVERAGE")
SOURCE_ROOTS = ("MuesliApp/ArchiveCLI", "MuesliApp/MuesliApp", "MuesliApp/MuesliAppTests", BACKEND + "/src", "scripts", "release")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(root, *args):
    return subprocess.check_output(["/usr/bin/git", "-C", str(root), *args],
                                   stderr=subprocess.DEVNULL, timeout=15)


def identity(root, environment):
    hashes = {key: digest((root / path).read_bytes()) if (root / path).is_file() else None
              for key, path in INPUTS.items()}
    # Command-line overrides can change compiled behavior. Hash their effective
    # values instead of exporting flags which may contain developer paths.
    hashes["compiler_flags"] = digest(json.dumps({key: environment.get(key) for key in FLAG_SETTINGS},
                                                 sort_keys=True, separators=(",", ":")).encode())
    commit = dirty = tree = None
    tracked = None
    try:
        # A project exported inside an unrelated Git repository is not that repo's build.
        git(root, "ls-files", "--error-unmatch", "MuesliApp/MuesliApp.xcodeproj/project.pbxproj")
        commit = git(root, "rev-parse", "HEAD").decode().strip()
        dirty = bool(git(root, "status", "--porcelain", "--untracked-files=normal", "--", ".").strip())
        tracked = set(git(root, "ls-files", "-z", "--cached", "--", ".").split(b"\0"))
    except (OSError, ValueError, subprocess.SubprocessError):
        commit = dirty = None
    try:
        # Hash the declared build source/resource roots even in a non-Git
        # export, where commit/dirty are unknown but source bytes are visible.
        names = {os.fsencode(path) for path in INPUTS.values()}
        for relative in SOURCE_ROOTS:
            for path in (root / relative).rglob("*"):
                if (relative in {BACKEND + "/src", "scripts", "release"} and path.parent.name == "__pycache__" and path.suffix == ".pyc") or path.name == ".DS_Store":
                    continue
                if path.is_file() or path.is_symlink():
                    raw = os.fsencode(str(path.relative_to(root)))
                    names.add(raw)
                    # Xcode synchronized groups compile ignored files too.
                    if tracked is not None and raw not in tracked:
                        dirty = True
        source = hashlib.sha256()
        for raw in sorted(names):
            path = root / os.fsdecode(raw)
            source.update(raw + b"\0")
            if path.is_symlink():
                source.update(b"link\0" + os.fsencode(os.readlink(path)))
                # External or directory links are not clean distribution input.
                if tracked is not None and (path.is_dir() or not path.resolve().is_relative_to(root)):
                    dirty = True
            if path.is_file():
                with path.open("rb") as handle:
                    for block in iter(lambda: handle.read(1024 * 1024), b""):
                        source.update(block)
            else:
                source.update(b"missing\0")
            source.update(b"\0")
        tree = source.hexdigest()
    except (OSError, ValueError):
        tree = None
    schemas_path = root / INPUTS["schemas"]
    schemas = json.loads(schemas_path.read_text()) if schemas_path.is_file() else {}
    if not isinstance(schemas, dict) or any(not isinstance(key, str) or type(version) is not int or version < 1
                                           for key, version in schemas.items()):
        raise ValueError("Build format revisions must be named positive integers.")
    value = {"schema_version": 1, "source_commit": commit, "source_dirty": dirty,
             "source_tree_sha256": tree, "expected_input_sha256": hashes,
             "schemas": schemas, "build_settings": {key: environment[key] for key in SETTINGS if key in environment}}
    required = environment.get("ACTION") == "install" or environment.get("MUESLI_REQUIRE_IDENTIFIED_BUILD") == "YES"
    if required and (commit is None or tree is None or dirty is not False or not all(hashes.values()) or not schemas):
        raise ValueError("Distribution requires clean, identified source and all expected build inputs; no archive was qualified.")
    value["build_id"] = digest(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
    return value


def write_if_changed(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == contents:
        return
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(contents)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        value = identity(args.root.resolve(), os.environ)
    except (OSError, ValueError) as error:
        parser.exit(1, "error: " + str(error) + "\n")
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
    write_if_changed(args.output / "build-identity.json", encoded + "\n")
    # Base64 is an ASCII Swift literal even when build settings contain quotes.
    import base64
    payload = base64.b64encode(encoded.encode()).decode()
    write_if_changed(args.output / "EmbeddedBuildIdentity.swift",
                     '// Generated; do not edit.\nnonisolated enum EmbeddedBuildIdentity {\n'
                     '    static let base64 = "' + payload + '"\n}\n')


if __name__ == "__main__":
    main()
