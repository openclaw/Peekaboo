#!/usr/bin/env python3
"""Exercise release archive publication with real tar/ditto write failures."""
import hashlib
import os
from pathlib import Path
import resource
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    assert result.returncode == 0, (args, result.returncode, result.stderr)
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


failures = []

with tempfile.TemporaryDirectory(prefix="peekaboo-archive-publication.") as directory:
    temporary = Path(directory)
    source = temporary / "source"
    source.mkdir()
    run(["/bin/cp", "/usr/bin/true", str(source / "peekaboo")])
    (source / "LICENSE").write_bytes(os.urandom(65536))
    release = temporary / "release"
    release.mkdir()
    staging = temporary / "staging"
    staging.mkdir()
    package = ROOT / "scripts/package-cli-artifact.sh"
    cli_archive = release / "peekaboo-macos-universal.tar.gz"
    run(["bash", str(package), str(source), str(staging), str(release), "9.8.7", "universal"])
    run(["/usr/bin/tar", "-tzf", str(cli_archive)])
    before = digest(cli_archive)
    failure_staging = temporary / "failure-staging"
    failure_staging.mkdir()
    commands = temporary / "commands"
    commands.mkdir()
    limited_tar = commands / "tar"
    limited_tar.write_text('#!/bin/bash\nulimit -f 1\nexec /usr/bin/tar "$@"\n')
    limited_tar.chmod(0o755)
    result = subprocess.run(
        ["bash", str(package), str(source), str(failure_staging), str(release), "9.8.7", "universal"],
        capture_output=True, text=True, env={**os.environ, "PATH": f"{commands}:{os.environ['PATH']}"},
    )
    assert result.returncode != 0, "native tar size limit must fail"
    if digest(cli_archive) != before:
        failures.append("failed tar publication replaced the previous archive")
    assert sorted(path.name for path in release.iterdir()) == [cli_archive.name], "tar temporary leaked"
    retry_staging = temporary / "retry-staging"
    retry_staging.mkdir()
    run(["bash", str(package), str(source), str(retry_staging), str(release), "9.8.8", "universal"])
    version = run(["/usr/bin/tar", "-xOf", str(cli_archive), "peekaboo-macos-universal/VERSION"])
    assert version.stdout == "9.8.8\n", "successful retry must publish the completed new archive"
    print("CHECK CLI tar: native success and actual size-limit failure (preservation assertions below)")

    app = temporary / "Fixture.app"
    contents = app / "Contents"
    contents.mkdir(parents=True)
    (contents / "payload").write_bytes(os.urandom(65536))
    zip_archive = release / "Fixture.zip"
    producer = ROOT / "scripts/create-app-zip.sh"
    run(["bash", str(producer), str(app), str(zip_archive)])
    run(["/usr/bin/unzip", "-t", str(zip_archive)])
    before = digest(zip_archive)

    def limit_archive_size():
        resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))

    result = subprocess.run(
        ["bash", str(producer), str(app), str(zip_archive)],
        capture_output=True, text=True, preexec_fn=limit_archive_size,
    )
    assert result.returncode != 0, "native ditto size limit must fail"
    if digest(zip_archive) != before:
        failures.append("failed ZIP publication replaced the previous archive")
    assert sorted(path.name for path in release.iterdir()) == sorted([cli_archive.name, zip_archive.name]), "ZIP temporary leaked"
    (contents / "payload").write_bytes(b"replacement payload")
    run(["bash", str(producer), str(app), str(zip_archive)])
    extracted = temporary / "extracted"
    run(["/usr/bin/ditto", "-x", "-k", str(zip_archive), str(extracted)])
    assert (extracted / "Fixture.app/Contents/payload").read_bytes() == b"replacement payload"
    print("CHECK app ZIP: native success and actual size-limit failure (preservation assertions below)")

assert not failures, failures
print("PASS both native release archive publication contracts")
