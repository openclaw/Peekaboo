"""One hosted-only diagnostic reproduction, never replacement test proof.

Helper argv/layout: swift-package-manager swift-6.3.3-RELEASE,
Sources/Commands/SwiftTestCommand.swift (TestRunner.args) and
Sources/PackageModel/UserToolchain.swift (getSwiftTestingHelper).
LLDB default frame-format uses function.name-with-args. Instead, use only
SBFrame.GetFunctionName and SBLineEntry metadata; never render default frames.
"""

import json
from itertools import chain, islice
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import time


def eligible(group, outcome, results):
    suite = results / "Core-PeekabooCore"
    return (
        group == "core"
        and outcome == "failure"
        and (suite / "status.txt").is_file()
        and (suite / "status.txt").read_text().strip() == "failed"
        and (suite / "test.log").is_file()
        and re.search(r"error: Process '[^\r\n]*swiftpm-testing-helper [^\r\n]*' "
                      r"exited with unexpected signal code 13\r?$",
                      (suite / "test.log").read_text(), re.MULTILINE) is not None
    )


def write_report(path, **fields):
    path.write_text(json.dumps(fields, indent=2) + "\n")


def prepare(root, results):
    def probe(*args):
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=30).strip()

    compiler = Path(probe("xcrun", "--find", "swiftc")).resolve(strict=True)
    helper = compiler.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
    debugger = Path(probe("xcrun", "--find", "lldb")).resolve(strict=True)
    # --show-bin-path only locates build output; no build/test discovery is requested.
    build = Path(probe("xcrun", "swift", "build", "--package-path", "Core/PeekabooCore",
                       "--configuration", "debug", "--show-bin-path")).resolve(strict=True)
    bundle = build / "PeekabooCorePackageTests.xctest/Contents/MacOS/PeekabooCorePackageTests"
    if not build.is_relative_to((root / "Core/PeekabooCore/.build").resolve(strict=True)):
        raise RuntimeError("Build output is outside the Core package")
    for executable in (helper, debugger, bundle):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise RuntimeError("Required diagnostic executable is missing")
    return {"helper": str(helper), "debugger": str(debugger), "bundle": str(bundle),
            "root": str(root), "report": str(results / "core-sigpipe-diagnostic.json"),
            "toolchain_record": str(results / "toolchain.txt")}


