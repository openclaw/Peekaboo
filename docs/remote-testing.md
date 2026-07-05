---
summary: 'Review Remote Testing Playbook guidance'
read_when:
  - 'planning work related to remote testing playbook'
  - 'debugging or extending features described here'
---

## Remote Testing Playbook

This document captures the current workflow for running Peekaboo’s SwiftPM test targets on a remote macOS VM over SSH, plus the pitfalls we hit while bringing the VM online.

### 1. Prerequisites

- **Network access**: the VM must be reachable via Tailscale. Verify with `ping 100.64.183.103` (replace with your tailnet IP).
- **SSH key**: copy your workstation key to the VM (`~/.ssh/authorized_keys`, 600 permissions). All commands below assume you can run `ssh steipete@peters-virtual-machine`.
- **Toolchains**: the VM needs Xcode/Swift toolchains that bundle the Swift Testing framework. On the VirtualBuddy instance we set the command line tools explicitly:
  ```bash
  sudo xcode-select --switch /Applications/Xcode.app
  xcode-select -p  # confirm path is /Applications/Xcode.app/Contents/Developer
  ```
- **Homebrew (optional)**: installed via `curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash` so we can add tooling later (tmux, pnpm, etc.).
- **Privacy permissions**: macOS only surfaces Accessibility / Screen Recording prompts in the GUI session. If you skip this step when driving tests over SSH, the CLI is denied access and the suite hangs. See [Granting privacy permissions](#granting-privacy-permissions-required-for-automation).

### 2. Sync the Repository

From the local checkout:
```bash
rsync -az --delete \
  --exclude '.build' --exclude 'DerivedData' --exclude '.DS_Store' \
  ./ steipete@peters-virtual-machine:Projects/peekaboo
```
This keeps the remote tree in lock-step with `main`, including submodules.

### 3. Running the “Safe” (Non-Automation) Test Set

```bash
ssh steipete@peters-virtual-machine \
  'cd ~/Projects/peekaboo/Apps/CLI && swift test -Xswiftc -DPEEKABOO_SKIP_AUTOMATION'
```

Hints:
- The `-DPEEKABOO_SKIP_AUTOMATION` flag matches local CI defaults and compiles only `CoreCLITests`.
- With Swift 6.2 / Swift Testing we had to enable the feature in `Package.swift` via `.enableExperimentalFeature("SwiftTesting")`. Without that, the remote build dies with `no such module 'Testing'`.
- If you want a log, send output to a file (`… > /tmp/peekaboo-safe.log`).

### 4. Running read-only automation checks

To exercise commands that only query system state (help text, listing apps/spaces, JSON output validation) without triggering UI changes, run:

```bash
pnpm run test:automation:read
```

This sets `RUN_AUTOMATION_READ=true` and executes the automation target. Tests that would click, drag, or launch apps are skipped.

### 5. Running the Full Automation Suite

If you just want the CLI automation target (without local UI interaction), the existing script still works:

```bash
ssh steipete@peters-virtual-machine \
  'cd ~/Projects/peekaboo/Apps/CLI && PEEKABOO_INCLUDE_AUTOMATION_TESTS=true swift test'
```

`PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` only compiles the automation test target. Tests
that synthesize keyboard or mouse input require the additional
`PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true` opt-in.

Input automation has a second safety gate: the frontmost app must be one of the
known test hosts (`boo.peekaboo.playground`, `boo.peekaboo.playground.debug`, or
`boo.peekaboo.peekaboo.testhost`). This prevents typing/clicking into the
operator's active app. To use another disposable host, set
`PEEKABOO_INPUT_AUTOMATION_ALLOWED_BUNDLE_IDS=com.example.Host`. Only set
`PEEKABOO_ALLOW_UNSAFE_INPUT_AUTOMATION=true` in a throwaway UI session.

For **full local automation** (UI-driven cases that expect a real display) we added a convenience script to `package.json`. It builds the CLI, points tests at the actual binary, and sets the right env vars:

```bash
pnpm run test:automation:local
```

This must be executed either:

- From an interactive Terminal on the VM (preferred), or
- Over SSH after privacy permissions have been granted and you’ve started a tmux session to keep the job alive.

`pnpm run test:automation:local` writes logs to `~/Projects/peekaboo/logs/automation-<timestamp>.log`. Tail the file while it runs to watch progress.

Warnings & learnings:
- The automation suite is heavy and may hang the VirtualBuddy UI if permissions are missing; watch the log for stalled commands.
- Running inside tmux (`brew install tmux`) is recommended so a frozen SSH session doesn’t kill the run.
- Grant Accessibility/Screen Recording before launching the script; otherwise macOS silently denies UI automation.

### 6. Diagnosing the Remote Environment

- `xcode-select -p` confirms which command line tools SwiftPM uses.
- `swift --version` prints the Swift toolchain (currently Swift 6.2.1 on the VM).
- If you need a visual check, Peekaboo can ironically be pointed at the VirtualBuddy UI to screenshot status dialogs.

### 7. Known Issues & Follow-up

- **Automation freeze**: investigate why `swift test` stalls during automation runs in VirtualBuddy (possibly accessibility permissions or long-running UI automation).
- **Tooling gaps**: install tmux and pnpm on the VM for parity with the Mac Studio workflow.
- **Logs**: standardize capturing test output under `/tmp/peekaboo-*.log` so multiple operators can review results.
- **Risky suites**: see the table below—anything marked *High* should only run on a disposable VM snapshot.

### Quick Checklist

1. `ssh steipete@peters-virtual-machine` works (authorized key + Tailscale).
2. `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`.
3. `rsync … ./ steipete@peters-virtual-machine:Projects/peekaboo`.
4. Safe suite: `swift test -Xswiftc -DPEEKABOO_SKIP_AUTOMATION`.
5. Automation suite (optional): `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true swift test`; add `PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true` only with a frontmost allowed test host, or in a disposable UI session with `PEEKABOO_ALLOW_UNSAFE_INPUT_AUTOMATION=true`.
6. Capture output for each run and file it in `/tmp` for later inspection.

Following this flow we successfully ran the non-automation tests remotely; automation still needs stabilization once the VM finishes freezing issues.

### Granting privacy permissions (required for automation)

macOS’ Transparency, Consent, and Control (TCC) framework **never** displays prompts to headless sessions. Launching automation over SSH without first approving the binaries leads to immediate hangs because helper processes (e.g. `swift-run peekaboo …`) are denied Accessibility / Screen Recording access. Fix:

1. Connect via Screen Sharing or VirtualBuddy and log in as the test user.
2. Open **System Settings → Privacy & Security** and visit **Accessibility**, **Screen Recording**, and **Automation** (optionally **Full Disk Access** if needed).
3. Add and enable these executables (update paths if SwiftPM rebuilds into a new folder):
   ```
   ~/Projects/peekaboo/Apps/CLI/.build/arm64-apple-macosx/debug/peekaboo
   ~/Projects/peekaboo/Apps/CLI/.build/arm64-apple-macosx/debug/peekabooPackageTests.xctest/Contents/MacOS/peekabooPackageTests
   /Applications/Xcode.app/Contents/Developer/usr/bin/swift
   /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
   ```
4. Relaunch the automation suite (from SSH or local Terminal); no prompts reappear once these executables are approved.

> There is no supported way to approve these prompts purely over SSH. If GUI access is impossible, pre-approve via an MDM/PPPC profile or script the System Settings UI while logged in locally.

### Automation suite risk map

| Suite (file) | Env gate | UI/system impact | Risk |
|--------------|----------|------------------|------|
| `AgentIntegrationTests.swift` | `RUN_AGENT_TESTS=true` + LLM API key | Launches TextEdit/Safari, types, minimizes windows | **High** |
| `AgentMenuTests.swift` | `RUN_LOCAL_TESTS=true` + LLM API key | Launches Calculator/TextEdit, agent drives menus | **High** |
| `AppCommandTests.swift` (integration section) | `RUN_LOCAL_TESTS=true` | Launch/quit/hide/show TextEdit (with `--save-changes`) | **High** |
| `DragCommandTests.swift` (integration section) | `RUN_LOCAL_TESTS=true` | Real drag gestures, can drop to Trash | **High** |
| `FocusIntegrationTests.swift`, `ClickCommandFocusTests.swift` | `RUN_LOCAL_TESTS=true` | Generates mouse/keyboard events to focus Finder/TextEdit | **High** |
| `MenuCommandTests.swift` (integration) | `RUN_LOCAL_TESTS=true` | Navigates Finder menus | **Medium–High** |
| `DialogCommandTests.swift` (integration) | `RUN_LOCAL_TESTS=true` | Interacts with active dialogs | **Medium** |
| `WindowCommandTests.swift` (local integration) | `RUN_LOCAL_TESTS=true` | Moves/minimizes TextEdit windows | **Medium** |
| `SeeCommandAnnotationIntegrationTests.swift` | Disabled by default; needs `RUN_LOCAL_TESTS=true` | Launches Safari to capture screenshots | **Medium** |
| `ScreenshotValidationTests.swift`, `AnnotationIntegrationTests.swift` | `RUN_LOCAL_TESTS=true` | Creates temporary NSWindows | **Low** |
| CLI parsing/JSON/configuration suites | none | Pure logic | **Low** |

Only enable the *High*-risk suites when you’re inside a dedicated VM snapshot and expect the UI to shift. Leave `RUN_AGENT_TESTS` unset unless you specifically want to exercise agent-driven flows.
