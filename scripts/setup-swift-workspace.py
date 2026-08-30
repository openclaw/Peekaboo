#!/usr/bin/env python3
"""Own the source checkout's Commander mapping, never the operator's SwiftPM settings."""

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
REMOTE = "https://github.com/steipete/Commander.git"
# Only consumers that already select the live Commander filesystem package.
# AutomationKit alone and the public root package deliberately retain remote resolution.
PACKAGES = (
    "Apps/CLI", "Apps/Mac", "Apps/Playground", "Apps/PeekabooInspector",
    "Core/PeekabooCore", "Core/PeekabooExternalDependencies", "Core/PeekabooUICore",
)
WORKSPACES = (
    "Apps/Peekaboo.xcworkspace",
    "Apps/Mac/Peekaboo.xcodeproj/project.xcworkspace",
    "Apps/Playground/Playground.xcodeproj/project.xcworkspace",
    "Apps/PeekabooInspector/Inspector.xcodeproj/project.xcworkspace",
)
OWNER = ".swiftpm/peekaboo-workspace"
STATE = OWNER + "/owner.json"
MIRROR = OWNER + "/mirrors.json"
CONFIGS = (MIRROR,) + tuple(p + "/.swiftpm/configuration/mirrors.json" for p in PACKAGES) + tuple(
    p + "/xcshareddata/swiftpm/configuration/mirrors.json" for p in WORKSPACES
)


class SetupError(Exception):
    pass


def fail(message):
    raise SetupError(message)


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def mapping(root):
    # A bare path is local SCM, whose SwiftPM validation rejects submodule gitfiles.
    # The file URL keeps the same canonical location as the explicit live package.
    return encoded({"version": 1, "object": [{"original": REMOTE, "mirror": (root / "Commander").as_uri()}]})


def ownership(root):
    return encoded({"owner": "scripts/setup-swift-workspace.py", "version": 1, "root": str(root)})


def safe_path(relative):
    path = ROOT
    for component in Path(relative).parts:
        path = path / component
        if path.is_symlink():
            fail("symlink in generated configuration path: " + relative)
        if path.exists():
            info = path.stat()
            if info.st_uid != os.getuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                fail("unsafe ownership/permissions in configuration path: " + relative)
    return path


def regular_bytes(relative):
    path = safe_path(relative)
    if not path.is_file() or path.stat().st_nlink != 1:
        fail("expected an unlinked regular configuration file: " + relative)
    return path.read_bytes()


