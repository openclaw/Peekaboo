---
summary: 'Review Peekaboo Playground Testing Methodology guidance'
read_when:
  - 'planning work related to peekaboo playground testing methodology'
  - 'debugging or extending features described here'
---

# Peekaboo Playground Testing Methodology

## Overview

The Playground app (`Apps/Playground`) is a dedicated test harness for validating Peekaboo's CLI commands. It provides a controlled environment with various UI elements and comprehensive logging to verify that automation commands work correctly.

## Testing Philosophy

When testing Peekaboo CLI tools with the Playground app, we follow a systematic approach that goes beyond basic functionality testing. The goal is to:

1. **Discover edge cases and bugs** before users encounter them
2. **Validate parameter naming consistency** across commands
3. **Ensure commands work as documented**
4. **Identify opportunities for API improvements**

## Comprehensive Testing Process

### 1. Pre-Testing Setup

Before starting tests:
- Build the CLI (`pnpm run build:cli`) so you test fresh bits
- Build and launch Playground app
- Clear any previous test artifacts
- Open terminal for log monitoring
- Run `peekaboo visualizer` with Peekaboo.app open to confirm visual feedback is working (treat this as part of the pre-flight check).

### 2. For Each Command

#### A. Documentation Review
```bash
# Always start with help documentation
./scripts/peekaboo-wait.sh <command> --help

# Review what parameters are available
# Note any confusing or inconsistent naming
```

#### B. Source Code Analysis
- Read the command implementation in `Apps/CLI/Sources/peekaboo/Commands/`
- Understand:
  - Expected parameter types and formats
  - Error handling logic
  - Dependencies on other services
  - Any special behaviors or edge cases

#### C. Basic Functionality Testing
```bash
# Test the primary use case
./scripts/peekaboo-wait.sh <command> <basic-args>

# Verify in logs
./Apps/Playground/scripts/playground-log.sh -n 20
```

#### D. Parameter Variation Testing
Test all parameter combinations:
- Required vs optional parameters
- Different parameter formats (if applicable)
- Conflicting parameters
- Missing required parameters
- Invalid parameter values

#### E. Edge Case Testing
- Empty values
- Special characters in strings
- Very large values
- Negative values (where applicable)
- Unicode/emoji in text inputs
- Quoted strings with spaces

#### F. Error Handling Validation
- Test commands without required setup (e.g., no active session)
- Test with non-existent targets
- Test timeout scenarios
- Test permission-related failures

### 3. Log Analysis

For each test, check logs for:
- Successful execution markers
- Error messages
- Performance metrics (execution time)
- Any warnings or unexpected behaviors

```bash
# Stream logs during testing
./Apps/Playground/scripts/playground-log.sh -f

# Or check recent logs
./Apps/Playground/scripts/playground-log.sh -n 50
```

### 4. Bug Documentation

When issues are found, document in `PLAYGROUND_TEST.md`:

```markdown
### ❌ [Command Name] - [Brief Description]

**Test Case**: `./scripts/peekaboo-wait.sh [exact command]`

**Expected**: [What should happen]

**Actual**: [What actually happened]

**Error Output**:
```
[Paste error output]
```

**Root Cause**: [Analysis of why it failed]

**Fix Applied**: [Description of fix, if any]

**Status**: [Fixed/Pending/Won't Fix]
```

### 5. Parameter Consistency Analysis

Track parameter naming inconsistencies:

```markdown
## Parameter Inconsistencies

| Command | Parameter | Expected | Suggestion |
|---------|-----------|----------|------------|
| click   | --on      | --app    | Support both for consistency |
| ...     | ...       | ...      | ... |
```

### 6. Performance Observations

Note any performance issues:
- Commands that take unusually long
- Commands with unexpected delays
- Resource-intensive operations

## Testing Tools

### Playground App Features

The Playground app provides:
- **Click Testing View**: Buttons with different states
- **Text Input View**: Various text fields for typing tests
- **Scroll Testing View**: Scrollable content areas
- **Window Testing View**: Multiple windows for window management
- **Drag & Drop View**: Drag targets
- **Menu Items**: Custom menu for menu testing
- **Keyboard View**: Keyboard shortcut testing

### Log Monitoring

```bash
# View logs with different filters
./Apps/Playground/scripts/playground-log.sh -f    # Follow logs
./Apps/Playground/scripts/playground-log.sh -n 100 # Last 100 lines
./Apps/Playground/scripts/playground-log.sh -e     # Errors only
```

### Session Management

```bash
# List recent sessions
ls -la ~/.peekaboo/snapshots/

# View session UI map
cat ~/.peekaboo/snapshots/<snapshot-id>/snapshot.json | jq .
```

## Common Testing Patterns

### 1. UI Element Interaction
```bash
# Capture UI first
./scripts/peekaboo-wait.sh see --app Playground

# Then interact with elements
./scripts/peekaboo-wait.sh click "Button Text"
./scripts/peekaboo-wait.sh type "Hello World"
```

### 2. Window Management
```bash
# List windows
./scripts/peekaboo-wait.sh list windows --app Playground

# Manipulate windows
./scripts/peekaboo-wait.sh window focus --app Playground
./scripts/peekaboo-wait.sh window minimize --app Playground
```

### 3. Menu Interaction
```bash
# Click menu items
./scripts/peekaboo-wait.sh menu click "Test Menu" "Test Action 1"
```

## Fix and Retest Cycle

When bugs are found:

1. **Analyze root cause** in source code
2. **Apply minimal fix** that addresses the issue
3. **Retest the specific case** that failed
4. **Run regression tests** on related functionality
5. **Update documentation** if behavior changed

## Testing Checklist Template

For each command, use this checklist:

```markdown
### Command: [name]

- [ ] Read --help documentation
- [ ] Review source code implementation
- [ ] Test basic functionality
- [ ] Test all parameters individually
- [ ] Test parameter combinations
- [ ] Test with missing required params
- [ ] Test with invalid values
- [ ] Test edge cases (empty, special chars, etc.)
- [ ] Test error scenarios
- [ ] Monitor logs during all tests
- [ ] Document any bugs found
- [ ] Note parameter naming issues
- [ ] Test performance characteristics
- [ ] Apply fixes if needed
- [ ] Retest after fixes
- [ ] Update test documentation
```

## Best Practices

1. **Always use the wrapper script**: `./scripts/peekaboo-wait.sh`
2. **Test incrementally**: Start simple, add complexity
3. **Document everything**: Even minor observations might be valuable
4. **Think like a user**: Would this behavior surprise someone?
5. **Consider automation**: How would this work in a script?
6. **Test combinations**: Real usage often combines multiple commands

## Continuous Improvement

The testing process itself should evolve:
- Add new test cases as bugs are discovered
- Update Playground app with new test scenarios
- Refine testing methodology based on findings
- Share learnings with the team
