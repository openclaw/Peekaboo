---
summary: 'How Peekaboo generates natural-looking cursor motion'
read_when:
  - 'tuning mouse movement heuristics'
  - 'debugging human-style pointer paths'
---

# Human-Style Mouse Movement

Peekaboo's `human` profile makes cursor motion look hand-driven without forcing users to juggle dozens of tuning flags. It builds on three ideas:

1. **Distance-aware pacing** - Short hops complete in ~300 ms while multi-display traversals stretch toward 1.5 s, following a loose Fitts-style curve.
2. **Organic paths** - A shallow Bézier arc uses minimum-jerk timing for quick acceleration and a precise settle, with one optional subtle overshoot.
3. **Micro-jitter** - Low-amplitude perpendicular noise tapers to zero near the destination, and the final event is always the exact requested point.

## Using the profile

- **CLI**: use `--smooth` for a natural `peekaboo move`, or add `--profile human` to `move`, `drag`, or `swipe`. Duration/sample counts pick sensible defaults per distance. Explicit `--duration` and `--steps` values are honored; human paths never emit more than 96 samples.
- **Agents / MCP**: include `"profile": "human"` in the move/drag/swipe tool arguments. Optional `duration` and `steps` fields work the same way as in the CLI-you only need them when you want to clamp the adaptive heuristics.

## Defaults at a glance

| Distance | Typical Duration | Typical Steps | Notes |
| --- | --- | --- | --- |
| < 200 px | 280-350 ms | 30-40 | Minimal overshoot; jitter keeps subtle motion. |
| 200-800 px | 400-900 ms | 40-80 | Overshoot only triggers when the hop is long enough to look intentional. |
| > 800 px | 900-1700 ms | 80-96 | Velocity eases into and out of the target without redundant events. |

Additional details:
- Overshoot probability starts near 0 for short hops and tops out around 20 % for long moves. When it fires, the cursor glides slightly past the destination before recentering.
- Jitter amplitude is capped at ~0.35 px per frame so it never visibly shakes; it simply breaks up ruler-straight lines.
- Randomness comes from a seeded generator. When the caller doesn't supply a seed, Peekaboo derives one from wall-clock time, so runs feel unique while tests can still inject deterministic seeds via `MouseMovementProfile.human(HumanMouseProfileConfiguration(randomSeed: ...))`.

## When to prefer other profiles

- Omit movement flags for an instant pixel-perfect hop. Use **`--profile linear`** with `--smooth` or `--duration` when an animated path must stay straight.
- Use **`--smooth`** or **`--profile human`** for menu exploration and demos where observers expect believable pointer motion.

For implementation details or to tweak the heuristics, see `GestureService.moveMouse` in `PeekabooAutomation`. Most adjustments boil down to the duration curve, overshoot probability, or jitter amplitude constants described above.
