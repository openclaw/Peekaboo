---
summary: 'Select literal text or place a caret without typing or focusing'
read_when:
  - 'selecting text or placing a caret in an observed element'
---

# `peekaboo select-text`

`select-text` changes only an element's native `AXSelectedTextRange`. It does not activate or focus the app,
synthesize keys, change text, or touch the clipboard. The equivalent MCP tool is `select_text`.

```bash
peekaboo select-text "hello" --on "$ELEMENT_ID" --snapshot "$EXACT_WINDOW_SNAPSHOT"
peekaboo select-text "hello" --on "$ELEMENT_ID" --prefix "Say " --selection-type cursor_after
peekaboo select-text "hello" --on "$ELEMENT_ID" --suffix " world" --selection-type cursor_before
```

`<text>` is a nonempty literal. `--prefix` and `--suffix` constrain the immediately adjacent literal context;
exactly one occurrence must remain. Matching is case-sensitive and does not normalize Unicode. Missing and
ambiguous matches refuse before input. `--selection-type` is `text` (default), `cursor_before`, or `cursor_after`.
MCP uses the same values in `selection_type`.

`--on` accepts an observed element ID or unique query. Use a fresh complete exact-window snapshot with
`--snapshot`, reuse the latest unmodified snapshot, or supply the ordinary app/window target flags for a fresh
targeted observation. A concrete snapshot cannot be combined with target flags. Process-only snapshots are
insufficient. There is no foreground or keyboard fallback.

Selection is always native `actionOnly`, independently of global or per-app input delivery preferences. Those
preferences continue to govern the existing key, mouse, value, and named-action operations; they do not give
`select-text` a synthesis route.

The element must expose readable nonsecure string content, a readable selection, and a settable
`AXSelectedTextRange`. Its `AXValue` need not be writable, and it need not already have keyboard focus. Apps,
including web views, that do not expose those native attributes are unsupported; Peekaboo does not obtain focus
or use browser/keyboard tricks to emulate support. Secure or unreadable security metadata refuses.

The retained element, process generation, window receipt, exact UTF-16 source text, and source selection are
revalidated before a single write. A desired range already reached is a zero-write no-op. Accepted writes are
observed for up to 250 ms; success requires both the requested range and unchanged UTF-16 text. An unconfirmed
write remains indeterminate and retry-unsafe. Observe again before retrying; the old snapshot cannot be replayed.

JSON includes `textSelection` with `matchedRange`, `selectedRange`, and `selectionType`, alongside the ordinary
canonical outcome and target receipt. MCP includes `matched_text_range`, `selected_text_range`, and
`selection_type`. Locations and lengths are UTF-16 code units; a caret has length zero. No source text is returned.
Remote selection requires Bridge protocol 1.42, the `textSelection` capability, and attested element-mutation
outcomes. Older hosts refuse before dispatch.
