---
summary: 'Agentic improvements: desktop context injection, tool gating, and verification loops (research + plan)'
read_when:
  - 'planning improvements to Peekaboo agent runtime'
  - 'auditing prompt-injection risks from desktop context'
  - 'wiring verification/smart-capture into tool execution'
---

# Agentic improvements (research + plan)

Scope: what PR #47 introduced, what we shipped to `main`, what is still missing, and a pragmatic plan for next iterations.

This doc is intentionally biased toward:

- security boundaries (indirect prompt injection),
- least privilege (tool exposure + data exposure),
- reliability (verification loops + smarter capture),
- minimal UX surface area (simple defaults; optional knobs).

## Current state (what shipped)

### Desktop context injection (`DESKTOP_STATE`)

Implemented in `Core/PeekabooCore/Sources/PeekabooAgentRuntime/Agent/PeekabooAgentService+Streaming.swift`.

Behavior:

- Gather lightweight desktop state: focused app/window title, cursor position.
- **Clipboard preview is included only when the `clipboard` tool is enabled** (tool-gated).
- Injected as **two messages**:
  - **System policy** message: declares `DESKTOP_STATE` as *untrusted data*; never instructions.
  - **User data** message: payload is **nonce-delimited** (`<DESKTOP_STATE …>…</DESKTOP_STATE …>`) and **datamarked** (every line prefixed with `DESKTOP_STATE | `).

Rationale:

- Window titles / clipboard contents are classic *indirect prompt injection* vectors.
- Keep “policy” stable and high-priority (system).
- Keep *untrusted content* out of system/developer tiers (data is user-role), while still providing provenance signals (delimiters + datamarking).

Docs:

- `docs/security.md` (section “Desktop context injection (DESKTOP_STATE)”).

### PR #47 “enhancements” scaffolding

PR #47 introduced these types and helpers. The production streaming path now passes
`AgentEnhancementOptions` and calls `executeToolWithVerification`; the uncalled
`runEnhancedStreamingLoop` compatibility wrapper was later removed in the v4 dead-code sweep.

- `AgentEnhancementOptions`
- `SmartCaptureService` (diff-aware capture, region capture)
- `ActionVerifier` (post-action screenshot verification via AI)
- `PeekabooAgentService+Enhancements.swift` verification helpers

## What did not ship from PR #47

Intentionally not carried over from the original PR diff:

- `Core/PeekabooCore/Package.resolved` (avoid unrelated dependency churn; upstream already moved on).
- `Core/PeekabooCore/Sources/PeekabooXPC/PeekabooXPCInterface.swift` (obsolete: Peekaboo v3 beta2 moved to the Bridge socket host model; XPC helper path removed).

## Problem framing

Peekaboo is an *agentic* system with:

- a long-running model loop,
- powerful local tools (click/type/shell/dialogs/files/clipboard/etc),
- real-world untrusted inputs (window titles, clipboard, filesystem names, OCR text, web pages),
- and real consequences (data exfil, destructive actions).

We’re optimizing for “safe enough by default” while staying ergonomic.

## Threat model (prompt injection)

Primary risk: **indirect prompt injection**.

Attackers can place adversarial instructions into data the agent will observe:

- window titles (e.g., a malicious tab title),
- clipboard contents,
- menu item names, file names, document contents,
- OCR / screen text,
- external MCP tool results.

Goal: trick the model into treating untrusted content as higher-priority instructions, resulting in:

- data leakage (clipboard/file contents to a remote model or tool),
- unsafe tool calls (shell/file writes/dialog confirmations),
- workflow derailment.

## Research notes (quick links)

These are the most relevant external references for our current design choices and next steps:

- Microsoft Research: “Spotlighting” defenses (delimiting, datamarking, encoding).  
  - Paper: https://www.microsoft.com/en-us/research/publication/defending-against-indirect-prompt-injection-attacks-with-spotlighting/  
  - MSRC blog explainer: https://msrc.microsoft.com/blog/2025/07/how-microsoft-defends-against-indirect-prompt-injection-attacks/
- OpenAI API docs: “Safety in building agents” (notably: don’t put untrusted input in developer messages; keep tool approvals on; use structured outputs).  
  - https://platform.openai.com/docs/guides/agent-builder-safety
- OpenAI safety overview: prompt injections, confirmations, limiting access.  
  - https://openai.com/safety/prompt-injections/  
  - Atlas hardening (agent browser): https://openai.com/index/hardening-atlas-against-prompt-injection/
- Anthropic research: browser-use prompt injection defenses + reality check (“far from solved”).  
  - https://www.anthropic.com/research/prompt-injection-defenses
- OWASP GenAI: Prompt Injection (LLM01).  
  - https://genai.owasp.org/llmrisk2023-24/llm01-24-prompt-injection/

## Improvement ideas (what to do next)

### 1) Make desktop context a tool result (stronger provenance boundary)

Current: system policy + user data message with delimiters/datamarking.

Proposed: model sees desktop state as a **tool result** (role `.tool`, `toolResult` content), generated by the host.

Why:

- “Tool output” is a clearer channel boundary than “user text”.
- Easier to audit (“this came from a tool”) and to apply uniform redaction/size limits.
- Aligns with OWASP “trust boundaries” guidance: treat external content and tool results as data, not instructions.

Sketch:

- Add an internal tool concept (not necessarily exposed) like `desktop_state`.
- Streaming loop:
  - emits the **policy** system message once per loop/session (or per injection if needed),
  - then appends a `.tool` message carrying the payload via `.toolResult(...)`.
- Keep Spotlighting-style markers (nonce delimiter + datamarking) inside the tool payload anyway (defense-in-depth).

Notes:

- This is compatible with “If clipboard tool enabled → include clipboard preview”.
- Avoids claiming “system message contains desktop truth” (it doesn’t; it’s untrusted observations).

### 2) Expand spotlighting modes (optional, targeted)

We currently do:

- delimiting (random nonce delimiters),
- datamarking (line prefix).

Consider adding **encoding** (Spotlighting “encoding mode”) for fields that are most injection-prone:

- clipboard preview,
- window title.

Example:

- include both plain + base64, or base64-only with explicit decode instructions:
  - `clipboard_preview_b64: …`
  - `window_title_b64: …`

Tradeoffs:

- encoding can reduce “looks like instructions” risk,
- but adds friction/debuggability cost,
- and can push token usage up.

Recommendation: keep current approach as default; add encoding only if we see real prompt injection incidents from desktop strings.

### 3) Tighten data minimization knobs (still simple)

Keep Peter’s simplicity rule: “If `clipboard` tool enabled → inject clipboard; else don’t.”

Add only minimal guardrails around that:

- hard cap `maxClipboardPreviewChars` (e.g., 200–500 chars),
- explicitly label clipboard as “preview only” and “untrusted” (already covered by policy),
- consider basic secret heuristics (optional):
  - obvious JWT/keys patterns => redact,
  - long base64 blobs => truncate.

Goal: reduce accidental leakage when clipboard contains secrets.

### 4) Wire verification into the real tool-call loop (selective, bounded)

What exists:

- `ActionVerifier` can capture a post-action screenshot and ask a model to judge success.
- `executeToolWithVerification(...)` exists in `PeekabooAgentService+Enhancements.swift`, but is not called from the real streaming loop.

What’s missing:

- integration into `handleToolCalls(...)` / tool execution path.

Proposed wiring (minimal viable):

- For each tool call:
  - execute tool normally,
  - if `enhancementOptions.verifyActions == true` and tool is mutating:
    - capture *after-action* screenshot (prefer region around action point if available),
    - run a cheap verification model,
    - append verification result as:
      - tool result metadata, or
      - a dedicated `verification` tool result message.
- If verification fails:
  - either re-try tool with bounded retries, or
  - ask model for next step (but in a constrained schema: retry / alternative action / ask user).

Constraints:

- Strictly bounded retries (`maxVerificationRetries`).
- Never block the user’s run solely due to verifier model failure.
- Avoid verifying “read-only” tools.

### 5) Smart capture: privacy + performance wins

Smart capture is a big lever for:

- speed (skip unchanged screenshots),
- privacy (crop to ROI; avoid whole-screen uploads),
- token/cost control.

Follow-ups:

- Region-first capture for mutating actions (`regionFocusAfterAction`), because whole-screen deltas are noisy.
- Add a “smallest adequate capture” heuristic:
  - use a tighter crop when we know target point/element bounds,
  - otherwise fall back to full screen.
- Ensure captures are downscaled (or JPEG) for verification to reduce token + network cost.

### 6) Optional “approvals” for high-risk actions

Peekaboo already supports tool allow/deny filters.

OpenAI guidance (and general agent safety practice) suggests **human confirmation** for consequential actions.

We can add an optional gate without complicating the default:

- config: `agent.approvals = off|consequential|all`
- “consequential” examples:
  - `shell`,
  - destructive file operations,
  - dialog confirmations (save/replace),
  - clipboard writes (set/clear) if we care about user disruption.

In CLI, approvals can be:

- interactive prompt (TTY),
- or require `--yes` / `PEEKABOO_APPROVE_ALL=1` for non-interactive.

### 7) Structured outputs between steps (reduce smuggling channels)

Where the agent makes decisions that drive tool calls:

- enforce JSON schema outputs for “next action” planning,
- validate and clamp tool arguments,
- log rejected plans (debug trace) for future evals.

This reduces prompt injection “instruction smuggling” across nodes.

## Implementation plan (small steps)

1. Consolidate context injection paths:
   - keep `DESKTOP_STATE` in the real streaming loop as the single mechanism,
   - either delete or refactor `injectDesktopContext(...)` to call into the same formatter/policy model.
2. Add “tool-result” variant for desktop context (behind a flag):
   - compare behavior across OpenAI/Anthropic,
   - keep current system policy + user payload as fallback.
3. Wire verification into tool execution (behind `verifyActions` flag):
   - start with `click/type/hotkey/press/scroll/drag`,
   - default off.
4. Smart capture ROI + downscale for verifier.
5. Optional approvals (config + CLI UX).
6. Add tests:
   - placement + gating + payload formatting,
   - verification bounded retry behavior (mock verifier).

## Open questions

- Should `DESKTOP_STATE` be injected once per loop (current) or before each LLM turn?
- Do we treat “window title” as sensitive enough to gate behind a tool (like clipboard), or is it fine as-is?
- Verification model choice:
  - cheapest vision model available,
  - or local/offline (Ollama) when configured?
- How to keep verification from creating privacy regressions (unnecessary screenshot uploads)?