def capture(debugger, lldb, request):
    report = Path(request["report"])
    facts = {key: request[key] for key in ("helper", "bundle", "toolchain_record")}
    facts["original_suite"] = "failed; diagnostic reproduction is not test-pass proof"
    facts["stage"] = "configure-debugger"
    process = None
    try:
        # No lldbinit, symbol-file scripts, automatic backtrace, or process output is retained.
        result = lldb.SBCommandReturnObject()
        debugger.GetCommandInterpreter().HandleCommand(
            "settings set target.load-script-from-symbol-file false", result)
        if not result.Succeeded():
            raise RuntimeError("Cannot disable symbol-file scripts")
        debugger.SetAsync(True)
        target = debugger.CreateTarget(request["helper"])
        if not target.IsValid():
            raise RuntimeError("Cannot create helper target")
        launch = target.GetLaunchInfo()
        launch.SetArguments([
            "--test-bundle-path", request["bundle"], "--package-path", "Core/PeekabooCore",
            "--jobs", "4", "--no-parallel", request["bundle"], "--testing-library", "swift-testing",
        ], False)
        launch.SetWorkingDirectory(request["root"])
        launch.SetLaunchFlags(launch.GetLaunchFlags() | lldb.eLaunchFlagStopAtEntry)
        for fd in (0, 1, 2):
            if not launch.AddOpenFileAction(fd, "/dev/null", fd == 0, fd != 0):
                raise RuntimeError("Cannot suppress diagnostic process IO")
        deadline = time.monotonic() + request["timeout_seconds"]
        error = lldb.SBError()
        facts["stage"] = "launch-helper"
        process = target.Launch(launch, error)
        if error.Fail() or not process.IsValid():
            raise RuntimeError("Cannot launch helper")
        facts["stage"] = "await-entry-stop"
        while process.GetState() in (lldb.eStateLaunching, lldb.eStateRunning):
            if time.monotonic() >= deadline:
                raise TimeoutError()
            time.sleep(0.1)
        if process.GetState() != lldb.eStateStopped:
            raise RuntimeError("Helper did not stop at entry")
        entry_stop_id = process.GetStopID()
        facts.update(stage="configure-sigpipe", entry_stop_id=entry_stop_id)
        signals = process.GetUnixSignals()
        sigpipe = signals.GetSignalNumberFromName("SIGPIPE")
        # Pass through normally if resumed; never install SIG_IGN in the test process.
        if (sigpipe != 13 or not signals.SetShouldSuppress(sigpipe, False)
                or not signals.SetShouldStop(sigpipe, True) or signals.GetShouldSuppress(sigpipe)):
            raise RuntimeError("Cannot establish SIGPIPE stop/pass policy")
        facts["stage"] = "resume-helper"
        if process.Continue().Fail():
            raise RuntimeError("Cannot resume helper")
        facts.update(stage="await-new-stop", observed_running=False)
        while time.monotonic() < deadline:
            state = process.GetState()
            if state == lldb.eStateRunning:
                facts["observed_running"] = True
            if state == lldb.eStateExited:
                facts.update(stage="helper-exited", outcome="exited-without-sigpipe",
                             helper_exit_code=process.GetExitStatus())
                break
            if state in (lldb.eStateStopped, lldb.eStateCrashed):
                stop_id = process.GetStopID()
                # Async Continue can leave the public state at entry until a new natural stop arrives.
                if stop_id <= entry_stop_id:
                    time.sleep(0.1)
                    continue
                facts.update(stage="post-resume-stop", stop_id=stop_id, process_state=int(state))
                stopped = []
                for thread in process:
                    reason = int(thread.GetStopReason())
                    # Only a signal reason's first word is a signal number; exception data may contain addresses.
                    signal_code = (int(thread.GetStopReasonDataAtIndex(0))
                                   if reason == lldb.eStopReasonSignal and thread.GetStopReasonDataCount() > 0 else None)
                    stopped.append((thread, reason, signal_code))
                signalled = [item for item in stopped if item[2] == sigpipe]
                if signalled:
                    facts.update(outcome="sigpipe-reproduced", signal_code=13)
                else:
                    facts["outcome"] = "stopped-without-sigpipe"
                facts["threads"] = []
                # Bounded symbol/source-only records, including unexpected new stops. Never resume those stops.
                threads = chain(signalled, (item for item in stopped if item[2] != sigpipe))
                for index, (thread, reason, signal_code) in enumerate(threads):
                    if index == 128:
                        facts["threads_truncated"] = True
                        break
                    frames = []
                    for frame in islice(thread, 128):
                        line = frame.GetLineEntry()
                        frames.append({"function": frame.GetFunctionName(),
                                       "file": line.GetFileSpec().GetFilename() if line.IsValid() else None,
                                       "line": line.GetLine() if line.IsValid() else None})
                    facts["threads"].append({"index": index, "sigpipe": signal_code == sigpipe,
                                             "reason_code": reason, "signal_code": signal_code,
                                             "frames": frames, "frames_truncated": thread.GetNumFrames() > 128})
                break
            if state in (lldb.eStateDetached, lldb.eStateInvalid):
                facts.update(stage="post-resume-terminal-state", outcome="unexpected-process-state",
                             process_state=int(state))
                break
            time.sleep(0.1)
        else:
            raise TimeoutError()
    except TimeoutError:
        facts["outcome"] = "diagnostic-timeout"
    except Exception:
        # Exception/LLDB descriptions may contain process data; retain only this fixed category.
        facts["outcome"] = "diagnostic-error"
    finally:
        if process is not None and process.IsValid() and process.GetState() != lldb.eStateExited:
            facts["owned_process_terminated"] = process.Kill().Success()
            if not facts["owned_process_terminated"]:
                facts["observed_outcome"] = facts["outcome"]
                facts["outcome"] = "diagnostic-cleanup-error"
        write_report(report, **facts)


def diagnose(root, results):
    report = results / "core-sigpipe-diagnostic.json"
    write_report(report, outcome="preparing", original_suite="failed")
    deadline = time.monotonic() + 540
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        request = prepare(root, results)
        request["timeout_seconds"] = min(480, max(1, deadline - time.monotonic() - 30))
        request_path = results / "core-sigpipe-diagnostic-request.json"
        write_report(request_path, **request)
        write_report(report, outcome="running", original_suite="failed")
        environment = dict(os.environ)
        environment["CORE_SIGPIPE_SCRIPT"] = str(Path(__file__).resolve())
        environment["CORE_SIGPIPE_REQUEST"] = str(request_path)
        command = "script import os, runpy; runpy.run_path(os.environ['CORE_SIGPIPE_SCRIPT'], run_name='__lldb_diagnostic__')"
        child = subprocess.Popen([request["debugger"], "--batch", "--no-lldbinit", "--one-line", command],
                                 env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            code = child.wait(timeout=max(1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            write_report(report, outcome="debugger-timeout", original_suite="failed")
            return 1
        outcome = json.loads(report.read_text())["outcome"]
        if code != 0 or outcome in ("preparing", "running"):
            write_report(report, outcome="debugger-failed", debugger_exit_code=code, original_suite="failed")
            return 1
        return 0 if outcome in ("sigpipe-reproduced", "exited-without-sigpipe") else 1
    except Exception:
        write_report(report, outcome="diagnostic-setup-error", original_suite="failed")
        return 1


def main():
    results = Path(os.environ["VALIDATION_RESULTS"])
    if not eligible(os.environ.get("DIAGNOSTIC_GROUP"), os.environ.get("ORIGINAL_SUITE_OUTCOME"), results):
        return 0
    if not (os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("RUNNER_OS") == "macOS"):
        raise RuntimeError("Diagnostic requires a genuine hosted macOS runner")
    return diagnose(Path.cwd().resolve(), results)


if __name__ == "__lldb_diagnostic__":
    import lldb
    capture(lldb.debugger, lldb, json.loads(Path(os.environ["CORE_SIGPIPE_REQUEST"]).read_text()))
elif __name__ == "__main__":
    raise SystemExit(main())
