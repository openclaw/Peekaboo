---
summary: 'Paste text or rich content via peekaboo paste'
read_when:
  - 'you want fewer steps than clipboard set + press-based paste + clipboard restore'
  - 'pasting rich text (RTF) into a targeted app/window without drift'
---

# `peekaboo paste`

`paste` sends Cmd+V. With no payload, it pastes the current clipboard contents. With text, a file, an image, or base64 data, it temporarily replaces the system clipboard, pastes into the target, then restores the previous clipboard items (or clears it if it was empty) only while it still owns that clipboard generation. A newer copy from the user or another app is preserved instead.

This reduces drift by collapsing multiple CLI steps into one command. Plain text uses direct process-targeted typing in background mode. Rich/current-clipboard payloads use Cmd+V. Pass `--foreground` for intentional foreground delivery; this does not guarantee confirmation that the receiving app consumed the paste.

## Key options
| Flag | Description |
| --- | --- |
| `[text]` / `--text` | Plain text to paste; omit payload flags to paste the current clipboard. |
| `--file-path` | Copy a file or image into the clipboard, then paste. |
| `--data-base64` + `--uti` | Paste raw base64 payload with explicit UTI (e.g. `public.rtf`). |
| `--also-text` | Optional plain-text companion when pasting binary. |
| `--restore-delay <duration>` | Delay before restoring the previous clipboard (default `150ms`; bare values are milliseconds; maximum `10000ms`). |
| Target flags | `--app <name>`, `--pid <pid>`, or an exact window selector for background paste. |
| `--foreground` | Focus a supplied target or intentionally send foreground/global Cmd+V. |
| Focus flags | Foreground focus controls (`--space-switch`, `--no-auto-focus`, etc.). |

