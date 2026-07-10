---
summary: 'Exercise Peekaboo visual feedback animations via peekaboo visualizer'
read_when:
  - 'verifying Peekaboo.app overlay rendering'
  - 'debugging visualizer transport/animations'
---

# `peekaboo visualizer`

Runs a lightweight smoke sequence that fires a representative set of visualizer events so you can verify Peekaboo’s overlay renderer is working end-to-end.

## What it does
- Connects to the visualizer host (typically `Peekaboo.app`)
- Emits events such as screenshot flash, capture HUD, cursor click, typing overlay, scroll indicator, cursor movement, swipe path, hotkey HUD, window/app/menu/dialog overlays, and a sample element-detection overlay

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
