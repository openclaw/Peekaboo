---
summary: 'Exercise Peekaboo visual feedback animations via peekaboo visualizer'
read_when:
  - 'verifying Peekaboo.app overlay rendering'
  - 'debugging visualizer transport/animations'
---

# `peekaboo visualizer`

Runs a lightweight smoke sequence for the three v4 visualizer surfaces: the agent cursor, app-anchored input HUD, and capture indicators.

## What it does
- Connects to the visualizer host (typically `Peekaboo.app`)
- Emits representative cursor, input HUD, and capture-indicator events

## Usage
```bash
peekaboo visualizer
peekaboo visualizer --json > .artifacts/playground-tools/visualizer.json
```

## Notes
- This is primarily a manual visual check: success means the command exits 0, dispatches all visualizer events, and you can see the overlay sequence render.
- If the visualizer host is not available, the command fails fast instead of pacing through the full animation sequence.
- If nothing appears, verify:
  - `Peekaboo.app` is running and reachable
  - permissions are granted (`peekaboo permissions status`)
  - your screen isn’t being captured by another app that blocks overlays