def source_command(function, *args):
    # Source validation has one owner, also used by the existing artifact builders.
    if any(name in os.environ for name in (
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES")):
        fail("unset Git repository-location overrides before workspace setup")
    result = subprocess.run(
        ["/bin/bash", "-c", 'source "$1/scripts/source-provenance.sh"; "$2" "$1" "${@:3}"',
         "workspace-source", str(ROOT), function, *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if result.returncode:
        # Do not relay Git/operator configuration or URLs from a failed subprocess.
        fail("source validation failed (initialized matching Commander/AXorcist gitlinks required; "
             "release also requires a clean exact source commit)")
    return result.stdout.strip()


def validate_source():
    source_command("peekaboo_verify_workspace_submodules")
    for package in PACKAGES:
        if not safe_path(package + "/Package.swift").is_file():
            fail("supported package is missing: " + package)
    for workspace in WORKSPACES:
        if not safe_path(workspace + "/contents.xcworkspacedata").is_file():
            fail("supported Xcode workspace is missing: " + workspace)


def inspect():
    state = safe_path(STATE)
    old_root = None
    if state.exists():
        try:
            receipt = json.loads(regular_bytes(STATE))
            old_root = Path(receipt["root"])
            if (set(receipt) != {"owner", "version", "root"} or receipt["version"] != 1 or
                    receipt["owner"] != "scripts/setup-swift-workspace.py" or not old_root.is_absolute() or
                    str(old_root) != receipt["root"]):
                raise ValueError()
        except (ValueError, KeyError, TypeError):
            fail("unknown workspace ownership receipt; preserve it for manual inspection")
    expected = mapping(old_root) if old_root else None
    for relative in CONFIGS:
        path = safe_path(relative)
        if path.exists():
            # Refuse unowned files without reading their potentially credential-bearing URLs.
            if expected is None:
                fail("unowned mirror configuration; preserve/move it explicitly before setup: " + relative)
            if regular_bytes(relative) != expected:
                fail("owned mirror configuration changed; refusing to overwrite: " + relative)
    if old_root is None and safe_path(OWNER).exists():
        fail("unowned workspace configuration directory: " + OWNER)
    if old_root is not None:
        if {p.name for p in safe_path(OWNER).iterdir()} - {"owner.json", "mirrors.json"}:
            fail("unknown files in workspace configuration directory; preserve them before setup")
    return old_root


def write_owned(relative, content, previous=None):
    path = safe_path(relative)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".peekaboo-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
        if path.exists():
            if previous is None or regular_bytes(relative) != previous:
                fail("configuration changed during setup: " + relative)
            os.replace(temporary, path)
        else:
            # Exclusive creation must not replace a user file appearing after preflight.
            os.link(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure(action):
    validate_source()
    old_root = inspect()
    if action == "check":
        if old_root != ROOT or any(not safe_path(p).is_file() for p in CONFIGS):
            fail("workspace setup is missing or relocated; run scripts/setup-swift-workspace.py setup")
        return
    if action == "remove":
        if old_root is None:
            return
        for relative in CONFIGS:
            path = safe_path(relative)
            if path.exists():
                path.unlink()
        safe_path(STATE).unlink()
        safe_path(OWNER).rmdir()
        return
    for relative in CONFIGS:
        if old_root != ROOT or not safe_path(relative).exists():
            write_owned(relative, mapping(ROOT), mapping(old_root) if old_root else None)
    if old_root != ROOT:
        write_owned(STATE, ownership(ROOT), ownership(old_root) if old_root else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("setup", "check", "remove", "run"))
    parser.add_argument("--release", action="store_true", help="verify the existing clean-source gate before/after")
    options, command = parser.parse_known_args()
    if command[:1] == ["--"]:
        command = command[1:]
    if (options.action == "run") != bool(command):
        parser.error("run requires -- COMMAND; other actions do not accept a command")
    if "SWIFTPM_MIRROR_CONFIG" in os.environ:
        fail("unset inherited SWIFTPM_MIRROR_CONFIG; checkout mapping is owned by this helper")
    original_umask = os.umask(0o077)
    # Serialize writers and hold ownership across compilation and the final integrity check.
    safe_path(".swiftpm").mkdir(exist_ok=True, mode=0o700)
    lock = safe_path(".swiftpm/peekaboo-workspace.lock")
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        fail("workspace configuration is busy (or an interrupted setup left .swiftpm/peekaboo-workspace.lock)")
    try:
        commit = source_command("peekaboo_require_source_commit") if options.release else None
        configure("setup" if options.action == "run" else options.action)
        if options.action == "run":
            child_env = dict(os.environ, SWIFTPM_MIRROR_CONFIG=str(ROOT / MIRROR))
            # Ownership modes apply only to generated configuration, not build products.
            os.umask(original_umask)
            try:
                result = subprocess.run(command, env=child_env)
            finally:
                os.umask(0o077)
            configure("check")
            if commit:
                source_command("peekaboo_verify_source_commit", commit)
            return result.returncode
        if commit:
            source_command("peekaboo_verify_source_commit", commit)
        return 0
    finally:
        lock.rmdir()
        os.umask(original_umask)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (SetupError, OSError) as error:
        # OS errors can include operator-supplied filenames; report only their type.
        message = str(error) if isinstance(error, SetupError) else type(error).__name__
        print("setup-swift-workspace: " + message, file=sys.stderr)
        sys.exit(1)
