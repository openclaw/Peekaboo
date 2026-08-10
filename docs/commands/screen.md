---
summary: 'Enumerate connected displays via peekaboo screen list'
read_when:
  - 'mapping global coordinates across Retina or multi-display layouts'
  - 'choosing a display before browser coordinate automation'
---

# `peekaboo screen`

`screen list` reports every connected display with its stable display ID, global logical bounds, scale factor, and primary state. Bare `peekaboo screen` defaults to `screen list`.

## Examples

```bash
# Human-readable display inventory
peekaboo screen list

# Coordinate-mapping fields for automation
peekaboo screen list --json \
  | jq '.data.screens[] | {id: .displayID, bounds, scale: .scaleFactor, main: .isPrimary}'
```

`bounds` and `position` use the same upper-left-origin global logical coordinate space as `click --global`. Multiply dimensions by `scaleFactor` when comparing them with physical-pixel captures. A Retina display can therefore report logical bounds of 1944×1274, scale 2, and a 3888×2548 pixel capture.

For browser pages whose accessibility tree contains no actionable web descendants, pair this inventory with
`peekaboo window list --app <browser> --json`, capture the selected exact window with
`peekaboo see --window-id <id> --no-elements --json`, then use the fresh receipt:

```bash
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at x,y \
  --foreground --input-strategy synthOnly
```
