---
summary: 'Run background-first Peekaboo subprocess workflows with explicit host ownership and structured failures.'
read_when:
  - 'using Peekaboo from Node.js, OpenClaw, or another subprocess runner'
  - 'diagnosing Bridge permissions, snapshot ownership, or failed automation steps'
---

# Subprocess Integration Guide

Use the separate `peekaboo` CLI binary, argument arrays, and `--json`. Targeted native interaction is background-first;
a subprocess wrapper must not silently add `--foreground`, change execution hosts, or replay failed input. Running
from Node.js or OpenClaw does not require a special capture backend.

## Choose the execution host deliberately

The process performing the operation needs the relevant macOS grants, not merely the terminal or editor that spawned
the CLI. A persistent Peekaboo daemon or GUI Bridge host can own those grants and reusable snapshots across successive
CLI invocations. Peekaboo.app is the permission broker, not a replacement for the CLI executable, and the CLI does not
automatically launch that app.

Start with read-only diagnostics:

```bash
peekaboo bridge status --verbose --json
peekaboo permissions status --all-sources --json
peekaboo app list --include-hidden --include-background --json
peekaboo window list --app Safari --json
```

Default discovery is operation-dependent: observations prefer the current CLI build's daemon, while other commands
can reuse a compatible daemon or Peekaboo.app. A concrete snapshot reference resolves its unique live authenticated
producer before normal host preferences. See [Bridge host discovery](../bridge-host.md#hosts-and-discovery) for the
full ordering.

For a controlled multi-command workflow, select one already-running, authenticated, capable host with
`--bridge-socket /absolute/path/to/bridge.sock` on every call, or set `PEEKABOO_BRIDGE_SOCKET` in the runner's environment.
Check that exact host's permissions and capabilities first. A successful handshake is not proof of capture readiness
or successful capture. Keep the host running throughout the workflow; a rejected or unavailable host is not permission
to switch to another host and repeat input.

`--no-remote` intentionally selects caller-local execution. It is a diagnostic override, not the default subprocess
fix. In SSH, LaunchAgent, and other background sessions, prefer the Bridge path: caller-local CoreGraphics can return
wallpaper or redacted pixels despite apparently granted permissions. Only when the caller is known to run in the
active Aqua GUI session with the necessary grants should you test a local capture such as:

```bash
peekaboo see --mode screen --screen-index 0 --no-remote --capture-engine cg --json
```

`--capture-engine cg` selects the backend on the chosen host; it does not itself make execution local or bypass TCC.
Do not add capture-engine flags to unrelated commands. Leave the default `auto` selection unless diagnosing a specific
backend problem. Engine availability, permissions, and ScreenCaptureKit ownership are separate checks; neither engine
is a blanket subprocess workaround. See [permissions](../permissions.md#bridge-and-subprocess-runners).

## A Node.js runner with output limits

Save this as `peekaboo-runner.mjs`. Supply the absolute path to the CLI you intend to execute. `execFile` does not invoke
a shell, so spaces, quotes, Unicode, dollar signs, and other shell metacharacters stay inside their individual
arguments. Supply the command path separately from its arguments: `peekaboo(['window', 'list'], ['--app', 'Safari'])`.
Runtime flags belong after the command path, not before the root command or after the `--` positional delimiter.

```javascript
import { execFile } from 'node:child_process';
import { isAbsolute } from 'node:path';

export function createPeekabooRunner(executable, {
  bridgeSocket,
  timeoutMs = 30_000,
  maxBuffer = 4 * 1024 * 1024,
} = {}) {
  if (!isAbsolute(executable)) throw new Error('Use an absolute Peekaboo CLI path');
  const route = bridgeSocket ? ['--bridge-socket', bridgeSocket] : [];

  return function peekaboo(commandPath, args = []) {
    return new Promise((resolve, reject) => {
      execFile(executable, [...commandPath, '--json', ...route, ...args], {
        encoding: 'utf8',
        shell: false,
        timeout: timeoutMs,
        maxBuffer,
      }, (processError, stdout, stderr) => {
        let response;
        try {
          response = JSON.parse(stdout);
        } catch {
          // Startup errors, killed processes, and truncated output may have no JSON.
        }

        if (!processError && response?.success === true) {
          resolve(response);
          return;
        }

        const failure = new Error('Peekaboo failed; inspect the response and current state before continuing');
        failure.response = response;
        failure.process = {
          exitCode: processError ? (Number.isInteger(processError.code) ? processError.code : null) : 0,
          code: typeof processError?.code === 'string' ? processError.code : null,
          signal: processError?.signal ?? null,
          killed: processError?.killed ?? false,
        };
        failure.stderr = stderr.slice(0, 2048);
        reject(failure);
      });
    });
  };
}
```

The wrapper parses **stdout even on a nonzero exit**. JSON-mode command failures normally carry `success: false` and
an `error` there; stderr is supplemental diagnostics, not the JSON result channel. Startup and argument errors can
still have no JSON. Failure `data` is not always null: an Agent step-limit failure includes its bounded, sanitized
execution trace and, for a saved session, its full session ID. Retain the response for diagnosis without treating it as
success or printing all potentially private data into a public log.

Success requires both a zero process exit and `success: true`. That still means command-level success, not proof that
the whole task completed: inspect canonical action outcomes, including `effect`, `retry_safe`, and
`requires_fresh_observation`, and verify the intended app state. In particular, accepted but unverified dispatch is not
confirmed application change. The wrapper never opts into `type --accept-dispatched` and never retries automatically.

The wrapper limits buffered output and requests child termination with Node's default `SIGTERM` on timeout. A child
that handles or ignores that signal can outlive the timeout; a supervising application needing a hard deadline must
also supervise termination. Neither terminating the CLI nor losing its response cancels work already accepted by a
Bridge host. A timeout, signal, overflow, malformed response, or transport failure may occur **after** input was sent.
Do not restart the same mutation automatically. Set the wrapper timeout longer than the command's own deadline and
allow cleanup time; use a separately chosen budget for long Agent runs. Keep screenshot bytes out of this JSON wrapper:
save images with `--path` or use `--tree --no-screenshot`, rather than `--path -`. Raise output limits only for a measured
need.

## Observe, act once, observe again

Select an intended app and exact window from the noun-based inventories (`app list`, `window list`, and `screen list`).
Use the opaque element IDs and `ps1_…` snapshot reference returned by the current observation; never synthesize them.
A screenshot or partial Accessibility tree alone does not grant mutation authority. Require a reusable snapshot and
the relevant actionable evidence.

Snapshots are producer-bound, not portable files. `--bridge-socket` checks only the named host; `--no-remote` checks
only the caller-local manager. Both refuse a snapshot they do not own. An old reference is not repaired by changing
flags, substituting `latest`, or copying its cache directory. Observe again on the intended host after resolving the
underlying problem.

After a mutation, run `see` again before deciding on another action. A pending action or an outcome requiring fresh
observation consumes the old snapshot for mutation; read-only inspection may remain available. Even a successful
action can change focus, elements, or geometry. Do not capture once and batch unrelated clicks or typing from that map.

This example replaces one known, non-secure field in an already-open exact window. It requires a unique stable AX
identifier observed on that field. Save it as `replace-field.mjs` beside the runner, and call it only for the app/window
and text you intend to change. It stops on any failure rather than replaying input.

```javascript
export async function replaceField(peekaboo, { app, windowId, fieldIdentifier, text }) {
  if (typeof fieldIdentifier !== 'string' || !fieldIdentifier || typeof text !== 'string') {
    throw new Error('Supply a nonempty field identifier and replacement text');
  }
  const observe = () => peekaboo(['see'], [
    '--app', app, '--window-id', String(windowId), '--tree', '--no-screenshot',
  ]);
  const requireSnapshot = (observation) => {
    const data = observation.data;
    if (!data?.snapshot_reusable || !data.mutation_targeting_available || !data.snapshot_id) {
      throw new Error('Observation does not authorize a mutation');
    }
    return data;
  };

  const before = requireSnapshot(await observe());
  const fields = before.ui_elements.filter((element) => element.identifier === fieldIdentifier);
  if (fields.length !== 1) throw new Error('Expected exactly one observed field');
  await peekaboo(['click'], ['--on', fields[0].id, '--snapshot', before.snapshot_id]);

  const focused = requireSnapshot(await observe());
  if (focused.focused_element?.identifier !== fieldIdentifier) {
    throw new Error('The fresh observation does not confirm the intended focused field');
  }
  const literalText = text.replaceAll('\\', '\\\\');
  await peekaboo(['type'], ['--snapshot', focused.snapshot_id, '--clear', '--', literalText]);
  return observe(); // Inspect the final observation against the task's expected state.
}
```

Create the runner with `createPeekabooRunner('/absolute/path/to/peekaboo', { bridgeSocket:
'/absolute/path/to/verified/bridge.sock' })`; omit `bridgeSocket` only when normal discovery is intended. Do not mix
host-selection modes within the workflow.

`type` takes positional text. The `--` delimiter keeps leading-hyphen text from being parsed as flags. Peekaboo also
interprets backslash sequences such as `\n` and `\t` as key actions; the example doubles literal backslashes so arbitrary
replacement text does not become those actions. See [type](../commands/type.md) before intentionally sending key
sequences. CLI `type` does not take an element ID: focus the field with `click`, observe again, and use the new snapshot.
Default background-only Agent/MCP typing has the stricter explicit fresh exact non-dialog snapshot policy.

If a step throws, retain `failure.response` and its bounded process diagnostics, inspect current state, and choose the
next action from that evidence. An Agent step-limit failure is partial work, not a rollback. Inspect before resuming a
saved session; a `--no-cache` run is not resumable. Never increase the step limit and blindly rerun the original task.

## Performance and troubleshooting

Prefer exact-window targets and keep the selected host alive. Use `see --tree --no-screenshot` when only Accessibility
metadata is needed, or `see --no-elements --path /absolute/path/capture.png` when only pixels are needed. A pixel-only
observation is not an element map. Measure with `--verbose` on the actual host and app; fixed capture-time promises or
universal CoreGraphics-versus-ScreenCaptureKit speed rankings are not reliable.

For permission failures, compare `bridge status --verbose` with `permissions status --all-sources` and fix the grants
of the process actually doing the work. For missing windows, inspect `window list --app ...`; do not activate an app as
an implicit recovery. For read-only AX timeouts, narrow the target or deliberately increase `see --timeout 30s` and the
outer timeout. For missing producer affinity or `SNAPSHOT_STALE`, obtain fresh evidence on the intended host. None of
these diagnoses authorizes a foreground fallback or automatic mutation retry.

See [Bridge snapshot authority](../bridge-host.md#snapshot-authority), [see](../commands/see.md),
[click](../commands/click.md), [type](../commands/type.md), and [Agent failure traces](../commands/agent.md#json-execution-trace)
for the complete command contracts.