## Delivery modes
- Bridge requirements apply to the negotiated connection, not just the host's installed version. A current host on a custom socket can be limited to protocol 1.28 by the client's host-trust policy and refuse before clipboard access or input. Inspect the same socket with `peekaboo bridge status --bridge-socket <path>`; see [Bridge host trust](bridge.md#notes).
- **Background** is the default when Peekaboo can resolve a target. Exact-window routes pin the process generation, window ID/bounds, and focused element. App/PID routes upgrade when one eligible window exists and refuse when several are eligible. Plain text is delivered directly without touching the clipboard. Binary/rich and current-clipboard requests remain receiver-unverifiable and return “may have pasted; do not retry” after cleanup.
- **Foreground** (`--foreground`) requires a supplied target to return a confirmed exact-window focus receipt before Cmd+V. A genuinely targetless foreground call remains intentionally global. `--no-auto-focus` cannot be combined with a target because Peekaboo will not guess that the requested window already owns keyboard focus.
- Without an app/PID target, `paste` fails before mutating the clipboard. Add `--foreground` only when global delivery is intentional.
- Exact window selectors stay exact through text or Cmd+V dispatch; focus, owner, generation, or bounds drift fails before clipboard access whenever no event has begun. Exact-window remote delivery requires Bridge protocol 1.24.
- Temporary rich/binary paste to an exact background window requires Bridge protocol 1.41 and prepared clipboard-guarded hotkey support before writing. The host prepares the exact standard window using a target-only activation record and one ordinary window-routed click on observed blank chrome, without moving the physical cursor or requesting foreground activation. Complete bounded AX reads must exclude title, proxy, controls, and content; an exact native window hit and unchanged editor, UTF-16 text, and selection are required. Unverifiable, nonstandard, modal, minimized, or fullscreen windows refuse instead of guessing or restoring stale focus.
- The transaction passes its retained native General-pasteboard write generation to the host, which checks ownership during preparation and before each new key-down. An intervening copy, including identical bytes, stops new input; any keys already down still receive their owed releases. Completed prepared delivery reports eight composite background units (activation 1, pointer 3, chord 4), remains unverified and retry-unsafe, and does not prove app consumption. Preparation can already have had an effect when later input is refused. Current-clipboard, foreground, direct-text and legacy process-only routes retain their existing contracts; the lower-level protocol-1.40 guarded hotkey remains preparation-free with four event units.
- A failed preparation observation (including lost editor focus) retains its underlying diagnostic without claiming that the read itself sent input or requested focus. This host-side observation happens after a temporary clipboard claim may already exist; earlier clipboard effects and any accepted preparation prefix remain observable and retry-unsafe.
- Process-targeted text and Cmd+V delivery retain the resolved app's process-generation receipt. Plain text revalidates before every emitted character, while clipboard-backed paste uses generation-pinned hotkey delivery. A target exit or relaunch never silently retargets the reusable PID. Remote background paste requires Bridge protocol 1.22 or newer.
- Clipboard-backed transactions are serialized across CLI, daemon, and GUI processes with a private per-user lock under `~/Library/Application Support/Peekaboo`, independent of each process's temporary directory.
- Admission shares one 15-second monotonic deadline across the in-process queue and file-lock acquisition. If either wait ends at or after that deadline, even with successful acquisition, Peekaboo refuses before running the transaction body. The canonical `TIMEOUT` is a retry-safe pre-dispatch refusal: this transaction has not changed the clipboard or dispatched paste input, and the timeout alone does not require a fresh observation.
- Target and temporary-clipboard ownership capabilities, cancellation checks, and a complete prior-clipboard snapshot must succeed before Peekaboo writes a temporary payload. Providers without ownership-aware temporary writes refuse rather than falling back to unconditional restoration. Every advertised representation must be readable: an unresolved promised type refuses temporary replacement without dropping it or treating unavailable data as empty. Lazy providers that supply data and zero-length data representations are supported.
- On macOS 15.4+, automatic General-clipboard replacement and current-clipboard reads require the reader's native access policy to be `alwaysAllow` before any contents are inspected. `default`, `ask`, and `alwaysDeny` refuse with `permission_denied`, including an empty clipboard and explicit foreground paste. This avoids deliberately triggering a permission alert; it is not an atomic guarantee against a concurrent permission-setting change. Use `clipboard status` for a content-free caller-local diagnostic; paste never opts into a permission alert. Named pasteboards remain exempt, and macOS 14–15.3 has no equivalent native access-policy preflight.
- Partial-write failures retain the actual native clipboard claim. Cleanup restores only that owned generation; a failure before any claim does not restore or clear anything. If another app has replaced the payload, cleanup leaves the newer contents untouched and reports `preserved_newer_contents`, even when the replacement has identical bytes.
- Background binary/rich paste still mutates the system clipboard briefly; `paste` completes the noncancellable `--restore-delay` settle and ownership-aware cleanup before releasing the transaction lock, even when delivery throws or the caller cancels. The admission deadline does not time out this already-admitted settle/cleanup phase or bound the whole command.
- Clipboard generation checks detect intervening ownership changes, but macOS exposes no atomic compare-and-swap for restoring a pasteboard. The adjacent check/write calls cannot exclude every concurrent cross-process race; the transaction lock only serializes cooperating Peekaboo paste clients. Explicit manual `clipboard restore` remains an intentional overwrite operation.

## Examples
```bash
# Paste the current clipboard into the focused app
peekaboo paste --foreground

# Paste plain text into TextEdit
peekaboo paste "Hello, world" --app TextEdit

# Paste rich text (RTF) into a specific window title
peekaboo paste --data-base64 "$RTF_B64" --uti public.rtf --also-text "fallback" --app TextEdit --window-title "Untitled"

# Paste a PNG into Notes using foreground delivery; verify the result afterward
peekaboo paste --file-path /tmp/snippet.png --app Notes --foreground

# Force foreground paste for apps that ignore background Cmd+V
peekaboo paste "Hello" --app TextEdit --foreground
```

### HTML with formatting and a hyperlink

Use `public.html` to insert a complete rich-text fragment at the current selection. In Notes, this avoids replacing the note's entire HTML body just to add a link. First open a disposable note in its own window, obtain its exact window ID, focus the editor, and place the caret where the fragment should go. Pasting replaces selected text, if any.

```bash
# Replace this with the observed disposable note's window ID.
NOTE_WINDOW_ID=12345
HTML_B64=$(python3 - <<'PY'
import base64

html = '''<html><head><meta charset="utf-8"></head><body>
<p><b>Rich paste test</b></p>
<p><a href="https://example.com/">Example &#8212; linked text</a></p>
<p><i>Formata&#231;&#227;o preserved.</i></p>
</body></html>'''
print(base64.b64encode(html.encode("ascii")).decode("ascii"))
PY
)
peekaboo paste --data-base64 "$HTML_B64" --uti public.html \
  --app Notes --window-id "$NOTE_WINDOW_ID" --foreground --json
```

Declare the HTML charset; numeric character references also keep the payload ASCII-safe. For a local-file link, use a properly URL-encoded `file:///absolute/path/to/file` in `href`. The link does not upload or share the file with collaborators.

In a manual Notes test with Peekaboo 4.5.0 on macOS 26.7, an inserted HTML fragment preserved bold, italic, a local-file hyperlink, and existing checked/unchecked items. This tests insertion into an existing note, not reconstruction of native checklists from HTML. The command still returned `INTERACTION_FAILED` even though independent UI inspection confirmed the inserted fragment.

## Notes
- Built-in Agent and public MCP remain direct-text-only by default. Their trusted `--allow-temporary-clipboard` flag
  additionally exposes bounded `dataBase64` + `uti` paste with a fresh exact non-dialog/non-system-UI `snapshot`,
  optional `alsoText`, and a bounded restore delay. That model-facing form rejects app/PID/window selectors,
  file/image paths, `allowLarge`, current-clipboard paste, and foreground input. It uses this command's existing
  ownership-aware transaction and prepared exact-window route; it does not change standalone CLI authorization.
- Restore delays must be between `0` and `10000ms`, inclusive. Existing CLI scripts or MCP callers using longer delays must reduce them; invalid values fail before clipboard access or input delivery. Direct calls to the shared consumption-wait helper are capped at 10 seconds as a backstop.
- File paths for `--file-path` accept `~/...`.
- Successful background text JSON reports delivery mode and target PID. Clipboard-backed background delivery returns `INTERACTION_FAILED` with the explicit retry-unsafe message instead of a success payload.
- JSON preserves a typed `TIMEOUT` even if a later input-lane wait expires after foreground focus has already changed the desktop. Check the canonical outcome and retry metadata: an earlier dispatched phase still makes the overall request indeterminate and unsafe to retry.
- A canonical no-dispatch refusal with no prior focus effect or attempted clipboard write preserves implicit observations, including wrapped target-resolution refusals and background text. Stronger aggregate or retry-unsafe metadata, partial clipboard writes, and unclassified input failures still invalidate conservatively, and another operation's pending mutation barrier is never canceled by this refusal.
- After Cmd+V dispatch begins, cancellation or a delivery error is indeterminate. A clipboard restoration failure is always reported with a canonical partial or indeterminate retry-unsafe outcome, including for receiptless providers. Inspect fresh UI state rather than replaying the paste.
- A dispatched targeted hotkey's non-confirmed outcome retains the runtime's reported process-generation or exact-window `target_receipt`, including current-clipboard paste and temporary payloads after cleanup reports `restored` or `preserved_newer_contents`. This identifies the input receiver for fresh observation; it does not confirm consumption or attribute shared clipboard changes to that receiver.
- Cleanup status is separate from input success. CLI successful payloads include `clipboardCleanupStatus`, CLI error JSON includes `error.clipboard_cleanup_status`, and public MCP plus model-facing Agent tool-error metadata preserve `clipboard_cleanup_status`: `restored`, `preserved_newer_contents`, or `not_needed`. The Agent's final JSON execution trace retains its smaller status-summary allowlist. Unknown or malformed cleanup values are omitted. A newer clipboard update never reports restoration success. A partial temporary write remains retry-unsafe even if no Cmd+V was sent; an error retains no prior clipboard payload.
- A canonical hotkey refusal after a temporary clipboard write cannot erase that earlier clipboard effect. The failure retains its error code but reports the caller-local clipboard mutation as retry-unsafe, without inventing a Cmd+V dispatch or exact receiver count. When an earlier window-focus action is combined with this untargeted clipboard effect, the aggregate does not inherit that focus window as its target or report an exact combined count. Refusals before any clipboard claim remain zero-dispatch and retry-safe.

## Custom clipboard providers

Temporary-payload paste now requires `ClipboardTemporaryWriteProviding` in addition to the existing `ClipboardServiceProtocol`. This is an intentional safety boundary: the old `get`/`set`/`save`/`restore` interface cannot establish whether another application has claimed the clipboard. There is no unconditional-restore fallback. Plain background text and current-clipboard paste do not require the new capability.

The built-in `ClipboardService` already implements the capability. Native wrappers should use that implementation for the same pasteboard as their existing methods and forward preparation:

```swift
// In an existing @MainActor wrapper conforming to ClipboardTemporaryWriteProviding:
func prepareTemporaryWrite() throws -> any ClipboardTemporaryWriteTransaction {
    try self.nativeClipboard.prepareTemporaryWrite()
}
```

A custom backend must return a transaction that records the actual write claim even on partial failure, fences complete prior contents, preserves newer ownership, and performs one-shot cleanup independently of task cancellation. Do not implement this by wrapping the old unconditional restore sequence. Unsupported-provider refusals occur before clipboard reads, focus setup, or paste input; they are not a reason to retry with foreground authority.

Temporary exact-window background paste also requires that transaction to conform to `ClipboardTemporaryWriteClaimProviding`.
Its `writeWithClaim` returns both the write result and the General pasteboard generation retained at native declaration.
Do not resample the clipboard after writing to construct this claim: another writer may already own that generation.
Named-pasteboard transactions cannot provide a General-pasteboard claim. A transaction without the refinement refuses
before its write; the capability does not grant clipboard-reading permission or move restoration to the Bridge host.

## Troubleshooting
- `Paste hotkey did not return a confirmed outcome.` does not prove that nothing was pasted, including with `--foreground`. Inspect `mutation_dispatched`, `retry_safe`, and `requires_fresh_observation`, then inspect the exact target's current contents before deciding what to do next. Do not automatically replay a retry-unsafe paste: the fragment may already be present. Foreground focus confirmation and receiver consumption are separate facts.
- If silent clipboard access is unavailable, arrange the reader's permission deliberately outside automation. An application still at `default` may not yet appear in System Settings because it has never shown a clipboard access alert. Peekaboo does not open settings, manufacture an alert, or change that policy automatically. Allowing the GUI host does not necessarily allow a separate caller-local clipboard reader.
- If a complete prior snapshot is unavailable, keep the original clipboard intact and resolve the supplying application's unreadable/promised data before trying temporary replacement. Changing foreground mode does not make an incomplete snapshot safe to discard.
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Background paste also requires Event Synthesizing access for the sending process; request it with `peekaboo permissions request event-synthesizing`.
- Confirm your target with `peekaboo app list`, `peekaboo window list`, or `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
