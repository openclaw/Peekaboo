#!/usr/bin/env python3
"""Check pblog argument handling without reading host logs."""
from pathlib import Path
import subprocess

script = Path(__file__).resolve().with_name("pblog.sh")
options = ("-n", "--lines", "-l", "--last", "-c", "--category", "-s", "--search",
           "-o", "--output", "--subsystem")
for option in options:
    try:
        result = subprocess.run(["bash", str(script), option], stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True, timeout=1)
    except subprocess.TimeoutExpired:
        raise AssertionError(f"Missing argument for {option} hangs instead of failing") from None
    assert result.returncode == 2, (option, result.returncode, result.stderr)
    assert f"{option} requires a value" in result.stderr, (option, result.stderr)
    # The help short circuit prevents any log command from running.
    valid = subprocess.run(["bash", str(script), option, "fixture", "--help"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=1)
    assert valid.returncode == 0, (option, valid.stderr)
print("test-pblog-arguments: ok")
