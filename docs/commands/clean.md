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
| `--all-snapshots` | Delete every producer-owned or cleanup-eligible legacy snapshot directory. |
| `--older-than <hours>` | Delete eligible snapshots older than the given hour threshold (defaults to 24 if omitted). |
| `--snapshot <id>` | Remove one eligible on-disk snapshot: a producer-owned `ps1_` reference or a strict legacy timestamp directory. |
| `--dry-run` | Print what would be removed without touching disk. |

Only one of the three selection flags may be supplied at a time; the command validates this before doing any IO.

Current snapshot references use exactly `ps1_` followed by 32 lowercase ASCII hexadecimal digits. Cleanup removes one
only when its on-disk producer marker binds the directory to that same reference. The 128-bit random reference is
reserved by its producer before snapshot data is stored; an unowned lookalike directory is ignored.

For migration cleanup only, `clean` also recognizes the old timestamp shape: exactly 13 decimal digits, a hyphen, and
4 decimal digits, such as `1787675983803-1514`. That directory must contain a regular, non-symlink `snapshot.json`.
Legacy timestamp IDs are not listed as usable snapshots and cannot be passed to interaction commands. Arbitrary names,
empty values, `.`/`..` traversal, nested or absolute paths, control characters, symlinks, and malformed legacy
directories are rejected or ignored without deleting them.

## Implementation notes
- Cleanup work is delegated to `services.files` (`cleanAllSnapshots`, `cleanOldSnapshots`, `cleanSpecificSnapshot`); specific-snapshot cleanup validates ownership or the strict legacy shape before either previewing or deleting it.
- `--all-snapshots` and age cleanup remove only producer-owned current directories or cleanup-eligible legacy
  directories. They leave unowned `ps1_` lookalikes and unrelated cache entries untouched.
- Text output summarizes number of snapshots removed and bytes freed (using `ByteCountFormatter`), while JSON output wraps the raw `CleanResult` with an `executionTime` so you can log metrics.
- A valid `--snapshot <id>` that is not found on disk succeeds with zero removals: text output says the ID missed the disk cache and JSON includes `data.not_found: true`. This command does not delete daemon-memory snapshots; that is tracked separately from disk pruning.

## Examples
```bash
# Preview what would be deleted without actually removing files
peekaboo clean --older-than 12 --dry-run

# Remove the snapshot returned from the last `see` run
SNAPSHOT=$(peekaboo see --json | jq -r '.data.snapshot_id')
peekaboo clean --snapshot "$SNAPSHOT"

# Preview removal of one strict legacy timestamp directory
peekaboo clean --snapshot 1787675983803-1514 --dry-run
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
