#!/usr/bin/env python3
"""Hosted-only focused proof; a zero-test Swift Testing exit is not success."""

import os
from pathlib import Path
import re
import subprocess
import sys


EXPECTED_IDS = (
    "CLIAutomationTests.SeeCommandRuntimeTests/`config environment restores inherited values`(werePresent:)",
    "CLIAutomationTests.SeeCommandRuntimeTests/`config environment restores nested throwing bodies`()",
)
DISPLAY_NAMES = (
    "config environment restores inherited values",
    "config environment restores nested throwing bodies",
)
# Test.ID can append a source location; do not match another declaration sharing a prefix.
SELECTION = "^(?:" + "|".join(re.escape(name) for name in EXPECTED_IDS) + ")(?:/|$)"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run_swift(arguments):
    result = subprocess.run(
        ["swift", "test", "--no-parallel", "--disable-xctest", "--enable-swift-testing",
         "-Xswiftc", "-DPEEKABOO_SKIP_AUTOMATION", "--filter", SELECTION, *arguments],
        cwd=Path(__file__).resolve().parent.parent / "Apps/CLI",
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
    )
    print(result.stdout, end="", flush=True)
    require(result.returncode == 0, f"Swift command failed with exit {result.returncode}")
    return re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)


def verify_discovery(output):
    # Ignore compiler chatter, but reject missing, duplicate, or additional test IDs.
    discovered = [line.strip() for line in output.splitlines()
                  if re.match(r"^[A-Za-z_]\w*\.[^/]+/", line.strip())]
    require(sorted(discovered) == sorted(EXPECTED_IDS),
            f"Expected exactly the two See environment declaration IDs, got {discovered!r}")
    print("Verified discovery: 2 See environment test declarations.", flush=True)


def verify_execution(output):
    summaries = re.findall(r"Test run with .*", output)
    require(len(summaries) == 1 and re.fullmatch(
        r"Test run with 2 tests in 1 suite passed after .+ seconds\.", summaries[0]),
        f"Expected one passing 2-test/1-suite summary, got {summaries!r}")
    passed = re.findall(r'Test "([^"]+)" passed after .+ seconds\.', output)
    require(sorted(passed) == sorted(DISPLAY_NAMES),
            f"Expected both See environment tests to pass exactly once, got {passed!r}")
    arguments = re.findall(
        r'Test case passing 1 argument werePresent → (false|true) '
        r'to "config environment restores inherited values" started\.', output)
    require(sorted(arguments) == ["false", "true"],
            f"Expected both inherited-value argument cases, got {arguments!r}")
    print("Verified execution: 2 tests in 1 suite, including both inherited-value cases.", flush=True)


def main():
    # This is not an operator-state sandbox or a replacement for protected local proof.
    require(os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
            "See environment proof is restricted to the secretless GitHub-hosted CI runner")
    for name, expected in (
        ("PEEKABOO_INCLUDE_AUTOMATION_TESTS", "true"),
        ("PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS", "false"),
        ("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1"),
    ):
        require(os.environ.get(name) == expected, f"Set {name}={expected} for this hosted proof")
    verify_discovery(run_swift(["--list-tests"]))
    # A separate nonparallel process, reusing precisely the discovered build and selector.
    verify_execution(run_swift(["--skip-build"]))


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        sys.exit(str(error))
