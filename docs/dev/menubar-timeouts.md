---
summary: 'Troubleshoot menubar listing hangs/timeouts (AXorcist + MenuService fast path).'
read_when:
  - 'peekaboo list menubar hangs or times out'
  - 'debugging Accessibility traversal performance'
---

# Menubar listing hangs / timeouts

If `peekaboo list menubar` (or `peekaboo menubar list`) appears to hang, the most common culprit is **unbounded Accessibility (AX) calls** during element traversal.

## What we changed

- `MenuService.listMenuExtras()` now prefers a **WindowServer-based fast path** (no AX) when it returns results.
- AX-heavy fallbacks (deep app sweep + AX hit-test enrichment) are opt-in via `PEEKABOO_MENUBAR_DEEP_AX_SWEEP=1`.
- AXorcist `Element.children(strict:)` avoids expensive debug formatting work (like `briefDescription(...)`) unless AX logging is actually enabled.

## Debugging checklist

1. Confirm you are running the **freshly-built CLI binary**:
   - Or: `cd Apps/CLI && swift build --show-bin-path` and run the binary from there.
2. If you suspect AX calls are blocking, capture a stack sample:
   - `sample <pid> 5 -file /tmp/peekaboo.sample.txt`
3. Avoid enabling AXorcist verbose logging unless needed; it can dramatically increase AX traffic.
