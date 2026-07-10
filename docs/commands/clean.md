---
summary: 'Prune snapshot caches via peekaboo clean'
read_when:
  - 'saving disk space or nuking stale snapshot artifacts'
  - 'debugging interactions that still reference an old snapshot ID'
---

# `peekaboo clean`

`clean` removes entries from `~/.peekaboo/snapshots/` by age, by ID, or wholesale. Because every `see`/`click` pipeline streams screenshots and UI maps into that cache, it can grow quickly; this command is the supported way to prune it without deleting unrelated files.

## Modes
| Flag | Effect |
| --- | --- |
| `--all-snapshots` | Delete every cached snapshot directory. |
| `--older-than <hours>` | Delete snapshots older than the given hour threshold (defaults to 24 if omitted). |
| `--snapshot <id>` | Remove a single on-disk snapshot by folder name (the `snapshotId` from `see`). |
| `--dry-run` | Print what would be removed without touching disk. |

Only one of the three selection flags may be supplied at a time; the command validates this before doing any IO.

## Implementation notes
- Cleanup work is delegated to `services.files` (`cleanAllSnapshots`, `cleanOldSnapshots`, `cleanSpecificSnapshot`), so it benefits from the same file-locking + sandbox awareness as the rest of Peekaboo.
- Text output summarizes number of snapshots removed and bytes freed (using `ByteCountFormatter`), while JSON output wraps the raw `CleanResult` with an `executionTime` so you can log metrics.
- When `--snapshot <id>` is not found on disk, text output says the ID missed the disk cache and JSON includes `data.not_found: true`. This command does not delete daemon-memory snapshots; that is tracked separately from disk pruning.

## Examples
```bash
# Preview what would be deleted without actually removing files
peekaboo clean --older-than 12 --dry-run

# Remove the snapshot returned from the last `see` run
SNAPSHOT=$(peekaboo see --json | jq -r '.data.snapshot_id')
peekaboo clean --snapshot "$SNAPSHOT"
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
