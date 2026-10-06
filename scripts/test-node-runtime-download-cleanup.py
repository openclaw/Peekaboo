#!/usr/bin/env python3
"""Exercise actual curl failure without fetching the pinned Node archives."""
import http.server
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent


class RejectProxy(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_CONNECT(self):
        self.calls.append(self.path)
        self.send_error(503, "Fixture denies outbound download")

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RejectProxy)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
owned_download = None
try:
    with tempfile.TemporaryDirectory(prefix="peekaboo-download-failure.") as directory:
        proxy = f"http://127.0.0.1:{server.server_port}"
        environment = dict(os.environ, HTTPS_PROXY=proxy, https_proxy=proxy,
                           ALL_PROXY="", all_proxy="", NO_PROXY="", no_proxy="")
        output = Path(directory) / "Runtime.app"
        # Trace the sanitized builder to find its exact owned mktemp result;
        # never compare or remove concurrent builders' temporary directories.
        command = [
            "/bin/bash", "-c",
            'source "$1/scripts/terminal-artifact-env.sh"; '
            'for name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do unset "$name"; done; '
            'exec /bin/bash -x "$1/scripts/build-node-runtime-macos.sh" --output-app "$2"',
            "node-download-cleanup", str(ROOT), str(output),
        ]
        result = subprocess.run(command, capture_output=True, text=True,
                                env=environment, timeout=10)
        match = re.search(r"^\+ download_root=(/tmp/peekaboo-node-download\.[A-Za-z0-9]+)$",
                          result.stderr, re.MULTILINE)
        assert match, "builder must reach the real download allocation"
        owned_download = Path(match.group(1))
        # CONNECT failures are reported as HTTP or proxy/transport errors by different curl versions.
        assert result.returncode != 0, result.stderr
        assert re.search(r"^curl: \(\d+\).*503", result.stderr, re.MULTILINE), result.stderr
        assert RejectProxy.calls == ["nodejs.org:443"], RejectProxy.calls
        assert not output.exists(), "failed download must not publish a runtime"
        assert not owned_download.exists(), "failed download leaked its owned temporary tree"
        print(f"PASS native curl503 (exit {result.returncode}): exact download directory removed; no archive fetched/runtime published")
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    if owned_download is not None and owned_download.exists():
        shutil.rmtree(owned_download)
