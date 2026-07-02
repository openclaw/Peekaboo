---
summary: 'Run Peekaboo reliably from subprocess contexts such as Node.js and OpenClaw.'
read_when:
  - 'using Peekaboo from a child process or wrapper script'
  - 'working around Bridge permission failures in automation hosts'
---

# Subprocess Integration Guide

## Problem: Permission Errors from Subprocesses

When running Peekaboo from Node.js, OpenClaw, or other subprocess contexts, you may see permission errors for capture commands (`see`, `image`, `capture`) even though System Settings shows permissions granted.

### Why This Happens

Peekaboo v3 uses a socket-based Bridge architecture:

```
Your Process (Node.js, OpenClaw)
    ↓
peekaboo CLI
    ↓
Peekaboo Bridge (daemon)
    ↓
ScreenCaptureKit ❌ (Bridge lacks TCC grant)
```

macOS grants Screen Recording permission per-process. The Bridge daemon doesn't inherit grants from your parent process.

### Solution: Use Local Mode

Add these flags to bypass Bridge routing:

```bash
--no-remote --capture-engine cg
```

**Example:**
```bash
# Before (may fail)
peekaboo see --app Safari --json

# After (works reliably)
peekaboo see --app Safari --no-remote --capture-engine cg --json
```

## Node.js Integration

### Basic Wrapper

```javascript
const { execSync } = require('child_process');

function peekaboo(command, args = {}) {
    const argList = [
        command,
        '--no-remote',
        '--capture-engine', 'cg',
        '--json',
        ...Object.entries(args).flatMap(([k, v]) => 
            v === true ? [`--${k}`] : [`--${k}`, String(v)]
        )
    ];
    
    const result = execSync(`peekaboo ${argList.join(' ')}`, {
        encoding: 'utf8',
        maxBuffer: 10 * 1024 * 1024 // 10MB for large screenshots
    });
    
    return JSON.parse(result);
}

// Usage
const snapshot = peekaboo('see', { app: 'Safari', annotate: true });
console.log('Captured:', snapshot.data.snapshot_id);
```

### Error Handling

```javascript
function peekabooSafe(command, args = {}) {
    try {
        return peekaboo(command, args);
    } catch (err) {
        const stderr = err.stderr?.toString() || err.message;
        
        // Parse JSON error if available
        try {
            const errData = JSON.parse(stderr);
            throw new Error(`Peekaboo error: ${errData.error?.message}`);
        } catch {
            throw new Error(`Peekaboo failed: ${stderr}`);
        }
    }
}
```

## OpenClaw Integration

### Recommended Pattern

Always use `--no-remote --capture-engine cg` for capture commands:

```bash
# Capture UI
peekaboo see --app Safari --no-remote --capture-engine cg --json

# Click element (doesn't need workaround, but safe to include)
peekaboo click --on "$ELEMENT_ID" --no-remote

# Type text (doesn't need workaround, but safe to include)
peekaboo type --text "Hello" --no-remote
```

## Commands That Don't Need Workaround

These commands work fine without `--no-remote`:

- `peekaboo click` (uses Accessibility API)
- `peekaboo type` (uses Accessibility API)
- `peekaboo hotkey` (uses Accessibility API)
- `peekaboo list apps` (public API)
- `peekaboo permissions` (just reads TCC database)

Only **capture commands** need the workaround:
- `peekaboo see`
- `peekaboo image`
- `peekaboo capture`

## Performance Considerations

### CoreGraphics vs ScreenCaptureKit

| Engine | Speed | Subprocess Compatibility |
|--------|-------|--------------------------|
| ScreenCaptureKit | Fast | ❌ Requires Bridge with TCC |
| CoreGraphics | Slightly slower | ✅ Works in-process |

**Recommendation:** Always use `--capture-engine cg` for subprocess contexts.

Typical timings with CoreGraphics:
- `see`: 300-500ms
- `image`: 200-400ms
- `capture`: Varies by duration

### Optimization Tips

1. **Reuse snapshots**: Store snapshot IDs, pass with `--snapshot <id>`
2. **Batch operations**: Capture once, click multiple times
3. **Avoid unnecessary captures**: Check if you need fresh UI state

## Troubleshooting

### "Window not found" errors

The app might not have visible windows. Check first:

```bash
peekaboo list windows --app Safari --json
```

### Timeout errors

Increase timeout for complex UIs:

```bash
peekaboo see --app Safari --timeout-seconds 30 --no-remote --capture-engine cg
```

### Memory issues (large screenshots)

Increase Node.js buffer:

```javascript
execSync('peekaboo see ...', { 
    maxBuffer: 50 * 1024 * 1024  // 50MB
});
```

## Alternative: Run Peekaboo.app

If you need ScreenCaptureKit performance:

1. Install Peekaboo.app (GUI version)
2. Grant permissions to Peekaboo.app in System Settings
3. Launch Peekaboo.app (keeps Bridge running with permissions)
4. Remove `--no-remote` flag (will use Bridge)

**Pros:** Faster ScreenCaptureKit engine  
**Cons:** Requires GUI app running, more memory

## Example: Complete Workflow

```javascript
const { execSync } = require('child_process');

function run(cmd) {
    return JSON.parse(execSync(cmd, { encoding: 'utf8' }));
}

// 1. Capture Safari UI
const snapshot = run('peekaboo see --app Safari --no-remote --capture-engine cg --json');
console.log('Captured:', snapshot.data.element_count, 'elements');

// 2. Find "Reload" button
const reloadBtn = snapshot.data.ui_elements.find(el => 
    el.label?.includes('Reload')
);

if (reloadBtn) {
    // 3. Click it
    run(`peekaboo click --on ${reloadBtn.id} --snapshot ${snapshot.data.snapshot_id} --no-remote`);
    console.log('Clicked Reload button');
}
```

## Related Issues

- #77 - Documents the subprocess workaround for OpenClaw permission errors
- #75 - Bridge capture failures (related)
